import Foundation
import UserNotifications

/// Receives taps on Alice's notifications.
///
/// On a cold start this fires before there is any interface to act on, so the
/// tap is parked on the notifier and picked up once the app is on screen.
/// Dropping it would make the one thing a notification is for — getting you to
/// the thing it is about — work only when the app happened to be running.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let deliver: @MainActor @Sendable (Notifier.Route) -> Void

    init(deliver: @escaping @MainActor @Sendable (Notifier.Route) -> Void) {
        self.deliver = deliver
        super.init()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = Notifier.Route(
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        let handler = deliver
        await MainActor.run { handler(route) }
    }

    /// While Alice is open, a banner would cover the very screen showing the
    /// thing it describes. The event is already in Activity, and the list is
    /// where it belongs.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }
}
