import Foundation

/// High-level transport consumed by `ChatService` (frames in/out, peer list).
@MainActor
protocol ChatTransport: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    var connectedPeers: [ConnectedPeer] { get }
    var discoveredPeerNames: [String] { get }
    var isRunning: Bool { get }
    var peerUUID: UUID { get }
    var displayName: String { get }
    var shortID: String { get }
    func start()
    func stop()
    func refreshDiscovery()
    func send(_ frame: WireFrame, to peerUUIDs: [UUID], dedupeKey: String?) throws
    func isConnected(_ uuid: UUID) -> Bool
    func updateDisplayName(_ name: String)
}

extension ChatTransport {
    func send(_ frame: WireFrame, to peerUUIDs: [UUID]) throws {
        try send(frame, to: peerUUIDs, dedupeKey: nil)
    }
}

enum LinkEvent: Sendable {
    case linkUp(UUID)
    case linkDown(UUID)
    case dataReceived(Data, from: UUID)
    case discoveredName(String)
}

/// Low-level link that carries opaque `MeshPacket` bytes.
@MainActor
protocol LinkTransport: AnyObject {
    var linkEvents: AsyncStream<LinkEvent> { get }
    var connectedLinkUUIDs: [UUID] { get }
    func start()
    func stop()
    func refreshDiscovery()
    func send(_ data: Data, to peerUUID: UUID) throws
    func broadcast(_ data: Data, excluding: UUID?)
}
