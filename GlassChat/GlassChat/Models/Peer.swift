import Foundation
import SwiftData

@Model
final class Peer {
    @Attribute(.unique) var uuid: UUID
    var displayName: String
    var lastSeenAt: Date
    /// TOFU-pinned Curve25519 public key (32 bytes).
    var publicKey: Data?

    init(uuid: UUID, displayName: String, lastSeenAt: Date = .now, publicKey: Data? = nil) {
        self.uuid = uuid
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.publicKey = publicKey
    }
}
