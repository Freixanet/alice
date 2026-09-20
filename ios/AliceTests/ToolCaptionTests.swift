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

    func testARunningToolNamesItselfInTheHeadline() {
        XCTAssertEqual(
            ToolCaption.headline(
                pending: true, note: nil, thoughtSeconds: nil,
                steps: [call("web_search", .done), call("mcp__cobalt__cobalt_download")], elapsed: 40
            ),
            "Downloading"
        )
    }

    func testAFinishedToolHandsTheHeadlineBackToThinking() {
        XCTAssertEqual(
            ToolCaption.headline(
                pending: true, note: nil, thoughtSeconds: nil,
                steps: [call("mcp__cobalt__cobalt_download", .done)], elapsed: 1
            ),
            "Thinking"
        )
    }

    func testAClarifyStepNeverHeadsTheLine() {
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: nil, thoughtSeconds: nil, steps: [call("clarify")], elapsed: 1),
            "Thinking"
        )
    }

    func testAShortWaitIsPlainAndALongOneMovesOn() {
        XCTAssertEqual(ToolCaption.musing(elapsed: 0, seed: 3), "Thinking")
        XCTAssertEqual(ToolCaption.musing(elapsed: ToolCaption.musingBeat - 0.1, seed: 3), "Thinking")
        let later = ToolCaption.musing(elapsed: ToolCaption.musingBeat, seed: 3)
        XCTAssertNotEqual(later, "Thinking")
        XCTAssertTrue(ToolCaption.musings.contains(later))
        XCTAssertNotEqual(later, ToolCaption.musing(elapsed: ToolCaption.musingBeat * 2, seed: 3), "the word changes each beat")
    }

    func testTwoRepliesStartTheirWaitInDifferentPlaces() {
        let a = ToolCaption.seed("reply-a"), b = ToolCaption.seed("reply-b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, ToolCaption.seed("reply-a"), "stable across redraws")
        XCTAssertNotEqual(
            ToolCaption.musing(elapsed: ToolCaption.musingBeat, seed: 0),
            ToolCaption.musing(elapsed: ToolCaption.musingBeat, seed: 1)
        )
    }

    func testEveryMusingIsShortEnoughForOneLine() {
        for word in ToolCaption.musings {
            XCTAssertLessThanOrEqual(word.count, 24, word)
            XCTAssertFalse(word.hasSuffix("…"), word)
        }
    }

    func testAStatusLineBeatsAMusing() {
        XCTAssertEqual(
            ToolCaption.headline(
                pending: true, note: nil, thoughtSeconds: nil, elapsed: 40, seed: 3,
                status: "Reading the notes store"
            ),
            "Reading the notes store"
        )
    }

    func testADeliveryNoteBeatsAStatusLine() {
        XCTAssertEqual(
            ToolCaption.headline(
                pending: true, note: "Reconnecting to Hermes…", thoughtSeconds: nil,
                elapsed: 40, status: "Reading the notes store"
            ),
            "Reconnecting to Hermes…"
        )
    }

    func testAToolWithAFileNamesTheFile() {
        let reading = Message.ToolCall(
            id: "t1", name: "read_file", status: .start, detail: "ios/Alice/NoteEditor.swift"
        )
        XCTAssertEqual(ToolCaption.phrase(for: reading), "Reading NoteEditor.swift")
        XCTAssertEqual(
            ToolCaption.headline(pending: true, note: nil, thoughtSeconds: nil, steps: [reading], elapsed: 40),
            "Reading NoteEditor.swift"
        )
    }

    func testMusingsStayUntilSomethingHappens() {
        let later = ToolCaption.headline(
            pending: true, note: nil, thoughtSeconds: nil, elapsed: ToolCaption.musingBeat, seed: 3
        )
        XCTAssertEqual(later, ToolCaption.musing(elapsed: ToolCaption.musingBeat, seed: 3))
        XCTAssertNotEqual(later, "Thinking")
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

    func testMediaToolsSayWhatTheyDo() {
        XCTAssertEqual(ToolCaption.phrase(for: call("mcp__cobalt__cobalt_download"), running: true), "Downloading…")
        XCTAssertEqual(ToolCaption.phrase(for: call("file_upload"), running: true), "Uploading…")
        XCTAssertEqual(ToolCaption.phrase(for: call("message_agent"), running: true), "Asking a teammate…")
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
