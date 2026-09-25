import XCTest
@testable import Alice

/// Each chat in the drawer says what it is waiting on: one state, the most
/// pressing, and nothing for a chat that needs nothing.
final class ChatAttentionTests: XCTestCase {
    private let now = Date()

    private func chat(_ messages: [Message]) -> Conversation {
        var chat = Conversation.blank()
        chat.messages = messages
        return chat
    }

    private func attention(
        _ chat: Conversation, active: Bool = false, sending: Bool = false,
        outOfSight: Bool = false, question: Bool = false, unseen: Bool = false, draft: Bool = false
    ) -> ChatAttention? {
        ChatAttention.of(
            chat, isActive: active, sending: sending, workingOutOfSight: outOfSight,
            waitingQuestion: question, unseenReply: unseen, hasDraft: draft
        )
    }

    private var answered: Conversation {
        chat([
            Message(id: "1", role: .user, content: "Hola", createdAt: now),
            Message(id: "2", role: .assistant, content: "Hola, Marcos", createdAt: now),
        ])
    }

    func testAChatThatNeedsNothingHasNoMark() {
        XCTAssertNil(attention(answered))
    }

    func testAPermissionOrAQuestionNeedsHimFirst() {
        let approval = Message.Approval(runID: "r", title: "terminal", detail: nil, command: "ls", choices: [.once, .deny])
        let asking = chat([
            Message(id: "1", role: .user, content: "Hazlo", createdAt: now),
            Message(id: "2", role: .assistant, content: "", createdAt: now, approval: approval),
        ])
        XCTAssertEqual(attention(asking, sending: true, draft: true), .needsYou)
        XCTAssertEqual(attention(answered, sending: true, question: true), .needsYou)
    }

    func testAPermissionBeingAnsweredNoLongerWaitsOnHim() {
        var approval = Message.Approval(runID: "r", title: "terminal", detail: nil, command: nil, choices: [.once])
        approval.resolving = true
        let resolving = chat([Message(id: "1", role: .assistant, content: "", createdAt: now, approval: approval)])
        XCTAssertNil(attention(resolving))
    }

    func testAReplyUnderWayHereOrOutOfSightIsWorking() {
        XCTAssertEqual(attention(answered, sending: true), .working)
        XCTAssertEqual(attention(answered, outOfSight: true), .working)
        let away = chat([Message(id: "1", role: .assistant, content: "", createdAt: now, awaitingRemote: true)])
        XCTAssertEqual(attention(away), .working)
    }

    func testAFailedOrCutReplyWasInterrupted() {
        let failed = chat([Message(id: "1", role: .assistant, content: "", createdAt: now, error: "Timeout")])
        let cut = chat([Message(id: "1", role: .assistant, content: "Bus", createdAt: now, incomplete: true)])
        XCTAssertEqual(attention(failed), .interrupted)
        XCTAssertEqual(attention(cut, active: true), .interrupted)
    }

    func testAReplyThatEndedWhileAwayIsNewUntilOpened() {
        XCTAssertEqual(attention(answered, unseen: true, draft: true), .newReply)
        XCTAssertNil(attention(answered, active: true, unseen: true))
    }

    func testTextLeftUnsentIsADraftExceptOnScreen() {
        XCTAssertEqual(attention(answered, draft: true), .draft)
        XCTAssertNil(attention(answered, active: true, draft: true))
    }
}
