import XCTest
import SwiftData
@testable import GlassChat

@MainActor
final class ChatServiceTests: XCTestCase {
    func testIdempotentMessageInsert() throws {
        let container = try ModelContainer(
            for: Peer.self, Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let identity = LocalIdentity.loadOrCreate()
        let transport = MultipeerTransport(identity: identity)
        let service = ChatService(modelContext: context, transport: transport, identity: identity)

        let peerUUID = UUID()
        let chatID = UUID.deterministic(
            from: [identity.peerUUID.uuidString, peerUUID.uuidString].sorted().joined(separator: "|")
        )
        let messageID = UUID()
        let frame = WireFrame.message(
            senderUUID: peerUUID,
            messageID: messageID,
            chatID: chatID,
            text: "ping",
            sentAt: .now,
            sequence: 1
        )

        // Simulate two deliveries of the same frame.
        service.exposeHandle(frame: frame, from: peerUUID)
        service.exposeHandle(frame: frame, from: peerUUID)

        let messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "ping")
    }

    func testAckMarksDeliveredForDirectChat() throws {
        let container = try ModelContainer(
            for: Peer.self, Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let identity = LocalIdentity.loadOrCreate()
        let transport = MultipeerTransport(identity: identity)
        let service = ChatService(modelContext: context, transport: transport, identity: identity)

        let peer = ConnectedPeer(uuid: UUID(), displayName: "Sam")
        let chat = service.openOrCreateDirectChat(with: peer)
        let message = Message(
            id: UUID(),
            senderUUID: identity.peerUUID,
            text: "hi",
            sequence: 1,
            status: .sent,
            isFromMe: true,
            chat: chat
        )
        context.insert(message)
        try context.save()

        let ack = WireFrame.ack(senderUUID: peer.uuid, ackedMessageID: message.id)
        service.exposeHandle(frame: ack, from: peer.uuid)

        XCTAssertEqual(message.status, .delivered)
        XCTAssertTrue(message.ackedBy.contains(peer.uuid))
    }
}

extension ChatService {
    /// Test seam — production code uses the transport event stream.
    func exposeHandle(frame: WireFrame, from sender: UUID) {
        // Mirror private handle via a package-visible helper.
        testHandle(frame: frame, from: sender)
    }
}
