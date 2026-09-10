import XCTest
@testable import Alice

/// Replies are dated above themselves and bots are dated at the end of their
/// row. A turn Hermes sent without a time must not be dated 1970.
final class MessageTimeTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }
    private let locale = Locale(identifier: "en_GB")

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(10, 12, 0) }

    private func time(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }

    func testAnUnknownTimeIsNotDated() {
        XCTAssertNil(MessageTime.caption(Date(timeIntervalSince1970: 0), now: now, calendar: calendar, locale: locale))
        XCTAssertNil(MessageTime.short(Date(timeIntervalSince1970: 0), now: now, calendar: calendar, locale: locale))
    }

    func testTodayIsJustTheTime() {
        let sent = date(10, 9, 5)
        XCTAssertEqual(MessageTime.caption(sent, now: now, calendar: calendar, locale: locale), time(sent))
        XCTAssertEqual(MessageTime.short(sent, now: now, calendar: calendar, locale: locale), time(sent))
    }

    func testYesterdaySaysSo() {
        let sent = date(9, 23, 50)
        XCTAssertEqual(MessageTime.caption(sent, now: now, calendar: calendar, locale: locale), "Yesterday \(time(sent))")
        XCTAssertEqual(MessageTime.short(sent, now: now, calendar: calendar, locale: locale), "Yesterday")
    }

    func testTheAgeBandsFollowTheCalendarDay() {
        XCTAssertEqual(MessageTime.age(of: date(10, 0, 1), now: now, calendar: calendar), .today)
        XCTAssertEqual(MessageTime.age(of: date(9, 23, 59), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(MessageTime.age(of: date(5, 12, 0), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(MessageTime.age(of: date(1, 12, 0), now: now, calendar: calendar), .thisYear)
        XCTAssertEqual(MessageTime.age(of: date(20, 12, 0, month: 12, year: 2025), now: now, calendar: calendar), .older)
    }

    /// Older than a week, the caption carries the date; a different year, the year too.
    func testOlderRepliesCarryTheirDate() throws {
        let thisYear = try XCTUnwrap(MessageTime.caption(date(1, 8, 30), now: now, calendar: calendar, locale: locale))
        XCTAssertTrue(thisYear.hasSuffix(", \(time(date(1, 8, 30)))"), thisYear)
        XCTAssertFalse(thisYear.contains("2026"), thisYear)
        let lastYear = try XCTUnwrap(MessageTime.short(date(20, 8, 30, month: 12, year: 2025), now: now, calendar: calendar, locale: locale))
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
    }
}
