import XCTest
@testable import Alice

final class BotUnreadTests: XCTestCase {
    private let opened = Date(timeIntervalSince1970: 1_000_000)

    func testAChatReplyAfterTheLastOpenIsUnread() {
        let reply = Message(
            id: "reply", role: .assistant, content: "New answer",
            createdAt: opened.addingTimeInterval(1), botName: "researcher"
        )
        XCTAssertTrue(AppStore.hasUnreadBotContent(
            messages: [reply], quietRuns: [], botName: "researcher", openedAt: opened
        ))
    }

    func testOldRepliesAndNewUserMessagesAreNotUnreadBotMessages() {
        let oldReply = Message(
            id: "old", role: .assistant, content: "Already read",
            createdAt: opened.addingTimeInterval(-1), botName: "researcher"
        )
        let newQuestion = Message(
            id: "question", role: .user, content: "Anything new?",
            createdAt: opened.addingTimeInterval(1), botName: "researcher"
        )
        XCTAssertFalse(AppStore.hasUnreadBotContent(
            messages: [oldReply, newQuestion], quietRuns: [],
            botName: "researcher", openedAt: opened
        ))
    }

    func testANewQuietRoutineRunIsUnread() {
        let quiet = QuietRoutineRun(
            id: "run", routineName: "Daily scan",
            finishedAt: opened.addingTimeInterval(1)
        )
        XCTAssertTrue(AppStore.hasUnreadBotContent(
            messages: [], quietRuns: [quiet], botName: "researcher", openedAt: opened
        ))
    }

    func testPendingRepliesDoNotBecomeUnreadUntilTheyFinish() {
        var reply = Message(
            id: "reply", role: .assistant, content: "Working",
            createdAt: opened.addingTimeInterval(1), botName: "researcher"
        )
        reply.pending = true
        XCTAssertFalse(AppStore.hasUnreadBotContent(
            messages: [reply], quietRuns: [], botName: "researcher", openedAt: opened
        ))
    }
}
