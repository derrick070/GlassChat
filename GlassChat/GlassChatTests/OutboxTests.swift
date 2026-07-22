import XCTest
import SwiftData
@testable import GlassChat

@MainActor
final class OutboxTests: XCTestCase {
    func testOutboxIncludesPendingAndSentOnly() throws {
        let container = try ModelContainer(
            for: Peer.self, Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let identity = LocalIdentity.loadOrCreate()
        let peer = ConnectedPeer(uuid: UUID(), displayName: "Riley")
        let transport = MultipeerTransport(identity: identity)
        let service = ChatService(modelContext: context, transport: transport, identity: identity)
        let chat = service.openOrCreateDirectChat(with: peer)

        let pending = Message(
            id: UUID(), senderUUID: identity.peerUUID, text: "a", sequence: 1,
            status: .pending, isFromMe: true, chat: chat
        )
        let sent = Message(
            id: UUID(), senderUUID: identity.peerUUID, text: "b", sequence: 2,
            status: .sent, isFromMe: true, chat: chat
        )
        let delivered = Message(
            id: UUID(), senderUUID: identity.peerUUID, text: "c", sequence: 3,
            status: .delivered, isFromMe: true, chat: chat
        )
        context.insert(pending)
        context.insert(sent)
        context.insert(delivered)
        try context.save()

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isFromMe && $0.statusRaw != "delivered" && $0.statusRaw != "failed" }
        )
        let outbox = try context.fetch(descriptor)
        XCTAssertEqual(Set(outbox.map(\.text)), Set(["a", "b"]))
    }
}
