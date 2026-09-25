import XCTest
@testable import Alice

/// Since gateway contract v7 (hermes-agent #110677) Hermes asks for approvals and
/// answers as JSON-RPC server→client requests; older installs send events. Both
/// must reach the same cards and be answered the way that Hermes expects.
final class GatewayServerRequestTests: XCTestCase {
    // MARK: - A fake transport

    private actor Transport: HermesRPCTransport {
        struct Sent: Equatable {
            /// `call:<method>` or `respond:<request id>`.
            let kind: String
            let fields: [String: String]
        }

        private let results: [String: JSONObject]
        private(set) var sent: [Sent] = []

        init(results: [String: [String: Any]] = [:]) {
            self.results = results.mapValues(JSONObject.init)
        }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            sent.append(Sent(kind: "call:\(method)", fields: Self.flatten(params.fields)))
            return results[method] ?? JSONObject([:])
        }

        func respond(toServerRequest id: String, result: JSONObject) async throws {
            sent.append(Sent(kind: "respond:\(id)", fields: Self.flatten(result.fields)))
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> {
            AsyncStream { $0.finish() }
        }

        private static func flatten(_ fields: [String: Any]) -> [String: String] {
            fields.compactMapValues { ($0 as? String) ?? ($0 as? Int).map(String.init) }
        }
    }

    private let identity = LiveEvents.SessionIdentity(
        profile: "radar-ia", sessionID: "stored-1", sessionKey: "stored-1",
        conversationID: "conversation-1", label: "Radar IA"
    )

    // MARK: - Frames

