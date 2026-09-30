import XCTest
@testable import Alice

/// Which of Hermes' sessions can be taken up on the phone (`AppStore.canContinue`).
final class ContinueSessionTests: XCTestCase {
    private func row(_ source: String?, title: String = "Plan del viaje", messages: Int = 4) -> SessionRow {
        SessionRow(id: "s1", title: title, preview: "", source: source, model: nil, messageCount: messages,
                   toolCallCount: 0, inputTokens: 0, outputTokens: 0, cost: nil, lastActive: nil)
    }

    func testConversationsStartedAtTheMacCanContinue() {
        for source in ["desktop", "cli", "tui", "webui", "Desktop"] {
            XCTAssertTrue(AppStore.canContinue(row(source)), source)
        }
    }

    func testOtherSurfacesStayARecord() {
        for source in ["cron", "api_server", "subagent", "telegram", "whatsapp", "photon"] {
            XCTAssertFalse(AppStore.canContinue(row(source)), source)
        }
        XCTAssertFalse(AppStore.canContinue(row(nil)))
    }

    func testAnAgentsForeverChatAndEmptySessionsAreLeftOut() {
        XCTAssertFalse(AppStore.canContinue(row("tui", title: "Bot Chat")))
        XCTAssertFalse(AppStore.canContinue(row("desktop", messages: 0)))
    }

    func testSourcesInWords() {
        XCTAssertEqual(SessionsScreen.sourceName("tui"), SessionsScreen.sourceName("cli"))
        XCTAssertEqual(SessionsScreen.sourceName("matrix"), "Matrix")
    }
}
