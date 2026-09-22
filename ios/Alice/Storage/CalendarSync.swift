import EventKit
import Foundation

/// Where the person's calendar stands with their Hermes
/// (`hermes-plugin/calendar_snapshot.py`).
enum CalendarLink: Equatable, Sendable {
    /// Not asked yet this launch.
    case unknown
    case notConnected
    /// Events are on Hermes, as of `updatedAt`.
    case connected(updatedAt: Date?)
    /// The person said "not now": agents stop offering it.
    case declined

    static func parse(_ object: [String: Any]) -> CalendarLink {
        switch object["status"] as? String {
        case "connected":
            let stamp = (object["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return .connected(updatedAt: stamp)
        case "declined":
            return .declined
        default:
            return .notConnected
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Reads the calendars on this iPhone, for the person's own Hermes.
///
/// Every account the phone holds — iCloud, Google, Exchange — without a
/// Google Cloud project or an OAuth client: iOS asks once, and a window of
/// events goes to Hermes, where agents read it through `calendar_events`.
/// Read-only, and notes never leave the phone.
enum CalendarSync {
    /// From yesterday to a month ahead: enough to plan, small enough to send.
    static func window(now: Date = Date()) -> (start: Date, end: Date) {
        let day: TimeInterval = 24 * 60 * 60
        return (now.addingTimeInterval(-day), now.addingTimeInterval(30 * day))
    }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Whether iOS has already been told no: asking again shows nothing, and
    /// the way back is Settings.
    static var refused: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    /// Asks iOS for read access. True when granted.
    static func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Writes one event the person confirmed, with an alert before it, into
    /// the calendar new events go to. Returns its identifier.
    @MainActor
    static func add(title: String, start: Date, allDay: Bool, minutes: Int, location: String?) throws -> String {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? start : start.addingTimeInterval(TimeInterval(minutes * 60))
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        // An hour before; for a whole day, that morning at nine.
        event.addAlarm(EKAlarm(relativeOffset: allDay ? 9 * 60 * 60 : -60 * 60))
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    /// One event as Hermes stores it: no notes, no attendees.
    struct Event: Sendable, Equatable {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let location: String?
        let calendar: String?

        var json: [String: Any] {
            let format = ISO8601DateFormatter()
            var row: [String: Any] = [
                "title": title, "start": format.string(from: start),
                "end": format.string(from: end), "all_day": allDay,
            ]
            if let location, !location.isEmpty { row["location"] = location }
            if let calendar { row["calendar"] = calendar }
            return row
        }
    }

    /// The window's events. Off the main thread: a busy calendar is thousands
    /// of events to read.
    static func events(from start: Date, to end: Date) async -> [Event] {
        await Task.detached(priority: .utility) {
            let store = EKEventStore()
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .prefix(600)
                .map { event in
                    Event(
                        title: event.title ?? "Busy", start: event.startDate, end: event.endDate,
                        allDay: event.isAllDay, location: event.location, calendar: event.calendar?.title
                    )
                }
        }.value
    }
}
