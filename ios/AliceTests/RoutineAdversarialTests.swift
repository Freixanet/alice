import XCTest
@testable import Alice

/// Attempts to make the routine path lie: hide a real routine, invent an
/// absence, file one under the wrong bot, or pass a partial answer off as
/// complete.
final class RoutineAdversarialTests: XCTestCase {
    private static func radarIA() -> [String: Any] { [
        "id": "c3cf075a5b68",
        "name": "Radar IA — informe diario",
        "schedule": ["kind": "cron", "expr": "0 10 * * *", "display": "daily at 10am"],
        "schedule_display": "daily at 10am",
        "enabled": true,
        "next_run_at": "2026-09-05T10:00:00+02:00",
        "profile": "radar-ia",
        "profile_name": "radar-ia",
    ] }

    // MARK: - A canonical answer is the answer, empty included

    /// A canonical 200 [] means the agent really has no routines anywhere.
    /// Consulting the legacy route after it and taking its rows would replace
    /// a true answer with an older contract's.
    func testAnEmptyCanonicalAnswerIsNotOverriddenByLegacy() async throws {
        let reader = RecordingRows([
            "api/cron/jobs?profile=all": .success([]),
            "api/crons?all_profiles=1": .success([Self.radarIA()]),
        ])

        let grouped = try await DashboardClient.routines(reading: reader)

        XCTAssertTrue(grouped.isEmpty, "legacy rows overrode a valid canonical []")
        XCTAssertEqual(
            reader.paths, ["api/cron/jobs?profile=all"],
            "legacy must not be consulted after a canonical success"
        )
    }

    /// The fallback still exists for an agent that does not serve the
    /// canonical route at all.
    func testLegacyIsStillConsultedWhenCanonicalIsAbsent() async throws {
        let reader = RecordingRows([
            "api/cron/jobs?profile=all": .failure(DashboardClient.Failure.http(404)),
            "api/crons?all_profiles=1": .success([Self.radarIA()]),
        ])

        let grouped = try await DashboardClient.routines(reading: reader)

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertEqual(reader.paths.count, 2)
    }

    // MARK: - Shape belongs to the route that answered

    func testCanonicalArrayIsAccepted() throws {
        let rows = try DashboardClient.rows(
            from: Data("[]".utf8), shape: .array
        )
        XCTAssertTrue(rows.isEmpty)
    }

    /// A canonical route that answers an object is malformed, not empty. It
    /// used to read as "0 routines" through the legacy envelope's tolerance.
    func testCanonicalObjectIsUnreadableNotEmpty() {
        for body in ["{}", "{\"foo\":\"bar\"}", "{\"jobs\":[]}"] {
            XCTAssertThrowsError(
                try DashboardClient.rows(from: Data(body.utf8), shape: .array),
                "canonical accepted \(body) as a listing"
            )
        }
    }

    func testLegacyEnvelopeIsAcceptedOnTheLegacyRoute() throws {
        XCTAssertTrue(
            try DashboardClient.rows(
                from: Data("{\"jobs\":[]}".utf8), shape: .legacyEnvelope
            ).isEmpty
        )
        XCTAssertEqual(
            try DashboardClient.rows(
                from: Data("{\"jobs\":[{\"id\":\"a\"}]}".utf8), shape: .legacyEnvelope
            ).count, 1
        )
    }

    // MARK: - Ownership

    /// `profile_name` is the same slug on the canonical route. A row carrying
    /// a display name there contradicts its own `profile`, and guessing which
    /// one means it would file the routine under a bot nobody looks up.
    func testADisplayNameNeverBecomesTheKey() {
        var row = Self.radarIA()
        row["profile_name"] = "Radar IA"

        let grouped = DashboardClient.group([row], ownership: .canonical)

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertNil(grouped["Radar IA"])
    }

    /// The canonical route never sends `owner_profile`. A row that carries one
    /// disagreeing with `profile` is two contracts mixed, and picking either
    /// silently attributes a real routine to a bot that may not own it.
    func testAContradictoryOwnerIsRejectedOnTheCanonicalRoute() {
        var row = Self.radarIA()
        row["owner_profile"] = "otra-cosa"

        let grouped = DashboardClient.group([row], ownership: .canonical)

        XCTAssertNil(grouped["otra-cosa"], "attributed to a bot that does not own it")
        XCTAssertNil(grouped["radar-ia"], "kept a row whose ownership contradicts itself")
    }

