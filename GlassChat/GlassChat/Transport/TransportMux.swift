import Foundation
import Observation
import SwiftData

/// Multiplexes Multipeer + BLE links through the mesh router and E2E crypto.
@Observable
@MainActor
final class TransportMux: ChatTransport {
    private(set) var connectedPeers: [ConnectedPeer] = []
    private(set) var discoveredPeerNames: [String] = []
    private(set) var isRunning = false

    private var identity: LocalIdentity
    private let multipeer: MultipeerTransport
    private let ble: BLETransport
    private let router = MeshRouter()
    private let store: MeshStore
    private let modelContext: ModelContext

    private var publicKeys: [UUID: Data] = [:]
    private var displayNames: [UUID: String] = [:]
    private var linkTasks: [Task<Void, Never>] = []

    private let eventContinuation: AsyncStream<TransportEvent>.Continuation
    let events: AsyncStream<TransportEvent>

    var peerUUID: UUID { identity.peerUUID }
    var displayName: String { identity.displayName }
    var shortID: String { identity.shortID }

    init(identity: LocalIdentity, modelContext: ModelContext) {
        self.identity = identity
        self.modelContext = modelContext
        self.store = MeshStore(modelContext: modelContext)
        self.multipeer = MultipeerTransport(identity: identity)
        self.ble = BLETransport(identity: identity)

        var continuation: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loadPinnedKeys()
        multipeer.start()
        ble.start()
        watch(link: multipeer)
        watch(link: ble)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        linkTasks.forEach { $0.cancel() }
        linkTasks.removeAll()
        multipeer.stop()
        ble.stop()
        connectedPeers = []
        discoveredPeerNames = []
    }

    func refreshDiscovery() {
        guard isRunning else { return }
        multipeer.refreshDiscovery()
        ble.refreshDiscovery()
    }

    func isConnected(_ uuid: UUID) -> Bool {
        // Reachable if we have a direct link OR any mesh link (can store-and-forward).
        if multipeer.connectedLinkUUIDs.contains(uuid) || ble.connectedLinkUUIDs.contains(uuid) {
            return true
        }
        return !allConnectedLinks().isEmpty && publicKeys[uuid] != nil
    }

    func updateDisplayName(_ name: String) {
        identity.updateDisplayName(name)
        multipeer.updateDisplayName(name)
        sendAnnounceToAllLinks()
    }

    func send(_ frame: WireFrame, to peerUUIDs: [UUID]) throws {
        var anyAccepted = false
        var lastError: Error = TransportError.noConnectedPeers

        for destination in peerUUIDs {
            do {
                try sendSealed(frame: frame, to: destination)
                anyAccepted = true
            } catch {
                lastError = error
            }
        }

        guard anyAccepted else { throw lastError }
    }

    // MARK: - Private

