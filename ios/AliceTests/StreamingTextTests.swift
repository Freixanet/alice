import XCTest
@testable import Alice

/// What shows of a reply while it is still arriving.
final class StreamingTextTests: XCTestCase {
    func testLeadingBlankLinesLeaveNoGap() {
        XCTAssertEqual(MessageRow.streamingText("\n\n\nYo iría a La Cuina."), "Yo iría a La Cuina.")
    }

    func testBoldMarkersDoNotShow() {
        XCTAssertEqual(MessageRow.streamingText("**Yo iría a La Cuina.** Es el mejor"), "Yo iría a La Cuina. Es el mejor")
    }

    func testAnOpenBlockIsHeldBackUntilItCloses() {
        XCTAssertEqual(MessageRow.streamingText("Tres sitios:\n\n```alice-ui\n{\"type\":\"places\","), "Tres sitios:")
        let closed = "Mira:\n```swift\nlet a = 1\n```\nY ya."
        XCTAssertEqual(MessageRow.streamingText(closed), closed)
    }
}

/// How a reply still arriving is cut into finished blocks and the paragraph being written.
final class StreamingSplitTests: XCTestCase {
    func testFinishedBlocksAreLaidOutAndTheLastParagraphIsWriting() {
        let parts = StreamingReply.split("### Los que vería\n\n1. [Brian Tong](https://youtu.be/x)\n\nEl más út")
        XCTAssertEqual(parts.finished, "### Los que vería\n\n1. [Brian Tong](https://youtu.be/x)")
        XCTAssertEqual(parts.writing, "El más út")
    }

    func testAnOpenBlockWaitsWholeAndABlankLineInsideItIsNoBoundary() {
        let parts = StreamingReply.split("Tres sitios:\n\n```alice-ui\n{\"type\":\"places\",\n\n\"items\":[")
        XCTAssertEqual(parts.finished, "Tres sitios:")
        XCTAssertEqual(parts.writing, "")
    }

    func testATableStillGrowingStaysOutOfSight() {
        let parts = StreamingReply.split("Comparo:\n\n| A | B |\n| --- |")
        XCTAssertEqual(parts.finished, "Comparo:")
        XCTAssertEqual(parts.writing, "")
    }
}
