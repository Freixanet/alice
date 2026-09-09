import XCTest
@testable import Alice

/// Standing guards for the recovered-history model that remains after the
/// one-off September importer was retired.
///
/// `legacyBotName` is display ownership only. Treating it as a routing identity
/// would splice an old simulated/default-profile transcript into a live bot
/// session; treating it as no ownership would put that history back in Home.
final class RecoveredHistoryBehaviorTests: XCTestCase {
    private static func recoveredRadar() -> Conversation {
        Conversation(
            id: "legacy-radar",
            title: "Radar IA — historial anterior",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            messages: [
                Message(
                    id: "m1", role: .user, content: "hola",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            botName: nil,
            legacyBotName: "radar-ia",
            hermesSessionID: nil
        )
    }

    private static func canonicalRadar() -> Conversation {
        Conversation(
            id: "live-radar",
            title: "Radar IA",
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4),
            botName: "radar-ia",
            hermesSessionID: "session-radar"
        )
    }

    func testRecoveredHistoryIsOwnedForDisplayButNeverRoutes() {
        let legacy = Self.recoveredRadar()

        XCTAssertEqual(legacy.owningBotName, "radar-ia")
        XCTAssertTrue(legacy.isBotOwnedConversation)
        XCTAssertTrue(legacy.isBotChat)
        XCTAssertTrue(legacy.isRecoveredHistory)
        XCTAssertNil(legacy.routedBotName)
        XCTAssertNil(legacy.hermesSessionID)
        XCTAssertFalse(legacy.isCanonicalBotChat)
    }

    func testCanonicalBotChatStillRoutesNormally() {
        let live = Self.canonicalRadar()

        XCTAssertEqual(live.owningBotName, "radar-ia")
        XCTAssertEqual(live.routedBotName, "radar-ia")
        XCTAssertTrue(live.isCanonicalBotChat)
        XCTAssertFalse(live.isRecoveredHistory)
    }

    func testRecoveredAndCanonicalThreadsCoexistWithoutIdentityCollision() {
        let all = [Self.recoveredRadar(), Self.canonicalRadar()]
        let underRadar = all.filter { $0.owningBotName == "radar-ia" }

        XCTAssertEqual(underRadar.count, 2)
        XCTAssertEqual(underRadar.filter(\.isRecoveredHistory).map(\.id), ["legacy-radar"])
        XCTAssertEqual(underRadar.filter(\.isCanonicalBotChat).map(\.id), ["live-radar"])
        XCTAssertEqual(Set(underRadar.map(\.id)).count, 2)
        XCTAssertTrue(all.filter { !$0.isBotChat }.isEmpty)
    }

    func testRecoveredHistoryRoundTripPreservesOwnershipWithoutCreatingRouting() throws {
        let original = Self.recoveredRadar()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.messages.map(\.content), ["hola"])
        XCTAssertEqual(restored.legacyBotName, "radar-ia")
        XCTAssertNil(restored.botName)
        XCTAssertNil(restored.routedBotName)
        XCTAssertTrue(restored.isRecoveredHistory)
    }
}
