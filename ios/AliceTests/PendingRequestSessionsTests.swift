import XCTest
@testable import Alice

final class PendingRequestSessionsTests: XCTestCase {
    private func mentioned(
        profile: String = "inbox", sessionID: String = "inbox-session",
        pending: Bool = true, awaiting: Bool = false
    ) -> Message {
        var message = Message(
            id: UUID().uuidString, role: .assistant, content: "", createdAt: Date(),
            pending: pending, awaitingRemote: awaiting, mentionProfile: profile
        )
        message.mentionSessionID = sessionID
        return message
    }

    func testMentionWithoutABotChatOrHomeSessionIsRead() {
        var home = Conversation.blank()
        home.messages = [mentioned()]
        let targets = PendingRequestSessions.targets(in: [home])
        XCTAssertEqual(targets, [.init(
            address: .init(profile: "inbox", sessionID: "inbox-session"),
            conversationID: home.id, isMention: true
        )])
    }

    func testHomeKeepsItsOwnSessionWhileReadingTheMention() {
        var home = Conversation.blank()
        home.hermesSessionID = "alice-session"
        home.messages = [mentioned()]
        let targets = PendingRequestSessions.targets(in: [home])
        XCTAssertEqual(targets.map(\.address), [
            .init(profile: "inbox", sessionID: "inbox-session"),
            .init(profile: nil, sessionID: "alice-session")
        ])
        XCTAssertEqual(home.hermesSessionID, "alice-session")
    }

    func testSameSessionIsReadOnceAndBelongsToTheMentionChat() {
        var home = Conversation.blank()
        home.messages = [mentioned(), mentioned()]
        var bot = Conversation.blank()
        bot.botName = "inbox"
        bot.hermesSessionID = "inbox-session"
        let targets = PendingRequestSessions.targets(in: [bot, home])
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.conversationID, home.id)
        XCTAssertEqual(targets.first?.isMention, true)
    }

    func testAwaitingRemoteMentionSurvivesArchiveRoundTrip() throws {
        var team = Conversation.blank()
        team.isChannel = true
        team.messages = [mentioned(pending: false, awaiting: true)]
        let restored = try JSONDecoder().decode(
            Conversation.self, from: JSONEncoder().encode(team)
        )
        let targets = PendingRequestSessions.targets(in: [restored])
        XCTAssertEqual(targets.first?.address.profile, "inbox")
        XCTAssertEqual(targets.first?.address.sessionID, "inbox-session")
        XCTAssertEqual(targets.first?.conversationID, team.id)
    }

    func testCompletedMentionIsNotResumedUnlessARequestStillWaits() {
        var home = Conversation.blank()
        home.messages = [mentioned(pending: false)]
        XCTAssertTrue(PendingRequestSessions.targets(in: [home]).isEmpty)
        let targets = PendingRequestSessions.targets(
            in: [home], waitingSessions: [.init(profile: "inbox", sessionID: "inbox-session")]
        )
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.conversationID, home.id)
    }

    func testMentionWithoutAnExactSessionIsNotGuessed() {
        var missing = mentioned()
        missing.mentionSessionID = nil
        let empty = mentioned(sessionID: "")
        var home = Conversation.blank()
        home.messages = [missing, empty]
        XCTAssertTrue(PendingRequestSessions.targets(in: [home]).isEmpty)
    }

    func testProfilesWithTheSameSessionIDAreKeptSeparate() {
        var team = Conversation.blank()
        team.isChannel = true
        team.messages = [mentioned(profile: "inbox"), mentioned(profile: "research")]
        let addresses = Set(PendingRequestSessions.targets(in: [team]).map(\.address))
        XCTAssertEqual(addresses, [
            .init(profile: "inbox", sessionID: "inbox-session"),
            .init(profile: "research", sessionID: "inbox-session")
        ])
    }

    func testIdleHomeChatsAreNotResumedButBotChatsStillAre() {
        var home = Conversation.blank()
        home.hermesSessionID = "alice-session"
        var bot = Conversation.blank()
        bot.botName = "inbox"
        bot.hermesSessionID = "inbox-session"
        let targets = PendingRequestSessions.targets(in: [home, bot])
        XCTAssertEqual(targets.map(\.address), [.init(profile: "inbox", sessionID: "inbox-session")])
        let waiting = PendingRequestSessions.targets(in: [home], waitingConversations: [home.id])
        XCTAssertEqual(waiting.first?.address, .init(profile: nil, sessionID: "alice-session"))
    }
}
