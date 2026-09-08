import XCTest
@testable import Alice

/// A parent turn with a child inside it.
///
/// `sendToBotChat` used to leave its stream on the first `message.complete` of
/// any shape. The subagent mirror in `agent_callbacks` emits exactly that —
/// `{"text": summary}`, no `status`, on the **parent's** session id — when a
/// child finishes, so a parent that delegated anything was abandoned mid-run
/// and the reply it was still writing was thrown away.
final class SubagentSequenceTests: XCTestCase {

    private let session = LiveEvents.SessionIdentity(
        profile: "radar-ia", sessionID: "sess-1", sessionKey: "key-1",
        conversationID: "conv-1", label: "Radar IA"
    )

    private func frame(_ type: String, _ payload: [String: Any]) -> HermesRPCEvent {
        HermesRPCEvent(type: type, sessionID: "sess-1", payload: payload)
    }

    /// The whole sequence, in order, as Hermes emits it.
    private var parentRunWithAChild: [HermesRPCEvent] {
        [
            frame("message.delta", ["text": "Looking into it. "]),
            frame("tool.start", ["name": "delegate_task", "id": "t1"]),
            // The child's mirror, on the parent's session id, with no status.
            frame("message.complete", ["text": "child finished its part"]),
            frame("tool.complete", ["name": "delegate_task", "id": "t1"]),
            frame("message.delta", ["text": "Here is what it found."]),
            // The parent's real ending.
            frame("message.complete", ["text": "Here is what it found.", "status": "complete"]),
        ]
    }

    /// Where the chat stream is allowed to stop.
    func testStreamStopsOnlyAtTheParentsRealEnding() {
        let stops = parentRunWithAChild.enumerated()
            .filter { LiveEvents.isTurnOutcome($0.element) }
            .map(\.offset)
        XCTAssertEqual(stops, [5], "the stream must run to the parent's own completion")
    }

    /// Replays the sequence the way the chat consumer does and checks that
    /// everything after the child still arrives.
    func testChildCompletionDoesNotCutTheParentShort() {
        var rendered: [String] = []
        var stopped = false

        for event in parentRunWithAChild {
            if stopped { break }
            if let chatEvent = AppStore.chatEvent(from: event) {
                if case let .delta(text) = chatEvent { rendered.append(text) }
                if case let .run(_, status, _) = chatEvent {
                    rendered.append("run:\(status)")
                }
            }
            if LiveEvents.isTurnOutcome(event) { stopped = true }
        }

        XCTAssertEqual(
            rendered,
            ["Looking into it. ", "Here is what it found.", "run:completed"],
            "the parent's second half and its ending must survive the child"
        )
    }

    /// The child's mirror must not be drawn as the turn ending either.
    func testChildCompletionIsNotAChatRunEvent() {
        XCTAssertNil(AppStore.chatEvent(from: frame("message.complete", ["text": "child"])))
    }

    /// …nor recorded in Activity as the assistant finishing.
    func testChildCompletionIsNotAnActivityEvent() {
        XCTAssertNil(LiveEvents.event(
            from: frame("message.complete", ["text": "child"]), session: session
        ))
    }

    // MARK: - The other two outcomes in the contract

    /// `_result_status` returns exactly complete / error / interrupted.
    func testErrorEndsTheStreamAndIsDrawnAsAFailure() throws {
        let ending = frame("message.complete", ["status": "error", "error": "model refused"])
        XCTAssertTrue(LiveEvents.isTurnOutcome(ending))

        let chatEvent = try XCTUnwrap(AppStore.chatEvent(from: ending))
        guard case let .run(_, status, _) = chatEvent else {
            return XCTFail("expected a run event, got \(chatEvent)")
        }
        XCTAssertEqual(status, .failed)

        let activity = try XCTUnwrap(LiveEvents.event(from: ending, session: session))
        XCTAssertEqual(activity.severity, .failure)
    }

    /// An interrupted turn ends the stream — the run really is over — but is
    /// not reported as finished work or as a failure, because stopping it was
    /// deliberate.
    func testInterruptedEndsTheStreamWithoutBeingReported() {
        let ending = frame("message.complete", ["text": "", "status": "interrupted"])
        XCTAssertTrue(LiveEvents.isTurnOutcome(ending))
        XCTAssertNil(LiveEvents.event(from: ending, session: session))
    }
}
