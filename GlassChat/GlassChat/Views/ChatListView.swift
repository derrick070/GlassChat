import SwiftUI
import SwiftData

private enum AppRoute: Hashable {
    case chat(UUID)
    case peerBrowser
    case newGroup
    case editGroup(UUID)
    case settings
}

struct ChatListView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TransportMux.self) private var transport
    @Environment(NotificationService.self) private var notifications
    @Query(sort: \Chat.lastMessageAt, order: .reverse) private var chats: [Chat]

    @State private var path = NavigationPath()
    @State private var showNameSheet = false
    @State private var draftName = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if chats.isEmpty {
                    emptyState
                } else {
                    chatList
                }
            }
            .navigationTitle("GlassChat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        path.append(AppRoute.settings)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            path.append(AppRoute.peerBrowser)
                        } label: {
                            Label("New Chat", systemImage: "person")
                        }
                        Button {
                            path.append(AppRoute.newGroup)
                        } label: {
                            Label("New Group", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .chat(let chatID):
                    if let chat = chats.first(where: { $0.id == chatID }) {
                        ChatView(chat: chat) {
                            path.append(AppRoute.editGroup(chat.id))
                        }
                    } else {
                        ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right")
                    }
                case .peerBrowser:
                    PeerBrowserView { chat in
                        replaceTop(with: .chat(chat.id))
                    }
                case .newGroup:
                    NewGroupView { chat in
                        replaceTop(with: .chat(chat.id))
                    }
                case .editGroup(let chatID):
                    if let chat = chats.first(where: { $0.id == chatID }) {
                        EditGroupView(chat: chat)
                    } else {
                        ContentUnavailableView("Group unavailable", systemImage: "person.3")
                    }
                case .settings:
                    SettingsView()
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(AtmosphereBackground())
        }
        .sheet(isPresented: $showNameSheet) {
            nameSheet
        }
        .onAppear {
            if !LocalIdentity.hasChosenDisplayName {
                draftName = chatService.displayName
                showNameSheet = true
            }
            openPendingChatIfNeeded()
        }
        .onChange(of: notifications.pendingChatID) { _, _ in
            openPendingChatIfNeeded()
        }
    }

    private func openPendingChatIfNeeded() {
        guard let chatID = notifications.consumePendingChatID() else { return }
        path.append(AppRoute.chat(chatID))
    }

    /// Replace the current destination (e.g. New Group) so Back returns to the list.
    private func replaceTop(with route: AppRoute) {
        if !path.isEmpty {
            path.removeLast()
        }
        path.append(route)
    }

    private var chatList: some View {
        List {
            ForEach(chats, id: \.id) { chat in
                NavigationLink(value: AppRoute.chat(chat.id)) {
                    chatRow(chat)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 28, bottom: 6, trailing: 28))
                .listRowSeparator(.hidden)
                .listRowBackground(chatRowBackground)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        chatService.deleteChat(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    private var chatRowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return shape
            .fill(.thinMaterial)
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
    }

    private func chatRow(_ chat: Chat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(connectivityColor(for: chat))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.name)
                        .font(.headline)
                    if chat.kind == .group {
                        Image(systemName: "person.3.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let last = chat.messages.max(by: { $0.sentAt < $1.sentAt }) {
                        Text(last.sentAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(snippet(for: chat))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(GlassTheme.accent))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a 1:1 or group chat with people nearby. Everything stays on your devices.")
        } actions: {
            Button {
                path.append(AppRoute.peerBrowser)
            } label: {
                Text("Find nearby peers")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glassChat)
        }
    }

    private var nameSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("What should nearby people call you?")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                TextField("Display name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                Button("Continue") {
                    chatService.updateDisplayName(draftName)
                    showNameSheet = false
                }
                .buttonStyle(.borderedProminent)
                .tint(GlassTheme.accent)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(.top, 32)
            .background(AtmosphereBackground())
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .presentationDetents([.medium])
    }

    private func snippet(for chat: Chat) -> String {
        guard let last = chat.messages.max(by: { $0.sentAt < $1.sentAt }) else {
            return "No messages yet"
        }
        let prefix = last.isFromMe ? "You: " : ""
        return prefix + last.text
    }

    private func connectivityColor(for chat: Chat) -> Color {
        let others = chat.memberUUIDs.filter { $0 != chatService.localUUID }
        let online = others.contains { transport.isConnected($0) }
        return online ? Color.green : Color.secondary.opacity(0.4)
    }
}
