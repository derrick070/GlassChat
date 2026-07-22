import SwiftUI
import SwiftData

@main
struct GlassChatApp: App {
    @State private var identity = LocalIdentity.loadOrCreate()
    @State private var transport: MultipeerTransport
    @State private var chatService: ChatService?
    @State private var outbox: OutboxProcessor?
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
        let transport = MultipeerTransport(identity: identity)
        _identity = State(initialValue: identity)
        _transport = State(initialValue: transport)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                identity: identity,
                transport: transport,
                chatService: $chatService,
                outbox: $outbox
            )
            .modelContainer(modelContainer)
            .environment(transport)
        }
        .onChange(of: scenePhase) { _, phase in
            outbox?.handleScenePhase(phase)
            if phase == .active {
                chatService?.start()
            }
        }
    }
}

private struct RootView: View {
    let identity: LocalIdentity
    let transport: MultipeerTransport
    @Binding var chatService: ChatService?
    @Binding var outbox: OutboxProcessor?
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
                    transport: transport,
                    identity: identity
                )
                chatService = service
                outbox = OutboxProcessor(chatService: service)
                service.start()
            }
        }
    }
}
