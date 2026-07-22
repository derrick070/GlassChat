import Foundation

struct ConnectedPeer: Identifiable, Equatable, Sendable {
    var id: UUID { uuid }
    let uuid: UUID
    var displayName: String
}

enum TransportEvent: Sendable {
    case peerConnected(ConnectedPeer)
    case peerDisconnected(UUID)
    case frameReceived(WireFrame, from: UUID)
}
