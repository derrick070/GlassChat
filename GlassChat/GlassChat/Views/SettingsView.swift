import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TransportMux.self) private var transport

    @State private var name: String = ""
    @State private var visible = true
    @State private var keepAwake = false

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
                Text("When visibility is off, GlassChat stops advertising and browsing. Existing chats stay on device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                Toggle("Keep screen awake", isOn: $keepAwake)
                    .onChange(of: keepAwake) { _, isOn in
                        LocalIdentity.keepScreenAwake = isOn
                    }
                Text("iOS suspends Multipeer when GlassChat is not on screen. Keeping the screen awake (and the app open) is the most reliable way to stay connected. Background keep-alive only delays disconnects for a short time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("GlassChat works fully offline. Nearby phones form a mesh over Bluetooth and local Wi‑Fi so messages can hop through peers. No accounts, no servers, no internet.")
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
            visible = LocalIdentity.isNearbyVisible
            keepAwake = LocalIdentity.keepScreenAwake
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != chatService.displayName else { return }
        chatService.updateDisplayName(trimmed)
    }
}
