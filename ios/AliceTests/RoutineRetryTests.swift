import XCTest
@testable import Alice

/// "Try again now" on an automation that had failed told someone "the dashboard
/// did not answer — it only listens on your own network" while Hermes was busy
/// running the automation they had just asked for. Hermes replies to run-now
/// only when the run ends; the phone stopped waiting after fifteen seconds.
final class RoutineRetryTests: XCTestCase {

    private func failed(runningSince: Date? = nil, manualRunAt: Date? = nil, lastRun: Date? = nil) -> JobRow {
        JobRow(
            id: "6abe3aebcb41", name: "Monitor Cuba — informe diario", prompt: "",
            schedule: "30 10 * * *", enabled: true, lastStatus: "error",
            lastError: "RuntimeError: Connection error.", lastRun: lastRun, nextRun: nil,
            profile: "537", runningSince: runningSince, manualRunAt: manualRunAt
        )
    }

    /// The claim Hermes wrote while the retried run was going.
    func testTheRunClaimIsRead() throws {
        let row = try XCTUnwrap(HermesClient.jobRow(from: [
            "id": "6abe3aebcb41",
            "fire_claim": ["at": "2026-09-10T15:22:35.249897+02:00",
                           "by": "hermes-host.local:5229:94627cf1554c4964a9709b519a5b054c"],
            "manual_run_at": "2026-09-10T15:20:35.100000+02:00",
        ]))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let claimed = utc.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 13, minute: 22, second: 35))!
        XCTAssertEqual(row.runningSince?.timeIntervalSince1970 ?? 0, claimed.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(row.manualRunAt)
        XCTAssertTrue(row.isRunning(now: claimed.addingTimeInterval(90)))
        // Hermes' own limit: a claim five minutes old belongs to a dead run.
        XCTAssertFalse(row.isRunning(now: claimed.addingTimeInterval(301)))
    }

    func testARunningRetryIsShownAndNotOfferedAgain() throws {
        let items = EventDigest.attention(
            routines: [failed(runningSince: Date().addingTimeInterval(-30))], components: []
        )
        let row = try XCTUnwrap(items.first)
        XCTAssertEqual(row.summary, "Running again now")
        XCTAssertEqual(row.advice?.fixes, [])
        XCTAssertEqual(row.severity, .needsAttention)
    }

    func testADeadClaimIsStillAFailureWithAFix() throws {
        let items = EventDigest.attention(
            routines: [failed(runningSince: Date().addingTimeInterval(-600))], components: []
        )
        let row = try XCTUnwrap(items.first)
        XCTAssertEqual(row.summary, "Couldn't reach the AI service")
        XCTAssertEqual(row.advice?.fixes, [.runAgain])
    }

    /// Any of Hermes' three marks of a started run counts; none of them is a
    /// failure to start, which is said as such.
    func testAStartIsConfirmedFromTheAutomationItself() {
        let asked = Date()
        XCTAssertTrue(AlertAdvice.runStarted(failed(runningSince: asked.addingTimeInterval(2)), askedAt: asked))
        XCTAssertTrue(AlertAdvice.runStarted(failed(manualRunAt: asked.addingTimeInterval(1)), askedAt: asked))
        XCTAssertTrue(AlertAdvice.runStarted(failed(lastRun: asked.addingTimeInterval(120)), askedAt: asked,
                                             now: asked.addingTimeInterval(130)))
        XCTAssertFalse(AlertAdvice.runStarted(failed(lastRun: asked.addingTimeInterval(-3600)), askedAt: asked))
        XCTAssertFalse(AlertAdvice.runStarted(nil, askedAt: asked))
    }

    /// A slow answer is not described as an unreachable dashboard.
    func testATimeoutIsNotCalledUnreachable() {
        let text = DashboardClient.Failure.timedOut.errorDescription ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("network"))
        XCTAssertNotEqual(text, DashboardClient.Failure.unreachable.errorDescription)
    }
}
