import XCTest
@testable import Alice

final class CronParsingTests: XCTestCase {
    func testCurrentHermesCronRowUsesPlainSchedule() throws {
        let row: [String: Any] = [
            "id": "c3cf075a5b68",
            "name": "Radar IA daily briefing",
            "schedule": "0 10 * * *",
            "enabled": true,
            "profile": "radar-ia",
            "next_run_at": 1_788_600_000.0,
        ]

        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertEqual(job.id, "c3cf075a5b68")
        XCTAssertEqual(job.schedule, "0 10 * * *")
        XCTAssertTrue(job.enabled)
        XCTAssertNotNil(job.nextRun)
    }

    func testOlderNestedScheduleStillParses() throws {
        let row: [String: Any] = [
            "id": "legacy",
            "schedule": ["expr": "0 9 * * 1-5"],
            "enabled": false,
        ]

        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertEqual(job.schedule, "0 9 * * 1-5")
        XCTAssertFalse(job.enabled)
    }

    func testIsoDateStillParses() {
        XCTAssertNotNil(HermesClient.date("2026-09-05T08:00:00Z"))
    }
}
