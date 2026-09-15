import XCTest
@testable import Alice

/// Alice's own chat as a Hermes session over the dashboard socket, where Hermes
/// can stop and ask a question.
final class HomeChatSessionTests: XCTestCase {
    private enum Refusal: Error, LocalizedError {
        case notFound, offline
        var errorDescription: String? {
            switch self {
            case .notFound: "session not found"
            case .offline: "The network connection was lost."
            }
        }
    }

    private actor FakeHermes: HermesRPCTransport {
        private(set) var calls: [(method: String, params: [String: Any])] = []
        private let resumeFailure: Refusal?
        private let configReply: [String: Any]

        init(resumeFailure: Refusal? = nil, configReply: [String: Any] = ["value": "ok"]) {
            self.resumeFailure = resumeFailure
            self.configReply = configReply
        }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            calls.append((method, params.fields))
            switch method {
            case "session.resume":
                if let resumeFailure { throw resumeFailure }
                return JSONObject([
                    "session_id": "live-resumed",
                    "session_key": params.fields["session_id"] as? String ?? "",
                    "info": ["model": "muse-spark", "provider": "opencode-free"],
                ])
            case "session.create":
                return JSONObject([
                    "session_id": "live-new",
                    "stored_session_id": "stored-new",
                    "info": ["model": params.fields["model"] as? String ?? "default-model"],
                ])
            case "config.set":
                return JSONObject(configReply)
            case "prompt.submit":
                return JSONObject(["status": "streaming"])
            default:
                return JSONObject([:])
            }
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> {
            AsyncStream { $0.finish() }
        }

        func methods() -> [String] { calls.map(\.method) }
        func params(of method: String) -> JSONObject? {
            calls.last { $0.method == method }.map { JSONObject($0.params) }
        }
    }

