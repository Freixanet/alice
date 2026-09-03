import Foundation
import XCTest
@testable import Alice

final class HermesRunProtocolTests: XCTestCase {
    func testApprovalRequestBecomesRunPauseAndApproval() throws {
        let chunk = """
        {
          "event": "approval.request",
          "run_id": "run-123",
          "tool": "terminal",
          "description": "Hermes wants to update itself.",
          "command": "hermes update",
          "choices": ["once", "session", "always", "deny", "invalid"]
        }
        """

        let events = HermesRunProtocol.events(from: chunk, fallbackRunID: "fallback")
        XCTAssertEqual(events.count, 2)

        guard case let .run(runID, status, output) = events[0] else {
            return XCTFail("Expected run state first")
        }
        XCTAssertEqual(runID, "run-123")
        XCTAssertEqual(status, .waitingForApproval)
        XCTAssertNil(output)

        guard case let .approval(approval) = events[1] else {
            return XCTFail("Expected approval second")
        }
        XCTAssertEqual(approval.runID, "run-123")
        XCTAssertEqual(approval.title, "terminal")
        XCTAssertEqual(approval.detail, "Hermes wants to update itself.")
        XCTAssertEqual(approval.command, "hermes update")
        XCTAssertEqual(approval.choices, [.once, .session, .always, .deny])
    }

    func testApprovalDefaultsToOnceAndDeny() {
        let chunk = """
        {"event":"approval.request","run_id":"run-1","title":"Confirm"}
        """
        let events = HermesRunProtocol.events(from: chunk, fallbackRunID: "fallback")
        guard events.count == 2, case let .approval(approval) = events[1] else {
            return XCTFail("Expected an approval event")
        }
        XCTAssertEqual(approval.choices, [.once, .deny])
    }

    func testRunSnapshotRecoversPendingApproval() throws {
        let data = Data(
            """
            {
              "run_id":"run-7",
              "status":"waiting_for_approval",
              "pending_approval": {
                "title":"Run command",
                "command":"hermes update",
                "choices":["once","deny"]
              }
            }
            """.utf8
        )

        let snapshot = try XCTUnwrap(HermesRunProtocol.parseSnapshot(data))
        XCTAssertEqual(snapshot.runID, "run-7")
        XCTAssertEqual(snapshot.status, .waitingForApproval)
        XCTAssertEqual(snapshot.approval?.command, "hermes update")
        XCTAssertEqual(snapshot.approval?.choices, [.once, .deny])
    }

    func testRunLifecycleAndToolEvents() {
        let started = HermesRunProtocol.events(
            from: #"{"event":"run.started","run_id":"run-2"}"#,
            fallbackRunID: "fallback"
        )
        guard case let .run(_, status, _) = started.first else {
            return XCTFail("Expected run event")
        }
        XCTAssertEqual(status, .running)

        let tool = HermesRunProtocol.events(
            from: #"{"event":"tool.completed","run_id":"run-2","tool":"terminal","call_id":"call-1","preview":"done"}"#,
            fallbackRunID: "fallback"
        )
        guard case let .tool(id, name, toolStatus, detail) = tool.first else {
            return XCTFail("Expected tool event")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "terminal")
        XCTAssertEqual(toolStatus, .done)
        XCTAssertEqual(detail, "done")
    }

    func testCompletedRunCarriesFinalOutput() {
        let events = HermesRunProtocol.events(
            from: #"{"event":"run.completed","run_id":"run-9","output":"Finished"}"#,
            fallbackRunID: "fallback"
        )
        guard case let .run(runID, status, output) = events.first else {
            return XCTFail("Expected run event")
        }
        XCTAssertEqual(runID, "run-9")
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(output, "Finished")
    }

    func testSavedMessagesFromBeforeRunFieldsStillDecode() throws {
        let original = Message(
            id: "message-1",
            role: .assistant,
            content: "hello",
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "runID")
        object.removeValue(forKey: "runStatus")
        object.removeValue(forKey: "approval")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Message.self, from: legacy)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.runID)
        XCTAssertNil(decoded.runStatus)
        XCTAssertNil(decoded.approval)
    }
}