    /// On the legacy route `owner_profile` is documented as the owning home
    /// and `profile` as where the job executes, so they may differ by design.
    func testLegacyOwnerWinsOverExecutionProfile() {
        let grouped = DashboardClient.group(
            [["id": "a", "owner_profile": "radar-ia", "profile": "default"]],
            ownership: .legacyWebUI
        )

        XCTAssertEqual(grouped["radar-ia"]?.count, 1)
        XCTAssertNil(grouped["default"])
    }

    func testARowWithNoProfileIsNotGuessedAt() {
        var row = Self.radarIA()
        row.removeValue(forKey: "profile")
        row.removeValue(forKey: "profile_name")

        XCTAssertTrue(DashboardClient.group([row], ownership: .canonical).isEmpty)
    }

    // MARK: - Rows we could not read

    /// Rows arrived and none of them parsed. That is a shape problem, and
    /// saying "no routines" turns it into a claim about the agent.
    func testRowsThatAllFailToParseAreAFailureNotAnEmptyAgent() async {
        let reader = RecordingRows([
            "api/cron/jobs?profile=all": .success([["no_id": "at all"]]),
        ])

        do {
            let grouped = try await DashboardClient.routines(reading: reader)
            XCTFail("read \(grouped.count) bots out of rows none of which parsed")
        } catch {}
    }

    // MARK: - Flatten

    /// Job ids are `uuid.uuid4().hex[:12]` with no collision check, in a store
    /// per profile home — nothing guarantees they are unique across profiles.
    /// Deduplicating on id alone would delete one bot's real routine.
    func testTwoProfilesSharingAnIdKeepBothRoutines() {
        let a = JobRow(
            id: "abc123", name: "radar", prompt: "", schedule: "", enabled: true,
            lastStatus: nil, lastError: nil, lastRun: nil, nextRun: nil,
            profile: "radar-ia"
        )
        let b = JobRow(
            id: "abc123", name: "chollo", prompt: "", schedule: "", enabled: true,
            lastStatus: nil, lastError: nil, lastRun: nil, nextRun: nil,
            profile: "chollometro"
        )

        let rows = RoutineCatalog.flatten(["radar-ia": [a], "chollometro": [b]])

        XCTAssertEqual(rows.count, 2, "a real routine was deduplicated away")
        XCTAssertEqual(Set(rows.map(\.name)), ["radar", "chollo"])
    }

    // MARK: - Scheduler state and history

    func testRichSchedulerStateSurvivesParsing() throws {
        var row = Self.radarIA()
        row["enabled"] = false
        row["state"] = "paused"
        row["deliver"] = "telegram"
        row["last_status"] = "delivery_failed"
        row["last_delivery_error"] = "No home target configured"
        row["paused_reason"] = "manual"
        row["last_fire_error"] = [
            "detail": "scheduler was busy",
            "at": "2026-09-05T10:01:00+02:00",
        ]
        row["model"] = "grok-4.6"
        row["provider"] = "xai-oauth"
        row["skills"] = ["web-search", "news"]
        row["repeat"] = ["times": 3, "completed": 1]

        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertTrue(job.isPaused)
        XCTAssertEqual(job.effectiveState, "paused")
        XCTAssertEqual(job.deliver, "telegram")
        XCTAssertEqual(job.lastStatus, "delivery_failed")
        XCTAssertEqual(job.lastDeliveryError, "No home target configured")
        XCTAssertEqual(job.pausedReason, "manual")
        XCTAssertEqual(job.lastFireError, "scheduler was busy")
        XCTAssertNotNil(job.lastFireAt)
        XCTAssertEqual(job.model, "grok-4.6")
        XCTAssertEqual(job.provider, "xai-oauth")
        XCTAssertEqual(job.skills, ["web-search", "news"])
        XCTAssertEqual(job.repeatTimes, 3)
        XCTAssertEqual(job.repeatCompleted, 1)
    }

