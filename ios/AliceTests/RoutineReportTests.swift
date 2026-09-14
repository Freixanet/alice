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

    private func message(_ id: String, _ role: Message.Role, _ content: String) -> Message {
        Message(id: id, role: role, content: content, createdAt: Date(timeIntervalSince1970: 1_789_500_000), remoteID: id)
    }

    private let report = "[Cronjob \"Chollos del dia\" output — scheduled job, not the user. Review it.]\n\n**FILA -85%**"

    func testAReportIsShownOnceAsTheBotsMessage() {
        let shown = RoutineDelivery.present([
            message("1", .assistant, "Hola"),
            message("2", .user, report),
            message("3", .assistant, "**FILA -85%**"),
        ], botName: "chollometro")
        XCTAssertEqual(shown.map(\.id), ["1", "2"])
        XCTAssertEqual(shown[1].role, .assistant)
        XCTAssertEqual(shown[1].content, "**FILA -85%**")
        XCTAssertEqual(shown[1].botName, "chollometro")
        XCTAssertEqual(shown[1].routineName, "Chollos del dia")
    }

    func testTheBotsCommentOnAReportIsLeftOutButTheNextExchangeIsNot() {
        let shown = RoutineDelivery.present([
            message("1", .user, report),
            message("2", .assistant, "La rutina de hoy funcionó y su contenido cuadra."),
            message("3", .user, "¿Y el hotel?"),
            message("4", .assistant, "Es en Blanes."),
        ], botName: "chollometro")
        XCTAssertEqual(shown.map(\.id), ["1", "3", "4"])
        XCTAssertEqual(shown.map(\.role), [.assistant, .user, .assistant])
    }

    func testAnApprovalTheBotWaitsOnStaysVisible() {
        var asking = message("2", .assistant, "")
        asking.approval = .init(runID: "r", title: "terminal", choices: [.once, .deny])
        let shown = RoutineDelivery.present([message("1", .user, report), asking], botName: "radar-ia")
        XCTAssertEqual(shown.map(\.id), ["1", "2"])
    }

    func testOrdinaryMessagesAreNotReports() {
        XCTAssertNil(RoutineReport("hola"))
        XCTAssertNil(RoutineReport("¿Qué dice el [Cronjob \"Radar\" output — scheduled job, not the user.]?"))
        XCTAssertNil(RoutineReport("[Cronjob \"Radar\" output]\n\nsin la marca de Hermes"))
        XCTAssertNil(RoutineReport("[Cronjob \"\" output — scheduled job, not the user.]\n\nsin nombre"))
    }
}
