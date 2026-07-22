import SwiftUI

struct SettingsView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(MultipeerTransport.self) private var transport

    @State private var name: String = ""
    @State private var visible = true

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name", text: $name)
                    .onSubmit(saveName)
                LabeledContent("Peer ID", value: chatService.shortID)
                    .font(.body.monospaced())
            }

            Section("Nearby") {
                Toggle("Visible to nearby devices", isOn: $visible)
                    .onChange(of: visible) { _, isOn in
                        if isOn {
                            chatService.start()
                        } else {
                            chatService.stop()
                        }
                    }
                LabeledContent("Connected", value: "\(transport.connectedPeers.count)")
            }

            Section {
                Text("GlassChat works fully offline over Bluetooth and local Wi‑Fi. No accounts, no servers, no internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AtmosphereBackground())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = chatService.displayName
            visible = transport.isRunning
        }
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        chatService.updateDisplayName(name)
    }
}
