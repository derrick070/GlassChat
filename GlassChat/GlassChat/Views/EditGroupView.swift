import SwiftUI

struct EditGroupView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TransportMux.self) private var transport
    @Environment(\.dismiss) private var dismiss
    @Bindable var chat: Chat

    @State private var name: String = ""
    @State private var selectedToAdd: Set<UUID> = []
    @State private var errorMessage: String?

    private var currentMemberIDs: Set<UUID> {
        Set(chat.memberUUIDs)
    }

    private var candidates: [ConnectedPeer] {
        transport.connectedPeers.filter { !currentMemberIDs.contains($0.uuid) }
    }

    private var selectedPeers: [ConnectedPeer] {
        candidates.filter { selectedToAdd.contains($0.uuid) }
    }

    private var slotsRemaining: Int {
        max(0, 8 - chat.memberUUIDs.count)
    }

    var body: some View {
        Form {
            Section("Group name") {
                TextField("Group name", text: $name)
            }

            Section("Members") {
                ForEach(chat.memberUUIDs, id: \.self) { uuid in
                    HStack {
                        Text(memberName(for: uuid))
                        Spacer()
                        if uuid == chatService.localUUID {
                            Text("You")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if candidates.isEmpty {
                    Text(slotsRemaining == 0
                         ? "This group is full (8 people max)."
                         : "No new nearby peers to add. Ask them to open GlassChat nearby.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { peer in
                        Toggle(isOn: Binding(
                            get: { selectedToAdd.contains(peer.uuid) },
                            set: { isOn in
                                if isOn {
                                    guard selectedToAdd.count < slotsRemaining else { return }
                                    selectedToAdd.insert(peer.uuid)
                                } else {
                                    selectedToAdd.remove(peer.uuid)
                                }
                            }
                        )) {
                            Text(peer.displayName)
                        }
                        .disabled(!selectedToAdd.contains(peer.uuid) && selectedToAdd.count >= slotsRemaining)
                    }
                }
            } header: {
                Text("Add nearby (\(selectedToAdd.count)/\(slotsRemaining))")
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
        .navigationTitle("Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            name = chat.name
        }
    }

    private func memberName(for uuid: UUID) -> String {
        chatService.peerDisplayName(for: uuid)
    }

    private func save() {
        do {
            try chatService.updateGroup(chat, name: name, addMembers: selectedPeers)
            dismiss()
        } catch ChatServiceError.groupTooLarge {
            errorMessage = "Groups can have at most 7 other members."
        } catch ChatServiceError.invalidGroupName {
            errorMessage = "Enter a group name."
        } catch {
            errorMessage = "Could not update group."
        }
    }
}
