import SwiftUI
import SwiftData
import PhotosUI

struct ChatView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TransportMux.self) private var transport
    @Environment(\.dismiss) private var dismiss
    @Bindable var chat: Chat
    var onEditGroup: (() -> Void)?

    @State private var draft = ""
    @State private var showDeleteConfirm = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isSendingImage = false
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
                            MessageBubble(
                                message: message,
                                senderName: groupSenderName(for: message),
                                progress: message.blobIDHex.flatMap { chatService.mediaProgress[$0] },
                                imageData: message.isImage ? chatService.imageData(for: message) : nil
                            ) {
                                chatService.retry(message)
                            } onRetryMedia: {
                                chatService.retryMediaFetch(message)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if chat.kind == .group {
                        Button {
                            onEditGroup?()
                        } label: {
                            Label("Edit Group", systemImage: "person.3")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(chat.kind == .group ? "Delete Group" : "Delete Chat", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            chat.kind == .group ? "Delete this group?" : "Delete this chat?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                chatService.deleteChat(chat)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages stay only on this device and will be removed here.")
        }
        .onAppear {
            chatService.setActiveChat(chat.id)
        }
        .onDisappear {
            if chatService.activeChatID == chat.id {
                chatService.setActiveChat(nil)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                isSendingImage = true
                defer {
                    isSendingImage = false
                    photoItem = nil
                }
                if let transferred = try? await item.loadTransferable(type: TransferableImageData.self) {
                    chatService.send(imageData: transferred.data, caption: draft, in: chat)
                    draft = ""
                }
            }
        }
    }

    private func groupSenderName(for message: Message) -> String? {
        guard chat.kind == .group, !message.isFromMe else { return nil }
        return chatService.peerDisplayName(for: message.senderUUID)
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
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(GlassTheme.accent)
                    .frame(width: 36, height: 36)
            }
            .disabled(isSendingImage)
            .accessibilityLabel("Send photo")

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
        .overlay {
            if isSendingImage {
                ProgressView()
                    .padding(.trailing, 56)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
