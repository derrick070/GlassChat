import SwiftUI

struct NewGroupView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TransportMux.self) private var transport
    var onCreated: (Chat) -> Void

    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var isCreating = false

    private var selectedPeers: [ConnectedPeer] {
        transport.connectedPeers.filter { selected.contains($0.uuid) }
    }

    var body: some View {
        Form {
            Section("Group name") {
                TextField("Weekend crew", text: $name)
            }

            Section {
                if transport.connectedPeers.isEmpty {
                    Text("Connect to nearby peers first, then create a group.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transport.connectedPeers) { peer in
                        Toggle(isOn: Binding(
                            get: { selected.contains(peer.uuid) },
                            set: { isOn in
                                if isOn {
                                    guard selected.count < 7 else { return }
                                    selected.insert(peer.uuid)
                                } else {
                                    selected.remove(peer.uuid)
                                }
                            }
                        )) {
                            Text(peer.displayName)
                        }
                    }
                }
            } header: {
                Text("Members (\(selected.count)/7)")
            } footer: {
                Text("Groups are limited to 8 people including you (Multipeer Connectivity limit).")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AtmosphereBackground())
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    create()
                }
                .disabled(
                    isCreating
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || selected.isEmpty
                )
            }
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        do {
            let chat = try chatService.createGroup(name: name, members: selectedPeers)
            onCreated(chat)
        } catch ChatServiceError.groupTooLarge {
            errorMessage = "Groups can have at most 7 other members."
            isCreating = false
        } catch ChatServiceError.invalidGroupName {
            errorMessage = "Enter a group name."
            isCreating = false
        } catch {
            errorMessage = "Could not create group."
            isCreating = false
        }
    }
}
