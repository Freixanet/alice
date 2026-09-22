import XCTest
@testable import Alice

/// An agent's ```alice-ui block becomes a component; anything that is not a
/// component it can read stays the code it was, so nothing is lost.
final class UIComponentTests: XCTestCase {
    private func component(_ json: String, fence: String = "alice-ui") -> RichBlock? {
        RichMarkdown.blocks("Here you go:\n```\(fence)\n\(json)\n```").last
    }

    func testPlacesBecomeACarousel() {
        let block = component(#"{"type":"places","items":[{"title":"La Pubilla","subtitle":"Lunch","image":"https://example.com/a.jpg","query":"La Pubilla Barcelona"}]}"#)
        guard case let .component(.places(places)) = block else { return XCTFail("\(String(describing: block))") }
        XCTAssertEqual(places.first?.title, "La Pubilla")
        XCTAssertEqual(places.first?.image?.absoluteString, "https://example.com/a.jpg")
        XCTAssertEqual(places.first?.query, "La Pubilla Barcelona")
    }

    func testOnlyWebAddressesAreKept() {
        let block = component(#"{"type":"products","items":[{"title":"Tray","image":"file:///etc/passwd","url":"javascript:alert(1)","price":"25 €"}]}"#)
        guard case let .component(.products(products)) = block else { return XCTFail() }
        XCTAssertNil(products.first?.image)
        XCTAssertNil(products.first?.url)
        XCTAssertEqual(products.first?.price, "25 €")
    }

    func testEventsReadLocalAndISOTimes() {
        let block = component(#"{"type":"events","items":[{"title":"Haircut","start":"2026-09-23T17:00"},{"title":"Call","start":"2026-09-24T09:30:00Z"}]}"#)
        guard case let .component(.events(events)) = block else { return XCTFail() }
        XCTAssertEqual(events.count, 2)
        XCTAssertNotNil(events[0].start)
        XCTAssertNotNil(events[1].start)
    }

    func testEmailKeepsItsBody() {
        let block = component(#"{"type":"email","to":"laura@example.com","subject":"Thursday","body":"Hi Laura,\n\nFriday?"}"#)
        XCTAssertEqual(block, .component(.email(.init(to: "laura@example.com", subject: "Thursday", body: "Hi Laura,\n\nFriday?"))))
    }

    func testMonthNeedsNoData() {
        XCTAssertEqual(component(#"{"type":"calendar","month":"2026-09"}"#), .component(.calendar(month: "2026-09")))
        XCTAssertNotNil(MonthCard.parse("2026-09"))
    }

    func testUnreadableStaysCode() {
        let broken = #"{"type":"places","items":["#
        XCTAssertEqual(component(broken), .code(language: "alice-ui", text: broken))
        let unknown = #"{"type":"hologram"}"#
        XCTAssertEqual(component(unknown), .code(language: "alice-ui", text: unknown))
        let empty = #"{"type":"places","items":[]}"#
        XCTAssertEqual(component(empty), .code(language: "alice-ui", text: empty))
    }

    func testOtherCodeIsUntouched() {
        let json = #"{"type":"places","items":[{"title":"A"}]}"#
        XCTAssertEqual(component(json, fence: "json"), .code(language: "json", text: json))
    }
}
