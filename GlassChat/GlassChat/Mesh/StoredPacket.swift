import Foundation
import SwiftData

@Model
final class StoredPacket {
    @Attribute(.unique) var packetID: UUID
    var destinationUUID: UUID?
    var sourceUUID: UUID
    var data: Data
    var createdAt: Date
    var expiresAt: Date

    init(
        packetID: UUID,
        destinationUUID: UUID?,
        sourceUUID: UUID,
        data: Data,
        createdAt: Date = .now,
        expiresAt: Date
    ) {
        self.packetID = packetID
        self.destinationUUID = destinationUUID
        self.sourceUUID = sourceUUID
        self.data = data
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
