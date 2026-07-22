import Foundation
import SwiftUI

/// Flushes pending/sent messages when peers reconnect or the app returns to foreground.
@MainActor
final class OutboxProcessor {
    private let chatService: ChatService

    init(chatService: ChatService) {
        self.chatService = chatService
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            chatService.flushOutbox()
        }
    }
}
