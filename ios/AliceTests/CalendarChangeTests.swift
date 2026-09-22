import XCTest
@testable import Alice

/// Reading an agent's proposal to move or cancel an event.
final class CalendarChangeTests: XCTestCase {
    func testAMoveBecomesACard() {
        let blocks = RichMarkdown.blocks("¿La paso al jueves a las 18?\n[Mover peluquería](alice://calendar/move?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&to_date=2026-09-24&to_time=18:00)")
        guard case let .changeEvent(change) = blocks.last else { return XCTFail("\(blocks)") }
        XCTAssertEqual(change.kind, .move)
        XCTAssertEqual(change.title, "Peluquería")
        XCTAssertEqual(change.toDate, "2026-09-24")
        XCTAssertEqual(change.toTime, "18:00")
        XCTAssertEqual(blocks.first, .paragraph("¿La paso al jueves a las 18?"))
    }

    func testACancellationNeedsNoTarget() {
        let change = RichCalendarChange(link: "alice://calendar/cancel?title=Dentista&date=2026-09-25")
        XCTAssertEqual(change?.kind, .cancel)
        XCTAssertNil(change?.time)
    }

    func testAMoveWithNowhereToGoIsDropped() {
        XCTAssertNil(RichCalendarChange(link: "alice://calendar/move?title=Dentista&date=2026-09-25"))
        XCTAssertNil(RichCalendarChange(link: "alice://calendar/delete?title=X&date=2026-09-25"))
    }
}
