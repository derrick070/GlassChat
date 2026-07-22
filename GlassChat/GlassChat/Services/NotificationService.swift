import Foundation
import Observation
import UIKit
import UserNotifications

@Observable
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    /// Set when the user taps a notification; ChatListView consumes and clears it.
    private(set) var pendingChatID: UUID?

    private let center = UNUserNotificationCenter.current()
    private var didConfigure = false

    private override init() {
        super.init()
    }

    func configure() {
        assert(Thread.isMainThread)
        guard !didConfigure else { return }
        didConfigure = true
        // UNUserNotificationCenter.delegate must be set on the main thread.
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied, .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }
    }

    /// Posts a local notification for a newly inserted inbound message.
    /// Skips banners when the matching chat is open, or when the app is active
    /// (in-app unread UI already covers that case). Still updates the badge.
    func notifyNewMessage(
        messageID: UUID,
        chatID: UUID,
        title: String,
        body: String,
        suppressBecauseChatIsOpen: Bool,
        unreadTotal: Int
    ) {
        Task { await setBadge(unreadTotal) }

        guard !suppressBecauseChatIsOpen else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: unreadTotal)
        content.threadIdentifier = chatID.uuidString
        content.userInfo = [
            "chatID": chatID.uuidString,
            "messageID": messageID.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: messageID.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func clearNotifications(for chatID: UUID) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { ($0.request.content.userInfo["chatID"] as? String) == chatID.uuidString }
                .map(\.request.identifier)
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                center.removeDeliveredNotifications(withIdentifiers: ids)
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func setBadge(_ unreadTotal: Int) async {
        do {
            try await center.setBadgeCount(unreadTotal)
        } catch {
            await MainActor.run {
                UIApplication.shared.applicationIconBadgeNumber = unreadTotal
            }
        }
    }

    func consumePendingChatID() -> UUID? {
        let id = pendingChatID
        pendingChatID = nil
        return id
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        guard let chatString = info["chatID"] as? String,
              let chatID = UUID(uuidString: chatString) else { return }
        pendingChatID = chatID
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Foreground: prefer in-app unread UI over system banners.
        []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            handleNotificationResponse(response)
        }
    }
}