    func testAServerRequestFrameIsAQuestionNotAResponse() {
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": "srq-1a2b", "method": "approval",
            "params": ["session_id": "live-1", "request_id": "q-9", "command": "rm -rf build"],
        ]
        guard case let .serverRequest(id, method, params) = HermesRPCClient.inbound(frame) else {
            return XCTFail("a server→client request was not recognised")
        }
        XCTAssertEqual(id, "srq-1a2b")
        XCTAssertEqual(method, "approval")
        XCTAssertEqual(params["command"] as? String, "rm -rf build")
    }

    func testResponsesAndEventsStillRouteAsBefore() throws {
        guard case let .response(id, result) = HermesRPCClient.inbound(
            ["jsonrpc": "2.0", "id": 4, "result": ["resolved": 1]]
        ) else { return XCTFail("a response was not recognised") }
        XCTAssertEqual(id, 4)
        XCTAssertEqual(try result.get()["resolved"] as? Int, 1)

        guard case let .event(event) = HermesRPCClient.inbound([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "approval.request", "session_id": "live-1", "payload": ["request_id": "q-1"]],
        ]) else { return XCTFail("an event was not recognised") }
        XCTAssertEqual(event.type, "approval.request")
        XCTAssertEqual(event.sessionID, "live-1")
    }

    func testTheAnswerIsAResponseFrameWithTheRequestsOwnID() throws {
        let answer = try Self.frame(HermesRPCClient.responseMessage(
            id: "srq-7", result: JSONObject(["choice": "once"])
        ))
        XCTAssertEqual(answer["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(answer["id"] as? String, "srq-7")
        XCTAssertNil(answer["method"], "a response, not another request")
        XCTAssertEqual((answer["result"] as? [String: Any])?["choice"] as? String, "once")

        let refusal = try Self.frame(HermesRPCClient.errorMessage(
            id: "srq-8", code: -32601, message: "Alice cannot answer sudo."
        ))
        XCTAssertEqual(refusal["id"] as? String, "srq-8")
        XCTAssertEqual((refusal["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: - Reaching the cards

    func testAnApprovalRequestReachesTheCardKeyedByItsOwnID() throws {
        let event = try XCTUnwrap(GatewayServerRequests.event(id: "srq-1", method: "approval", params: [
            "session_id": "live-1", "request_id": "q-9",
            "command": "rm -rf build", "description": "delete the build folder",
            "choices": ["once", "session", "deny"],
        ]))
        XCTAssertEqual(event.type, "approval.request")
        XCTAssertEqual(event.sessionID, "live-1")
        XCTAssertEqual(LiveEvents.requestID(event.payload), "srq-1")

        guard case let .approval(approval) = AppStore.chatEvent(from: event) else {
            return XCTFail("no approval card in the chat")
        }
        XCTAssertEqual(approval.requestID, "srq-1")
        XCTAssertEqual(approval.command, "rm -rf build")

        let activity = try XCTUnwrap(LiveEvents.event(from: event, session: identity))
        XCTAssertEqual(activity.reference.requestID, "srq-1")
        XCTAssertEqual(activity.standing, .waiting)
    }

    func testAClarifyBatchKeepsItsQuestionsAndLockedAnswers() throws {
        let event = try XCTUnwrap(GatewayServerRequests.event(id: "srq-2", method: "clarify", params: [
            "session_id": "live-1",
            "questions": [
                ["qid": "q0", "question": "¿A o B?", "choices": ["A", "B"]],
                ["qid": "q1", "question": "¿Por qué?"],
            ],
            "answers": ["q0": "A"],
        ]))
        let activity = try XCTUnwrap(LiveEvents.event(from: event, session: identity))
        XCTAssertEqual(activity.reference.requestID, "srq-2")
        XCTAssertEqual(activity.questions.map(\.id), ["q0", "q1"])
        XCTAssertEqual(activity.questions.first?.answer, "A")
    }

    func testQuestionsAliceCannotShowAreNotTurnedIntoCards() {
        for method in ["sudo", "mcp.setup", "terminal.read", "tour"] {
            XCTAssertNil(
                GatewayServerRequests.event(id: "srq-9", method: method, params: ["session_id": "live-1"]),
                method
            )
        }
    }

    func testWhatOnlyThePersonCanTypeBecomesASecureCard() {
        for method in ["secret", "vault.unlock_prompt", "vault.save_login", "vault.code"] {
            let event = GatewayServerRequests.event(id: "srq-9", method: method, params: ["session_id": "live-1"])
            XCTAssertEqual(event?.type, "secure.request", method)
            XCTAssertEqual(event?.payload["kind"] as? String, method)
        }
    }

    func testACancelNamesTheRequestItWithdraws() {
        let cancel = HermesRPCEvent(
            type: "request.cancel", sessionID: "live-1",
            payload: ["id": "srq-1", "method": "approval", "reason": "timeout"]
        )
        XCTAssertEqual(GatewayServerRequests.cancelledRequestID(cancel), "srq-1")
        XCTAssertNil(GatewayServerRequests.cancelledRequestID(
            HermesRPCEvent(type: "message.complete", sessionID: "live-1", payload: ["id": "srq-1"])
        ))
    }

    // MARK: - Answering

    func testApprovalAnswersGoTheWayTheirHermesExpects() async throws {
        let transport = Transport(results: ["approval.respond": ["resolved": 1]])
        let source = WebSocketBotChatSource(rpc: transport)

        let current = try await source.respondToApproval(
            sessionID: "stored-1", requestID: "srq-1", choice: "session"
        )
        let older = try await source.respondToApproval(
            sessionID: "stored-1", requestID: "q-9", choice: "once"
        )

        XCTAssertTrue(LiveEvents.didResolve(current))
        XCTAssertTrue(LiveEvents.didResolve(older))
        let sent = await transport.sent
        XCTAssertEqual(sent, [
            .init(kind: "respond:srq-1", fields: ["choice": "session"]),
            .init(kind: "call:approval.respond", fields: [
                "session_id": "stored-1", "request_id": "q-9", "choice": "once",
            ]),
        ])
    }

    func testClarifyAnswersGoTheWayTheirHermesExpects() async throws {
        let transport = Transport(results: [
            "clarify.lock": ["status": "ok", "remaining": ["q1"]],
            "clarify.respond": ["status": "ok"],
        ])
        let source = WebSocketBotChatSource(rpc: transport)

        let single = try await source.answerClarify(
            sessionID: "stored-1", requestID: "srq-3", questionID: nil, answer: "beta"
        )
        let locked = try await source.answerClarify(
            sessionID: "stored-1", requestID: "srq-4", questionID: "q0", answer: "A"
        )
        let older = try await source.answerClarify(
            sessionID: "stored-1", requestID: "c-5", questionID: nil, answer: "yes"
        )

        XCTAssertEqual(LiveEvents.clarifyReply(single, questionID: nil), .resolved)
        XCTAssertEqual(LiveEvents.clarifyReply(locked, questionID: "q0"), .partial(remaining: ["q1"]))
        XCTAssertEqual(LiveEvents.clarifyReply(older, questionID: nil), .resolved)
        let sent = await transport.sent
        XCTAssertEqual(sent.map(\.kind), ["respond:srq-3", "call:clarify.lock", "call:clarify.respond"])
        XCTAssertEqual(sent[0].fields, ["answer": "beta"])
        XCTAssertEqual(sent[1].fields, ["request_id": "srq-4", "question_id": "q0", "answer": "A"])
        XCTAssertEqual(sent[2].fields, ["request_id": "c-5", "answer": "yes", "session_id": "stored-1"])
    }

    // MARK: - Reconnecting

    func testAReconnectReplaysOpenRequestsAndIgnoresTheLeftoverApproval() {
        let resumed = JSONObject([
            "session_id": "live-2",
            "open_requests": [
                ["id": "srq-5", "method": "approval",
                 "params": ["session_id": "live-2", "request_id": "q-9", "command": "ls"]],
                ["id": "srq-6", "method": "clarify",
                 "params": ["session_id": "live-2", "question": "¿Seguro?"]],
                ["id": "srq-7", "method": "sudo", "params": ["session_id": "live-2"]],
            ],
            "pending_approval": ["request_id": "q-9", "command": "ls"],
        ])
        let events = LiveEvents.pendingEvents(from: resumed, session: identity)
        XCTAssertEqual(events.compactMap(\.reference.requestID), ["srq-5", "srq-6"])
    }

    func testAnOlderHermesStillReportsItsPendingRequests() {
        let resumed = JSONObject([
            "pending_approval": ["request_id": "q-9", "command": "ls"],
            "pending_clarify": ["request_id": "c-1", "question": "¿Seguro?"],
        ])
        let events = LiveEvents.pendingEvents(from: resumed, session: identity)
        XCTAssertEqual(events.compactMap(\.reference.requestID), ["q-9", "c-1"])
    }

    // MARK: - Helpers

    private static func frame(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        guard case let .string(text) = message else {
            XCTFail("Hermes reads text frames")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
