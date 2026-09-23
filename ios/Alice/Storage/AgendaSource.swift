import EventKit
import Foundation
import UIKit

/// The person's commitments as this iPhone holds them: calendar events, and —
/// when they have chosen to include them — open reminders. Read on the phone
/// and never sent anywhere; Hermes' copy of the calendar is `CalendarSync`'s.
enum AgendaSource {
    /// The one store the agenda reads and writes through, so an event opened
    /// for its detail is the same object the list came from.
    @MainActor static let store = EKEventStore()

    static var remindersAllowed: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static var remindersRefused: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .denied || status == .restricted
    }

    @MainActor
    static func requestReminders() async -> Bool {
        if remindersAllowed { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Events from the start of today to the horizon, one row per occurrence.
    @MainActor
    static func events(now: Date = Date()) -> [AgendaItem] {
        guard CalendarSync.hasAccess else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: today) else { return [] }
        let predicate = store.predicateForEvents(withStart: today, end: horizon, calendars: nil)
        return store.events(matching: predicate).prefix(400).map { event in
            let identifier = event.eventIdentifier ?? UUID().uuidString
            return AgendaItem(
                // A repeating event shares one identifier across its dates.
                id: "event:\(identifier):\(Int(event.startDate.timeIntervalSince1970))",
                kind: .event(identifier: identifier, color: color(event.calendar?.cgColor)),
                title: (event.title ?? "").isEmpty ? String(localized: "Busy") : event.title!,
                start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    /// Open reminders due before the horizon (overdue included), and the
    /// undated ones.
    @MainActor
    static func reminders(now: Date = Date()) async -> [AgendaItem] {
        guard remindersAllowed else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let calendar = Calendar.current
        let horizon = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: calendar.startOfDay(for: now)) ?? now
        return await withCheckedContinuation { done in
            // Read into plain values where EventKit hands them over.
            store.fetchReminders(matching: predicate) { found in
                let items: [AgendaItem] = (found ?? []).compactMap { reminder in
                    let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
                    if let due, due >= horizon { return nil }
                    let title = reminder.title ?? ""
                    return AgendaItem(
                        id: "reminder:\(reminder.calendarItemIdentifier)",
                        kind: .reminder(identifier: reminder.calendarItemIdentifier, color: color(reminder.calendar?.cgColor)),
                        title: title.isEmpty ? String(localized: "Reminder") : title,
                        start: due, end: nil,
                        allDay: reminder.dueDateComponents.map { $0.hour == nil } ?? false,
                        location: reminder.location.flatMap { $0.isEmpty ? nil : $0 }
                    )
                }
                done.resume(returning: items)
            }
        }
    }

    /// Ticks a reminder off in Reminders itself.
    @MainActor
    static func complete(_ identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw CalendarSync.ChangeFailure.gone
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    @MainActor
    static func event(_ identifier: String, starting start: Date?) -> EKEvent? {
        guard let first = store.event(withIdentifier: identifier) else { return nil }
        // The occurrence tapped, not the series' first date.
        guard let start, first.hasRecurrenceRules else { return first }
        let day = Calendar.current.startOfDay(for: start)
        let next = day.addingTimeInterval(24 * 60 * 60)
        return store.events(matching: store.predicateForEvents(withStart: day, end: next, calendars: [first.calendar]))
            .first { $0.eventIdentifier == identifier && $0.startDate == start } ?? first
    }

    private static func color(_ cg: CGColor?) -> AgendaColor? {
        guard let cg, let rgb = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return nil }
        return AgendaColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}
