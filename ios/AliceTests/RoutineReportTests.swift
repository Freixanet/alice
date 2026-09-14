import XCTest
@testable import Alice

/// Stock Hermes hands a routine's report to a bot's chat as a turn addressed to
/// the bot. Alice shows it as the routine's report, never as the person's words.
final class RoutineReportTests: XCTestCase {

    func testHermesDeliveryIsReadAsTheRoutinesReport() {
        let text = "[Cronjob \"Radar IA — informe diario\" output — scheduled job, not the user. "
            + "Review it, act on anything that needs action, and summarize for the chat.]\n\n"
            + "## Radar\n- uno\n- dos\n"
        XCTAssertEqual(
            RoutineReport(text),
            RoutineReport(name: "Radar IA — informe diario", body: "## Radar\n- uno\n- dos")
        )
    }

    func testAChangedInstructionAfterTheNameStillParses() {
        let text = "[Cronjob \"Chollos del dia\" output — scheduled job, not the user. Just post it.]\n\nOfertas"
        XCTAssertEqual(RoutineReport(text), RoutineReport(name: "Chollos del dia", body: "Ofertas"))
    }

    func testBracketsInTheReportAreLeftAlone() {
        let text = "[Cronjob \"Monitor [beta]\" output — scheduled job, not the user. Review it.]\n\n[link](https://example.com)"
        XCTAssertEqual(
            RoutineReport(text),
            RoutineReport(name: "Monitor [beta]", body: "[link](https://example.com)")
        )
    }

    func testOrdinaryMessagesAreNotReports() {
        XCTAssertNil(RoutineReport("hola"))
        XCTAssertNil(RoutineReport("¿Qué dice el [Cronjob \"Radar\" output — scheduled job, not the user.]?"))
        XCTAssertNil(RoutineReport("[Cronjob \"Radar\" output]\n\nsin la marca de Hermes"))
        XCTAssertNil(RoutineReport("[Cronjob \"\" output — scheduled job, not the user.]\n\nsin nombre"))
    }
}