    private func watch(link: LinkTransport) {
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in link.linkEvents {
                await self.handleLinkEvent(event, from: link)
            }
        }
        linkTasks.append(task)
    }

    private func handleLinkEvent(_ event: LinkEvent, from link: LinkTransport) async {
        switch event {
        case .discoveredName(let name):
            if !discoveredPeerNames.contains(name) {
                discoveredPeerNames.append(name)
            }
        case .linkUp(let uuid):
            await onLinkUp(uuid)
        case .linkDown(let uuid):
            // Only drop peer if no other link remains.
            let stillLinked = multipeer.connectedLinkUUIDs.contains(uuid)
                || ble.connectedLinkUUIDs.contains(uuid)
            if !stillLinked {
                connectedPeers.removeAll { $0.uuid == uuid }
                eventContinuation.yield(.peerDisconnected(uuid))
            }
        case .dataReceived(let data, let from):
            await onData(data, from: from)
        }
    }

    private func onLinkUp(_ uuid: UUID) async {
        sendAnnounce(to: uuid)
        replayStore(to: uuid)
    }

    private func onData(_ data: Data, from linkUUID: UUID) async {
        // Upgrade provisional BLE central IDs when announce arrives.
        if let packet = try? MeshPacket.decode(from: data),
           packet.kind == .announce,
           linkUUID != packet.sourceUUID {
            ble.remapProvisionalLink(from: linkUUID, to: packet.sourceUUID)
        }

        let effectiveFrom: UUID
        if let packet = try? MeshPacket.decode(from: data), packet.kind == .announce {
            effectiveFrom = packet.sourceUUID
        } else {
            effectiveFrom = linkUUID
        }

        switch router.handleInbound(data, fromLink: effectiveFrom, myUUID: identity.peerUUID) {
        case .ignore:
            // Could still be sealed for us if seen-cache path skipped — try deliver.
            if let packet = try? MeshPacket.decode(from: data),
               packet.kind == .sealed,
               packet.destinationUUID == identity.peerUUID {
                await deliverSealed(packet)
            }
        case .announce(let payload, let from):
            handleAnnounce(payload, from: from)
        case .deliverSealed(let packet):
            await deliverSealed(packet)
        case .relay(let action):
            store.persist(action.packet, encoded: action.encoded)
            if action.shouldBroadcast {
                broadcast(action.encoded, excluding: action.excludeLink)
            }
        }
    }

    private func handleAnnounce(_ payload: AnnouncePayload, from uuid: UUID) {
        if let pinned = publicKeys[uuid], pinned != payload.publicKey {
            // TOFU mismatch — reject.
            return
        }
        if publicKeys[uuid] == nil {
            publicKeys[uuid] = payload.publicKey
            persistPeer(uuid: uuid, displayName: payload.displayName, publicKey: payload.publicKey)
        } else {
            displayNames[uuid] = payload.displayName
            persistPeer(uuid: uuid, displayName: payload.displayName, publicKey: publicKeys[uuid])
        }
        displayNames[uuid] = payload.displayName

        let peer = ConnectedPeer(uuid: uuid, displayName: payload.displayName)
        if let index = connectedPeers.firstIndex(where: { $0.uuid == uuid }) {
            connectedPeers[index] = peer
        } else {
            connectedPeers.append(peer)
        }
        if !discoveredPeerNames.contains(payload.displayName) {
            discoveredPeerNames.append(payload.displayName)
        }
        eventContinuation.yield(.peerConnected(peer))
    }

    private func deliverSealed(_ packet: MeshPacket) async {
        guard let theirKey = publicKeys[packet.sourceUUID] else { return }
        let aad = uuidData(packet.packetID)
        do {
            let plaintext = try EnvelopeCrypto.open(
                ciphertext: packet.payload,
                from: theirKey,
                myPrivate: identity.crypto.privateKey,
                myUUID: identity.peerUUID,
                theirUUID: packet.sourceUUID,
                authenticatedData: aad
            )
            let frame = try WireFrame.decode(from: plaintext)
            eventContinuation.yield(.frameReceived(frame, from: packet.sourceUUID))
        } catch {
            // Decryption failure — drop.
        }
    }

    private func sendSealed(frame: WireFrame, to destination: UUID) throws {
        guard let theirKey = publicKeys[destination] else {
            throw TransportError.missingPeerKey
        }
        let plaintext = try frame.encode()
        let packetID = UUID()
        let aad = uuidData(packetID)
        let ciphertext = try EnvelopeCrypto.seal(
            plaintext: plaintext,
            to: theirKey,
            myPrivate: identity.crypto.privateKey,
            myUUID: identity.peerUUID,
            theirUUID: destination,
            authenticatedData: aad
        )
        var packet = MeshPacket.sealed(
            sourceUUID: identity.peerUUID,
            destinationUUID: destination,
            ciphertext: ciphertext,
            ttl: MeshRouter.maxTTL
        )
        packet.packetID = packetID
        let encoded = try packet.encode()

        let directLinks = allConnectedLinks()
        var sentDirect = false
        if directLinks.contains(destination) {
            try sendOnAnyLink(encoded, to: destination)
            sentDirect = true
        } else if !directLinks.isEmpty {
            // Hand to nearby relays.
            broadcast(encoded, excluding: nil)
            sentDirect = true
        }

        // Always persist so we can relay when new links appear.
        store.persist(packet, encoded: encoded)

        if !sentDirect {
            // No links at all — still stored for later; treat as accepted pending path.
            // ChatService outbox stays pending only when throw — we accept store-only.
        }
    }

    private func sendAnnounce(to uuid: UUID) {
        guard let packet = try? MeshPacket.announce(
            sourceUUID: identity.peerUUID,
            displayName: identity.displayName,
            publicKey: identity.crypto.publicKeyData
        ),
        let data = try? packet.encode() else { return }
        try? sendOnAnyLink(data, to: uuid)
    }

    private func sendAnnounceToAllLinks() {
        for uuid in allConnectedLinks() {
            sendAnnounce(to: uuid)
        }
    }

    private func replayStore(to peerUUID: UUID) {
        store.purgeExpired()
        let packets = store.allPacketsOldestFirst()
        Task {
            for stored in packets {
                if stored.sourceUUID == peerUUID { continue }
                try? await Task.sleep(for: .milliseconds(200))
                try? sendOnAnyLink(stored.data, to: peerUUID)
            }
        }
    }

    private func sendOnAnyLink(_ data: Data, to peerUUID: UUID) throws {
        if multipeer.connectedLinkUUIDs.contains(peerUUID) {
            try multipeer.send(data, to: peerUUID)
            return
        }
        if ble.connectedLinkUUIDs.contains(peerUUID) {
            try ble.send(data, to: peerUUID)
            return
        }
        // Provisional BLE links / broadcast path
        do {
            try ble.send(data, to: peerUUID)
            return
        } catch {
            throw TransportError.noConnectedPeers
        }
    }

    private func broadcast(_ data: Data, excluding: UUID?) {
        multipeer.broadcast(data, excluding: excluding)
        ble.broadcast(data, excluding: excluding)
    }

    private func allConnectedLinks() -> [UUID] {
        Array(Set(multipeer.connectedLinkUUIDs + ble.connectedLinkUUIDs))
    }

    private func loadPinnedKeys() {
        let descriptor = FetchDescriptor<Peer>()
        guard let peers = try? modelContext.fetch(descriptor) else { return }
        for peer in peers {
            if let key = peer.publicKey {
                publicKeys[peer.uuid] = key
            }
            displayNames[peer.uuid] = peer.displayName
        }
    }

    private func persistPeer(uuid: UUID, displayName: String, publicKey: Data?) {
        let id = uuid
        let descriptor = FetchDescriptor<Peer>(predicate: #Predicate { $0.uuid == id })
        if let peer = try? modelContext.fetch(descriptor).first {
            peer.displayName = displayName
            peer.lastSeenAt = .now
            if peer.publicKey == nil {
                peer.publicKey = publicKey
            }
        } else {
            modelContext.insert(Peer(uuid: uuid, displayName: displayName, publicKey: publicKey))
        }
        try? modelContext.save()
    }

    private func uuidData(_ uuid: UUID) -> Data {
        var data = Data()
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        return data
    }
}
