import XCTest
@testable import Alice

/// The JSON-RPC transport that makes a bot chat the bot's own chat.
///
/// The defect these lock down: Alice used to send a bot's turn to the *default*
/// profile with a synthetic "You are '<bot>'" system directive and a local
/// UUID for a session key, so the reply came from the wrong agent and landed
/// in a transcript cron never wrote to.
final class WebSocketBotChatTests: XCTestCase {
    // MARK: - A fake agent

    private actor FakeRPC: HermesRPCTransport {
        struct Call: Equatable {
            let method: String
            let params: [String: String]
        }

        private var results: [String: JSONObject]
        private(set) var calls: [Call] = []
        private var pushes: [HermesRPCEvent] = []
        var failNext: Error?

        init(results: [String: [String: Any]] = [:]) {
            self.results = results.mapValues(JSONObject.init)
        }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            calls.append(Call(method: method, params: Self.flatten(params.fields)))
            if let failNext {
                self.failNext = nil
                throw failNext
            }
            return results[method] ?? JSONObject([:])
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> {
            AsyncStream { continuation in
                Task {
                    for event in await self.pushes { continuation.yield(event) }
                    continuation.finish()
                }
            }
        }

        func set(_ method: String, _ result: [String: Any]) {
            results[method] = JSONObject(result)
        }

        func queue(_ events: [HermesRPCEvent]) { pushes = events }
        func fail(with error: Error) { failNext = error }

        func params(of method: String) -> [String: String]? {
            calls.last(where: { $0.method == method })?.params
        }

        func methods() -> [String] { calls.map(\.method) }

        /// Only scalar params matter to these assertions.
        private static func flatten(_ fields: [String: Any]) -> [String: String] {
            var out: [String: String] = [:]
            for (key, value) in fields {
                if let text = value as? String { out[key] = text }
                else if let flag = value as? Bool { out[key] = flag ? "true" : "false" }
                else if let number = value as? Int { out[key] = String(number) }
            }
            return out
        }
    }

    private enum Dropped: Error, LocalizedError {
        case socket
        var errorDescription: String? { "Hermes disconnected." }
    }

    private static func roster(
        _ profile: String, id: String, resolved: String? = nil
    ) -> [String: Any] {
        var canonical: [String: Any] = ["id": id, "title": "Bot Chat"]
        if let resolved { canonical["resolved_id"] = resolved }
        return ["profiles": [
            ["name": "default", "canonical_session": NSNull()],
            ["name": profile, "canonical_session": canonical],
        ]]
    }

    private static func history(_ rows: [[String: Any]]) -> [String: Any] {
        ["session_id": "s", "messages": rows]
    }

    private static func row(
        _ rowID: Int, _ role: String, _ text: String, _ ts: Double
    ) -> [String: Any] {
        ["row_id": rowID, "role": role, "text": text, "timestamp": ts]
    }

    // MARK: - B. The canonical session comes from the server

