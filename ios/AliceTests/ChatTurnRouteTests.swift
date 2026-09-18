import XCTest
@testable import Alice

final class ChatTurnRouteTests: XCTestCase {
    func testMentionRetainsItsProfileBeforeDashboardConnects() {
        for ready in [false, true] {
            XCTAssertEqual(ChatTurnRoute.resolve(
                in: .blank(), invokedBot: "inbox", dashboardReady: ready, updatingHermes: false
            ), .agent(profile: "inbox", mention: true))
        }
    }

    func testDirectAgentChatRetainsItsProfileWhenOffline() {
        var chat = Conversation.blank()
        chat.botName = "inbox"
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: chat, invokedBot: nil, dashboardReady: false, updatingHermes: false
        ), .agent(profile: "inbox", mention: false))
    }

    func testDirectChatTakesPrecedenceOverAnotherMention() {
        var chat = Conversation.blank()
        chat.botName = "inbox"
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: chat, invokedBot: "research", dashboardReady: true, updatingHermes: false
        ), .agent(profile: "inbox", mention: false))
    }

    func testTeamAgentCannotFallBackToTheInstallationProfile() {
        var team = Conversation.blank()
        team.isChannel = true
        for ready in [false, true] {
            XCTAssertEqual(ChatTurnRoute.resolve(
                in: team, invokedBot: "inbox", dashboardReady: ready, updatingHermes: false
            ), .agent(profile: "inbox", mention: true))
        }
    }

    func testTeamWithoutAnAgentCannotSend() {
        var team = Conversation.blank()
        team.isChannel = true
        XCTAssertNil(ChatTurnRoute.resolve(
            in: team, invokedBot: nil, dashboardReady: true, updatingHermes: false
        ))
    }

    func testRecoveredHistoryCannotBeResumedAsARealAgent() {
        var recovered = Conversation.blank()
        recovered.legacyBotName = "inbox"
        XCTAssertNil(ChatTurnRoute.resolve(
            in: recovered, invokedBot: "inbox", dashboardReady: true, updatingHermes: false
        ))
    }

    func testHomeUsesItsAvailableTransport() {
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: .blank(), invokedBot: nil, dashboardReady: true, updatingHermes: false
        ), .home)
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: .blank(), invokedBot: nil, dashboardReady: false, updatingHermes: false
        ), .gateway)
    }

    func testInstallationUpdateStillUsesGateway() {
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: .blank(), invokedBot: nil, dashboardReady: true, updatingHermes: true
        ), .gateway)
    }

    func testUpdateWordsCannotRetargetAMention() {
        XCTAssertEqual(ChatTurnRoute.resolve(
            in: .blank(), invokedBot: "inbox", dashboardReady: true, updatingHermes: true
        ), .agent(profile: "inbox", mention: true))
    }
}
