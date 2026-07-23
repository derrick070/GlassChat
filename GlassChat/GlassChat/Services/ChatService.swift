import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

@Observable
@MainActor
final class ChatService {
    private let modelContext: ModelContext
    private let transport: TransportMux
    private var eventTask: Task<Void, Never>?
    private var sequenceStore: [String: Int64] = [:]
    /// Chat currently on screen — incoming messages here do not bump unread.
    private(set) var activeChatID: UUID?

    init(modelContext: ModelContext, transport: TransportMux) {
        self.modelContext = modelContext
        self.transport = transport
        // Subscribe once for the app-lifetime of this service. AsyncStream is
        // single-consumer; cancelling the iterator finishes the stream forever.
        // Intentionally retains self for the process lifetime (singleton).
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.events {
                await self.handle(event)
            }
        }
    }

    /// Start advertising/browsing when the user wants to be discoverable.
    func start() {
        LocalIdentity.isNearbyVisible = true
        transport.start()
    }

    /// Stop nearby discovery without tearing down the event subscription.
    func stop() {
        LocalIdentity.isNearbyVisible = false
        transport.stop()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            BackgroundSessionKeeper.end()
            UIApplication.shared.isIdleTimerDisabled = LocalIdentity.keepScreenAwake
            if LocalIdentity.isNearbyVisible {
                if transport.isRunning {
                    transport.refreshDiscovery()
                } else {
                    transport.start()
                }
            }
            flushOutbox()
            Task { await NotificationService.shared.setBadge(totalUnreadCount()) }
        case .inactive, .background:
            // Ask iOS for extra runtime so existing Multipeer sessions last longer.
            // This is best-effort (usually ~30s–a few minutes) — not indefinite.
            if transport.isRunning, !transport.connectedPeers.isEmpty {
                BackgroundSessionKeeper.beginIfNeeded()
            }
        @unknown default:
            break
        }
    }

    func updateDisplayName(_ name: String) {
        transport.updateDisplayName(name)
    }

    func setActiveChat(_ id: UUID?) {
        activeChatID = id
        if let id, let chat = fetchChat(id: id) {
            markChatRead(chat)
        }
    }

    /// Ask for notification permission once the user starts chatting.
    func prepareNotifications() {
        Task {
            await NotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    var localUUID: UUID { transport.peerUUID }
    var displayName: String { transport.displayName }
    var shortID: String { transport.shortID }

    // MARK: - Chats

    @discardableResult
    func openOrCreateDirectChat(with peer: ConnectedPeer) -> Chat {
        prepareNotifications()
        upsertPeer(uuid: peer.uuid, displayName: peer.displayName)
        let chatID = directChatID(with: peer.uuid)
        if let existing = fetchChat(id: chatID) {
            existing.name = peer.displayName
            try? modelContext.save()
            return existing
        }
        let chat = Chat(
            id: chatID,
            kind: .direct,
            name: peer.displayName,
            memberUUIDs: [transport.peerUUID, peer.uuid].sorted { $0.uuidString < $1.uuidString }
        )
        modelContext.insert(chat)
        try? modelContext.save()
        return chat
    }

    @discardableResult
    func createGroup(name: String, members: [ConnectedPeer]) throws -> Chat {
        prepareNotifications()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatServiceError.invalidGroupName }
        guard members.count <= 7 else { throw ChatServiceError.groupTooLarge }

        var memberUUIDs = Set(members.map(\.uuid))
        memberUUIDs.insert(transport.peerUUID)
        let chat = Chat(
            id: UUID(),
            kind: .group,
            name: trimmed,
            memberUUIDs: Array(memberUUIDs).sorted { $0.uuidString < $1.uuidString }
        )
        modelContext.insert(chat)
        try modelContext.save()
        return chat
    }

    func updateGroup(_ chat: Chat, name: String, addMembers: [ConnectedPeer]) throws {
        guard chat.kind == .group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatServiceError.invalidGroupName }

        var members = Set(chat.memberUUIDs)
        for peer in addMembers {
            guard members.count < 8 else { throw ChatServiceError.groupTooLarge }
            members.insert(peer.uuid)
            upsertPeer(uuid: peer.uuid, displayName: peer.displayName)
        }
        chat.name = trimmed
        chat.memberUUIDs = Array(members).sorted { $0.uuidString < $1.uuidString }
        try modelContext.save()

        // Announce so other devices pick up the updated membership via groupInfo.
        if !addMembers.isEmpty {
            let names = addMembers.map(\.displayName).joined(separator: ", ")
            send(text: "Added \(names) to the group", in: chat)
        }
    }

    func deleteChat(_ chat: Chat) {
        let id = chat.id
        if activeChatID == id {
            activeChatID = nil
        }
        NotificationService.shared.clearNotifications(for: id)
        modelContext.delete(chat)
        try? modelContext.save()
        Task { await NotificationService.shared.setBadge(totalUnreadCount()) }
    }

    func peerDisplayName(for uuid: UUID) -> String {
        if uuid == transport.peerUUID { return transport.displayName }
        if let live = transport.connectedPeers.first(where: { $0.uuid == uuid })?.displayName {
            return live
        }
        let peerID = uuid
        let descriptor = FetchDescriptor<Peer>(predicate: #Predicate { $0.uuid == peerID })
        if let peer = try? modelContext.fetch(descriptor).first {
            return peer.displayName
        }
        return String(uuid.uuidString.prefix(8)).uppercased()
    }

    // MARK: - Send / Receive

    func send(text: String, in chat: Chat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let messageID = UUID()
        let sequence = nextSequence(for: chat.id)
        let message = Message(
            id: messageID,
            senderUUID: transport.peerUUID,
            text: trimmed,
            sequence: sequence,
            status: .pending,
            isFromMe: true,
            chat: chat
        )
        chat.messages.append(message)
        chat.lastMessageAt = message.sentAt
        modelContext.insert(message)
        try? modelContext.save()

        transmit(message: message, chat: chat)
    }

    func retry(_ message: Message) {
        guard let chat = message.chat else { return }
        message.status = .pending
        try? modelContext.save()
        transmit(message: message, chat: chat)
    }

    func markChatRead(_ chat: Chat) {
        chat.unreadCount = 0
        try? modelContext.save()
        NotificationService.shared.clearNotifications(for: chat.id)
        Task { await NotificationService.shared.setBadge(totalUnreadCount()) }
    }

    func flushOutbox(for peerUUID: UUID? = nil) {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isFromMe && $0.statusRaw != "delivered" && $0.statusRaw != "failed" }
        )
        guard let pending = try? modelContext.fetch(descriptor) else { return }
        for message in pending {
            guard let chat = message.chat else { continue }
            if let peerUUID {
                let targets = undeliveredTargets(for: message, in: chat)
                guard targets.contains(peerUUID) else { continue }
            }
            transmit(message: message, chat: chat)
        }
    }

    // MARK: - Internals

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .peerConnected(let peer):
            upsertPeer(uuid: peer.uuid, displayName: peer.displayName)
            flushOutbox(for: peer.uuid)
        case .peerDisconnected:
            break
        case .frameReceived(let frame, let from):
            handle(frame: frame, from: from)
        }
    }

    private func handle(frame: WireFrame, from sender: UUID) {
        switch frame.kind {
        case .hello:
            break
        case .message:
            handleIncomingMessage(frame, from: sender)
        case .ack:
            handleAck(frame, from: sender)
        }
    }

    #if DEBUG
    /// Test-only entry point for frame handling without a live transport.
    func testHandle(frame: WireFrame, from sender: UUID) {
        handle(frame: frame, from: sender)
    }
    #endif

    private func handleIncomingMessage(_ frame: WireFrame, from sender: UUID) {
        guard let messageID = frame.messageID,
              let chatID = frame.chatID,
              let text = frame.text,
              let sentAt = frame.sentAt,
              let sequence = frame.sequence else { return }

        // Always ACK, even for duplicates (original ACK may have been lost).
        sendAck(for: messageID, to: sender)

        if messageExists(id: messageID) {
            return
        }

        prepareNotifications()

        let chat = materializeChat(
            chatID: chatID,
            groupInfo: frame.groupInfo,
            senderUUID: sender,
            senderName: transport.connectedPeers.first(where: { $0.uuid == sender })?.displayName
        )

        let message = Message(
            id: messageID,
            senderUUID: sender,
            text: text,
            sentAt: sentAt,
            sequence: sequence,
            status: .delivered,
            isFromMe: false,
            chat: chat
        )
        chat.messages.append(message)
        chat.lastMessageAt = sentAt
        let chatIsOpen = activeChatID == chat.id
        if !chatIsOpen {
            chat.unreadCount += 1
        }
        modelContext.insert(message)
        let senderName = transport.connectedPeers.first(where: { $0.uuid == sender })?.displayName
            ?? chat.name
        upsertPeer(uuid: sender, displayName: senderName)
        try? modelContext.save()

        let title: String
        let body: String
        if chat.kind == .group {
            title = chat.name
            body = "\(senderName): \(text)"
        } else {
            title = senderName
            body = text
        }
        NotificationService.shared.notifyNewMessage(
            messageID: messageID,
            chatID: chat.id,
            title: title,
            body: body,
            suppressBecauseChatIsOpen: chatIsOpen,
            unreadTotal: totalUnreadCount()
        )
    }

    private func handleAck(_ frame: WireFrame, from sender: UUID) {
        guard let ackedID = frame.ackedMessageID else { return }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == ackedID }
        )
        guard let message = try? modelContext.fetch(descriptor).first else { return }
        if !message.ackedBy.contains(sender) {
            message.ackedBy.append(sender)
        }
        if let chat = message.chat {
            let needed = chat.memberUUIDs.filter { $0 != transport.peerUUID }
            let fullyDelivered = needed.allSatisfy { message.ackedBy.contains($0) }
            message.status = fullyDelivered ? .delivered : .sent
        } else {
            message.status = .delivered
        }
        try? modelContext.save()
    }

    private func transmit(message: Message, chat: Chat) {
        let targets = undeliveredTargets(for: message, in: chat)
        guard !targets.isEmpty else {
            // No one online yet — stay pending for outbox flush.
            return
        }

        let groupInfo: GroupInfo? = chat.kind == .group
            ? GroupInfo(name: chat.name, memberUUIDs: chat.memberUUIDs)
            : nil

        let frame = WireFrame.message(
            senderUUID: transport.peerUUID,
            messageID: message.id,
            chatID: chat.id,
            text: message.text,
            sentAt: message.sentAt,
            sequence: message.sequence,
            groupInfo: groupInfo
        )

        do {
            try transport.send(frame, to: targets)
            if message.status == .pending || message.status == .failed {
                message.status = .sent
            }
            try? modelContext.save()
        } catch TransportError.noConnectedPeers, TransportError.missingPeerKey {
            message.status = .pending
            try? modelContext.save()
        } catch {
            // Encode failures or unexpected transport errors — surface retry UI.
            message.status = .failed
            try? modelContext.save()
        }
    }

    private func sendAck(for messageID: UUID, to peer: UUID) {
        let frame = WireFrame.ack(senderUUID: transport.peerUUID, ackedMessageID: messageID)
        try? transport.send(frame, to: [peer])
    }

    private func undeliveredTargets(for message: Message, in chat: Chat) -> [UUID] {
        chat.memberUUIDs
            .filter { $0 != transport.peerUUID }
            .filter { !message.ackedBy.contains($0) }
            .filter { transport.isConnected($0) }
    }

    private func materializeChat(
        chatID: UUID,
        groupInfo: GroupInfo?,
        senderUUID: UUID,
        senderName: String?
    ) -> Chat {
        if let existing = fetchChat(id: chatID) {
            if let groupInfo {
                existing.name = groupInfo.name
                existing.memberUUIDs = groupInfo.memberUUIDs
            }
            return existing
        }

        if let groupInfo {
            let chat = Chat(
                id: chatID,
                kind: .group,
                name: groupInfo.name,
                memberUUIDs: groupInfo.memberUUIDs
            )
            modelContext.insert(chat)
            return chat
        }

        let chat = Chat(
            id: chatID,
            kind: .direct,
            name: senderName ?? "Peer",
            memberUUIDs: [transport.peerUUID, senderUUID].sorted { $0.uuidString < $1.uuidString }
        )
        modelContext.insert(chat)
        return chat
    }

    private func fetchChat(id: UUID) -> Chat? {
        let descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func messageExists(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        return ((try? modelContext.fetch(descriptor).count) ?? 0) > 0
    }

    private func upsertPeer(uuid: UUID, displayName: String) {
        let descriptor = FetchDescriptor<Peer>(predicate: #Predicate { $0.uuid == uuid })
        if let peer = try? modelContext.fetch(descriptor).first {
            peer.displayName = displayName
            peer.lastSeenAt = .now
        } else {
            modelContext.insert(Peer(uuid: uuid, displayName: displayName))
        }
        try? modelContext.save()
    }

    private func directChatID(with peerUUID: UUID) -> UUID {
        // Deterministic chat ID from sorted UUID pair so both sides share one thread.
        let a = transport.peerUUID.uuidString
        let b = peerUUID.uuidString
        let seed = [a, b].sorted().joined(separator: "|")
        return UUID.deterministic(from: seed)
    }

    private func nextSequence(for chatID: UUID) -> Int64 {
        let key = "seq.\(chatID.uuidString)"
        let current = sequenceStore[key]
            ?? Int64(UserDefaults.standard.integer(forKey: key))
        let next = current + 1
        sequenceStore[key] = next
        UserDefaults.standard.set(Int(next), forKey: key)
        return next
    }

    private func totalUnreadCount() -> Int {
        let descriptor = FetchDescriptor<Chat>()
        let chats = (try? modelContext.fetch(descriptor)) ?? []
        return chats.reduce(0) { $0 + $1.unreadCount }
    }
}

enum ChatServiceError: Error {
    case invalidGroupName
    case groupTooLarge
}

extension UUID {
    /// Stable UUID derived from a string (FNV-1a inspired hashing into 16 bytes).
    static func deterministic(from string: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        var hash2: UInt64 = 0x84222325cbf29ce4
        for byte in string.utf8.reversed() {
            hash2 ^= UInt64(byte)
            hash2 &*= 0x100000001b3
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (i * 8)) & 0xff)
            bytes[8 + i] = UInt8((hash2 >> (i * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4-ish
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
