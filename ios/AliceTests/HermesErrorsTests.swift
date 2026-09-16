import XCTest
@testable import Alice

/// A failure in a bot chat says what failed. "Hermes did not answer." is the
/// last resort, not the default.
final class HermesErrorsTests: XCTestCase {
    private struct Bare: Error {}

    func testHermesOwnReasonIsKept() {
        let refusal = HermesRPCClient.Failure(reason: "cannot delete an active session")
        XCTAssertEqual(HermesErrors.describe(refusal), "cannot delete an active session")
    }

    func testANetworkFailureIsSaidInWordsNeverAsACode() {
        // Minted bare, as a fake would: no Foundation text to lean on.
        XCTAssertEqual(
            HermesErrors.describe(URLError(.networkConnectionLost)),
            "The network connection to Hermes was lost."
        )
        XCTAssertEqual(HermesErrors.describe(URLError(.notConnectedToInternet)), "This phone is offline.")
        XCTAssertFalse(HermesErrors.describe(URLError(.badServerResponse)).contains("NSURLErrorDomain"))
        // With Foundation's own words, those are kept.
        let worded = NSError(
            domain: NSURLErrorDomain, code: URLError.Code.networkConnectionLost.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        XCTAssertEqual(HermesErrors.describe(worded), "The network connection was lost.")
    }

    func testACancelledCallIsNotBlamedOnHermes() {
        XCTAssertEqual(HermesErrors.describe(CancellationError()), "Stopped before Hermes answered.")
    }

    func testAnErrorWithNoWordsFallsBackHonestly() {
        XCTAssertEqual(HermesErrors.describe(Bare()), "Hermes did not answer.")
        XCTAssertEqual(HermesErrors.describe(Bare(), fallback: "The dashboard did not answer."),
                       "The dashboard did not answer.")
    }

    func testTheDeadlineIsLongEnoughForAPromptAckAndShortEnoughToNotice() {
        let seconds = HermesRPCClient.callDeadline.components.seconds
        XCTAssertGreaterThanOrEqual(seconds, 20, "a slow resume must not be cut off")
        XCTAssertLessThanOrEqual(seconds, 60, "a dead socket must be noticed within a minute")
    }
}
