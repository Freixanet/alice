import XCTest
@testable import Alice

final class ToolCaptionTests: XCTestCase {
    private func call(_ name: String, _ status: Message.ToolCall.Status = .start) -> Message.ToolCall {
        Message.ToolCall(id: name, name: name, status: status, detail: nil)
    }

    // ── which steps are shown ────────────────────────────────────────────────

    func testClarifyIsNotAStep() {
        let steps = ToolCaption.steps(in: [call("web_extract"), call("clarify")])
        XCTAssertEqual(steps.map(\.name), ["web_extract"])
    }

    func testEveryOtherToolIsAStep() {
        let steps = ToolCaption.steps(in: [call("web_search"), call("terminal"), call("memory")])
        XCTAssertEqual(steps.count, 3)
    }

    // ── what the line above the reply says ───────────────────────────────────

    func testItSaysItIsThinkingWhileTheReplyIsComing() {
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: nil, thoughtSeconds: nil), "Thinking"
        )
    }

    func testWhatItIsWaitingOnBeatsThinking() {
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: "Reconnecting to Hermes…", thoughtSeconds: 2),
            "Reconnecting to Hermes…"
        )
    }

    func testAFinishedReplySaysWhatItTook() {
        XCTAssertEqual(
            ToolCaption.headline(pending: false, note: nil, thoughtSeconds: 4),
            "Thought for 4 seconds"
        )
        XCTAssertEqual(
            ToolCaption.headline(pending: false, note: nil, thoughtSeconds: 1),
            "Thought for 1 second"
        )
    }

    func testAReplyThatTookNoTimeSaysSoInWords() {
        // "Thought for 0 seconds" reads as a bug in the clock.
        XCTAssertEqual(
            ToolCaption.headline(pending: false, note: nil, thoughtSeconds: 0),
            "Thought for a moment"
        )
        XCTAssertEqual(
            ToolCaption.headline(pending: false, note: nil, thoughtSeconds: nil),
            "Thought for a moment"
        )
    }

    // ── how a step is named ──────────────────────────────────────────────────

    func testARunningStepIsStillHappening() {
        XCTAssertEqual(ToolCaption.phrase(for: call("web_extract"), running: true), "Reading a page…")
    }

    func testAFinishedStepDropsTheEllipsis() {
        XCTAssertEqual(ToolCaption.phrase(for: call("web_extract"), running: false), "Reading a page")
    }

    func testAnUnknownToolIsNamedInItsOwnWords() {
        XCTAssertEqual(ToolCaption.phrase(for: call("note_add"), running: false), "Note add")
    }

    // ── settling ─────────────────────────────────────────────────────────────

    func testSettlingClosesLeftoverToolsAndRecordsTheTime() {
        var message = Message(
            id: "a", role: .assistant, content: "Done.", createdAt: Date(timeIntervalSinceNow: -4),
            pending: true, tools: [call("web_extract")]
        )
        message.settle()
        XCTAssertEqual(message.tools.first?.status, .done)
        XCTAssertFalse(message.pending)
        XCTAssertEqual(message.thoughtSeconds, 4)
    }

    func testSettlingTwiceKeepsTheFirstTime() {
        var message = Message(
            id: "a", role: .assistant, content: "Done.",
            createdAt: Date(timeIntervalSinceNow: -3), pending: true
        )
        message.settle()
        message.pending = true
        message.settle(at: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(message.thoughtSeconds, 3)
    }

    func testAReplyRecoveredHoursLaterIsNotStampedWithTheNap() {
        var message = Message(
            id: "a", role: .assistant, content: "Done.",
            createdAt: Date(timeIntervalSinceNow: -7200), pending: true
        )
        message.settle()
        XCTAssertNil(message.thoughtSeconds)
        XCTAssertFalse(message.pending)
    }
}
