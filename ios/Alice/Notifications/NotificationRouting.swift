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
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = Notifier.Route(
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        await accept(route)
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
