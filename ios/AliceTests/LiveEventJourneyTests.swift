import XCTest
@testable import Alice

/// The journey from a Hermes frame to something a person can act on.
///
/// Fixtures are the shapes read out of the installed Hermes 0.21 source, not
/// invented ones: `_complete_turn_payload` always sets `status`, the subagent
/// mirror in `agent_callbacks` emits `{"text": …}` without one, and
/// `_approval_request_payload` fills `choices` and redacts `command`.
final class LiveEventTranslationTests: XCTestCase {

    private let session = LiveEvents.SessionIdentity(
        profile: "radar-ia", sessionID: "sess-1", sessionKey: "key-1",
        conversationID: "conv-1", label: "Radar IA"
    )

    private func frame(_ type: String, _ payload: [String: Any]) -> HermesRPCEvent {
        HermesRPCEvent(type: type, sessionID: "sess-1", payload: payload)
    }

    // MARK: - Completion, and the trap in it

    func testTurnCompletionIsAFinishedEvent() throws {
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("message.complete", ["text": "done", "status": "complete"]),
            session: session
        ))
        XCTAssertEqual(event.kind, .finished)
        XCTAssertEqual(event.profile, "radar-ia")
        XCTAssertEqual(event.reference.conversationID, "conv-1")
        XCTAssertEqual(event.reference.sessionKey, "key-1")
    }

    /// `agent_callbacks` emits `message.complete` with only `{"text": summary}`
    /// on the *parent's* session id when a child subagent finishes. Reading the
    /// name alone would announce "the assistant finished" in the middle of a
    /// run that is still going.
    func testSubagentMirrorIsNotACompletion() {
        XCTAssertNil(LiveEvents.event(
            from: frame("message.complete", ["text": "child summary"]),
            session: session
        ))
    }

    /// A turn stopped on purpose is neither finished work nor a failure.
    func testInterruptedTurnIsNotReported() {
        XCTAssertNil(LiveEvents.event(
            from: frame("message.complete", ["text": "", "status": "interrupted"]),
            session: session
        ))
    }

    func testErroredTurnIsAFailure() throws {
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("message.complete", ["status": "error", "error": "model refused"]),
            session: session
        ))
        XCTAssertEqual(event.severity, .failure)
        XCTAssertEqual(event.detail, "model refused")
    }

    /// The reply text is the one thing that must never travel to a lock screen.
    func testCompletionNeverCarriesTheReply() throws {
        let secret = "The password rotation plan is attached"
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("message.complete", ["text": secret, "status": "complete"]),
            session: session
        ))
        XCTAssertFalse(event.summary.contains(secret))
        XCTAssertNil(event.detail)
    }

    /// `notification.show` is the in-session notice spine — credit warnings,
    /// "still starting the agent" — replaced in place by key and retracted by
    /// `notification.clear`. It is not a record of finished work.
    func testInSessionNoticeIsNotAnEvent() {
        XCTAssertNil(LiveEvents.event(
            from: frame("notification.show", [
                "text": "Still starting the agent", "level": "info", "key": "agent-build",
            ]),
            session: session
        ))
    }

    // MARK: - Intervention

    func testApprovalRequestNeedsInputAndKeepsItsRequestID() throws {
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("approval.request", [
                "request_id": "req-9", "command": "rm -rf build",
                "choices": ["once", "session", "always", "deny"],
            ]),
            session: session
        ))
        XCTAssertEqual(event.kind, .needsInput)
        XCTAssertEqual(event.standing, .waiting)
        XCTAssertTrue(event.isActionable)
        XCTAssertEqual(event.reference.requestID, "req-9")
        XCTAssertEqual(event.id, "approval:req-9")
    }

    func testClarifyRequestNeedsInput() throws {
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("clarify.request", [
                "request_id": "req-10", "question": "Which repository?",
            ]),
            session: session
        ))
        XCTAssertEqual(event.kind, .needsInput)
        XCTAssertEqual(event.id, "clarify:req-10")
    }

    /// Without an id there is nothing to resolve against, so there is nothing
    /// worth showing a button for.
    func testRequestWithoutAnIdIsIgnored() {
        XCTAssertNil(LiveEvents.event(
            from: frame("approval.request", ["command": "ls"]), session: session
        ))
    }

    /// The same request arriving live and again in a pending snapshot must be
    /// one row, or answering it in one place leaves the other still asking.
    func testLiveAndPendingApprovalShareAnIdentity() throws {
        let live = try XCTUnwrap(LiveEvents.event(
            from: frame("approval.request", ["request_id": "req-9", "command": "ls"]),
            session: session
        ))
        let polled = try XCTUnwrap(LiveEvents.pendingApproval(
            ["request_id": "req-9", "command": "ls"], session: session
        ))
        XCTAssertEqual(live.id, polled.id)
    }

    /// Hermes marks a smart-denied request as offering only once/deny. Offering
    /// "always" there would propose a permanent grant the server will refuse.
    func testChoicesComeFromTheServer() {
        XCTAssertEqual(
            LiveEvents.choices(["choices": ["once", "deny"]]), [.once, .deny]
        )
        XCTAssertEqual(
            LiveEvents.choices(["choices": ["once", "session", "always", "deny"]]),
            [.once, .session, .always, .deny]
        )
        // No list at all falls back to the pair every approval supports.
        XCTAssertEqual(LiveEvents.choices([:]), [.once, .deny])
    }

    // MARK: - Reconciliation

    private func waiting(_ requestID: String, session key: String = "key-1") -> AliceEvent {
        AliceEvent(
            id: "approval:\(requestID)", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "waiting", occurred: Date(),
            reference: .init(sessionID: key, sessionKey: key, requestID: requestID),
            standing: .waiting
        )
    }

    /// Answered on the laptop, timed out, or its session deleted: from here all
    /// three look the same, and all three mean there is nothing left to answer.
    func testRequestGoneFromTheServerStopsAsking() throws {
        let settled = LiveEvents.reconcile(
            held: [waiting("req-9")], stillPending: [], checked: ["key-1"]
        )
        let row = try XCTUnwrap(settled.first)
        XCTAssertEqual(row.standing, .gone)
        XCTAssertFalse(row.isActionable)
        XCTAssertEqual(row.severity, .informational)
    }

    func testRequestStillPendingKeepsAsking() throws {
        let settled = LiveEvents.reconcile(
            held: [waiting("req-9")], stillPending: ["req-9"], checked: ["key-1"]
        )
        XCTAssertEqual(try XCTUnwrap(settled.first).standing, .waiting)
    }

    /// A session that was not read says nothing about its requests. Declaring
    /// them over on that basis would drop a live approval because the sync
    /// happened to skip its chat.
    func testUncheckedSessionIsLeftAlone() throws {
        let settled = LiveEvents.reconcile(
            held: [waiting("req-9", session: "key-other")],
            stillPending: [], checked: ["key-1"]
        )
        XCTAssertEqual(try XCTUnwrap(settled.first).standing, .waiting)
    }

    /// Already-settled rows are not re-settled on every later sync.
    func testResolvedRowsAreLeftAlone() throws {
        var resolved = waiting("req-9")
        resolved.standing = .resolved
        let settled = LiveEvents.reconcile(
            held: [resolved], stillPending: [], checked: ["key-1"]
        )
        XCTAssertEqual(try XCTUnwrap(settled.first).standing, .resolved)
    }

    // MARK: - Routing

    func testRouteSurvivesTheNotificationRoundTrip() throws {
        let event = try XCTUnwrap(LiveEvents.event(
            from: frame("approval.request", ["request_id": "req-9"]), session: session
        ))
        // Exactly what `Notifier.post` writes into `userInfo`.
        var info: [AnyHashable: Any] = ["event": event.id]
        info["conversation"] = event.reference.conversationID
        info["profile"] = event.reference.profile
        info["session"] = event.reference.sessionID
        info["request"] = event.reference.requestID

        let route = try XCTUnwrap(Notifier.Route(userInfo: info))
        XCTAssertEqual(route.eventID, "approval:req-9")
        XCTAssertEqual(route.conversationID, "conv-1")
        XCTAssertEqual(route.requestID, "req-9")
        XCTAssertEqual(route.profile, "radar-ia")
    }

    func testRouteRejectsAForeignNotification() {
        XCTAssertNil(Notifier.Route(userInfo: ["something": "else"]))
    }

    /// A different Hermes has different cursors and a different activity list.
    func testInstallationFingerprintDistinguishesServers() {
        let a = AppStore.installationFingerprint("http://100.67.213.42:9119")
        let b = AppStore.installationFingerprint("http://192.168.1.10:9119")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, AppStore.installationFingerprint("http://100.67.213.42:9119"))
    }
}
