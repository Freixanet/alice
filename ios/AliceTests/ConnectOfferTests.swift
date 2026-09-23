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

    func testTheSearchKeyOfferBecomesACard() {
        let text = "No he podido buscar.\n[Conectar búsqueda](alice://connect/search)"
        XCTAssertEqual(RichMarkdown.blocks(text), [
            .paragraph("No he podido buscar."),
            .connect("search"),
        ])
    }

    func testHermesSaysWhereTheCalendarStands() {
        XCTAssertEqual(CalendarLink.parse(["status": "declined"]), .declined)
        XCTAssertEqual(CalendarLink.parse(["status": "not_connected"]), .notConnected)
        XCTAssertTrue(CalendarLink.parse(["status": "connected", "updated_at": "2026-09-22T08:00:00+00:00"]).isConnected)
    }

    func testAProposedEventBecomesACardWithWhatWasSaid() {
        let text = "¿Lo apunto?\n[Añadir a tu calendario](alice://calendar/add?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&location=Gr%C3%A0cia)"
        let blocks = RichMarkdown.blocks(text)
        XCTAssertEqual(blocks.first, .paragraph("¿Lo apunto?"))
        guard case let .addEvent(event)? = blocks.last else { return XCTFail("no event card: \(blocks)") }
        XCTAssertEqual(event.title, "Peluquería")
        XCTAssertEqual(event.date, "2026-09-23")
        XCTAssertEqual(event.time, "17:00")
        XCTAssertEqual(event.minutes, 60)
        XCTAssertEqual(event.location, "Gràcia")
    }

    func testTheTimeIsOptionalAndABadLinkLeavesNothingBehind() {
        XCTAssertNil(RichCalendarEvent(link: "alice://calendar/add?title=X&date=2026-09-23")?.time)
        let bad = RichMarkdown.calendarAdds(in: "Hola\n[Añadir](alice://calendar/add?title=X&date=mañana)")
        XCTAssertEqual(bad.text, "Hola")
        XCTAssertTrue(bad.events.isEmpty)
    }

    func testCardsSpeakTheConversationsLanguage() {
        XCTAssertEqual(ChatLanguage.of("Cita en la peluquería el miércoles 23. ¿Lo apunto en tu calendario, cielo?"), .spanish)
        XCTAssertEqual(ChatLanguage.of("Haircut on Wednesday the 23rd. Shall I add it to your calendar?"), .english)
        XCTAssertEqual(ChatLanguage.spanish.pick("Open", "Abrir"), "Abrir")
    }
}
