import XCTest
import SwiftData
@testable import GlassChat

@MainActor
final class ChatServiceTests: XCTestCase {
    private func makeService() throws -> (ChatService, ModelContext, MultipeerTransport) {
        let container = try ModelContainer(
            for: Peer.self, Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let identity = LocalIdentity.loadOrCreate()
        let transport = MultipeerTransport(identity: identity)
        let service = ChatService(modelContext: context, transport: transport)
        return (service, context, transport)
    }

    func testIdempotentMessageInsert() throws {
        let (service, context, _) = try makeService()
        let peerUUID = UUID()
        let chatID = UUID.deterministic(
            from: [service.localUUID.uuidString, peerUUID.uuidString].sorted().joined(separator: "|")
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

        service.testHandle(frame: frame, from: peerUUID)
        service.testHandle(frame: frame, from: peerUUID)

        let messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "ping")
    }

    func testAckMarksDeliveredForDirectChat() throws {
        let (service, context, _) = try makeService()
        let peer = ConnectedPeer(uuid: UUID(), displayName: "Sam")
        let chat = service.openOrCreateDirectChat(with: peer)
        let message = Message(
            id: UUID(),
            senderUUID: service.localUUID,
            text: "hi",
            sequence: 1,
            status: .sent,
            isFromMe: true,
            chat: chat
        )
        context.insert(message)
        try context.save()

        let ack = WireFrame.ack(senderUUID: peer.uuid, ackedMessageID: message.id)
        service.testHandle(frame: ack, from: peer.uuid)

        XCTAssertEqual(message.status, .delivered)
        XCTAssertTrue(message.ackedBy.contains(peer.uuid))
    }

    func testActiveChatDoesNotIncrementUnread() throws {
        let (service, context, _) = try makeService()
        let peerUUID = UUID()
        let chatID = UUID.deterministic(
            from: [service.localUUID.uuidString, peerUUID.uuidString].sorted().joined(separator: "|")
        )
        service.setActiveChat(chatID)

        let frame = WireFrame.message(
            senderUUID: peerUUID,
            messageID: UUID(),
            chatID: chatID,
            text: "while open",
            sentAt: .now,
            sequence: 1
        )
        service.testHandle(frame: frame, from: peerUUID)

        let chat = try context.fetch(FetchDescriptor<Chat>()).first
        XCTAssertEqual(chat?.unreadCount, 0)
    }
}
