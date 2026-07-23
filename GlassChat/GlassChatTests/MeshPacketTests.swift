import XCTest
@testable import GlassChat

final class MeshPacketTests: XCTestCase {
    func testAnnounceRoundTrip() throws {
        let packet = try MeshPacket.announce(
            sourceUUID: UUID(),
            displayName: "Ada",
            publicKey: Data(repeating: 1, count: 32)
        )
        let data = try packet.encode()
        let decoded = try MeshPacket.decode(from: data)
        XCTAssertEqual(decoded.kind, .announce)
        XCTAssertEqual(decoded.ttl, 1)
        let payload = try JSONDecoder.wire.decode(AnnouncePayload.self, from: decoded.payload)
        XCTAssertEqual(payload.displayName, "Ada")
    }

    func testFragmentReassembly() async {
        let payload = Data(repeating: 7, count: 500)
        let parts = BLEFragmenter.fragment(payload, mtu: 100)
        XCTAssertGreaterThan(parts.count, 1)
        let reassembler = await MainActor.run { BLEReassembler() }
        var result: Data?
        for part in parts {
            result = await MainActor.run { reassembler.ingest(part) }
        }
        XCTAssertEqual(result, payload)
    }
}
