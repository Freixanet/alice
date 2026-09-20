import XCTest
@testable import Alice

final class NoteSaveStateTests: XCTestCase {
    func testAFailedBackgroundSaveRetriesWithGrowingPauses() {
        XCTAssertEqual(NoteSaveState.delay(afterFailures: 1), 2)
        XCTAssertEqual(NoteSaveState.delay(afterFailures: 2), 5)
        XCTAssertEqual(NoteSaveState.delay(afterFailures: 3), 15)
        XCTAssertNil(NoteSaveState.delay(afterFailures: 4))
        XCTAssertNil(NoteSaveState.delay(afterFailures: 0))
    }

    func testRetriesRunOutIntoAQuietFailure() {
        XCTAssertEqual(
            NoteSaveState.afterFailure(previousFailures: 0, reason: "slow"),
            .retrying(attempt: 1, reason: "slow")
        )
        XCTAssertEqual(
            NoteSaveState.afterFailure(previousFailures: 2, reason: "slow"),
            .retrying(attempt: 3, reason: "slow")
        )
        XCTAssertEqual(
            NoteSaveState.afterFailure(previousFailures: 3, reason: "slow"),
            .failed(reason: "slow")
        )
    }

    func testOnlyAnExhaustedSaveBlocksLeavingQuietly() {
        XCTAssertFalse(NoteSaveState.saved.blocksLeavingQuietly)
        XCTAssertFalse(NoteSaveState.saving.blocksLeavingQuietly)
        XCTAssertFalse(NoteSaveState.retrying(attempt: 1, reason: "x").blocksLeavingQuietly)
        XCTAssertTrue(NoteSaveState.failed(reason: "x").blocksLeavingQuietly)
    }

    func testTheCaptionIsSilentWhenSaved() {
        XCTAssertNil(NoteSaveState.saved.caption)
        XCTAssertNotNil(NoteSaveState.saving.caption)
        XCTAssertNotNil(NoteSaveState.retrying(attempt: 1, reason: "x").caption)
        XCTAssertNotNil(NoteSaveState.failed(reason: "x").caption)
    }
}
