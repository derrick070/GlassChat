import Foundation
import MultipeerConnectivity
import Observation

/// Multipeer Connectivity link: carries opaque `MeshPacket` bytes for the mesh mux.
@Observable
@MainActor
final class MultipeerTransport: NSObject, LinkTransport {
    static let serviceType = "glass-chat"

    private(set) var connectedLinkUUIDs: [UUID] = []
    private(set) var discoveredPeerNames: [String] = []
    private(set) var isRunning = false

    private var identity: LocalIdentity
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    private var mcPeerToUUID: [MCPeerID: UUID] = [:]
    private var uuidToMCPeer: [UUID: MCPeerID] = [:]
    private var discoveredUUIDByPeer: [MCPeerID: UUID] = [:]
    private var pendingInvites: Set<MCPeerID> = []

    private static let inviteTimeout: TimeInterval = 30

    private let linkContinuation: AsyncStream<LinkEvent>.Continuation
    let linkEvents: AsyncStream<LinkEvent>

    init(identity: LocalIdentity) {
        self.identity = identity
        var continuation: AsyncStream<LinkEvent>.Continuation!
        self.linkEvents = AsyncStream { continuation = $0 }
        self.linkContinuation = continuation
        super.init()
        configureSession()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginDiscovery()
    }

    func refreshDiscovery() {
        guard isRunning else { return }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        beginDiscovery()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedLinkUUIDs = []
        discoveredPeerNames = []
        mcPeerToUUID.removeAll()
        uuidToMCPeer.removeAll()
        discoveredUUIDByPeer.removeAll()
        pendingInvites.removeAll()
        configureSession()
    }

    func send(_ data: Data, to peerUUID: UUID) throws {
        guard let peer = uuidToMCPeer[peerUUID] else {
            throw TransportError.noConnectedPeers
        }
        try session.send(data, toPeers: [peer], with: .reliable)
    }

    func broadcast(_ data: Data, excluding: UUID?) {
        let targets = connectedLinkUUIDs.filter { $0 != excluding }.compactMap { uuidToMCPeer[$0] }
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
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

    private func beginDiscovery() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    private func scheduleInvite(to peerID: MCPeerID, remoteUUID: UUID) {
        guard isRunning else { return }
        guard identity.peerUUID.uuidString < remoteUUID.uuidString else { return }
        guard !pendingInvites.contains(peerID),
              !session.connectedPeers.contains(peerID) else { return }
        guard session.connectedPeers.count < 7 else { return }

        pendingInvites.insert(peerID)
        let context = identity.peerUUID.uuidString.data(using: .utf8)
        browser.invitePeer(peerID, to: session, withContext: context, timeout: Self.inviteTimeout)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.inviteTimeout + 1))
            pendingInvites.remove(peerID)
            if isRunning, !session.connectedPeers.contains(peerID) {
                refreshDiscovery()
            }
        }
    }

    private func register(uuid: UUID, mcPeerID: MCPeerID) {
        mcPeerToUUID[mcPeerID] = uuid
        uuidToMCPeer[uuid] = mcPeerID
        if !connectedLinkUUIDs.contains(uuid) {
            connectedLinkUUIDs.append(uuid)
            linkContinuation.yield(.linkUp(uuid))
        }
    }

    private func handleDisconnect(from peerID: MCPeerID) {
        if let uuid = mcPeerToUUID.removeValue(forKey: peerID) {
            uuidToMCPeer.removeValue(forKey: uuid)
            connectedLinkUUIDs.removeAll { $0 == uuid }
            linkContinuation.yield(.linkDown(uuid))
        }
        pendingInvites.remove(peerID)
    }
}

enum TransportError: Error {
    case noConnectedPeers
    case missingPeerKey
    case cryptoFailed
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
                if let uuid = discoveredUUIDByPeer[peerID] ?? mcPeerToUUID[peerID] {
                    register(uuid: uuid, mcPeerID: peerID)
                }
            case .notConnected:
                handleDisconnect(from: peerID)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            guard let uuid = mcPeerToUUID[peerID] ?? discoveredUUIDByPeer[peerID] else { return }
            linkContinuation.yield(.dataReceived(data, from: uuid))
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
            if let context,
               let string = String(data: context, encoding: .utf8),
               let uuid = UUID(uuidString: string) {
                discoveredUUIDByPeer[peerID] = uuid
            }
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
                linkContinuation.yield(.discoveredName(peerID.displayName))
            }
            guard let uuidString = info?["uuid"], let remoteUUID = UUID(uuidString: uuidString) else {
                return
            }
            discoveredUUIDByPeer[peerID] = remoteUUID
            scheduleInvite(to: peerID, remoteUUID: remoteUUID)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            discoveredPeerNames.removeAll { $0 == peerID.displayName }
            discoveredUUIDByPeer.removeValue(forKey: peerID)
            pendingInvites.remove(peerID)
        }
    }
}
