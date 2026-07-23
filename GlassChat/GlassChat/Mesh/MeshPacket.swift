import Foundation

struct AnnouncePayload: Codable, Equatable, Sendable {
    var displayName: String
    var publicKey: Data
}

struct MeshPacket: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case announce
        case sealed
    }

    var version: UInt8
    var packetID: UUID
    var sourceUUID: UUID
    var destinationUUID: UUID?
    var ttl: UInt8
    var createdAt: Date
    var kind: Kind
    var payload: Data

    static let currentVersion: UInt8 = 1
    static let defaultTTL: UInt8 = 6

    static func announce(
        sourceUUID: UUID,
        displayName: String,
        publicKey: Data
    ) throws -> MeshPacket {
        let payload = try JSONEncoder.wire.encode(
            AnnouncePayload(displayName: displayName, publicKey: publicKey)
        )
        return MeshPacket(
            version: currentVersion,
            packetID: UUID(),
            sourceUUID: sourceUUID,
            destinationUUID: nil,
            ttl: 1,
            createdAt: .now,
            kind: .announce,
            payload: payload
        )
    }

    static func sealed(
        sourceUUID: UUID,
        destinationUUID: UUID,
        ciphertext: Data,
        ttl: UInt8 = defaultTTL
    ) -> MeshPacket {
        MeshPacket(
            version: currentVersion,
            packetID: UUID(),
            sourceUUID: sourceUUID,
            destinationUUID: destinationUUID,
            ttl: ttl,
            createdAt: .now,
            kind: .sealed,
            payload: ciphertext
        )
    }

    func encode() throws -> Data {
        try JSONEncoder.wire.encode(self)
    }

    static func decode(from data: Data) throws -> MeshPacket {
        try JSONDecoder.wire.decode(MeshPacket.self, from: data)
    }
}
