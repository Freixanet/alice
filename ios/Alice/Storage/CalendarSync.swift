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

    /// A matched event on the phone, for a card to show and act on.
    struct Found: Sendable, Equatable {
        let identifier: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let location: String?
        let editable: Bool
    }

    /// The event an agent means: on that day, whose title matches (either
    /// contains the other, case and accents aside), nearest the time given.
    /// Nil when there is none — a card never acts on a guess.
    @MainActor
    static func find(title: String, day: Date, time: Date?) -> Found? {
        guard hasAccess else { return nil }
        let store = EKEventStore()
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: day)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from) else { return nil }
        let wanted = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matches = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter {
                let have = ($0.title ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return !have.isEmpty && (have.contains(wanted) || wanted.contains(have))
            }
        let best = time.map { t in matches.min { abs($0.startDate.timeIntervalSince(t)) < abs($1.startDate.timeIntervalSince(t)) } }
            ?? matches.first
        guard let event = best ?? matches.first else { return nil }
        return Found(
            identifier: event.eventIdentifier ?? "", title: event.title ?? title,
            start: event.startDate, end: event.endDate, allDay: event.isAllDay,
            location: event.location, editable: event.calendar.allowsContentModifications
        )
    }

    /// Moves an event to a new start, keeping how long it lasts.
    @MainActor
    static func move(_ identifier: String, to start: Date) throws {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { throw ChangeFailure.gone }
        let length = event.endDate.timeIntervalSince(event.startDate)
        event.startDate = start
        event.endDate = start.addingTimeInterval(length)
        try store.save(event, span: .thisEvent, commit: true)
    }

    /// Removes one occurrence: a repeating event keeps its other dates.
    @MainActor
    static func cancel(_ identifier: String) throws {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { throw ChangeFailure.gone }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    enum ChangeFailure: LocalizedError {
        case gone
        var errorDescription: String? { "The event is no longer in the calendar." }
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
