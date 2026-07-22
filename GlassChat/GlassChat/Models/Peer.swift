import Foundation
import SwiftData

@Model
final class Peer {
    @Attribute(.unique) var uuid: UUID
    var displayName: String
    var lastSeenAt: Date

    init(uuid: UUID, displayName: String, lastSeenAt: Date = .now) {
        self.uuid = uuid
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
    }
}
