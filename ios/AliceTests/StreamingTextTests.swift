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
