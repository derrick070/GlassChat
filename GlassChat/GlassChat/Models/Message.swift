import Foundation
import SwiftData

enum DeliveryStatus: String, Codable {
    case pending
    case sent
    case delivered
    case failed
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var senderUUID: UUID
    var text: String
    var sentAt: Date
    var sequence: Int64
    var statusRaw: String
    var isFromMe: Bool
    var ackedBy: [UUID]
    var chat: Chat?

    var status: DeliveryStatus {
        get { DeliveryStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        senderUUID: UUID,
        text: String,
        sentAt: Date = .now,
        sequence: Int64,
        status: DeliveryStatus = .pending,
        isFromMe: Bool,
        ackedBy: [UUID] = [],
        chat: Chat? = nil
    ) {
        self.id = id
        self.senderUUID = senderUUID
        self.text = text
        self.sentAt = sentAt
        self.sequence = sequence
        self.statusRaw = status.rawValue
        self.isFromMe = isFromMe
        self.ackedBy = ackedBy
        self.chat = chat
    }
}
