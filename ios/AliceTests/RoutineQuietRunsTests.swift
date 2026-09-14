import XCTest
@testable import Alice

/// Hermes sends nothing when a routine finds nothing. Alice reads the run and
/// shows a card, so "no news" never looks like "not working".
final class RoutineQuietRunsTests: XCTestCase {
    private let finished = Date(timeIntervalSince1970: 1_789_408_423)

    private var run: [String: Any] {
        ["id": "cron_6abe3aebcb41_20260914_195141", "end_reason": "cron_complete", "ended_at": 1_789_408_423.0]
    }

    func testHermesSilenceIsRecognisedTheWayHermesRecognisesIt() {
        for silent in ["[SILENT]", "  [silent] nada nuevo", "SILENT", "NO_REPLY", "Revisado todo.\n[SILENT]"] {
            XCTAssertTrue(QuietRoutineRun.isSilence(silent), silent)
        }
        for spoken in ["", "Silent retry succeeded", "**Hermes v0.21.3** salió", "Hoy no hay [SILENT] novedades"] {
            XCTAssertFalse(QuietRoutineRun.isSilence(spoken), spoken)
        }
    }

    func testARunWhoseFinalAnswerWasSilenceIsQuiet() {
        let messages: [[String: Any]] = [
            ["id": 372, "role": "assistant", "content": "[SILENT]"],
            ["id": 371, "role": "tool", "content": "{\"results\": []}"],
            ["id": 370, "role": "assistant", "content": ""],
            ["id": 369, "role": "assistant", "content": "Buscando en el Federal Register"],
        ]
        XCTAssertEqual(
            QuietRoutineRun(run: run, messages: messages, routineName: "Monitor Cuba — informe diario"),
            QuietRoutineRun(id: "cron_6abe3aebcb41_20260914_195141", routineName: "Monitor Cuba — informe diario", finishedAt: finished)
        )
    }

    func testARunThatReportedOrHasNotFinishedIsNotQuiet() {
        let reported: [[String: Any]] = [["id": 9, "role": "assistant", "content": "**Nueva orden de OFAC**"]]
        XCTAssertNil(QuietRoutineRun(run: run, messages: reported, routineName: "Monitor Cuba"))

        var running = run
        running["end_reason"] = NSNull()
        XCTAssertNil(QuietRoutineRun(run: running, messages: [["id": 1, "role": "assistant", "content": "[SILENT]"]], routineName: "Monitor Cuba"))
    }

    func testOnlyRoutinesDeliveringToTheBotsChatAreLookedAt() {
        XCTAssertTrue(QuietRoutineRun.deliversToBotChat("bot-chat"))
        XCTAssertTrue(QuietRoutineRun.deliversToBotChat("origin, bot-chat:radar-ia"))
        XCTAssertFalse(QuietRoutineRun.deliversToBotChat("telegram"))
        XCTAssertFalse(QuietRoutineRun.deliversToBotChat(nil))
    }

    func testANoNewsCardSitsWhereTheRunHappened() {
        let before = Message(id: "a", role: .assistant, content: "Informe de ayer", createdAt: finished.addingTimeInterval(-86_400), remoteID: "a")
        let after = Message(id: "b", role: .user, content: "¿Algo nuevo?", createdAt: finished.addingTimeInterval(600), remoteID: "b")
        let quiet = QuietRoutineRun(id: "r1", routineName: "Monitor Cuba — informe diario", finishedAt: finished)

        let shown = RoutineDelivery.present([before, after], botName: "537", quietRuns: [quiet, quiet])
        XCTAssertEqual(shown.map(\.id), ["a", "quiet:r1", "b"])
        XCTAssertEqual(shown[1].content, RoutineDelivery.noNews)
        XCTAssertEqual(shown[1].routineName, "Monitor Cuba — informe diario")
        XCTAssertEqual(shown[1].botName, "537")
        XCTAssertEqual(shown[1].role, .assistant)
    }
}
