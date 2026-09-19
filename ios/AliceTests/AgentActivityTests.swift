import XCTest
@testable import Alice

/// What an agent's Live Activity says.
final class AgentActivityTests: XCTestCase {
    func testTheStatusSaysWhoTheAgentIsWaitingFor() {
        XCTAssertEqual(AgentActivityText.waiting(for: []), "Working")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado"]), "Waiting for Mercado")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado", "Producto"]), "Waiting for Mercado and Producto")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado", "Producto", "Growth"]), "Waiting for Mercado and 2 more")
    }

    func testAnEndedActivitySaysHowItEnded() {
        XCTAssertEqual(AgentActivityText.ended(.finished), "Done")
        XCTAssertEqual(AgentActivityText.ended(.failed), "Failed")
        XCTAssertEqual(AgentActivityText.ended(.stopped), "Stopped")
    }

    func testTheStateTravelsIntact() throws {
        let start = Date(timeIntervalSince1970: 1_789_500_000)
        let state = AgentActivityAttributes.ContentState(
            phase: .waiting, detail: "Waiting for Mercado", startedAt: start,
            endedAt: nil, updatedAt: start.addingTimeInterval(60)
        )
        let decoded = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.isDone, false)
    }

    func testHomeChatHasItsOwnActivityIdentity() {
        XCTAssertEqual(AppStore.homeActivityProfile, "default")
        XCTAssertNotEqual(AppStore.homeActivityProfile, "alice")
    }

    func testTheActivityLineMatchesTheChatHeadline() {
        let download = Message.ToolCall(id: "t1", name: "cobalt_download", status: .start)
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: nil, thoughtSeconds: nil, steps: [download]),
            "Downloading"
        )
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: "Reconnecting to Hermes…", thoughtSeconds: nil),
            "Reconnecting to Hermes…"
        )
    }

    func testTwoChatsNeverShareOneActivitySlot() {
        let mark = BotMark(colour: 0, shape: 0)
        let home = AgentActivities.Work(
            conversationID: "home", profile: "default", name: "Alice", mark: mark,
            waitingOn: [], headline: "Thinking"
        )
        let other = AgentActivities.Work(
            conversationID: "bot-1", profile: "default", name: "Alice", mark: mark,
            waitingOn: [], headline: "Downloading"
        )
        let map = AgentActivities.uniqueWorks([home, other])
        XCTAssertEqual(Set(map.keys), ["home", "bot-1"])
        XCTAssertEqual(map["home"]?.headline, "Thinking")
        XCTAssertEqual(map["bot-1"]?.headline, "Downloading")
    }

    func testEndingOneConversationLeavesTheOthers() {
        let mark = BotMark(colour: 0, shape: 0)
        let home = AgentActivities.Work(
            conversationID: "home", profile: "default", name: "Alice", mark: mark,
            waitingOn: [], headline: "Thinking"
        )
        let other = AgentActivities.Work(
            conversationID: "bot-1", profile: "news", name: "News", mark: mark,
            waitingOn: [], headline: "Searching the web"
        )
        let after = AgentActivities.removing(
            AgentActivities.uniqueWorks([home, other]), conversationID: "home"
        )
        XCTAssertNil(after["home"])
        XCTAssertEqual(after["bot-1"]?.conversationID, "bot-1")
        XCTAssertEqual(
            AgentActivities.removing(after, conversationID: "missing")["bot-1"]?.conversationID,
            "bot-1"
        )
    }

    func testAClarifyQuestionIsNotWorking() {
        XCTAssertFalse(
            AppStore.isWorking(
                sending: true, backgroundEmpty: false,
                waitingOnPerson: true, awaitedByPeer: false
            )
        )
        XCTAssertTrue(
            AppStore.isWorking(
                sending: true, backgroundEmpty: true,
                waitingOnPerson: false, awaitedByPeer: false
            )
        )
        XCTAssertTrue(
            AppStore.isWorking(
                sending: false, backgroundEmpty: true,
                waitingOnPerson: false, awaitedByPeer: true
            )
        )
        XCTAssertFalse(
            AppStore.isWorking(
                sending: false, backgroundEmpty: true,
                waitingOnPerson: false, awaitedByPeer: false
            )
        )
    }
}
