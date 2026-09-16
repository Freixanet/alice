import XCTest
@testable import Alice

/// Tapping a Needs-attention row that names a chat must open that chat, even
/// when Alice no longer has the original conversation id.
@MainActor
final class ActivityNavigationTests: XCTestCase {
    private func store() throws -> (AppStore, String) {
        let suite = "alice.activity-nav.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppStore(defaults: defaults), suite)
    }

    func testAMissingConversationIdStillOpensTheBotChat() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let bot = Conversation(
            id: "bot-chat", title: "Radar IA",
            createdAt: Date(), updatedAt: Date(),
            botName: "radar-ia", hermesSessionID: "sess-radar"
        )
        store.conversations.insert(bot, at: 0)

        let route = try XCTUnwrap(Notifier.Route(userInfo: [
            "event": "clarify:req-1",
            "profile": "radar-ia",
        ]))
        XCTAssertTrue(store.open(route))
        XCTAssertEqual(store.activeID, "bot-chat")
        XCTAssertNil(store.routeNotice)
    }

    func testAStaleConversationIdFallsBackToTheBot() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let bot = Conversation(
            id: "bot-chat", title: "Radar IA",
            createdAt: Date(), updatedAt: Date(),
            botName: "radar-ia"
        )
        store.conversations.insert(bot, at: 0)

        let route = try XCTUnwrap(Notifier.Route(userInfo: [
            "event": "clarify:req-1",
            "conversation": "gone-id",
            "profile": "radar-ia",
        ]))
        XCTAssertTrue(store.open(route))
        XCTAssertEqual(store.activeID, "bot-chat")
        XCTAssertNil(store.routeNotice)
    }

    func testASessionIdOpensTheMatchingChat() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let home = try XCTUnwrap(store.conversations.first)
        var chat = home
        chat.hermesSessionID = "live-home"
        store.conversations[0] = chat

        let route = try XCTUnwrap(Notifier.Route(userInfo: [
            "event": "clarify:req-2",
            "session": "live-home",
        ]))
        XCTAssertTrue(store.open(route))
        XCTAssertEqual(store.activeID, chat.id)
        XCTAssertNil(store.routeNotice)
    }
}
