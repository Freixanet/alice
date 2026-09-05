import XCTest
@testable import Alice

final class CronParsingTests: XCTestCase {
    /// The real row for `c3cf075a5b68` stores `schedule` as an object and
    /// sends its times as ISO-8601 with an offset — not the plain string and
    /// Unix seconds an earlier fixture here assumed. Both are accepted; this
    /// asserts the one this installation actually sends.
    func testTheStoredScheduleObjectAndIsoTimesParse() throws {
        let row: [String: Any] = [
            "id": "c3cf075a5b68",
            "name": "Radar IA — informe diario",
            "schedule": ["kind": "cron", "expr": "0 10 * * *", "display": "daily at 10am"],
            "schedule_display": "daily at 10am",
            "enabled": true,
            "profile": "radar-ia",
            "next_run_at": "2026-09-05T10:00:00+02:00",
            "last_run_at": NSNull(),
        ]

        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertEqual(job.id, "c3cf075a5b68")
        XCTAssertEqual(job.schedule, "daily at 10am")
        XCTAssertTrue(job.enabled)
        XCTAssertNotNil(job.nextRun)
        XCTAssertNil(job.lastRun)
    }

    /// A plain-string schedule and Unix seconds, which other Hermes surfaces
    /// send. Tolerated, not this one's contract.
    func testPlainStringScheduleAndUnixTimesAlsoParse() throws {
        let row: [String: Any] = [
            "id": "other",
            "schedule": "0 10 * * *",
            "enabled": true,
            "next_run_at": 1_788_600_000.0,
        ]

        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertEqual(job.schedule, "0 10 * * *")
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
///
/// The fixture is the real row for `c3cf075a5b68` as this agent serves it:
/// the stored job from `profiles/radar-ia/cron/jobs.json` plus the `profile`
/// and `profile_name` that `_annotate_cron_job` stamps on the way out. The
/// prompt is elided and nothing else is altered.
final class CronGroupingTests: XCTestCase {
    static func radarIARow() -> [String: Any] { [
        "id": "c3cf075a5b68",
        "name": "Radar IA — informe diario",
        "prompt": "<elided>",
        "model": "stepfun/step-3.7-flash:free",
        "provider": "nous",
        "schedule": ["kind": "cron", "expr": "0 10 * * *", "display": "daily at 10am"],
        "schedule_display": "daily at 10am",
        "enabled": true,
        "state": "scheduled",
        "created_at": "2026-09-05T05:12:40.009802+02:00",
        "next_run_at": "2026-09-05T10:00:00+02:00",
        "last_run_at": NSNull(),
        "deliver": "bot-chat:default",
        "profile": "radar-ia",
        "profile_name": "radar-ia",
        "is_default_profile": false,
    ] }

    /// The whole point: this row has to land under the slug, because that is
    /// what `BotRow.name` holds and what `routines(for:)` is asked for.
    func testTheRealRadarIARowLandsUnderItsSlug() throws {
        let grouped = DashboardClient.group([Self.radarIARow()])

        XCTAssertEqual(Array(grouped.keys), ["radar-ia"])
        let job = try XCTUnwrap(grouped["radar-ia"]?.first)
        XCTAssertEqual(job.id, "c3cf075a5b68")
        XCTAssertEqual(job.name, "Radar IA — informe diario")
        XCTAssertEqual(job.schedule, "daily at 10am")
        XCTAssertTrue(job.enabled)
        XCTAssertNotNil(job.nextRun)
        XCTAssertNil(job.lastRun)
    }

    /// A display name must never become the key. This agent sends the slug in
    /// both fields, but a row that carried a pretty name would file the
    /// routine where nobody looks — the original bug, exactly.
    func testADisplayNameDoesNotDisplaceTheSlug() throws {
        var row = Self.radarIARow()
        row["profile"] = "radar-ia"
        row["profile_name"] = "Radar IA"

        let grouped = DashboardClient.group([row])

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertNil(grouped["Radar IA"])
    }

    /// A profile with no routines is an empty answer, not a missing key that
    /// the screen could mistake for a failure.
    func testAProfileWithNoRoutinesGroupsToNothing() {
        XCTAssertTrue(DashboardClient.group([]).isEmpty)
        XCTAssertNil(DashboardClient.group([]).keys.first)
    }

    /// `profile=all` concatenates every profile's store. One bot's routine
    /// must not appear under another.
    func testAnotherProfilesRoutineStaysOutOfRadarIA() throws {
        var other = Self.radarIARow()
        other["id"] = "aa11bb22cc33"
        other["profile"] = "chollometro"
        other["profile_name"] = "chollometro"

        let grouped = DashboardClient.group([Self.radarIARow(), other])

        XCTAssertEqual(grouped["radar-ia"]?.map(\.id), ["c3cf075a5b68"])
        XCTAssertEqual(grouped["chollometro"]?.map(\.id), ["aa11bb22cc33"])
    }

    /// Legacy shape. The web UI's own listing sets `owner_profile` per row;
    /// the agent Alice talks to does not send that field at all. Kept so a
    /// dashboard pointed at the web UI still groups, not as this
    /// installation's contract.
    func testLegacyOwnerProfilePayloadStillGroups() {
        let grouped = DashboardClient.group([
            ["id": "a", "schedule": "0 10 * * *", "owner_profile": "radar-ia"],
            ["id": "b", "schedule": "0 9 * * *", "owner_profile": "chollometro"],
            ["id": "c", "schedule": "0 8 * * *", "owner_profile": "radar-ia"],
        ])

        XCTAssertEqual(Set(grouped.keys), ["radar-ia", "chollometro"])
        XCTAssertEqual(grouped["radar-ia"]?.map(\.id), ["a", "c"])
    }

    /// Legacy shape again, and the reason `owner_profile` leads the chain: in
    /// the web UI's listing the persisted `profile` says where a job executes,
    /// which can be another home entirely, while `owner_profile` says whose it
    /// is. This agent never sends both, so the case is only reachable there.
    func testLegacyOwnerProfileWinsOverTheExecutionProfile() {
        let grouped = DashboardClient.group([
            [
                "id": "a", "schedule": "0 10 * * *",
                "owner_profile": "radar-ia", "profile": "default",
            ]
        ])

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertNil(grouped["default"])
    }

    /// This installation's actual shape: `_annotate_cron_job` sets `profile`
    /// and `profile_name` to the same canonical profile name and no owner.
    func testGroupsByProfileWhenNoOwnerIsSent() {
        let grouped = DashboardClient.group([
            [
                "id": "a", "schedule": "0 10 * * *",
                "profile": "radar-ia", "profile_name": "radar-ia",
            ]
        ])

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
    }

    /// An empty ownership field is not an owner. It used to key the whole
    /// dictionary under "", where nothing looks.
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