    func testANewChatOpensOnTheChosenModelWithTheConversationSoFar() async throws {
        let hermes = FakeHermes()
        let history = [["role": "user", "content": "hola"], ["role": "assistant", "content": "¡Hola!"]]
        let session = try await WebSocketBotChatSource(rpc: hermes).openHomeChat(
            storedID: nil, model: "gpt-5.6-luna", provider: "openai-codex", history: history
        )

        XCTAssertEqual(session.storedID, "stored-new")
        XCTAssertEqual(session.liveID, "live-new")
        XCTAssertEqual(session.model, "gpt-5.6-luna")
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.create"])
        let sent = await hermes.params(of: "session.create")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(params["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(params["provider"] as? String, "openai-codex")
        XCTAssertEqual(params["messages"] as? [[String: String]], history)
        XCTAssertNil(params["profile"], "Alice's own chat runs as the dashboard's profile")
    }

    func testAChatThatHasASessionContinuesInIt() async throws {
        let hermes = FakeHermes()
        let session = try await WebSocketBotChatSource(rpc: hermes).openHomeChat(
            storedID: "stored-1", model: nil, provider: nil, history: [["role": "user", "content": "x"]]
        )

        XCTAssertEqual(session, HomeChatSession(
            storedID: "stored-1", liveID: "live-resumed",
            model: "muse-spark", provider: "opencode-free"
        ))
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume"])
        let sent = await hermes.params(of: "session.resume")
        let params = try XCTUnwrap(sent)
        XCTAssertNil(params["profile"])
    }

    func testASessionDeletedInHermesIsReplacedByANewOne() async throws {
        let hermes = FakeHermes(resumeFailure: .notFound)
        let session = try await WebSocketBotChatSource(rpc: hermes).openHomeChat(
            storedID: "gone", model: nil, provider: nil, history: []
        )
        XCTAssertEqual(session.storedID, "stored-new")
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume", "session.create"])
    }

    func testAConnectionFailureDoesNotSilentlyStartAnotherChat() async {
        let hermes = FakeHermes(resumeFailure: .offline)
        do {
            _ = try await WebSocketBotChatSource(rpc: hermes).openHomeChat(
                storedID: "stored-1", model: nil, provider: nil, history: []
            )
            XCTFail("expected the connection failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The network connection was lost.")
        }
        let methods = await hermes.methods()
        XCTAssertFalse(methods.contains("session.create"))
    }

    func testTheModelIsSwitchedOnlyWhenItDiffers() async throws {
        let hermes = FakeHermes()
        let source = WebSocketBotChatSource(rpc: hermes)
        let session = HomeChatSession(
            storedID: "s", liveID: "live-1", model: "muse-spark", provider: "opencode-free"
        )

        let same = try await source.useModel("muse-spark", provider: "opencode-free", in: session)
        XCTAssertEqual(same, session)
        let untouched = await hermes.methods()
        XCTAssertTrue(untouched.isEmpty)

        let switched = try await source.useModel("gpt-5.6-luna", provider: "openai-codex", in: session)
        XCTAssertEqual(switched.model, "gpt-5.6-luna")
        XCTAssertEqual(switched.provider, "openai-codex")
        let sent = await hermes.params(of: "config.set")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(params["session_id"] as? String, "live-1")
        XCTAssertEqual(params["key"] as? String, "model")
        XCTAssertEqual(params["value"] as? String, "gpt-5.6-luna --provider openai-codex")
    }

    func testAModelHermesWantsConfirmedIsNotConfirmedOnSomebodysBehalf() async {
        let hermes = FakeHermes(configReply: [
            "confirm_required": true, "confirm_message": "This model is expensive.",
        ])
        let session = HomeChatSession(storedID: "s", liveID: "live-1", model: "a", provider: nil)
        do {
            _ = try await WebSocketBotChatSource(rpc: hermes).useModel("b", provider: nil, in: session)
            XCTFail("expected Hermes' confirmation to be surfaced")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This model is expensive.")
        }
        let params = await hermes.params(of: "config.set")
        XCTAssertNil(params?["confirm_expensive_model"])
    }

    func testASessionAlreadyLiveTakesThePromptWithoutAResume() async throws {
        let hermes = FakeHermes()
        let submission = try await WebSocketBotChatSource(rpc: hermes).submit(
            liveSessionID: "live-new", text: "¿qué tiempo hace?"
        )
        XCTAssertEqual(submission.liveSessionID, "live-new")
        XCTAssertEqual(submission.disposition, .started)
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["prompt.submit"])
    }

    func testTheOpeningHistoryHoldsOnlyWhatWasSaid() {
        let now = Date()
        var failed = Message(id: "3", role: .assistant, content: "partial", createdAt: now)
        failed.error = "Provider refused"
        let messages = [
            Message(id: "1", role: .user, content: "  hola  ", createdAt: now),
            Message(id: "2", role: .assistant, content: "¡Hola!", createdAt: now),
            failed,
            Message(id: "4", role: .assistant, content: "", createdAt: now, pending: true),
            Message(id: "5", role: .user, content: "   ", createdAt: now),
        ]
        XCTAssertEqual(
            WebSocketBotChatSource.openingHistory(messages),
            [["role": "user", "content": "hola"], ["role": "assistant", "content": "¡Hola!"]]
        )
        XCTAssertEqual(
            WebSocketBotChatSource.openingHistory(messages, limit: 1),
            [["role": "assistant", "content": "¡Hola!"]]
        )
    }

    func testAFinishedReplyIsTakenOnlyWhenItAnswersThisMessage() {
        let sent = Date(timeIntervalSince1970: 10_000)
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = sent.addingTimeInterval(20)

        let answered = [
            BotChatTurn(id: "1", role: .user, content: "old", createdAt: earlier),
            BotChatTurn(id: "2", role: .assistant, content: "old answer", createdAt: earlier),
            BotChatTurn(id: "3", role: .user, content: "new", createdAt: later),
            BotChatTurn(id: "4", role: .assistant, content: "new answer", createdAt: later),
        ]
        XCTAssertEqual(WebSocketBotChatSource.finishedReply(in: answered, sentAt: sent), "new answer")

        // The message never reached Hermes: the answer on top is the old one.
        XCTAssertNil(WebSocketBotChatSource.finishedReply(in: Array(answered.prefix(2)), sentAt: sent))
        // Still working: nothing after the message yet.
        XCTAssertNil(WebSocketBotChatSource.finishedReply(in: Array(answered.prefix(3)), sentAt: sent))
    }

    func testOnlyAHomeChatWithASessionIsHeldInHermes() {
        let now = Date()
        var home = Conversation(id: "c", title: "Chat", createdAt: now, updatedAt: now)
        XCTAssertFalse(home.isHomeSessionChat)
        home.hermesSessionID = "stored"
        XCTAssertTrue(home.isHomeSessionChat)

        let bot = Conversation(
            id: "b", title: "Bot", createdAt: now, updatedAt: now,
            botName: "radar-ia", hermesSessionID: "stored"
        )
        XCTAssertFalse(bot.isHomeSessionChat)
        let team = Conversation(
            id: "t", title: "Team", createdAt: now, updatedAt: now,
            hermesSessionID: "stored", isChannel: true
        )
        XCTAssertFalse(team.isHomeSessionChat)
    }
}
