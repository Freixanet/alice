import UIKit
import UserNotifications

/// Owns notification responses from the earliest application lifecycle point.
///
/// `UNUserNotificationCenter` can deliver the response that launched the app
/// before SwiftUI runs a view `.task`. The previous router was installed from
/// that task, so a genuine cold-start tap could launch Alice and still lose the
/// route. This delegate is registered during `didFinishLaunching` and buffers
/// one response until the SwiftUI shell is ready to navigate.
final class NotificationApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor private var pendingRoute: Notifier.Route?
    @MainActor var deliver: (@MainActor @Sendable (Notifier.Route) -> Void)? {
        didSet {
            guard let deliver, let pendingRoute else { return }
            self.pendingRoute = nil
            deliver(pendingRoute)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    @MainActor
    func accept(_ route: Notifier.Route) {
        if let deliver {
            deliver(route)
        } else {
            pendingRoute = route
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        guard let route = Notifier.Route(
            userInfo: response.notification.request.content.userInfo
        ) else {
            completionHandler()
            return
        }

        // Let UIKit finish the notification-response transaction before any
        // SwiftUI navigation mutates scene state. On a cold start, navigating
        // from inside the callback can collide with UIKit's snapshot/state
        // restoration work and abort the process.
        completionHandler()
        DispatchQueue.main.async { [weak self] in
            self?.accept(route)
        }
    }

    /// While Alice is open, a banner would cover the very screen showing the
    /// event. Keep it in Notification Center instead.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }
}

/// Where a notification sent from outside Alice points.
///
/// Alice cannot be woken while iOS has it suspended, so the Mac that hosts
/// Hermes watches for replies and routine results and notifies through Bark
/// (mac/notifier). Tapping one opens `alice://open?bot=<profile>` for a bot's
/// chat, or `alice://open?chat=<conversation>` — `chat=home` for Alice's own.
/// Opening a chat is all a link can do: any app can open one.
enum NotificationLink: Equatable, Sendable {
    case bot(String)
    /// A conversation id, or nil for Alice's most recent chat of her own.
    case chat(String?)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "alice",
              url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        if let bot = items.first(where: { $0.name == "bot" })?.value, !bot.isEmpty {
            self = .bot(bot)
        } else if let chat = items.first(where: { $0.name == "chat" })?.value, !chat.isEmpty {
            self = .chat(chat == "home" ? nil : chat)
        } else {
            return nil
        }
    }
}
