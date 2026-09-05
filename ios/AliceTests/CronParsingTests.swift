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

/// The grouping, which decides whether a routine is ever found again.
final class CronGroupingTests: XCTestCase {
    /// The shape this agent actually serves: `api/crons?all_profiles=1`
    /// answers `{"jobs": [...]}` with `owner_profile` set per row.
    func testGroupsByOwnerProfile() {
        let grouped = DashboardClient.group([
            ["id": "a", "schedule": "0 10 * * *", "owner_profile": "radar-ia"],
            ["id": "b", "schedule": "0 9 * * *", "owner_profile": "chollometro"],
            ["id": "c", "schedule": "0 8 * * *", "owner_profile": "radar-ia"],
        ])

        XCTAssertEqual(Set(grouped.keys), ["radar-ia", "chollometro"])
        XCTAssertEqual(grouped["radar-ia"]?.map(\.id), ["a", "c"])
    }

    /// `owner_profile` says whose the routine is; the persisted `profile` says
    /// where it runs, and the two differ for a job that executes elsewhere.
    /// Grouping by the wrong one files the routine under a bot that does not
    /// own it, and the owner's screen shows nothing.
    func testOwnerWinsOverTheExecutionProfile() {
        let grouped = DashboardClient.group([
            [
                "id": "a", "schedule": "0 10 * * *",
                "owner_profile": "radar-ia", "profile": "default",
            ]
        ])

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertNil(grouped["default"])
    }

    /// The newer upstream shape, which annotates rows with `profile` and
    /// `profile_name` and no owner at all.
    func testFallsBackToProfileWhenNoOwnerIsSent() {
        let grouped = DashboardClient.group([
            [
                "id": "a", "schedule": "0 10 * * *",
                "profile": "radar-ia", "profile_name": "radar-ia",
            ]
        ])

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
    }

    /// An empty owner is not an owner. It used to key the whole dictionary
    /// under "", where nothing looks.
    func testSkipsRowsWithNoUsableOwner() {
        let grouped = DashboardClient.group([
            ["id": "a", "owner_profile": "", "profile": "radar-ia"],
            ["id": "b", "owner_profile": ""],
            ["schedule": "0 10 * * *", "owner_profile": "radar-ia"],
        ])

        XCTAssertEqual(grouped["radar-ia"]?.map(\.id), ["a"])
        XCTAssertNil(grouped[""])
    }
}
