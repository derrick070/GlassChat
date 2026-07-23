import Foundation
import SwiftData

@MainActor
final class MeshStore {
    static let storeExpiry: TimeInterval = 24 * 60 * 60
    static let storeCapPackets = 500

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func persist(_ packet: MeshPacket, encoded: Data) {
        purgeExpired()
        let expires = packet.createdAt.addingTimeInterval(Self.storeExpiry)
        if let existing = fetch(packetID: packet.packetID) {
            existing.data = encoded
            existing.expiresAt = expires
        } else {
            modelContext.insert(
                StoredPacket(
                    packetID: packet.packetID,
                    destinationUUID: packet.destinationUUID,
                    sourceUUID: packet.sourceUUID,
                    data: encoded,
                    createdAt: packet.createdAt,
                    expiresAt: expires
                )
            )
        }
        enforceCaps()
        try? modelContext.save()
    }

    func allPacketsOldestFirst() -> [StoredPacket] {
        purgeExpired()
        var descriptor = FetchDescriptor<StoredPacket>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func remove(packetID: UUID) {
        if let packet = fetch(packetID: packetID) {
            modelContext.delete(packet)
            try? modelContext.save()
        }
    }

    func purgeExpired() {
        let now = Date()
        let descriptor = FetchDescriptor<StoredPacket>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        for packet in all where packet.expiresAt < now {
            modelContext.delete(packet)
        }
        try? modelContext.save()
    }

    private func fetch(packetID: UUID) -> StoredPacket? {
        let id = packetID
        let descriptor = FetchDescriptor<StoredPacket>(predicate: #Predicate { $0.packetID == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func enforceCaps() {
        var descriptor = FetchDescriptor<StoredPacket>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard var all = try? modelContext.fetch(descriptor) else { return }
        while all.count > Self.storeCapPackets {
            if let oldest = all.first {
                modelContext.delete(oldest)
                all.removeFirst()
            } else {
                break
            }
        }
    }
}
