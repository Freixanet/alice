import XCTest
@testable import Alice

/// Answering things, and the ways an answer can fail to mean what it looks like.
final class ClarifyContractTests: XCTestCase {

    private let session = LiveEvents.SessionIdentity(
        profile: "radar-ia", sessionID: "sess-1", sessionKey: "key-1",
        conversationID: "conv-1", label: "Radar IA"
    )

    /// `_clarify_block` single-question shape.
    func testSingleQuestionWithChoices() throws {
        let event = try XCTUnwrap(LiveEvents.clarify(
            ["request_id": "c1", "question": "Which repository?",
             "choices": ["alice", "hermes"]],
            session: session
        ))
        let question = try XCTUnwrap(event.question)
        XCTAssertEqual(question.text, "Which repository?")
        XCTAssertEqual(question.choices, ["alice", "hermes"])
        XCTAssertFalse(question.allowsMultiple)
        XCTAssertEqual(event.id, "clarify:c1")
        XCTAssertTrue(event.isActionable)
    }

    /// `clarify` is used for open questions too. With no choices there must
    /// still be a way to answer, or the agent stays blocked with nothing to
    /// press.
    func testOpenQuestionKeepsAnAnswerBox() throws {
        let event = try XCTUnwrap(LiveEvents.clarify(
            ["request_id": "c2", "question": "What should I call it?", "choices": []],
            session: session
        ))
        XCTAssertTrue(try XCTUnwrap(event.question).choices.isEmpty)
        XCTAssertTrue(event.isActionable)
    }

    func testMultiSelectIsCarried() throws {
        let event = try XCTUnwrap(LiveEvents.clarify(
            ["request_id": "c3", "question": "Which ones?",
             "choices": ["a", "b"], "multi_select": true],
            session: session
        ))
        XCTAssertTrue(try XCTUnwrap(event.question).allowsMultiple)
    }

    /// The batch shape: `{questions: [{qid, question, choices, multi_select}]}`.
    func testBatchSurfacesItsFirstQuestion() throws {
        let event = try XCTUnwrap(LiveEvents.clarify(
            ["request_id": "c4", "questions": [
                ["qid": "q1", "question": "Branch?", "choices": ["main"], "multi_select": false],
                ["qid": "q2", "question": "Push?", "choices": ["yes", "no"], "multi_select": false],
            ]],
            session: session
        ))
        XCTAssertEqual(try XCTUnwrap(event.question).text, "Branch?")
        XCTAssertEqual(try XCTUnwrap(event.question).choices, ["main"])
    }

    /// A live frame and the `session.resume` snapshot are the same shape, so
    /// they must read as one row rather than two.
    func testLiveAndPendingClarifyShareAnIdentity() throws {
        let payload: [String: Any] = ["request_id": "c1", "question": "Which repository?"]
        let live = try XCTUnwrap(LiveEvents.event(
            from: HermesRPCEvent(type: "clarify.request", sessionID: "sess-1", payload: payload),
            session: session
        ))
        let polled = try XCTUnwrap(LiveEvents.pendingClarify(payload, session: session))
        XCTAssertEqual(live.id, polled.id)
        XCTAssertEqual(live.question, polled.question)
    }

    func testQuestionlessFrameIsIgnored() {
        XCTAssertNil(LiveEvents.clarify(["request_id": "c5"], session: session))
    }
}

/// Both response methods answer *successfully* while reporting that nothing was
/// resolved. A call that did not throw is not evidence that anything happened.
final class ResolutionEvidenceTests: XCTestCase {

    /// `approval.respond` → `{"resolved": <count>}`.
    func testApprovalResolvedCount() {
        XCTAssertTrue(LiveEvents.didResolve(JSONObject(["resolved": 1])))
        XCTAssertTrue(LiveEvents.didResolve(JSONObject(["resolved": 3])))
        // Nothing was holding it: already answered elsewhere, or expired.
        XCTAssertFalse(LiveEvents.didResolve(JSONObject(["resolved": 0])))
    }

    /// `clarify.respond` → `{"status": "ok"|"expired"}`, both as successes.
    func testClarifyStatus() {
        XCTAssertTrue(LiveEvents.didResolve(JSONObject(["status": "ok"])))
        XCTAssertFalse(LiveEvents.didResolve(JSONObject(["status": "expired"])))
    }

    /// An answer Alice cannot interpret is not proof of anything.
    func testUnrecognisedReplyIsNotResolution() {
        XCTAssertFalse(LiveEvents.didResolve(JSONObject([:])))
        XCTAssertFalse(LiveEvents.didResolve(JSONObject(["ok": true])))
    }
}

/// A request must be answered on the transport it arrived on, and never on a
/// server it does not belong to.
final class TransportRoutingTests: XCTestCase {

    func testDefaultTransportIsTheSocket() {
        XCTAssertEqual(AliceEvent.Reference().transport, .socket)
    }

    /// The two are different protocols on different ports: `approval.respond`
    /// keyed by `request_id` over the dashboard socket, versus a POST to
    /// `/v1/runs/{id}/approval` keyed by the run.
    func testGatewayRunKeepsItsRunIdentity() {
        let reference = AliceEvent.Reference(
            transport: .gatewayRun, runID: "run-7", profile: "radar-ia"
        )
        XCTAssertEqual(reference.transport, .gatewayRun)
        XCTAssertEqual(reference.runID, "run-7")
        XCTAssertNil(reference.requestID)
    }

    /// A notification kept from before Alice was pointed at another Hermes must
    /// not answer on the new one.
    func testReferenceRefusesAForeignInstallation() {
        let home = AppStore.installationFingerprint("http://100.67.213.42:9119")
        let other = AppStore.installationFingerprint("http://192.168.1.10:9119")
        let reference = AliceEvent.Reference(installation: home)

        XCTAssertTrue(reference.belongs(to: home))
        XCTAssertFalse(reference.belongs(to: other))
        // A reference from before Alice recorded which installation it was.
        XCTAssertTrue(AliceEvent.Reference().belongs(to: home))
    }
}
