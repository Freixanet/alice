import XCTest
@testable import Alice

/// An agent offers a connection with `[…](alice://connect/<service>)`; the
/// chat shows it as a card, never as a link that goes nowhere.
final class ConnectOfferTests: XCTestCase {
    func testTheOfferBecomesACardAndLeavesTheText() {
        let text = "Puedo verlo si conectas tu calendario.\n[Conectar calendario](alice://connect/calendar)"
        let blocks = RichMarkdown.blocks(text)
        XCTAssertEqual(blocks, [
            .paragraph("Puedo verlo si conectas tu calendario."),
            .connect("calendar"),
        ])
    }

    func testAServiceTheAppCannotConnectIsDropped() {
        let offers = RichMarkdown.connectOffers(in: "Hola\n[Conectar](alice://connect/fax)")
        XCTAssertEqual(offers.text, "Hola")
        XCTAssertTrue(offers.services.isEmpty)
    }

    func testHermesSaysWhereTheCalendarStands() {
        XCTAssertEqual(CalendarLink.parse(["status": "declined"]), .declined)
        XCTAssertEqual(CalendarLink.parse(["status": "not_connected"]), .notConnected)
        XCTAssertTrue(CalendarLink.parse(["status": "connected", "updated_at": "2026-09-22T08:00:00+00:00"]).isConnected)
    }
}
