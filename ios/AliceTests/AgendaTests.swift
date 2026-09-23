import XCTest
@testable import Alice

final class AgendaTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    /// Wednesday 23 September 2026, 20:00 in Madrid.
    private var now: Date { date(23, 20, 0) }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, minutes: Int = 60, allDay: Bool = false) -> AgendaItem {
        AgendaItem(id: id, kind: .event(identifier: id, color: nil), title: id, start: start,
                   end: start.addingTimeInterval(TimeInterval(minutes * 60)), allDay: allDay, location: nil)
    }

    private func reminder(_ id: String, _ due: Date?) -> AgendaItem {
        AgendaItem(id: id, kind: .reminder(identifier: id, color: nil), title: id, start: due,
                   end: nil, allDay: false, location: nil)
    }

    func testDaysComeInOrderWithOverdueFirstAndUndatedLast() {
        let items = [
            event("hairdresser", date(24, 11, 30)),
            event("dinner", date(23, 21, 0)),
            event("morning", date(23, 9, 0)),
            event("holiday", calendar.startOfDay(for: date(23, 0, 0)), minutes: 24 * 60, allDay: true),
            reminder("pay rent", date(20, 10, 0)),
            reminder("call mum", nil),
            event("far away", date(23, 10, 0).addingTimeInterval(20 * 24 * 3600)),
        ]
        let days = Agenda.days(items, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.label), [.overdue, .today, .tomorrow, .someday])
        XCTAssertEqual(days[0].items.map(\.id), ["pay rent"])
        // All-day first, then by time; what is over stays on today, faded by the view.
        XCTAssertEqual(days[1].items.map(\.id), ["holiday", "morning", "dinner"])
        XCTAssertEqual(days[2].items.map(\.id), ["hairdresser"])
        XCTAssertEqual(days[3].items.map(\.id), ["call mum"])
    }

    func testAnEventStillRunningFromYesterdayIsOnToday() {
        let overnight = event("flight", date(22, 23, 0), minutes: 22 * 60)
        let days = Agenda.days([overnight], now: now, calendar: calendar)
        XCTAssertEqual(days.first?.label, .today)
        XCTAssertTrue(Agenda.days([event("done", date(22, 10, 0))], now: now, calendar: calendar).isEmpty)
    }

    func testNextIsTheNextTimedThingWithinADayAndAHalf() {
        let items = [
            event("over", date(23, 18, 0)),
            event("holiday", date(24, 0, 0), minutes: 24 * 60, allDay: true),
            event("hairdresser", date(24, 11, 30)),
            reminder("undated", nil),
        ]
        XCTAssertEqual(Agenda.next(items, now: now)?.id, "hairdresser")
        XCTAssertNil(Agenda.next([event("later", date(26, 10, 0))], now: now))
    }

    func testGlanceSaysTodayTomorrowOrTheWeekday() {
        let item = event("Peluquería", date(24, 11, 30))
        let line = Agenda.glance(item, now: now, calendar: calendar)
        XCTAssertTrue(line.hasSuffix("· Peluquería"), line)
        XCTAssertTrue(line.contains(item.start!.formatted(date: .omitted, time: .shortened)), line)
    }

    func testCountdown() {
        XCTAssertEqual(Agenda.countdown(to: now.addingTimeInterval(25 * 60), now: now), "In 25 min")
        XCTAssertEqual(Agenda.countdown(to: now.addingTimeInterval(90 * 60), now: now), "In 1 h 30 min")
        XCTAssertEqual(Agenda.countdown(to: now.addingTimeInterval(4 * 3600 + 600), now: now), "In 4 h")
        XCTAssertEqual(Agenda.countdown(to: now.addingTimeInterval(-60), now: now), "Now")
    }

    func testNowAndPast() {
        let running = event("call", now.addingTimeInterval(-600), minutes: 30)
        XCTAssertTrue(running.isNow(now))
        XCTAssertFalse(running.isPast(now))
        XCTAssertTrue(event("before", now.addingTimeInterval(-7200)).isPast(now))
        // A reminder is never "past": it waits until it is ticked.
        XCTAssertFalse(reminder("late", now.addingTimeInterval(-86400)).isPast(now))
    }

    func testAliceRemindersAreOneTimeRoutinesStillToCome() {
        func row(_ id: String, times: Int?, done: Int? = nil, next: Date?, state: String? = "scheduled") -> JobRow {
            var row = JobRow(id: id, name: "Recordar \(id)", prompt: "", schedule: "once", enabled: true,
                             lastStatus: nil, lastError: nil, lastRun: nil, nextRun: next, profile: "default")
            row.repeatTimes = times
            row.repeatCompleted = done
            row.state = state
            return row
        }
        let items = Agenda.aliceReminders([
            row("a", times: 1, next: date(24, 10, 0)),
            row("daily", times: nil, next: date(24, 8, 0)),
            row("sent", times: 1, done: 1, next: date(24, 10, 0)),
            row("gone", times: 1, next: date(23, 10, 0)),
            row("paused", times: 1, next: date(24, 10, 0), state: "paused"),
        ], now: now)
        XCTAssertEqual(items.map(\.id), ["alice:default/a"])
        XCTAssertTrue(items[0].isAlice)
    }

    func testTheHomeMentionsTheNextCommitment() {
        let rows = HomeSuggestions.make(nextUp: "Tomorrow 11:30 · Peluquería", now: now)
        XCTAssertEqual(rows.first?.id, "agenda-next")
        XCTAssertEqual(rows.first?.action, .agenda)
        XCTAssertEqual(rows.first?.symbol, "calendar")
        XCTAssertTrue(HomeSuggestions.make(nextUp: "", now: now).isEmpty)
    }
}
