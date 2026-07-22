import XCTest
@testable import GlassChat

final class WireFrameTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let frame = WireFrame.hello(senderUUID: UUID(), displayName: "Alex")
        let data = try frame.encode()
        let decoded = try WireFrame.decode(from: data)
        XCTAssertEqual(decoded.kind, .hello)
        XCTAssertEqual(decoded.displayName, "Alex")
        XCTAssertEqual(decoded.senderUUID, frame.senderUUID)
    }

    func testMessageRoundTrip() throws {
        let id = UUID()
        let chatID = UUID()
        let sender = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = WireFrame.message(
            senderUUID: sender,
            messageID: id,
            chatID: chatID,
            text: "hello offline",
            sentAt: sentAt,
            sequence: 3,
            groupInfo: GroupInfo(name: "Crew", memberUUIDs: [sender, UUID()])
        )
        let decoded = try WireFrame.decode(from: try frame.encode())
        XCTAssertEqual(decoded.kind, .message)
        XCTAssertEqual(decoded.messageID, id)
        XCTAssertEqual(decoded.chatID, chatID)
        XCTAssertEqual(decoded.text, "hello offline")
        XCTAssertEqual(decoded.sequence, 3)
        XCTAssertEqual(decoded.groupInfo?.name, "Crew")
    }

    func testAckRoundTrip() throws {
        let acked = UUID()
        let frame = WireFrame.ack(senderUUID: UUID(), ackedMessageID: acked)
        let decoded = try WireFrame.decode(from: try frame.encode())
        XCTAssertEqual(decoded.kind, .ack)
        XCTAssertEqual(decoded.ackedMessageID, acked)
    }

    func testDeterministicDirectChatID() {
        let a = UUID()
        let b = UUID()
        let seed1 = [a.uuidString, b.uuidString].sorted().joined(separator: "|")
        let seed2 = [b.uuidString, a.uuidString].sorted().joined(separator: "|")
        XCTAssertEqual(UUID.deterministic(from: seed1), UUID.deterministic(from: seed2))
        XCTAssertNotEqual(UUID.deterministic(from: seed1), UUID.deterministic(from: "other"))
    }
}
