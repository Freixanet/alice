import XCTest
@testable import Alice

final class ToolCaptionTests: XCTestCase {
    func testAFinishedReplyHidesAToolThatNeverReportedDone() {
        let stuck = Message.ToolCall(id: "1", name: "web_extract", status: .start, detail: nil)
        XCTAssertNil(
            ToolCaption.line(tools: [stuck], pending: false, hasContent: true, note: nil)
        )
    }

    func testARunningToolIsNamedWhileTheReplyIsStillComing() {
        let stuck = Message.ToolCall(id: "1", name: "web_extract", status: .start, detail: nil)
        XCTAssertEqual(
            ToolCaption.line(tools: [stuck], pending: true, hasContent: true, note: nil),
            "Reading a page…"
        )
    }

    func testClarifyIsNotNamedAsARunningTool() {
        let clarify = Message.ToolCall(id: "1", name: "clarify", status: .start, detail: nil)
        XCTAssertNil(
            ToolCaption.line(tools: [clarify], pending: true, hasContent: true, note: nil)
        )
        XCTAssertNil(
            ToolCaption.line(tools: [clarify], pending: true, hasContent: false, note: nil)
        )
    }

    func testThinkingShowsWhenNothingHasArrivedYet() {
        XCTAssertEqual(
            ToolCaption.line(tools: [], pending: true, hasContent: false, note: nil),
            "Thinking…"
        )
    }

    func testCloseOpenToolsMarksLeftoversDone() {
        var message = Message(
            id: "a", role: .assistant, content: "Done.", createdAt: Date(),
            pending: false,
            tools: [Message.ToolCall(id: "1", name: "web_extract", status: .start, detail: nil)]
        )
        message.closeOpenTools()
        XCTAssertEqual(message.tools.first?.status, .done)
        XCTAssertNil(
            ToolCaption.line(
                tools: message.tools, pending: message.pending, hasContent: true, note: nil
            )
        )
    }
}
