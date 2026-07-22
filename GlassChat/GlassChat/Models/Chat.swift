import Foundation
import SwiftData

enum ChatKind: String, Codable {
    case direct
    case group
}

@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var name: String
    var memberUUIDs: [UUID]
    var createdAt: Date
    var lastMessageAt: Date
    var unreadCount: Int

    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message]

    var kind: ChatKind {
        get { ChatKind(rawValue: kindRaw) ?? .direct }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: ChatKind,
        name: String,
        memberUUIDs: [UUID],
        createdAt: Date = .now,
        lastMessageAt: Date = .now,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.memberUUIDs = memberUUIDs
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.messages = []
    }
}
