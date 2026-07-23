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
        case imageOffer
        case blobRequest
        case blobChunk
    }

    var kind: Kind
    var senderUUID: UUID

    // hello
    var displayName: String? = nil

    // message / imageOffer
    var messageID: UUID? = nil
    var chatID: UUID? = nil
    var groupInfo: GroupInfo? = nil
    var text: String? = nil
    var sentAt: Date? = nil
    var sequence: Int64? = nil

    // ack
    var ackedMessageID: UUID? = nil

    // imageOffer / blob*
    var blobIDHex: String? = nil
    var blobKeyData: Data? = nil
    var mimeType: String? = nil
    var byteCount: Int? = nil
    var chunkCount: Int? = nil
    var width: Int? = nil
    var height: Int? = nil
    var thumbnailData: Data? = nil

    // blobRequest
    var missingChunkIndexes: [Int]? = nil

    // blobChunk
    var chunkIndex: Int? = nil
    var chunkData: Data? = nil

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

    static func imageOffer(
        senderUUID: UUID,
        messageID: UUID,
        chatID: UUID,
        text: String,
        sentAt: Date,
        sequence: Int64,
        blobIDHex: String,
        blobKeyData: Data,
        mimeType: String,
        byteCount: Int,
        chunkCount: Int,
        width: Int,
        height: Int,
        thumbnailData: Data,
        groupInfo: GroupInfo? = nil
    ) -> WireFrame {
        WireFrame(
            kind: .imageOffer,
            senderUUID: senderUUID,
            messageID: messageID,
            chatID: chatID,
            groupInfo: groupInfo,
            text: text,
            sentAt: sentAt,
            sequence: sequence,
            blobIDHex: blobIDHex,
            blobKeyData: blobKeyData,
            mimeType: mimeType,
            byteCount: byteCount,
            chunkCount: chunkCount,
            width: width,
            height: height,
            thumbnailData: thumbnailData
        )
    }

    static func blobRequest(
        senderUUID: UUID,
        blobIDHex: String,
        missingChunkIndexes: [Int]
    ) -> WireFrame {
        WireFrame(
            kind: .blobRequest,
            senderUUID: senderUUID,
            blobIDHex: blobIDHex,
            missingChunkIndexes: missingChunkIndexes
        )
    }

    static func blobChunk(
        senderUUID: UUID,
        blobIDHex: String,
        chunkIndex: Int,
        chunkCount: Int,
        chunkData: Data
    ) -> WireFrame {
        WireFrame(
            kind: .blobChunk,
            senderUUID: senderUUID,
            blobIDHex: blobIDHex,
            chunkCount: chunkCount,
            chunkIndex: chunkIndex,
            chunkData: chunkData
        )
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
