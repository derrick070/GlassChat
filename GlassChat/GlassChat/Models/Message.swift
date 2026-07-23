import Foundation
import SwiftData

enum DeliveryStatus: String, Codable {
    case pending
    case sent
    case delivered
    case failed
}

enum MediaKind: String, Codable {
    case image
}

enum MediaTransferStatus: String, Codable {
    case none
    case pending
    case transferring
    case ready
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

    // Optional media (image) fields — nil/empty for text-only messages.
    var mediaKindRaw: String? = nil
    var blobIDHex: String? = nil
    var blobKeyData: Data? = nil
    var thumbnailData: Data? = nil
    var mediaMime: String? = nil
    var mediaByteCount: Int = 0
    var mediaWidth: Int = 0
    var mediaHeight: Int = 0
    var chunkCount: Int = 0
    var mediaTransferRaw: String? = nil

    var status: DeliveryStatus {
        get { DeliveryStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var mediaKind: MediaKind? {
        get {
            guard let mediaKindRaw else { return nil }
            return MediaKind(rawValue: mediaKindRaw)
        }
        set { mediaKindRaw = newValue?.rawValue }
    }

    var mediaTransfer: MediaTransferStatus {
        get {
            guard let mediaTransferRaw else { return .none }
            return MediaTransferStatus(rawValue: mediaTransferRaw) ?? .none
        }
        set { mediaTransferRaw = newValue == .none ? nil : newValue.rawValue }
    }

    var isImage: Bool { mediaKind == .image }

    init(
        id: UUID = UUID(),
        senderUUID: UUID,
        text: String,
        sentAt: Date = .now,
        sequence: Int64,
        status: DeliveryStatus = .pending,
        isFromMe: Bool,
        ackedBy: [UUID] = [],
        chat: Chat? = nil,
        mediaKind: MediaKind? = nil,
        blobIDHex: String? = nil,
        blobKeyData: Data? = nil,
        thumbnailData: Data? = nil,
        mediaMime: String? = nil,
        mediaByteCount: Int = 0,
        mediaWidth: Int = 0,
        mediaHeight: Int = 0,
        chunkCount: Int = 0,
        mediaTransfer: MediaTransferStatus = .none
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
        self.mediaKindRaw = mediaKind?.rawValue
        self.blobIDHex = blobIDHex
        self.blobKeyData = blobKeyData
        self.thumbnailData = thumbnailData
        self.mediaMime = mediaMime
        self.mediaByteCount = mediaByteCount
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.chunkCount = chunkCount
        self.mediaTransferRaw = mediaTransfer == .none ? nil : mediaTransfer.rawValue
    }
}
