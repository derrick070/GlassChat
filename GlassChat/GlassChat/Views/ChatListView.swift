import SwiftUI
import SwiftData

private enum AppRoute: Hashable {
    case chat(UUID)
    case peerBrowser
    case newGroup
    case settings
}

struct ChatListView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(MultipeerTransport.self) private var transport
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
                        ChatView(chat: chat)
                    } else {
                        ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right")
                    }
                case .peerBrowser:
                    PeerBrowserView { chat in
                        path.append(AppRoute.chat(chat.id))
                    }
                case .newGroup:
                    NewGroupView { chat in
                        path.append(AppRoute.chat(chat.id))
                    }
                case .settings:
                    SettingsView()
                }
            }
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
        }
    }

    private var chatList: some View {
        List {
            ForEach(chats, id: \.id) { chat in
                NavigationLink(value: AppRoute.chat(chat.id)) {
                    chatRow(chat)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .padding(.vertical, 2)
                )
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func chatRow(_ chat: Chat) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connectivityColor(for: chat))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chat.name)
                        .font(.headline)
                    if chat.kind == .group {
                        Image(systemName: "person.3.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let last = chat.messages.max(by: { $0.sentAt < $1.sentAt }) {
                        Text(last.sentAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(snippet(for: chat))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
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
        .padding(.vertical, 4)
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
