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

    func testNoNewsIsTheAgentsMessageNotACard() {
        let before = Message(id: "a", role: .assistant, content: "Informe de ayer", createdAt: finished.addingTimeInterval(-86_400), remoteID: "a")
        let after = Message(id: "b", role: .user, content: "¿Algo nuevo?", createdAt: finished.addingTimeInterval(600), remoteID: "b")
        let quiet = QuietRoutineRun(id: "r1", routineName: "Monitor Cuba — informe diario", finishedAt: finished)

        let shown = RoutineDelivery.present([before, after], botName: "537", quietRuns: [quiet, quiet])
        XCTAssertEqual(shown.map(\.id), ["a", "quiet:r1", "b"])
        // Without the agent's own words, a sentence in its voice — never a card.
        XCTAssertEqual(shown[1].content, RoutineDelivery.noNews("Monitor Cuba — informe diario"))
        XCTAssertNil(shown[1].routineName)
        XCTAssertEqual(shown[1].botName, "537")
        XCTAssertEqual(shown[1].role, .assistant)
    }

    func testTheAgentsOwnWordsAboutNothingNewAreKept() {
        let messages: [[String: Any]] = [["id": 9, "role": "assistant",
            "content": "Hoy he repasado USCIS, OFAC y elTOQUE: nada ha cambiado desde ayer. Mañana vuelvo a mirar.\n[SILENT]"]]
        let quiet = QuietRoutineRun(run: run, messages: messages, routineName: "Monitor Cuba")
        XCTAssertEqual(quiet?.note, "Hoy he repasado USCIS, OFAC y elTOQUE: nada ha cambiado desde ayer. Mañana vuelvo a mirar.")
        let shown = RoutineDelivery.present([], botName: "537", quietRuns: [quiet!])
        XCTAssertEqual(shown.first?.content, quiet?.note)
        XCTAssertNil(shown.first?.routineName)
        XCTAssertNil(QuietRoutineRun.note(in: "[SILENT]"))
    }

    func testAReportOpensWithTheAgentsMessageAndKeepsTheCard() {
        let body = "Buenos días: hoy hay dos cosas que te van a interesar, sobre todo la segunda.\n---\n## Radar\n- Uno\n- Dos"
        let turn = Message(id: "r", role: .user,
                           content: "[Cronjob \"Radar IA\" output — scheduled job, not the user.]\n\n" + body,
                           createdAt: finished, remoteID: "r")
        let shown = RoutineDelivery.present([turn], botName: "radar-ia")
        XCTAssertEqual(shown.map(\.id), ["r:intro", "r"])
        XCTAssertEqual(shown[0].content, "Buenos días: hoy hay dos cosas que te van a interesar, sobre todo la segunda.")
        XCTAssertNil(shown[0].routineName)
        XCTAssertEqual(shown[1].routineName, "Radar IA")
        XCTAssertEqual(shown[1].content, "## Radar\n- Uno\n- Dos")
        // No separator: all of it is the report, as before.
        XCTAssertNil(RoutineReport.split("Solo el informe\n- Uno").intro)
    }

    func testOnlyReportRoutinesSayTheyFoundNothing() {
        for schedule in ["0 10 * * *", "30 7 * * *", "0 9,21 * * *", "daily at 10am", "weekly on monday", "0 19 * * 0"] {
            XCTAssertTrue(QuietRoutineRun.runsAtMostDaily(schedule), schedule)
        }
        for schedule in ["*/15 * * * *", "*/10 * * * *", "every 10m", "every 2h", "0 * * * *", ""] {
            XCTAssertFalse(QuietRoutineRun.runsAtMostDaily(schedule), schedule)
        }
    }

    func testADeliveryIsOpeningCardAndClosingAsOneMessage() {
        let body = "Estos son los resultados de hoy: uno te interesa más.\n---\n**Uno**\nDetalle\n---\nLo importante: el primero te ahorra una hora a la semana."
        let turn = Message(id: "r", role: .user,
                           content: "[Cronjob \"Radar IA\" output — scheduled job, not the user.]\n\n" + body,
                           createdAt: finished, remoteID: "r")
        let shown = RoutineDelivery.present([turn], botName: "radar-ia")
        XCTAssertEqual(shown.map(\.id), ["r:intro", "r", "r:outro"])
        XCTAssertEqual(shown.map(\.routinePart), [.opening, .card, .closing])
        XCTAssertEqual(shown[1].content, "**Uno**\nDetalle")
        XCTAssertEqual(shown[2].content, "Lo importante: el primero te ahorra una hora a la semana.")
        // One task: the time once, above the opening.
        let positions = ChatTasks.positions(shown)
        XCTAssertEqual(shown.map { positions[$0.id]?.isFirst }, [true, false, false])
    }
}
