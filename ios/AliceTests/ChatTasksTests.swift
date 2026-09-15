import XCTest
@testable import Alice

/// One request, one message: the agent's consecutive replies are one task.
final class ChatTasksTests: XCTestCase {
    private let now = Date()

    private func message(_ id: String, _ role: Message.Role, _ content: String = "x", routine: String? = nil) -> Message {
        var message = Message(id: id, role: role, content: content, createdAt: now)
        message.routineName = routine
        return message
    }

    func testConsecutiveRepliesAreOneTaskWithOneTimeAndOneSetOfActions() {
        let messages = [
            message("u1", .user, "Valida la idea"),
            message("a1", .assistant, "Consultando al equipo."),
            message("card", .assistant, "ENTREGA de Mercado"),
            message("a2", .assistant, "Recomendación final."),
            message("u2", .user, "Gracias"),
            message("a3", .assistant, "De nada."),
        ]
        let positions = ChatTasks.positions(messages)
        XCTAssertNil(positions["u1"])
        XCTAssertEqual(positions["a1"]?.isFirst, true)
        XCTAssertEqual(positions["a1"]?.isLast, false)
        XCTAssertEqual(positions["card"]?.isFirst, false)
        XCTAssertEqual(positions["a2"]?.isLast, true)
        XCTAssertEqual(positions["a2"]?.isLatest, false)
        XCTAssertEqual(positions["a2"]?.text, "Consultando al equipo.\n\nENTREGA de Mercado\n\nRecomendación final.")
        XCTAssertEqual(positions["a3"], .init(isFirst: true, isLast: true, isLatest: true, text: "De nada."))
    }

    func testARoutineReportIsAMessageOfItsOwn() {
        let messages = [
            message("a1", .assistant, "Hecho."),
            message("r1", .assistant, "Informe diario", routine: "Radar IA"),
            message("a2", .assistant, "Comentario."),
        ]
        let positions = ChatTasks.positions(messages)
        XCTAssertEqual(positions["a1"]?.isLast, true)
        XCTAssertEqual(positions["r1"], .init(isFirst: true, isLast: true, isLatest: false, text: "Informe diario"))
        XCTAssertEqual(positions["a2"]?.isFirst, true)
    }
}
