import XCTest
@testable import Alice

/// /update follows the update to its end and says how it went in words. The
/// dashboard restarts in the middle and forgets the run, so only evidence tied
/// to this run may end the wait.
final class HermesUpdateWatchTests: XCTestCase {
    private let asked = Date(timeIntervalSince1970: 1_789_500_000)

    private func status(
        running: Bool = false, exitCode: Int? = nil, actionID: String? = nil,
        lines: [String] = [], outcome: String? = nil, startedAt: Date? = nil, version: String? = nil
    ) -> HermesUpdateStatus {
        var object: [String: Any] = ["running": running, "lines": lines]
        if let exitCode { object["exit_code"] = exitCode }
        if let actionID { object["action_id"] = actionID }
        if let outcome {
            var receipt: [String: Any] = ["outcome": outcome]
            if let startedAt {
                receipt["started_at"] = ISO8601DateFormatter().string(from: startedAt)
                    .replacingOccurrences(of: "Z", with: ".235273+00:00")
            }
            if let version { receipt["post_version"] = version }
            object["receipt"] = receipt
        }
        return HermesUpdateStatus(object)
    }

    func testHermesReceiptTimesAreRead() {
        XCTAssertEqual(status(outcome: "success", startedAt: asked).receipt?.startedAt, asked)
    }

    func testARunningUpdateAndTheRestartGapKeepWaiting() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        XCTAssertEqual(watch.observe(status(running: true), at: asked.addingTimeInterval(5)), .waiting)
        XCTAssertEqual(watch.observe(nil, at: asked.addingTimeInterval(10)), .waiting)
    }

    func testAnEarlierRunsReceiptDoesNotEndTheWait() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        let old = status(exitCode: 0, outcome: "success", startedAt: asked.addingTimeInterval(-3 * 3600))
        for second in stride(from: 5.0, through: 120, by: 5) {
            XCTAssertEqual(watch.observe(old, at: asked.addingTimeInterval(second)), .waiting)
        }
    }

    func testThisRunsCompletionMarkerIsSuccess() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        XCTAssertEqual(
            watch.observe(status(exitCode: 0, actionID: "abc"), at: asked.addingTimeInterval(300)),
            .finished("Done — Hermes is up to date.")
        )
    }

    func testThisRunsReceiptSaysHowItWent() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        XCTAssertEqual(
            watch.observe(
                status(exitCode: 1, outcome: "partial", startedAt: asked.addingTimeInterval(2), version: "v0.22.0"),
                at: asked.addingTimeInterval(400)
            ),
            .finished("Hermes updated (v0.22.0), but part of it didn’t restart cleanly. If a bot stops answering, restart Hermes on its computer.")
        )
    }

    func testAMergeConflictIsExplainedWithoutGitWords() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        let lines = [
            "=== hermes-update started 2026-09-14 09:00:00 ===",
            "✗ Network error — cannot reach the remote repository.",
            "=== hermes-update started 2026-09-14 12:12:41 ===",
            "→ Fetching updates...",
            "✗ Merge conflict between local commits and upstream — update stopped, nothing was changed.",
            "  Resolve manually: cd ~/.hermes/hermes-agent && git merge origin/main",
        ]
        guard case let .finished(sentence) = watch.observe(
            status(exitCode: 1, lines: lines, outcome: "failed", startedAt: asked), at: asked.addingTimeInterval(60)
        ) else { return XCTFail("expected the run to be over") }
        XCTAssertTrue(sentence.contains("changed by hand"), sentence)
        XCTAssertTrue(sentence.contains("Nothing was changed"), sentence)
        XCTAssertFalse(sentence.lowercased().contains("merge"), sentence)
    }

    func testCommonCausesAreToldApart() {
        func said(_ line: String) -> String {
            HermesUpdateOutcome.sentence(outcome: "failed", version: nil, exitCode: 1, lines: [line])
        }
        XCTAssertTrue(said("✗ Network error — cannot reach the remote repository.").contains("couldn’t reach GitHub"))
        XCTAssertTrue(said("OSError: [Errno 28] No space left on device").contains("out of disk space"))
        XCTAssertTrue(said("✗ Pulled code has a syntax error in a critical file:").contains("went back"))
        XCTAssertEqual(
            said("✗ Branch 'main' not found on origin."),
            "Hermes couldn’t finish updating. It keeps running the version it had. Hermes said: “Branch 'main' not found on origin.”"
        )
    }

    func testAnExitWithNoReceiptAtAllIsBelievedAfterAGrace() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: nil)
        let refused = status(exitCode: 2, lines: ["✗ Not a git repository — cannot check for updates."])
        XCTAssertEqual(watch.observe(refused, at: asked.addingTimeInterval(5)), .waiting)
        guard case let .finished(sentence) = watch.observe(refused, at: asked.addingTimeInterval(40)) else {
            return XCTFail("expected the run to be over")
        }
        XCTAssertTrue(sentence.contains("Not a git repository"), sentence)
    }

    func testAnUpdateThatOutlastsTheBudgetSaysItIsStillGoing() {
        var watch = HermesUpdateWatch(requestedAt: asked, actionID: "abc")
        XCTAssertEqual(
            watch.observe(status(running: true), at: asked.addingTimeInterval(HermesUpdateWatch.budget)),
            .finished(HermesUpdateOutcome.stillRunning)
        )
    }
}
