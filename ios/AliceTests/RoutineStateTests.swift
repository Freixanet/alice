import XCTest
@testable import Alice

/// What a bot's screen is allowed to conclude from a routine read.
///
/// "No routines yet" is a statement about the bot. Every one of these cases
/// used to produce it, including the ones that are statements about the
/// network, the session or the dashboard's absence.
final class RoutineStateTests: XCTestCase {
    private enum Parsing: Error, LocalizedError {
        case malformed
        var errorDescription: String? { "The dashboard sent something unreadable." }
    }

    private static let radarIA = JobRow(
        id: "c3cf075a5b68", name: "Radar IA — informe diario", prompt: "",
        schedule: "daily at 10am", enabled: true, lastStatus: nil,
        lastError: nil, lastRun: nil, nextRun: nil
    )

    // 1. A real, successful, empty answer.
    func testASuccessfulEmptyAnswerIsEmptyNotFailed() async {
        let state = await RoutineState.resolving { [] }

        XCTAssertEqual(state, .loaded([]))
        XCTAssertTrue(state.isEmptyAnswer)
        XCTAssertNil(state.failure)
    }

    // 2. The real routine comes through.
    func testTheRealRoutineLoads() async {
        let state = await RoutineState.resolving { [Self.radarIA] }

        XCTAssertEqual(state.rows.map(\.id), ["c3cf075a5b68"])
        XCTAssertFalse(state.isEmptyAnswer)
    }

    // 3, 4. Refused and not-found are failures, not emptiness.
    func testHttpFailuresDoNotReadAsNoRoutines() async {
        for status in [401, 403, 404, 500] {
            let state = await RoutineState.resolving {
                throw DashboardClient.Failure.http(status, detail: "refused")
            }

            XCTAssertFalse(
                state.isEmptyAnswer, "\(status) must not read as an empty agent"
            )
            XCTAssertNotNil(state.failure, "\(status) must surface as a failure")
            XCTAssertTrue(state.rows.isEmpty)
        }
    }

    // 5. Nothing answered at all.
    func testUnreachableDoesNotReadAsNoRoutines() async {
        let state = await RoutineState.resolving {
            throw URLError(.timedOut)
        }

        XCTAssertFalse(state.isEmptyAnswer)
        XCTAssertNotNil(state.failure)
    }

    // 6. The answer arrived and made no sense.
    func testAParsingFailureDoesNotReadAsNoRoutines() async {
        let state = await RoutineState.resolving { throw Parsing.malformed }

        XCTAssertFalse(state.isEmptyAnswer)
        XCTAssertEqual(state.failure, "The dashboard sent something unreadable.")
    }

    /// No dashboard configured is also not a bot without routines.
    func testAnUnconfiguredDashboardIsAFailureNotAnEmptyBot() async {
        let state = await RoutineState.resolving {
            throw DashboardClient.Failure.notConfigured
        }

        XCTAssertFalse(state.isEmptyAnswer)
        XCTAssertNotNil(state.failure)
    }

    /// Only `.loaded` ever yields rows, so no state can quietly pass an empty
    /// list off as the agent's answer.
    func testOnlyALoadedStateReportsAnEmptyAnswer() {
        XCTAssertFalse(RoutineState.loading.isEmptyAnswer)
        XCTAssertFalse(RoutineState.failed("boom").isEmptyAnswer)
        XCTAssertTrue(RoutineState.loaded([]).isEmptyAnswer)
    }
}
