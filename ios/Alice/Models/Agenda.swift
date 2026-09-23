import Foundation

/// One commitment: an event on the phone's calendar, a reminder in Reminders,
/// or something Alice has promised to bring up (a routine that runs once).
struct AgendaItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// `identifier` is EventKit's; `color` the calendar's, as RGB.
        case event(identifier: String, color: AgendaColor?)
        /// A to-do in Reminders; `due` may be absent ("someday").
        case reminder(identifier: String, color: AgendaColor?)
        /// A one-time routine: Alice writes to the person at `start`.
        case alice(profile: String?, routine: String)
    }

    var id: String
    var kind: Kind
    var title: String
    /// Nil only for an undated reminder.
    var start: Date?
    var end: Date?
    var allDay: Bool
    var location: String?
    // Reminders only.
    var notes: String? = nil
    /// Reminders' own scale as it shows it: 0 none, 1 low (!), 2 medium (!!), 3 high (!!!).
    var priority: Int = 0
    var recurring: Bool = false
    /// The list (EventKit calendar) it is in.
    var list: String? = nil
    var completed: Bool = false
    var completedAt: Date? = nil

    var isReminder: Bool { if case .reminder = kind { true } else { false } }
    var isAlice: Bool { if case .alice = kind { true } else { false } }

    /// Under way now: started, not ended. All-day items are not "now" — they
    /// are the day itself.
    func isNow(_ now: Date) -> Bool {
        guard !allDay, let start, let end else { return false }
        return start <= now && now < end
    }

    /// Over: an event that has ended, an Alice reminder already sent. A
    /// reminder stays until it is ticked, however late.
    func isPast(_ now: Date) -> Bool {
        if isReminder { return false }
        if allDay { return false }
        return (end ?? start ?? .distantFuture) <= now
    }
}

/// A calendar's colour without UIKit, so the model stays testable.
struct AgendaColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// One day of the agenda, and what is on it.
struct AgendaDay: Identifiable, Hashable, Sendable {
    enum Label: Hashable, Sendable {
        /// Reminders whose date has passed and are still open.
        case overdue
        case today
        case tomorrow
        case day(Date)
        /// Reminders with no date.
        case someday
    }

    var id: String
    var label: Label
    var items: [AgendaItem]
}

enum Agenda {
    /// How far ahead the page looks.
    static let horizonDays = 14
    /// How far ahead the home says what is next.
    static let glanceHours: Double = 36

    /// Days in order, each sorted all-day first and then by time. Past days
    /// are dropped; today keeps what is over (shown faded) so the day reads
    /// whole. Overdue reminders come first; undated ones last.
    static func days(_ items: [AgendaItem], now: Date, calendar: Calendar = .current) -> [AgendaDay] {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        var overdue: [AgendaItem] = []
        var someday: [AgendaItem] = []
        var byDay: [Date: [AgendaItem]] = [:]
        for item in unique(items) {
            guard let start = item.start else {
                if item.isReminder { someday.append(item) }
                continue
            }
            let day = calendar.startOfDay(for: start)
            if day < today {
                // An event that began before today and still runs belongs to today.
                if item.isReminder {
                    overdue.append(item)
                } else if let end = item.end, end > today {
                    byDay[today, default: []].append(item)
                }
                continue
            }
            guard day < horizon else { continue }
            byDay[day, default: []].append(item)
        }
        var days: [AgendaDay] = []
        if !overdue.isEmpty {
            days.append(AgendaDay(id: "overdue", label: .overdue, items: overdue.sorted(by: order)))
        }
        for day in byDay.keys.sorted() {
            let label: AgendaDay.Label = day == today ? .today : day == tomorrow ? .tomorrow : .day(day)
            days.append(AgendaDay(id: "d\(Int(day.timeIntervalSince1970))", label: label,
                                  items: byDay[day]!.sorted(by: order)))
        }
        if !someday.isEmpty {
            days.append(AgendaDay(id: "someday", label: .someday,
                                  items: someday.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }))
        }
        return days
    }

    /// The next thing that has a time and has not started, within the glance
    /// window: what the home mentions. All-day items and undated reminders are
    /// not "next" — nothing happens at a moment.
    static func next(_ items: [AgendaItem], now: Date) -> AgendaItem? {
        items
            .filter { !$0.allDay && ($0.start.map { $0 > now && $0.timeIntervalSince(now) <= glanceHours * 3600 } ?? false) }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Alice's promises to write: routines that run once and have not yet.
    static func aliceReminders(_ routines: [JobRow], now: Date) -> [AgendaItem] {
        routines.compactMap { row in
            guard row.repeatTimes == 1, !row.isCompleted, !row.isPaused,
                  (row.repeatCompleted ?? 0) < 1, let next = row.nextRun, next > now
            else { return nil }
            let title = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgendaItem(
                id: "alice:\(row.listIdentity)", kind: .alice(profile: row.profile, routine: row.id),
                title: title.isEmpty ? String(localized: "Reminder from Alice") : title,
                start: next, end: nil, allDay: false, location: nil
            )
        }
    }

    /// "Miércoles, 23 de septiembre": the day, as the agenda and the home title it.
    static func dayTitle(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "Jueves": a day's name, capitalised as a heading.
    static func weekday(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide))
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// A line for the home: "Tomorrow 11:30 · Hairdresser".
    static func glance(_ item: AgendaItem, now: Date, calendar: Calendar = .current) -> String {
        guard let start = item.start else { return item.title }
        let time = start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(start, inSameDayAs: now) {
            return String(localized: "Today \(time) · \(item.title)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow \(time) · \(item.title)")
        }
        return "\(start.formatted(.dateTime.weekday(.wide))) \(time) · \(item.title)"
    }

    /// "in 25 min", "in 2 h", "now" — how soon, for the next item's card.
    static func countdown(to start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return String(localized: "Now") }
        if minutes < 60 { return String(localized: "In \(minutes) min") }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 || hours >= 3
                ? String(localized: "In \(hours) h")
                : String(localized: "In \(hours) h \(rest) min")
        }
        let days = Int((Double(minutes) / 1440).rounded())
        return String(localized: "In \(days) days")
    }

    // Sorting: all-day first, then by time, then by title for a stable list.
    private static func order(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        if a.allDay != b.allDay { return a.allDay }
        let sa = a.start ?? .distantFuture, sb = b.start ?? .distantFuture
        if sa != sb { return sa < sb }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }

    /// An event the phone lists twice (shared calendars) shows once.
    private static func unique(_ items: [AgendaItem]) -> [AgendaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
