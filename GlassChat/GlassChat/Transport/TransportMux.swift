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
    /// Explicit reachability set so SwiftUI observes link changes reliably.
    private(set) var onlinePeerUUIDs: Set<UUID> = []

    private var identity: LocalIdentity
    private let multipeer: MultipeerTransport
    private let ble: BLETransport
    private let router = MeshRouter()
    private let store: MeshStore
    private let modelContext: ModelContext

    private var publicKeys: [UUID: Data] = [:]
    private var displayNames: [UUID: String] = [:]
    private var keyMismatched: Set<UUID> = []

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

        // Watchers live for the mux lifetime; stop/start must not cancel them
        // or AsyncStream consumers permanently finish.
        watch(link: multipeer)
        watch(link: ble)

        multipeer.onResourceSendFailed = { [weak self] peerUUID, name in
            self?.resourceSendFailedHandler?(peerUUID, name)
        }
    }

    /// Wired by ChatService so media push dedupe can clear on send failure.
    var resourceSendFailedHandler: ((UUID, String) -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loadPinnedKeys()
        multipeer.start()
        ble.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        multipeer.stop()
        ble.stop()
        connectedPeers = []
        discoveredPeerNames = []
        onlinePeerUUIDs = []
    }

    func refreshDiscovery() {
        guard isRunning else { return }
        multipeer.refreshDiscovery()
        ble.refreshDiscovery()
    }

    func isConnected(_ uuid: UUID) -> Bool {
        onlinePeerUUIDs.contains(uuid)
    }

    func updateDisplayName(_ name: String) {
        identity.updateDisplayName(name)
        multipeer.updateDisplayName(name)
        sendAnnounceToAllLinks()
    }

    func send(_ frame: WireFrame, to peerUUIDs: [UUID], dedupeKey: String?) throws {
        var anyAccepted = false
        var lastError: Error = TransportError.noConnectedPeers

        for destination in peerUUIDs {
            do {
                try sendSealed(frame: frame, to: destination, dedupeKey: dedupeKey, persist: true, allowFlood: true)
                anyAccepted = true
            } catch {
                lastError = error
            }
        }

        guard anyAccepted else { throw lastError }
    }

    func sendDirect(_ frame: WireFrame, to peerUUID: UUID) throws {
        try sendSealed(frame: frame, to: peerUUID, dedupeKey: nil, persist: false, allowFlood: false)
    }

    func hasDirectLink(to uuid: UUID) -> Bool {
        multipeer.connectedLinkUUIDs.contains(uuid) || ble.connectedLinkUUIDs.contains(uuid)
    }

    func hasMultipeerLink(to uuid: UUID) -> Bool {
        multipeer.connectedLinkUUIDs.contains(uuid)
    }

    func sendResource(at url: URL, withName name: String, to peerUUID: UUID) throws {
        try multipeer.sendResource(at: url, withName: name, to: peerUUID)
    }

    // MARK: - Private

    private func watch(link: LinkTransport) {
        Task { [weak self] in
            guard let self else { return }
            for await event in link.linkEvents {
                await self.handleLinkEvent(event, from: link)
            }
        }
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
            let stillLinked = multipeer.connectedLinkUUIDs.contains(uuid)
                || ble.connectedLinkUUIDs.contains(uuid)
            if !stillLinked {
                connectedPeers.removeAll { $0.uuid == uuid }
                eventContinuation.yield(.peerDisconnected(uuid))
            }
            refreshOnlinePeers()
        case .dataReceived(let data, let from):
            await onData(data, from: from)
        case .resourceReceived(let name, let localURL, let from):
            eventContinuation.yield(.resourceReceived(name: name, localURL: localURL, from: from))
        }
    }

    private func onLinkUp(_ uuid: UUID) async {
        refreshOnlinePeers()
        sendAnnounce(to: uuid)
        replayStore(to: uuid)
    }

    private func onData(_ data: Data, from linkUUID: UUID) async {
        guard let packet = try? MeshPacket.decode(from: data) else { return }

        if packet.kind == .announce, linkUUID != packet.sourceUUID {
            ble.remapProvisionalLink(from: linkUUID, to: packet.sourceUUID)
        }

        let effectiveFrom = packet.kind == .announce ? packet.sourceUUID : linkUUID

        switch router.handleInbound(
            packet: packet,
            encoded: data,
            fromLink: effectiveFrom,
            myUUID: identity.peerUUID
        ) {
        case .ignore:
            break
        case .announce(let payload, let from):
            handleAnnounce(payload, from: from)
        case .deliverSealed(let sealed):
            await deliverSealed(sealed)
        case .relay(let action):
            store.persist(action.packet, encoded: action.encoded)
            if action.shouldBroadcast {
                broadcast(action.encoded, excluding: action.excludeLink)
            }
        }
    }

    private func handleAnnounce(_ payload: AnnouncePayload, from uuid: UUID) {
        if let pinned = publicKeys[uuid], pinned != payload.publicKey {
            keyMismatched.insert(uuid)
            persistKeyMismatch(uuid: uuid, displayName: payload.displayName)
            refreshOnlinePeers()
            print("GlassChat: TOFU key mismatch for \(uuid) — peer marked unreachable")
            return
        }
        keyMismatched.remove(uuid)
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
        refreshOnlinePeers()
        eventContinuation.yield(.peerConnected(peer))
    }

    private func deliverSealed(_ packet: MeshPacket) async {
        guard let theirKey = publicKeys[packet.sourceUUID] else { return }
        let aad = uuidData(packet.packetID) + uuidData(packet.sourceUUID) + uuidData(identity.peerUUID)
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

    private func sendSealed(
        frame: WireFrame,
        to destination: UUID,
        dedupeKey: String?,
        persist: Bool,
        allowFlood: Bool
    ) throws {
        guard let theirKey = publicKeys[destination] else {
            throw TransportError.missingPeerKey
        }
        let plaintext = try frame.encode()
        let seed = "\(dedupeKey ?? UUID().uuidString)|\(destination.uuidString)"
        let packetID = UUID.deterministic(from: seed)
        let aad = uuidData(packetID) + uuidData(identity.peerUUID) + uuidData(destination)
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
            ttl: allowFlood ? MeshRouter.maxTTL : 1
        )
        packet.packetID = packetID
        router.noteSent(packetID)
        let encoded = try packet.encode()

        let directLinks = allConnectedLinks()
        var sentDirect = false
        if directLinks.contains(destination) {
            try sendOnAnyLink(encoded, to: destination)
            sentDirect = true
        } else if allowFlood, !directLinks.isEmpty {
            broadcast(encoded, excluding: nil)
            sentDirect = true
        }

        let destinationDirect = directLinks.contains(destination)
        let skipPersist = !persist || (frame.kind == .ack && destinationDirect)
        if !skipPersist {
            store.persist(packet, encoded: encoded)
        }

        if !sentDirect, !persist {
            throw TransportError.noConnectedPeers
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
        // Snapshot value fields before the async loop — SwiftData models may be
        // deleted/faulted while we sleep between sends.
        struct Snapshot {
            let packetID: UUID
            let sourceUUID: UUID
            let destinationUUID: UUID?
            let data: Data
        }
        let snapshots: [Snapshot] = store.allPacketsOldestFirst().map {
            Snapshot(
                packetID: $0.packetID,
                sourceUUID: $0.sourceUUID,
                destinationUUID: $0.destinationUUID,
                data: $0.data
            )
        }
        Task {
            for stored in snapshots {
                if stored.sourceUUID == peerUUID { continue }
                guard var packet = try? MeshPacket.decode(from: stored.data) else { continue }
                if packet.destinationUUID == peerUUID {
                    try? await Task.sleep(for: .milliseconds(200))
                    if (try? sendOnAnyLink(stored.data, to: peerUUID)) != nil {
                        store.remove(packetID: stored.packetID)
                    }
                } else if packet.ttl > 1 {
                    packet.ttl -= 1
                    guard let encoded = try? packet.encode() else { continue }
                    try? await Task.sleep(for: .milliseconds(200))
                    try? sendOnAnyLink(encoded, to: peerUUID)
                }
                // ttl <= 1 and not addressed to this peer: do not replay.
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

    private func refreshOnlinePeers() {
        var online = Set<UUID>()
        let links = Set(allConnectedLinks())
        for uuid in links where !keyMismatched.contains(uuid) {
            online.insert(uuid)
        }
        // Mesh-reachable: we have any live link and a TOFU key for the peer.
        if !links.isEmpty {
            for (uuid, _) in publicKeys where !keyMismatched.contains(uuid) {
                online.insert(uuid)
            }
        }
        onlinePeerUUIDs = online
    }

    private func loadPinnedKeys() {
        let descriptor = FetchDescriptor<Peer>()
        guard let peers = try? modelContext.fetch(descriptor) else { return }
        for peer in peers {
            if let key = peer.publicKey {
                publicKeys[peer.uuid] = key
            }
            displayNames[peer.uuid] = peer.displayName
            if peer.keyMismatchAt != nil {
                keyMismatched.insert(peer.uuid)
            }
        }
    }

    private func persistPeer(uuid: UUID, displayName: String, publicKey: Data?) {
        let id = uuid
        let descriptor = FetchDescriptor<Peer>(predicate: #Predicate { $0.uuid == id })
        if let peer = try? modelContext.fetch(descriptor).first {
            peer.displayName = displayName
            peer.lastSeenAt = .now
            peer.keyMismatchAt = nil
            if peer.publicKey == nil {
                peer.publicKey = publicKey
            }
        } else {
            modelContext.insert(Peer(uuid: uuid, displayName: displayName, publicKey: publicKey))
        }
        try? modelContext.save()
    }

    private func persistKeyMismatch(uuid: UUID, displayName: String) {
        let id = uuid
        let descriptor = FetchDescriptor<Peer>(predicate: #Predicate { $0.uuid == id })
        if let peer = try? modelContext.fetch(descriptor).first {
            peer.displayName = displayName
            peer.keyMismatchAt = .now
            peer.lastSeenAt = .now
        } else {
            let peer = Peer(uuid: uuid, displayName: displayName)
            peer.keyMismatchAt = .now
            modelContext.insert(peer)
        }
        try? modelContext.save()
    }

    private func uuidData(_ uuid: UUID) -> Data {
        var data = Data()
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        return data
    }
}
