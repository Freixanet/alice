import EventKit
import Foundation
import Observation

/// What the Agenda shows, read once and shared by every view of it — day,
/// list, month and the reminder lists — so they never disagree.
///
/// Events are read for a window around the day being looked at; reminders
/// all at once, since Reminders itself keeps them few enough to hold. Any
/// change to the phone's calendars or reminders, from this app or another,
/// reloads it.
@MainActor
@Observable
final class AgendaModel {
    private(set) var events: [AgendaItem] = []
    private(set) var reminders: [AgendaItem] = []
    private(set) var completed: [AgendaItem] = []
    private(set) var lists: [AgendaSource.ReminderList] = []
    /// Alice's own promises to write: one-time routines on Hermes.
    private(set) var fromAlice: [AgendaItem] = []
    private(set) var loaded = false
    private(set) var hasCalendar = CalendarSync.hasAccess
    private(set) var hasReminders = AgendaSource.remindersAllowed

    /// The window events are read for.
    private(set) var window: DateInterval

    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored private var showsCompleted = false

    init(now: Date = Date()) {
        window = Self.window(around: now)
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Six weeks back to ten ahead of a day: every view of it, the month
    /// grid included, has what it shows.
    static func window(around day: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let from = calendar.date(byAdding: .day, value: -42, to: start) ?? start
        let to = calendar.date(byAdding: .day, value: 70, to: start) ?? start
        return DateInterval(start: from, end: to)
    }

    /// Moves the window when the day looked at nears its edge.
    func look(at day: Date) async {
        let margin: TimeInterval = 21 * 86_400
        guard day.timeIntervalSince(window.start) < margin || window.end.timeIntervalSince(day) < margin else { return }
        window = Self.window(around: day)
        events = AgendaSource.events(from: window.start, to: window.end)
    }

    func reload() async {
        hasCalendar = CalendarSync.hasAccess
        hasReminders = AgendaSource.remindersAllowed
        events = AgendaSource.events(from: window.start, to: window.end)
        reminders = await AgendaSource.reminders()
        lists = AgendaSource.reminderLists()
        if showsCompleted { completed = await AgendaSource.completedReminders() }
        loaded = true
    }

    func loadCompleted() async {
        showsCompleted = true
        completed = await AgendaSource.completedReminders()
    }

    func setAlice(_ items: [AgendaItem]) {
        fromAlice = items
    }

    /// Asks for whichever of Calendar and Reminders is still unanswered.
    func requestAccess() async {
        if !CalendarSync.hasAccess, !CalendarSync.refused { _ = await CalendarSync.requestAccess() }
        if !AgendaSource.remindersAllowed, !AgendaSource.remindersRefused { _ = await AgendaSource.requestReminders() }
        await reload()
    }

    // MARK: Reading

    /// Everything dated on one day: events that touch it, reminders due on
    /// it, Alice's on it. Today also carries what is overdue.
    func items(on day: Date, now: Date = Date(), calendar: Calendar = .current) -> [AgendaItem] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let dayEvents = events.filter { event in
            guard let from = event.start else { return false }
            let to = event.end ?? from
            return from < end && (to > start || from >= start)
        }
        let dayReminders = reminders.filter { reminder in
            guard let due = reminder.start else { return false }
            return (due >= start && due < end) || (isToday && due < start)
        }
        let dayAlice = fromAlice.filter { ($0.start.map { $0 >= start && $0 < end }) ?? false }
        return dayEvents + dayReminders + dayAlice
    }

    /// Whether a day has anything, for the dot under it.
    func hasItems(on day: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        let touches: (AgendaItem) -> Bool = { item in
            guard let from = item.start else { return false }
            return from < end && ((item.end ?? from) > start || from >= start)
        }
        return events.contains(where: touches) || reminders.contains(where: touches) || fromAlice.contains(where: touches)
    }

    /// Everything the list view shows: events in the window from today, all
    /// open reminders, Alice's.
    var all: [AgendaItem] { events + reminders + fromAlice }

    func count(in list: String) -> Int {
        reminders.filter { $0.list == list }.count
    }

    func list(_ id: String?) -> AgendaSource.ReminderList? {
        guard let id else { return nil }
        return lists.first { $0.id == id }
    }
}
