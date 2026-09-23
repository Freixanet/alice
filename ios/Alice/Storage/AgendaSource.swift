import CoreLocation
import EventKit
import Foundation
import UIKit

/// The person's calendars and reminders as this iPhone holds them, read and
/// written through EventKit — the same store Calendar and Reminders use, so
/// everything syncs wherever those apps do. Nothing here goes to Hermes;
/// Hermes' copy of the calendar is `CalendarSync`'s.
///
/// Reminders exposes to other apps: title, notes, URL, date and time, alerts
/// (by time or by arriving or leaving a place), repeat, priority, list, done.
/// Flags, tags, subtasks, sections, images and "Urgent" are Reminders' own
/// and no other app can read or set them.
enum AgendaSource {
    /// One store for reading and writing, so an item opened for its details
    /// is the one the list came from.
    @MainActor static let store = EKEventStore()

    // MARK: Access

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

    // MARK: Events

    /// Every occurrence between two dates.
    @MainActor
    static func events(from start: Date, to end: Date) -> [AgendaItem] {
        guard CalendarSync.hasAccess, start < end else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(2000).map(item(for:))
    }

    /// From the start of today to the horizon.
    @MainActor
    static func events(now: Date = Date()) -> [AgendaItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: today) else { return [] }
        return events(from: today, to: horizon)
    }

    @MainActor
    private static func item(for event: EKEvent) -> AgendaItem {
        let identifier = event.eventIdentifier ?? UUID().uuidString
        let title = event.title ?? ""
        return AgendaItem(
            // A repeating event shares one identifier across its dates.
            id: "event:\(identifier):\(Int(event.startDate.timeIntervalSince1970))",
            kind: .event(identifier: identifier, color: color(event.calendar?.cgColor)),
            title: title.isEmpty ? String(localized: "Busy") : title,
            start: event.startDate, end: event.endDate, allDay: event.isAllDay,
            location: event.location.flatMap { $0.isEmpty ? nil : $0 },
            recurring: event.hasRecurrenceRules
        )
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

    // MARK: Reminders

    /// Every open reminder, dated or not.
    @MainActor
    static func reminders() async -> [AgendaItem] {
        guard remindersAllowed else { return [] }
        return await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
    }

    /// Reminders completed in the last `days`, newest first.
    @MainActor
    static func completedReminders(days: Int = 30, now: Date = Date()) async -> [AgendaItem] {
        guard remindersAllowed else { return [] }
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: now, calendars: nil)
        return await fetch(predicate).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    @MainActor
    private static func fetch(_ predicate: NSPredicate) async -> [AgendaItem] {
        let calendar = Calendar.current
        return await withCheckedContinuation { done in
            // Read into plain values where EventKit hands them over.
            store.fetchReminders(matching: predicate) { found in
                let items: [AgendaItem] = (found ?? []).map { reminder in
                    let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
                    let title = reminder.title ?? ""
                    let identifier = reminder.calendarItemIdentifier
                    return AgendaItem(
                        id: "reminder:\(identifier)",
                        kind: .reminder(identifier: identifier, color: color(reminder.calendar?.cgColor)),
                        title: title.isEmpty ? String(localized: "Reminder") : title,
                        start: due, end: nil,
                        allDay: reminder.dueDateComponents.map { $0.hour == nil } ?? false,
                        location: place(of: reminder)?.title ?? reminder.location.flatMap { $0.isEmpty ? nil : $0 },
                        notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 },
                        priority: ReminderPriority(eventKit: reminder.priority).rawValue,
                        recurring: reminder.hasRecurrenceRules,
                        list: reminder.calendar?.calendarIdentifier,
                        completed: reminder.isCompleted,
                        completedAt: reminder.completionDate
                    )
                }
                done.resume(returning: items)
            }
        }
    }

    /// Done, or not done again.
    @MainActor
    static func setCompleted(_ identifier: String, _ done: Bool) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw CalendarSync.ChangeFailure.gone
        }
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
    }

    @MainActor
    static func complete(_ identifier: String) throws {
        try setCompleted(identifier, true)
    }

    @MainActor
    static func delete(_ identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    // MARK: Lists

    /// A list in Reminders.
    struct ReminderList: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let color: AgendaColor?
        let editable: Bool
    }

    /// Every list, the default first, then by name.
    @MainActor
    static func reminderLists() -> [ReminderList] {
        guard remindersAllowed else { return [] }
        let preferred = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .sorted {
                ($0.calendarIdentifier == preferred ? 0 : 1, $0.title.localizedLowercase)
                    < ($1.calendarIdentifier == preferred ? 0 : 1, $1.title.localizedLowercase)
            }
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, color: color($0.cgColor),
                                editable: $0.allowsContentModifications) }
    }

    /// A new list, in the account new reminders go to.
    @MainActor
    @discardableResult
    static func createList(title: String, color: AgendaColor) throws -> String {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        list.cgColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else {
            throw CalendarSync.ChangeFailure.gone
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list.calendarIdentifier
    }

    @MainActor
    static func deleteList(_ id: String) throws {
        guard let list = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(list, commit: true)
    }

    // MARK: Writing a reminder

    /// What a reminder says, for adding one or changing it. `due` without a
    /// time is a day; no `due` at all is a to-do.
    struct ReminderDraft: Equatable, Sendable {
        var title = ""
        var notes = ""
        var url = ""
        var due: Date?
        var hasTime = false
        var repeats: ReminderRepeat = .never
        var priority: ReminderPriority = .none
        var place: ReminderPlace?
        var list: String?
    }

    /// The reminder as it stands, for its details.
    @MainActor
    static func draft(of identifier: String) -> ReminderDraft? {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return nil }
        let components = reminder.dueDateComponents
        return ReminderDraft(
            title: reminder.title ?? "", notes: reminder.notes ?? "",
            url: reminder.url?.absoluteString ?? "",
            due: components.flatMap { Calendar.current.date(from: $0) },
            hasTime: components?.hour != nil,
            repeats: ReminderRepeat(rule: reminder.recurrenceRules?.first),
            priority: ReminderPriority(eventKit: reminder.priority),
            place: place(of: reminder),
            list: reminder.calendar?.calendarIdentifier
        )
    }

    /// Adds a reminder, or changes the one `identifier` names. A time gets
    /// an alert at that time and a place an alert on arriving or leaving, as
    /// Reminders sets them.
    @MainActor
    @discardableResult
    static func save(_ draft: ReminderDraft, identifier: String? = nil) throws -> String {
        let reminder: EKReminder
        if let identifier {
            guard let found = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
                throw CalendarSync.ChangeFailure.gone
            }
            reminder = found
        } else {
            reminder = EKReminder(eventStore: store)
        }
        reminder.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.url = draft.url.isEmpty ? nil : URL(string: draft.url)
        let calendar = Calendar.current
        if let due = draft.due {
            let parts: Set<Calendar.Component> = draft.hasTime
                ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = calendar.dateComponents(parts, from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if let due = draft.due, draft.hasTime {
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        if let place = draft.place {
            let location = EKStructuredLocation(title: place.title)
            location.geoLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            location.radius = 150
            let alarm = EKAlarm()
            alarm.structuredLocation = location
            alarm.proximity = place.arriving ? .enter : .leave
            reminder.addAlarm(alarm)
            reminder.location = place.title
        } else {
            reminder.location = nil
        }
        reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
        // A repeat needs a date to repeat from.
        if draft.due != nil, let rule = draft.repeats.rule {
            reminder.addRecurrenceRule(rule)
        }
        reminder.priority = draft.priority.eventKit
        if let list = draft.list, let chosen = store.calendar(withIdentifier: list) {
            reminder.calendar = chosen
        } else if reminder.calendar == nil {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private static func place(of reminder: EKReminder) -> ReminderPlace? {
        guard let alarm = reminder.alarms?.first(where: { $0.structuredLocation != nil }),
              let location = alarm.structuredLocation, let geo = location.geoLocation else { return nil }
        return ReminderPlace(title: location.title ?? "", latitude: geo.coordinate.latitude,
                             longitude: geo.coordinate.longitude, arriving: alarm.proximity != .leave)
    }

    static func color(_ cg: CGColor?) -> AgendaColor? {
        guard let cg, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = cg.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return nil }
        return AgendaColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}

/// Repeat, as Reminders offers it.
enum ReminderRepeat: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekdays, weekends, weekly, biweekly, monthly, everyThreeMonths, everySixMonths, yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .daily: String(localized: "Daily")
        case .weekdays: String(localized: "Weekdays")
        case .weekends: String(localized: "Weekends")
        case .weekly: String(localized: "Weekly")
        case .biweekly: String(localized: "Biweekly")
        case .monthly: String(localized: "Monthly")
        case .everyThreeMonths: String(localized: "Every 3 Months")
        case .everySixMonths: String(localized: "Every 6 Months")
        case .yearly: String(localized: "Yearly")
        }
    }

    var rule: EKRecurrenceRule? {
        func every(_ frequency: EKRecurrenceFrequency, _ interval: Int = 1, on days: [EKWeekday]? = nil) -> EKRecurrenceRule {
            EKRecurrenceRule(
                recurrenceWith: frequency, interval: interval,
                daysOfTheWeek: days?.map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil
            )
        }
        switch self {
        case .never: return nil
        case .daily: return every(.daily)
        case .weekdays: return every(.weekly, on: [.monday, .tuesday, .wednesday, .thursday, .friday])
        case .weekends: return every(.weekly, on: [.saturday, .sunday])
        case .weekly: return every(.weekly)
        case .biweekly: return every(.weekly, 2)
        case .monthly: return every(.monthly)
        case .everyThreeMonths: return every(.monthly, 3)
        case .everySixMonths: return every(.monthly, 6)
        case .yearly: return every(.yearly)
        }
    }

    init(rule: EKRecurrenceRule?) {
        guard let rule else { self = .never; return }
        let days = Set(rule.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) ?? [])
        switch rule.frequency {
        case .daily: self = .daily
        case .weekly:
            if rule.interval == 2 { self = .biweekly }
            else if days == [2, 3, 4, 5, 6] { self = .weekdays }
            else if days == [1, 7] { self = .weekends }
            else { self = .weekly }
        case .monthly:
            self = rule.interval == 3 ? .everyThreeMonths : rule.interval == 6 ? .everySixMonths : .monthly
        case .yearly: self = .yearly
        @unknown default: self = .never
        }
    }
}

/// Priority, as Reminders shows it: "!", "!!", "!!!".
enum ReminderPriority: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, low, medium, high

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }

    var marks: String { String(repeating: "!", count: rawValue) }

    /// EventKit's scale: 1–4 high, 5 medium, 6–9 low, 0 none.
    var eventKit: Int {
        switch self {
        case .none: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        }
    }

    init(eventKit value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

/// Where a reminder goes off: arriving at a place, or leaving it.
struct ReminderPlace: Equatable, Sendable {
    var title: String
    var latitude: Double
    var longitude: Double
    var arriving = true
}
