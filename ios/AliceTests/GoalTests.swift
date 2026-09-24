import XCTest
@testable import Alice

final class GoalTests: XCTestCase {
    func testAGoalFromThePluginReadsWithItsPlanAndProgress() {
        let row: [String: Any] = [
            "id": "a1", "title": "Vuelta al cole", "why": "Que no se escape nada", "status": "active",
            "due": "2026-09-30", "created_at": 1_790_000_000.0, "updated_at": 1_790_000_100.0,
            "steps": [
                ["id": "s1", "text": "Leer los correos", "status": "done", "done_at": 1_790_000_050.0],
                ["id": "s2", "text": "Comprar el material", "status": "doing"],
                ["id": "s3", "text": "Reservar la cena", "status": "todo"],
            ],
            "log": [["at": 1_790_000_050.0, "by": "agent", "text": "Done: Leer los correos"]],
            "routines": ["job1"],
        ]
        let goal = Goal.parse(row)
        XCTAssertEqual(goal?.done, 1)
        XCTAssertEqual(goal?.progress ?? 0, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(goal?.next?.id, "s2")
        XCTAssertNotNil(goal?.dueDate)
        XCTAssertEqual(goal?.log.first?.byPerson, false)
        XCTAssertNil(Goal.parse(["title": "sin id"]))
    }

    func testChangesBecomeThePluginsFields() {
        let body = GoalChange(stepID: "s2", stepStatus: .done).body
        XCTAssertEqual(body["step_id"] as? String, "s2")
        XCTAssertEqual(body["step_status"] as? String, "done")
        XCTAssertNil(body["remove_step"])
        XCTAssertEqual(GoalChange(status: .paused).body["status"] as? String, "paused")
    }
}
