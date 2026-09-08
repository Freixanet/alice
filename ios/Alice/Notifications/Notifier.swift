import Foundation
import UserNotifications

/// Delivers events to the phone, and is honest about when it cannot.
///
/// What Alice can actually do, established from the Hermes source rather than
/// assumed:
///
/// * **While Alice is open** it can watch the dashboard's JSON-RPC socket and
///   poll the agent, so it learns about work immediately.
/// * **When iOS next wakes Alice in the background** it can compare durable
///   server state — cron run records, component health — against what it last
///   saw and report the difference. iOS decides when that happens, and it does
///   not happen at all if the app has been force-quit.
/// * **It cannot be told anything while it is suspended.** Hermes has no push
///   credentials and no relay, and `session.events.since` is a 512-entry
///   in-memory ring per session that resets with the gateway — a reconnect
///   aid, not a record. Guaranteed background alerts would need infrastructure
///   that does not exist in either repository, so Alice does not claim them.
///
/// Nothing here schedules a notification for something that has not happened.
@MainActor
@Observable
final class Notifier {
    /// Whether the system will actually deliver what Alice posts.
    enum Permission: Equatable, Sendable {
        /// Never asked. Alice asks in context, not at first launch.
        case notAsked
        case allowed
        /// Allowed, but silently — banners are off, so an alert would not show.
        case allowedQuietly
        /// Refused, or switched off later in iOS Settings.
        case refused

        var canDeliver: Bool { self == .allowed || self == .allowedQuietly }
    }

    private(set) var permission: Permission = .notAsked

    private let center: NotificationScheduling

    init(center: NotificationScheduling = UNUserNotificationCenter.current()) {
        self.center = center
    }

    /// Reads the current setting. Worth re-reading whenever Alice becomes
    /// active: permission can be revoked in iOS Settings at any time, and a
    /// switch that still says "on" after that is a lie.
    func refreshPermission() async {
        permission = await center.currentPermission()
    }

    /// Asks, in context, having already explained why.
    ///
    /// Returns whether Alice can now deliver. A refusal is a normal outcome:
    /// the caller turns the feature off rather than leaving it looking armed.
    @discardableResult
    func requestPermission() async -> Bool {
        if permission == .refused {
            // iOS only presents the prompt once. After a refusal the only way
            // back is Settings, so asking again would do nothing at all.
            return false
        }
        _ = try? await center.requestAuthorization()
        await refreshPermission()
        return permission.canDeliver
    }

    /// Posts one event.
    ///
    /// The body is Alice's own sentence about what happened, never the agent's
    /// output. A completed research task can contain anything, and a lock
    /// screen is a public surface; the content belongs inside the app, behind
    /// whatever unlocks the phone.
    func post(_ event: AliceEvent) async {
        guard permission.canDeliver else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.summary
        content.sound = event.severity == .informational ? nil : .default
        content.interruptionLevel = event.kind == .needsInput ? .timeSensitive : .active
        content.threadIdentifier = event.profile ?? event.kind.rawValue
        // Enough to reopen the exact thing after a cold start, when nothing of
        // the session that produced it is left in memory.
        var route: [String: String] = ["event": event.id]
        route["conversation"] = event.reference.conversationID
        route["profile"] = event.reference.profile
        route["session"] = event.reference.sessionID
        route["request"] = event.reference.requestID
        content.userInfo = route.compactMapValues { $0 }
        await center.add(identifier: event.id, content: content)
    }

    func post(_ events: [AliceEvent]) async {
        for event in events { await post(event) }
    }

    /// Takes back a notification whose subject is over.
    ///
    /// A banner still offering to answer a question that has been answered is
    /// the same kind of lie as a switch that promises delivery and sends none.
    func withdraw(_ eventID: String) {
        center.withdraw([eventID])
    }

    /// Where a tapped notification should land.
    struct Route: Equatable, Sendable {
        var eventID: String
        var conversationID: String?
        var profile: String?
        var sessionID: String?
        var requestID: String?

        init?(userInfo: [AnyHashable: Any]) {
            guard let eventID = userInfo["event"] as? String else { return nil }
            self.eventID = eventID
            conversationID = userInfo["conversation"] as? String
            profile = userInfo["profile"] as? String
            sessionID = userInfo["session"] as? String
            requestID = userInfo["request"] as? String
        }
    }

    /// The tap the app has not handled yet.
    ///
    /// Set from the notification delegate, which on a cold start fires before
    /// anything is on screen — so it is held here until the interface exists to
    /// act on it, rather than dropped.
    var pendingRoute: Route?
}

/// The slice of `UNUserNotificationCenter` Alice uses, so the permission
/// semantics — which are most of the behaviour worth getting right — can be
/// tested without the system asking a real person a real question.
protocol NotificationScheduling: Sendable {
    func currentPermission() async -> Notifier.Permission
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, content: UNNotificationContent) async
    func withdraw(_ identifiers: [String])
}

extension UNUserNotificationCenter: NotificationScheduling {
    func currentPermission() async -> Notifier.Permission {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied: return .refused
        case .authorized, .provisional, .ephemeral:
            // Authorised but with every presentation style off delivers
            // nothing a person would see.
            let visible = settings.alertSetting == .enabled
                || settings.badgeSetting == .enabled
                || settings.soundSetting == .enabled
            return visible ? .allowed : .allowedQuietly
        @unknown default: return .refused
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(identifier: String, content: UNNotificationContent) async {
        // No trigger: the thing already happened, so it is delivered now
        // rather than scheduled for a future that might not resemble this one.
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        try? await add(request)
    }

    func withdraw(_ identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