    func testTheCanonicalSessionIsTheServersOwnAnswer() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "20260905_104136_281747")
        ])
        let source = WebSocketBotChatSource(rpc: rpc)

        let chat = try await source.canonicalBotChat(profile: "radar-ia")

        XCTAssertEqual(chat?.id, "20260905_104136_281747")
        XCTAssertEqual(chat?.resolvedID, "20260905_104136_281747")
        let params = await rpc.params(of: "profiles.list")
        XCTAssertEqual(params?["include_sessions"], "true")
    }

    // MARK: - H. Compression moves the tip; Alice follows it

    func testAResolvedTipIsFollowedWithoutMakingAnotherChat() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "root-row", resolved: "live-tip"),
            "session.resume": Self.history([Self.row(1, "assistant", "informe", 100)]),
        ])
        let source = WebSocketBotChatSource(rpc: rpc)

        let chat = try await BotChatSync(source: source).refresh(
            profile: "radar-ia", into: Conversation(
                id: "local", title: "Radar IA", createdAt: Date(), updatedAt: Date(),
                botName: "radar-ia"
            )
        )

        XCTAssertEqual(chat.hermesSessionID, "live-tip", "the live tip is what gets read")
        let created = await rpc.methods().filter { $0 == "session.create" }
        XCTAssertTrue(created.isEmpty, "a moved tip is not a reason to mint a chat")
    }

    // MARK: - C. Resume names the profile

    func testResumeCarriesTheProfile() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "s1"),
            "session.resume": Self.history([]),
        ])
        let source = WebSocketBotChatSource(rpc: rpc)

        _ = try await source.transcript(profile: "radar-ia", sessionID: "s1")

        let params = await rpc.params(of: "session.resume")
        XCTAssertEqual(params?["profile"], "radar-ia")
        XCTAssertEqual(params?["session_id"], "s1")
    }

    // MARK: - D. The transcript maps onto messages

    func testHistoryBecomesMessagesKeyedOnTheDurableRowID() {
        let turns = WebSocketBotChatSource.turns(from: [
            Self.row(11, "user", "¿novedades?", 10),
            Self.row(12, "assistant", "**Radar IA — 6 de septiembre**", 20),
            ["role": "tool", "name": "web_search"],
            ["role": "assistant", "text": "sin row_id todavía"],
            ["role": "system", "text": "andamiaje"],
        ])

        XCTAssertEqual(turns.map(\.id), ["11", "12"])
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns[1].createdAt, Date(timeIntervalSince1970: 20))
    }

    // MARK: - E. Sending — the heart of it

    func testSendingGoesToTheCanonicalSessionUnderTheBotsProfile() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "20260905_104136_281747"),
            "session.resume": Self.history([]),
        ])
        let source = WebSocketBotChatSource(rpc: rpc)
        let aliceLocalUUID = UUID().uuidString

        try await source.submit(
            profile: "radar-ia",
            sessionID: "20260905_104136_281747",
            text: "¿algo nuevo?"
        )

        let submit = await rpc.params(of: "prompt.submit")
        XCTAssertEqual(submit?["session_id"], "20260905_104136_281747")
        XCTAssertNotEqual(submit?["session_id"], aliceLocalUUID,
                          "a local UUID must never be the session")
        XCTAssertEqual(submit?["text"], "¿algo nuevo?")

        let resume = await rpc.params(of: "session.resume")
        XCTAssertEqual(resume?["profile"], "radar-ia", "the turn runs as the bot")
        XCTAssertNotEqual(resume?["profile"], "default")

        // Nothing anywhere tells the agent to pretend to be someone.
        let everything = await rpc.calls.flatMap { $0.params.values }
        XCTAssertFalse(
            everything.contains { $0.localizedCaseInsensitiveContains("a separate assistant") },
            "the synthetic persona directive must be gone"
        )
    }

    /// The model the UI shows for a bot must be the one the turn actually
    /// runs under. A per-session override is the sanctioned way; a global
    /// config write is not, and neither is quietly sending via another route.
    func testAModelChoiceIsAPerSessionOverrideNotAGlobalWrite() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": ["profiles": [["name": "radar-ia", "canonical_session": NSNull()]]],
            "session.resume": Self.history([]),
        ])
        await rpc.set("session.create", ["session_id": "fresh"])
        let source = WebSocketBotChatSource(rpc: rpc)

        _ = try? await source.createCanonicalBotChat(profile: "radar-ia")

        let methods = await rpc.methods()
        XCTAssertFalse(methods.contains("config.set"), "no global config write")
        let create = await rpc.params(of: "session.create")
        XCTAssertEqual(create?["profile"], "radar-ia")
        XCTAssertEqual(create?["title"], "Bot Chat")
    }

    // MARK: - F. Streaming

    func testDeltasAndCompletionProduceTheReply() {
        let deltas = ["**Radar IA", " — 6 de septiembre", " de 2026**"].map {
            HermesRPCEvent(type: "message.delta", sessionID: "s1", payload: ["text": $0])
        }
        var text = ""
        for event in deltas {
            if case let .delta(chunk)? = AppStore.chatEvent(from: event) { text += chunk }
        }
        XCTAssertEqual(text, "**Radar IA — 6 de septiembre de 2026**")

        // Corrected against the Hermes source: `_complete_turn_payload` always
        // carries `status`, and a payload without one is the subagent mirror
        // from `agent_callbacks` — emitted on the PARENT's session id when a
        // child finishes. This case previously asserted that the mirror shape
        // closes the turn, which is what cut parents short and lost their
        // final reply. See SubagentSequenceTests.
        let done = AppStore.chatEvent(from: HermesRPCEvent(
            type: "message.complete", sessionID: "s1", payload: ["status": "complete"]
        ))
        guard case let .run(_, status, _)? = done else {
            return XCTFail("a real turn outcome must close the turn")
        }
        XCTAssertEqual(status, .completed)

        XCTAssertNil(
            AppStore.chatEvent(
                from: HermesRPCEvent(type: "message.complete", sessionID: "s1", payload: [:])
            ),
            "a child's mirror must not close the parent's turn"
        )
    }

    func testToolAndApprovalEventsReachTheExistingRenderer() {
        let tool = AppStore.chatEvent(from: HermesRPCEvent(
            type: "tool.start", sessionID: "s1",
            payload: ["id": "t1", "name": "web_search", "context": "chollos"]
        ))
        guard case let .tool(id, name, status, _)? = tool else {
            return XCTFail("tool events must map")
        }
        XCTAssertEqual([id, name], ["t1", "web_search"])
        XCTAssertEqual(status, .start)

        let approval = AppStore.chatEvent(from: HermesRPCEvent(
            type: "approval.request", sessionID: "s1",
            // The real payload: Hermes sends no `title`. It carries `command`,
            // `description`, `pattern_key(s)`, `allow_*` and a computed
            // `choices`. Requiring a title made this return nil for every
            // genuine approval, so the card never appeared in a bot chat.
            payload: [
                "request_id": "r1", "description": "Run a shell command",
                "command": "ls", "choices": ["once", "deny"],
            ]
        ))
        guard case let .approval(request)? = approval else {
            return XCTFail("approval requests must map")
        }
        XCTAssertEqual(request.runID, "r1")
        XCTAssertEqual(request.command, "ls")
        XCTAssertEqual(request.title, "Run a shell command")
        // Only what Hermes offered: "always" here would propose a permanent
        // grant the server refuses.
        XCTAssertEqual(request.choices, [.once, .deny])
    }

    func testInterruptedCompletionIsNotACompletedRun() {
        let event = AppStore.chatEvent(from: HermesRPCEvent(
            type: "message.complete", sessionID: "s1",
            payload: ["status": "interrupted"]
        ))
        guard case let .run(_, status, _)? = event else {
            return XCTFail("interrupted must close the run")
        }
        XCTAssertEqual(status, .interrupted)
    }

    func testSocketApprovalReturnsResolutionEvidenceAndExactIdentity() async throws {
        let rpc = FakeRPC(results: ["approval.respond": ["resolved": 0]])
        let source = WebSocketBotChatSource(rpc: rpc)

        let result = try await source.respondToApproval(
            sessionID: "sess-1", requestID: "req-9", choice: "deny"
        )

        XCTAssertFalse(LiveEvents.didResolve(result))
        let params = await rpc.params(of: "approval.respond")
        XCTAssertEqual(params?["session_id"], "sess-1")
        XCTAssertEqual(params?["request_id"], "req-9")
        XCTAssertEqual(params?["choice"], "deny")
    }

    // MARK: - G. Out of band

    func testACronDeliveryArrivesOnRefreshExactlyOnce() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "s1"),
            "session.resume": Self.history([Self.row(1, "user", "hola", 10)]),
        ])
        let source = WebSocketBotChatSource(rpc: rpc)
        let sync = BotChatSync(source: source)
        var chat = try await sync.refresh(
            profile: "radar-ia",
            into: Conversation(id: "local", title: "Radar IA",
                               createdAt: Date(), updatedAt: Date(), botName: "radar-ia")
        )
        XCTAssertEqual(chat.messages.count, 1)

        // Cron writes into the canonical chat while Alice is elsewhere.
        await rpc.set("session.resume", Self.history([
            Self.row(1, "user", "hola", 10),
            Self.row(2, "assistant", "**Radar IA — 6 de septiembre de 2026**", 100),
        ]))

        chat = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(chat.messages.map(\.remoteID), ["1", "2"])

        chat = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(chat.messages.map(\.remoteID), ["1", "2"], "no duplicate on reopen")
    }

    // MARK: - I. Profiles stay apart

    func testTwoProfilesNeverShareASession() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": ["profiles": [
                ["name": "radar-ia", "canonical_session": ["id": "s-radar"]],
                ["name": "researcher", "canonical_session": ["id": "s-researcher"]],
            ]]
        ])
        let source = WebSocketBotChatSource(rpc: rpc)

        let radar = try await source.canonicalBotChat(profile: "radar-ia")
        let researcher = try await source.canonicalBotChat(profile: "researcher")

        XCTAssertEqual(radar?.id, "s-radar")
        XCTAssertEqual(researcher?.id, "s-researcher")
        XCTAssertNotEqual(radar?.id, researcher?.id)
    }

    // MARK: - J. A dropped socket is not an empty chat

    func testADroppedSocketLeavesTheCacheAndRetryRecovers() async throws {
        let rpc = FakeRPC(results: [
            "profiles.list": Self.roster("radar-ia", id: "s1"),
            "session.resume": Self.history([Self.row(1, "assistant", "informe", 10)]),
        ])
        let source = WebSocketBotChatSource(rpc: rpc)
        let sync = BotChatSync(source: source)
        let cached = try await sync.refresh(
            profile: "radar-ia",
            into: Conversation(id: "local", title: "Radar IA",
                               createdAt: Date(), updatedAt: Date(), botName: "radar-ia")
        )
        XCTAssertEqual(cached.messages.count, 1)

        await rpc.fail(with: Dropped.socket)
        do {
            _ = try await sync.refresh(profile: "radar-ia", into: cached)
            XCTFail("a dropped socket must not resolve to a transcript")
        } catch {
            XCTAssertEqual(cached.messages.count, 1, "the cache is untouched")
        }

        // The next attempt reconnects and recovers.
        let recovered = try await sync.refresh(profile: "radar-ia", into: cached)
        XCTAssertEqual(recovered.messages.map(\.remoteID), ["1"])
    }

    // MARK: - A. The ticket

    func testJSONRPCRequestsUseTextWebSocketFrames() throws {
        let message = try HermesRPCClient.requestMessage(
            id: 17, method: "profiles.list", params: JSONObject(["include_sessions": true])
        )
        guard case let .string(text) = message else {
            return XCTFail("Hermes /api/ws reads text frames; binary JSON is never dispatched")
        }
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 17)
        XCTAssertEqual(object["method"] as? String, "profiles.list")
        XCTAssertEqual((object["params"] as? [String: Any])?["include_sessions"] as? Bool, true)
    }

    func testTheSocketURLCarriesAFreshTicketAndNoCredential() throws {
        let dashboard = try XCTUnwrap(URL(string: "http://100.67.213.42:9119"))
        let first = try XCTUnwrap(
            HermesRPCClient.socketURL(dashboard: dashboard, ticket: "ticket-one")
        )
        let second = try XCTUnwrap(
            HermesRPCClient.socketURL(dashboard: dashboard, ticket: "ticket-two")
        )

        XCTAssertEqual(first.scheme, "ws")
        XCTAssertEqual(first.path, "/api/ws")
        XCTAssertTrue(first.query?.contains("ticket=ticket-one") == true)
        XCTAssertNotEqual(first, second, "a reconnect uses a new single-use ticket")

        // Nothing about the credential reaches the URL.
        for url in [first, second] {
            let text = url.absoluteString.lowercased()
            XCTAssertFalse(text.contains("password"))
            XCTAssertFalse(text.contains("alice:"))
        }
    }

    func testHttpsBecomesASecureSocket() throws {
        let dashboard = try XCTUnwrap(URL(string: "https://hermes.example/base/"))
        let url = try XCTUnwrap(
            HermesRPCClient.socketURL(dashboard: dashboard, ticket: "t")
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/base/api/ws")
    }
}
