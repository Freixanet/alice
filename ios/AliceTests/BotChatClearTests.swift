import XCTest
@testable import Alice

/// Clearing an agent's chat deletes its canonical Bot Chat in Hermes and makes a
/// fresh one. Hermes refuses to rename that chat, and to delete one held live.
final class BotChatClearTests: XCTestCase {
    private enum Refusal: Error, LocalizedError {
        case notFound, active
        var errorDescription: String? {
            switch self {
            case .notFound: "session not found"
            case .active: "cannot delete an active session"
            }
        }
    }

    private actor FakeHermes: HermesRPCTransport {
        private(set) var calls: [(method: String, sessionID: String?)] = []
        private var canonical: [String: Any]?
        private let refusals: [String: Refusal]
        private let keepsOldChat: Bool
        private var busyDeletes: Int

        init(
            canonical: [String: Any]?, refusals: [String: Refusal] = [:],
            keepsOldChat: Bool = false, busyDeletes: Int = 0
        ) {
            self.canonical = canonical
            self.refusals = refusals
            self.keepsOldChat = keepsOldChat
            self.busyDeletes = busyDeletes
        }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            let sessionID = params.fields["session_id"] as? String
            calls.append((method, sessionID))
            switch method {
            case "profiles.list":
                var row: [String: Any] = ["name": "radar-ia"]
                if let canonical { row["canonical_session"] = canonical }
                return JSONObject(["profiles": [row]])
            case "session.resume":
                return JSONObject(["session_id": "live-1", "session_key": sessionID ?? ""])
            case "session.delete":
                if let sessionID, let refusal = refusals[sessionID] { throw refusal }
                if busyDeletes > 0 {
                    busyDeletes -= 1
                    throw Refusal.active
                }
                if !keepsOldChat { canonical = nil }
                return JSONObject(["deleted": sessionID ?? ""])
            case "session.create":
                if !keepsOldChat { canonical = ["id": "fresh"] }
                return JSONObject(["session_id": "live-2"])
            default:
                return JSONObject([:])
            }
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> {
            AsyncStream { $0.finish() }
        }

        func methods() -> [String] { calls.map(\.method) }
        func deleted() -> [String] { calls.filter { $0.method == "session.delete" }.compactMap(\.sessionID) }
    }

    func testClearingLetsGoOfTheLiveChatDeletesItAndStartsAFreshOne() async throws {
        let hermes = FakeHermes(canonical: ["id": "root", "resolved_id": "tip"])
        let fresh = try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")

        XCTAssertEqual(fresh, CanonicalBotChat(id: "fresh"))
        let methods = await hermes.methods()
        let close = try XCTUnwrap(methods.firstIndex(of: "session.close"))
        let firstDelete = try XCTUnwrap(methods.firstIndex(of: "session.delete"))
        XCTAssertLessThan(close, firstDelete, "Hermes will not delete a live session")
        let deleted = await hermes.deleted()
        XCTAssertEqual(deleted, ["tip", "root"])
        XCTAssertTrue(methods.contains("session.create"))
    }

    func testAChatAlreadyGoneStillClears() async throws {
        let hermes = FakeHermes(canonical: ["id": "root"], refusals: ["root": .notFound])
        let fresh = try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")
        XCTAssertEqual(fresh.id, "fresh")
    }

    func testAChatOpenElsewhereIsNotClearedAndSaysWhy() async {
        let hermes = FakeHermes(canonical: ["id": "root"], refusals: ["root": .active])
        do {
            try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")
            XCTFail("expected Hermes' refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "cannot delete an active session")
        }
        let methods = await hermes.methods()
        XCTAssertFalse(methods.contains("session.create"))
    }

    func testAChatTakenHoldOfAgainMidClearIsReleasedAgainAndCleared() async throws {
        let hermes = FakeHermes(canonical: ["id": "root"], busyDeletes: 1)
        let fresh = try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")
        XCTAssertEqual(fresh.id, "fresh")
        let methods = await hermes.methods()
        XCTAssertEqual(methods.filter { $0 == "session.close" }.count, 2)
    }

    func testAnOldChatHermesHandsBackIsNotPassedOffAsCleared() async {
        let hermes = FakeHermes(canonical: ["id": "root"], keepsOldChat: true)
        do {
            try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")
            XCTFail("expected clearing to say the old chat is still there")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Hermes kept the old chat, so nothing was cleared. Try again."
            )
        }
    }

    func testAnAgentThatNeverTalkedJustGetsItsChat() async throws {
        let hermes = FakeHermes(canonical: nil)
        let fresh = try await WebSocketBotChatSource(rpc: hermes).clearCanonicalBotChat(profile: "radar-ia")
        XCTAssertEqual(fresh.id, "fresh")
        let deleted = await hermes.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }
}
