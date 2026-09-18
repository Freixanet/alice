import XCTest
@testable import Alice

/// Where a question gets asked when the turn was sent by naming an agent.
///
/// A `@bot` turn runs in that agent's own Hermes session, so its clarify
/// request comes back under that profile and that session — never under the
/// conversation it was typed in. The profile alone is not enough: an older
/// unresolved request from the same agent must not jump into a newer turn.
final class MentionQuestionsTests: XCTestCase {
    private func asking(
        profile: String?, conversationID: String? = nil,
        sessionID: String? = "inbox-session"
    ) -> AliceEvent {
        AliceEvent(
            id: "clarify:req-1", kind: .needsInput, severity: .needsAttention,
            profile: profile, title: "Needs an answer", summary: "Asked you a question.",
            occurred: Date(),
            reference: AliceEvent.Reference(
                profile: profile, sessionID: sessionID, conversationID: conversationID
            ),
            standing: .waiting,
            questions: [AliceEvent.Question(text: "¿Qué carpetas creo?", choices: ["Salud", "Alice"])]
        )
    }

    private var inboxAwaited: Set<PendingRequestSessions.Address> {
        [.init(profile: "inbox", sessionID: "inbox-session")]
    }

    func testTheChatWaitingOnThatExactAgentSessionIsAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: nil, routedSessionID: nil, awaitedSessions: inboxAwaited
        ))
    }

    func testTheAgentsOwnExactChatIsStillAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "chat-inbox",
            routedBot: "inbox", routedSessionID: "inbox-session", awaitedSessions: []
        ))
    }

    func testAQuestionOfItsOwnConversationIsAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: nil, conversationID: "home", sessionID: nil), conversationID: "home",
            routedBot: nil, routedSessionID: nil, awaitedSessions: []
        ))
    }

    func testAChatWaitingOnNobodyIsNotAsked() {
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: nil, routedSessionID: nil, awaitedSessions: []
        ))
    }

    func testAChatWaitingOnAnotherAgentIsNotAsked() {
        let chief: Set<PendingRequestSessions.Address> = [
            .init(profile: "chief-of-staff", sessionID: "chief-session")
        ]
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: "radar-ia", routedSessionID: "radar-session", awaitedSessions: chief
        ))
    }

    func testAnEventWithNoQuestionsIsNotAsked() {
        var event = asking(profile: "inbox")
        event.questions = []
        XCTAssertFalse(AppStore.claimsQuestions(
            event, conversationID: "home", routedBot: nil,
            routedSessionID: nil, awaitedSessions: inboxAwaited
        ))
    }

    func testOlderQuestionFromSameProfileDoesNotJumpIntoNewMention() {
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox", sessionID: "old-inbox-session"), conversationID: "home",
            routedBot: nil, routedSessionID: nil, awaitedSessions: inboxAwaited
        ))
    }

    func testOlderQuestionFromSameProfileDoesNotJumpIntoCanonicalBotChat() {
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox", sessionID: "old-inbox-session"),
            conversationID: "chat-inbox", routedBot: "inbox",
            routedSessionID: "inbox-session", awaitedSessions: []
        ))
    }

    func testLegacyQuestionWithoutSessionCanStillFollowActivelyAwaitedProfile() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: "inbox", sessionID: nil), conversationID: "home",
            routedBot: nil, routedSessionID: nil, awaitedSessions: inboxAwaited
        ))
    }
}
