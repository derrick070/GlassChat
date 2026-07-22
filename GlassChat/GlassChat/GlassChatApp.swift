import SwiftUI
import SwiftData

@main
struct GlassChatApp: App {
    @State private var transport: MultipeerTransport
    @State private var chatService: ChatService?
    @Environment(\.scenePhase) private var scenePhase

    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([Peer.self, Chat.self, Message.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let identity = LocalIdentity.loadOrCreate()
        _transport = State(initialValue: MultipeerTransport(identity: identity))
    }

    var body: some Scene {
        WindowGroup {
            RootView(transport: transport, chatService: $chatService)
                .modelContainer(modelContainer)
                .environment(transport)
                .environment(NotificationService.shared)
                .task {
                    NotificationService.shared.configure()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            chatService?.handleScenePhase(phase)
        }
    }
}

private struct RootView: View {
    let transport: MultipeerTransport
    @Binding var chatService: ChatService?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let chatService {
                ChatListView()
                    .environment(chatService)
            } else {
                ProgressView("Starting…")
            }
        }
        .onAppear {
            if chatService == nil {
                let service = ChatService(
                    modelContext: modelContext,
                    transport: transport
                )
                chatService = service
                if LocalIdentity.isNearbyVisible {
                    service.start()
                }
            }
        }
    }
}
