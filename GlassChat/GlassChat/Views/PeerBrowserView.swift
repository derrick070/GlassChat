import SwiftUI

struct PeerBrowserView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(MultipeerTransport.self) private var transport
    @Environment(\.dismiss) private var dismiss

    var onOpenChat: (Chat) -> Void

    var body: some View {
        List {
            Section {
                if transport.connectedPeers.isEmpty {
                    ContentUnavailableView(
                        "No nearby peers",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Ask someone nearby to open GlassChat. Discovery uses Bluetooth and local Wi‑Fi — no internet needed.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(transport.connectedPeers) { peer in
                        Button {
                            let chat = chatService.openOrCreateDirectChat(with: peer)
                            onOpenChat(chat)
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(GlassTheme.accent)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .foregroundStyle(.primary)
                                    Text(peer.uuid.uuidString.prefix(8).uppercased())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "message")
                                    .foregroundStyle(GlassTheme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Nearby")
            }

            if !transport.discoveredPeerNames.isEmpty {
                Section("Seen on network") {
                    ForEach(transport.discoveredPeerNames, id: \.self) { name in
                        Text(name)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AtmosphereBackground())
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}
