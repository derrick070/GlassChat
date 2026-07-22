import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(MultipeerTransport.self) private var transport
    @Bindable var chat: Chat

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var sortedMessages: [Message] {
        chat.messages.sorted {
            if $0.sentAt == $1.sentAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.sentAt < $1.sentAt
        }
    }

    private var counterpartOnline: Bool {
        let others = chat.memberUUIDs.filter { $0 != chatService.localUUID }
        return others.contains { transport.isConnected($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !counterpartOnline {
                offlineBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedMessages, id: \.id) { message in
                            MessageBubble(message: message) {
                                chatService.retry(message)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = sortedMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = sortedMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            composer
        }
        .navigationTitle(chat.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(AtmosphereBackground())
        .onAppear {
            chatService.setActiveChat(chat.id)
        }
        .onDisappear {
            if chatService.activeChatID == chat.id {
                chatService.setActiveChat(nil)
            }
        }
    }

    private var offlineBanner: some View {
        Text("Nearby delivery paused — will send when peers are in range.")
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassSurface(cornerRadius: 16)
            .padding(.horizontal, GlassTheme.spacing)
            .padding(.top, 8)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassSurface(cornerRadius: 20)

            Button {
                let text = draft
                draft = ""
                chatService.send(text: text, in: chat)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Color.secondary
                                     : GlassTheme.accent)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, GlassTheme.spacing)
        .padding(.vertical, 10)
        .background(.clear)
    }
}
