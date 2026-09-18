import XCTest
@testable import Alice

/// Where a question gets asked when the turn was sent by naming an agent.
///
/// A `@bot` turn runs in that agent's own Hermes session, so its clarify
/// request comes back under that profile and that session — never under the
/// conversation it was typed in. Until this was taught, the question landed in
/// the bot's own chat and the reader, sitting in front of Alice's, watched
/// "Thinking…" while the agent waited on them.
final class MentionQuestionsTests: XCTestCase {
    private func asking(profile: String?, conversationID: String? = nil) -> AliceEvent {
        AliceEvent(
            id: "clarify:req-1", kind: .needsInput, severity: .needsAttention,
            profile: profile, title: "Needs an answer", summary: "Asked you a question.",
            occurred: Date(),
            reference: AliceEvent.Reference(profile: profile, conversationID: conversationID),
            standing: .waiting,
            questions: [AliceEvent.Question(text: "¿Qué carpetas creo?", choices: ["Salud", "Alice"])]
        )
    }

    func testTheChatWaitingOnThatAgentIsAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: nil, awaitedProfiles: ["inbox"]
        ))
    }

    func testTheAgentsOwnChatIsStillAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "chat-inbox",
            routedBot: "inbox", awaitedProfiles: []
        ))
    }

    func testAQuestionOfItsOwnConversationIsAsked() {
        XCTAssertTrue(AppStore.claimsQuestions(
            asking(profile: nil, conversationID: "home"), conversationID: "home",
            routedBot: nil, awaitedProfiles: []
        ))
    }

    func testAChatWaitingOnNobodyIsNotAsked() {
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: nil, awaitedProfiles: []
        ))
    }

    func testAChatWaitingOnAnotherAgentIsNotAsked() {
        XCTAssertFalse(AppStore.claimsQuestions(
            asking(profile: "inbox"), conversationID: "home",
            routedBot: "radar-ia", awaitedProfiles: ["chief-of-staff"]
        ))
    }

    func testAnEventWithNoQuestionsIsNotAsked() {
        var event = asking(profile: "inbox")
        event.questions = []
        XCTAssertFalse(AppStore.claimsQuestions(
            event, conversationID: "home", routedBot: nil, awaitedProfiles: ["inbox"]
        ))
    }
}