    func testCompletedRoutineIsNotMisreportedAsPaused() throws {
        var row = Self.radarIA()
        row["enabled"] = false
        row["state"] = "completed"
        let job = try XCTUnwrap(HermesClient.jobRow(from: row))
        XCTAssertTrue(job.isCompleted)
        XCTAssertFalse(job.isPaused)
        XCTAssertEqual(job.effectiveState, "completed")
    }

    func testRoutineRunHistoryKeepsExecutionFacts() throws {
        let runs = try DashboardClient.routineRuns(from: ["runs": [[
            "id": "session-1",
            "title": "Radar IA daily",
            "preview": "Three important updates",
            "started_at": "2026-09-05T10:00:00+02:00",
            "ended_at": "2026-09-05T10:00:11+02:00",
            "end_reason": "completed",
            "model": "grok-4.6",
            "input_tokens": 120,
            "output_tokens": 80,
            "actual_cost_usd": 0.012,
            "is_active": false,
        ]]])
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.id, "session-1")
        XCTAssertEqual(run.preview, "Three important updates")
        XCTAssertEqual(run.tokens, 200)
        XCTAssertEqual(try XCTUnwrap(run.cost), 0.012, accuracy: 0.000001)
        XCTAssertEqual(run.endReason, "completed")
        XCTAssertFalse(run.isActive)
    }

    func testDeliveryTargetsExposeMissingHomeChannel() throws {
        let targets = try DashboardClient.deliveryTargets(from: ["targets": [
            ["id": "local", "name": "Local", "home_target_set": true],
            ["id": "telegram", "name": "Telegram", "home_target_set": false],
        ]])
        XCTAssertEqual(targets.map(\.id), ["local", "telegram"])
        XCTAssertTrue(targets[0].homeTargetSet)
        XCTAssertFalse(targets[1].homeTargetSet)
    }

    func testMalformedNonemptyRunAndTargetBodiesDoNotReadAsEmpty() {
        XCTAssertThrowsError(try DashboardClient.routineRuns(from: ["runs": [["no_id": true]]]))
        XCTAssertThrowsError(try DashboardClient.deliveryTargets(from: ["targets": [["name": "Telegram"]]]))
    }
}

/// A body reader that records which paths were asked for.
private final class RecordingRows: DashboardRowReading, @unchecked Sendable {
    enum Answer { case success([[String: Any]]), failure(Error) }

    private let answers: [String: Answer]
    private(set) var paths: [String] = []

    init(_ answers: [String: Answer]) { self.answers = answers }

    func rows(
        _ path: String, shape: DashboardClient.BodyShape
    ) async throws -> JSONRows {
        paths.append(path)
        switch answers[path] {
        case let .success(rows): return JSONRows(rows)
        case let .failure(error): throw error
        case nil: throw DashboardClient.Failure.http(404)
        }
    }
}

/// The bots listing has the same failure mode the routines listing had.
final class BotListingAdversarialTests: XCTestCase {
    /// `GET /api/profiles` always answers `{"profiles": [...]}`. A body
    /// without the key used to read as an agent with no bots.
    func testAProfilesBodyWithoutTheKeyIsUnreadableNotEmpty() {
        XCTAssertThrowsError(
            try DashboardClient.bots(from: ["unexpected": "shape"], active: nil)
        )
        XCTAssertThrowsError(
            try DashboardClient.bots(from: [:], active: nil)
        )
    }

    /// Rows arrived and none of them had a name: a shape problem, not an
    /// agent without bots.
    func testProfileRowsThatAllLackANameAreUnreadable() {
        XCTAssertThrowsError(
            try DashboardClient.bots(
                from: ["profiles": [["no_name": true]]], active: nil
            )
        )
    }

    func testARealProfilesBodyParses() throws {
        let bots = try DashboardClient.bots(
            from: ["profiles": [
                ["name": "radar-ia", "display_name": "Radar IA"],
                ["name": "chollometro"],
            ]],
            active: "radar-ia"
        )

        XCTAssertEqual(bots.map(\.name), ["radar-ia", "chollometro"])
        XCTAssertEqual(bots.first?.displayName, "Radar IA")
        XCTAssertTrue(bots.first?.active == true)
    }

    /// An agent that genuinely has none still reads as none.
    func testAnEmptyProfilesArrayIsAValidEmptyAnswer() throws {
        XCTAssertTrue(try DashboardClient.bots(from: ["profiles": []], active: nil).isEmpty)
    }
}
