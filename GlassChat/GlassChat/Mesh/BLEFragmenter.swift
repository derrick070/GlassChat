import Foundation

enum BLEFragmenter {
    static let headerSize = 20 // 16 UUID + 2 index + 2 total

    static func fragment(_ data: Data, mtu: Int) -> [Data] {
        let chunkSize = max(1, mtu - headerSize)
        let total = Int(ceil(Double(data.count) / Double(chunkSize)))
        let fragmentID = UUID()
        var parts: [Data] = []
        parts.reserveCapacity(total)
        for index in 0..<total {
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            var packet = Data()
            withUnsafeBytes(of: fragmentID.uuid) { packet.append(contentsOf: $0) }
            var idx = UInt16(index).bigEndian
            var tot = UInt16(total).bigEndian
            withUnsafeBytes(of: &idx) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: &tot) { packet.append(contentsOf: $0) }
            packet.append(data[start..<end])
            parts.append(packet)
        }
        return parts
    }
}

@MainActor
final class BLEReassembler {
    private struct Buffer {
        var total: Int
        var parts: [Int: Data]
        var createdAt: Date
    }

    private var buffers: [UUID: Buffer] = [:]
    private let timeout: TimeInterval = 30

    func ingest(_ fragment: Data) -> Data? {
        purgeExpired()
        guard fragment.count >= BLEFragmenter.headerSize else { return nil }

        let uuidBytes = Array(fragment.prefix(16))
        guard let fragmentID = uuidFromBytes(uuidBytes) else { return nil }
        let index = Int(UInt16(bigEndian: fragment.subdata(in: 16..<18).withUnsafeBytes { $0.load(as: UInt16.self) }))
        let total = Int(UInt16(bigEndian: fragment.subdata(in: 18..<20).withUnsafeBytes { $0.load(as: UInt16.self) }))
        guard total > 0, index < total else { return nil }

        let payload = fragment.suffix(from: BLEFragmenter.headerSize)
        var buffer = buffers[fragmentID] ?? Buffer(total: total, parts: [:], createdAt: .now)
        buffer.total = total
        buffer.parts[index] = Data(payload)
        buffers[fragmentID] = buffer

        guard buffer.parts.count == total else { return nil }
        var assembled = Data()
        for i in 0..<total {
            guard let part = buffer.parts[i] else { return nil }
            assembled.append(part)
        }
        buffers.removeValue(forKey: fragmentID)
        return assembled
    }

    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-timeout)
        buffers = buffers.filter { $0.value.createdAt >= cutoff }
    }

    private func uuidFromBytes(_ bytes: [UInt8]) -> UUID? {
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
