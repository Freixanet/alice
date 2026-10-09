import Foundation
import XCTest
@testable import Alice

final class ReviewTaskTests: XCTestCase {
    private func task(_ status: String = "needs_review") throws -> ReviewTask {
        let object: [String: Any] = [
            "id": "task", "title": "Reply", "request": "Prepare a reply", "profile": "default",
            "session_id": "original", "status": status, "version": 7, "summary": "Ready",
            "checks": ["Checked the recipient"], "attention_id": "round-2",
            "proposal": ["tool": "send", "description": "Send the prepared reply", "args": ["id": "draft", "confirm": true, "message_id": Int64(9007199254740993)]],
            "blocks": [["type": "draft", "channel": "email", "to": ["person@example.com"], "body": "<script>do not execute</script>"]]
        ]
        return try JSONDecoder().decode(ReviewTask.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testServerVersionAndConversationArePreserved() throws {
        let value = try task()
        XCTAssertEqual(value.version, 7)
        XCTAssertEqual(value.session_id, "original")
        XCTAssertEqual(value.profile, "default")
        XCTAssertEqual(value.attention_id, "round-2")
        XCTAssertNil(value.resume_state)
    }
    func testEveryHostStateDecodesWithoutInventingAState() throws {
        for status in ["backlog", "in_progress", "needs_review", "blocked", "done", "failed"] {
            XCTAssertEqual(try task(status).status.rawValue, status)
        }
        XCTAssertThrowsError(try task("approved"))
    }
    func testDraftIsLiteralDataAndArgumentsRemainInspectable() throws {
        let value = try task()
        XCTAssertEqual(value.blocks[0].body, "<script>do not execute</script>")
        let args = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(value.proposal).args.formatted.utf8)) as? [String: Any]
        XCTAssertEqual(args?["id"] as? String, "draft")
        XCTAssertEqual(args?["confirm"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(value.proposal).args.formatted.contains("9007199254740993"))
    }
}
