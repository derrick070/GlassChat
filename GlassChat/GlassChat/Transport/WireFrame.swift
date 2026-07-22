import Foundation

struct GroupInfo: Codable, Equatable, Sendable {
    var name: String
    var memberUUIDs: [UUID]
}

struct WireFrame: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case message
        case ack
    }

    var kind: Kind
    var senderUUID: UUID

    // hello
    var displayName: String?

    // message
    var messageID: UUID?
    var chatID: UUID?
    var groupInfo: GroupInfo?
    var text: String?
    var sentAt: Date?
    var sequence: Int64?

    // ack
    var ackedMessageID: UUID?

    static func hello(senderUUID: UUID, displayName: String) -> WireFrame {
        WireFrame(kind: .hello, senderUUID: senderUUID, displayName: displayName)
    }

    static func message(
        senderUUID: UUID,
        messageID: UUID,
        chatID: UUID,
        text: String,
        sentAt: Date,
        sequence: Int64,
        groupInfo: GroupInfo? = nil
    ) -> WireFrame {
        WireFrame(
            kind: .message,
            senderUUID: senderUUID,
            messageID: messageID,
            chatID: chatID,
            groupInfo: groupInfo,
            text: text,
            sentAt: sentAt,
            sequence: sequence
        )
    }

    static func ack(senderUUID: UUID, ackedMessageID: UUID) -> WireFrame {
        WireFrame(kind: .ack, senderUUID: senderUUID, ackedMessageID: ackedMessageID)
    }

    func encode() throws -> Data {
        try JSONEncoder.wire.encode(self)
    }

    static func decode(from data: Data) throws -> WireFrame {
        try JSONDecoder.wire.decode(WireFrame.self, from: data)
    }
}

extension JSONEncoder {
    static let wire: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let wire: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
