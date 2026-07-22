import Foundation
import MultipeerConnectivity
import Observation

struct TransportPeerBinding: Equatable {
    let uuid: UUID
    let displayName: String
    let mcPeerID: MCPeerID
}

@Observable
@MainActor
final class MultipeerTransport: NSObject {
    static let serviceType = "glass-chat"

    private(set) var connectedPeers: [ConnectedPeer] = []
    private(set) var discoveredPeerNames: [String] = []
    private(set) var isRunning = false

    private var identity: LocalIdentity
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    private var mcPeerToUUID: [MCPeerID: UUID] = [:]
    private var uuidToMCPeer: [UUID: MCPeerID] = [:]
    private var pendingInvites: Set<MCPeerID> = []
    private var helloSent: Set<MCPeerID> = []

    private let eventContinuation: AsyncStream<TransportEvent>.Continuation
    let events: AsyncStream<TransportEvent>

    init(identity: LocalIdentity) {
        self.identity = identity
        var continuation: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
        super.init()
        configureSession()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedPeers = []
        discoveredPeerNames = []
        mcPeerToUUID.removeAll()
        uuidToMCPeer.removeAll()
        pendingInvites.removeAll()
        helloSent.removeAll()
        configureSession()
    }

    func send(_ frame: WireFrame, to peerUUIDs: [UUID]) throws {
        let targets = peerUUIDs.compactMap { uuidToMCPeer[$0] }
        guard !targets.isEmpty else {
            throw TransportError.noConnectedPeers
        }
        let data = try frame.encode()
        try session.send(data, toPeers: targets, with: .reliable)
    }

    func isConnected(_ uuid: UUID) -> Bool {
        uuidToMCPeer[uuid] != nil
    }

    func updateDisplayName(_ name: String) {
        identity.updateDisplayName(name)
    }

    private func configureSession() {
        session = MCSession(
            peer: identity.mcPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(
            peer: identity.mcPeerID,
            discoveryInfo: ["uuid": identity.peerUUID.uuidString],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self

        browser = MCNearbyServiceBrowser(peer: identity.mcPeerID, serviceType: Self.serviceType)
        browser.delegate = self
    }

    private func sendHello(to peer: MCPeerID) {
        guard !helloSent.contains(peer) else { return }
        helloSent.insert(peer)
        let frame = WireFrame.hello(senderUUID: identity.peerUUID, displayName: identity.displayName)
        guard let data = try? frame.encode() else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func register(uuid: UUID, displayName: String, mcPeerID: MCPeerID) {
        mcPeerToUUID[mcPeerID] = uuid
        uuidToMCPeer[uuid] = mcPeerID
        let peer = ConnectedPeer(uuid: uuid, displayName: displayName)
        if let index = connectedPeers.firstIndex(where: { $0.uuid == uuid }) {
            connectedPeers[index] = peer
        } else {
            connectedPeers.append(peer)
        }
        eventContinuation.yield(.peerConnected(peer))
    }

    private func shouldInvite(_ remoteUUID: UUID) -> Bool {
        identity.peerUUID.uuidString < remoteUUID.uuidString
    }
}

enum TransportError: Error {
    case noConnectedPeers
}

extension MultipeerTransport: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task { @MainActor in
            switch state {
            case .connected:
                sendHello(to: peerID)
            case .notConnected:
                if let uuid = mcPeerToUUID.removeValue(forKey: peerID) {
                    uuidToMCPeer.removeValue(forKey: uuid)
                    connectedPeers.removeAll { $0.uuid == uuid }
                    eventContinuation.yield(.peerDisconnected(uuid))
                }
                helloSent.remove(peerID)
                pendingInvites.remove(peerID)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            guard let frame = try? WireFrame.decode(from: data) else { return }
            switch frame.kind {
            case .hello:
                let name = frame.displayName ?? peerID.displayName
                register(uuid: frame.senderUUID, displayName: name, mcPeerID: peerID)
            case .message, .ack:
                let uuid = mcPeerToUUID[peerID] ?? frame.senderUUID
                if mcPeerToUUID[peerID] == nil {
                    register(uuid: frame.senderUUID, displayName: peerID.displayName, mcPeerID: peerID)
                }
                eventContinuation.yield(.frameReceived(frame, from: uuid))
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            invitationHandler(true, session)
        }
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor in
            if !discoveredPeerNames.contains(peerID.displayName) {
                discoveredPeerNames.append(peerID.displayName)
            }
            guard let uuidString = info?["uuid"], let remoteUUID = UUID(uuidString: uuidString) else {
                return
            }
            guard shouldInvite(remoteUUID) else { return }
            guard !pendingInvites.contains(peerID),
                  session.connectedPeers.contains(peerID) == false else { return }
            pendingInvites.insert(peerID)
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            discoveredPeerNames.removeAll { $0 == peerID.displayName }
            pendingInvites.remove(peerID)
        }
    }
}
