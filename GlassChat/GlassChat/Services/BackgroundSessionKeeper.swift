import Foundation
import UIKit

/// Best-effort Multipeer keep-alive while GlassChat is backgrounded.
/// iOS still suspends the app after a few minutes — this only delays the drop.
@MainActor
enum BackgroundSessionKeeper {
    private static var taskID: UIBackgroundTaskIdentifier = .invalid

    static func beginIfNeeded() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "GlassChat.KeepPeers") {
            end()
        }
    }

    static func end() {
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
