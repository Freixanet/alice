import XCTest
@testable import Alice

/// Run recovery follows a run for as long as Hermes answers, and gives up only
/// on silence. Counted from the start, a three-minute tool call surfaced as
/// "Hermes didn't answer in time" while the run was still going.
final class RunRecoveryBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_000_000)

    func testSilenceForTheWholeWindowEndsRecovery() {
        let budget = HermesClient.RunRecoveryBudget(now: start)
        XCTAssertFalse(budget.isExhausted(at: start.addingTimeInterval(179)))
        XCTAssertTrue(budget.isExhausted(at: start.addingTimeInterval(180)))
    }

    func testARunThatKeepsAnsweringIsFollowedPastTheWindow() {
        var budget = HermesClient.RunRecoveryBudget(now: start)
        // Every probe for ten minutes said "running", as during a blocked tool.
        for second in stride(from: 1, through: 600, by: 1) {
            let now = start.addingTimeInterval(TimeInterval(second))
            XCTAssertFalse(budget.isExhausted(at: now), "gave up at \(second)s on a run still answering")
            budget.heard(at: now)
        }
    }

    func testTheWindowRestartsFromTheLastAnswer() {
        var budget = HermesClient.RunRecoveryBudget(now: start)
        budget.heard(at: start.addingTimeInterval(170))
        XCTAssertFalse(budget.isExhausted(at: start.addingTimeInterval(349)))
        XCTAssertTrue(budget.isExhausted(at: start.addingTimeInterval(350)))
    }
}
