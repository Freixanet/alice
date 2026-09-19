import XCTest
@testable import Alice

final class StreamWinnerTests: XCTestCase {
    func testFirstClaimWinsAndKeepsWinning() {
        var winner = HermesClient.StreamWinner.none
        XCTAssertTrue(winner.claim(by: .stream))
        XCTAssertTrue(winner.claim(by: .stream))   // later frames keep the win
        XCTAssertFalse(winner.claim(by: .hedge))   // a late hedge loses
        XCTAssertEqual(winner, .stream)
    }

    func testHedgeClaimsOnlyWhenStreamIsSilent() {
        var winner = HermesClient.StreamWinner.none
        XCTAssertTrue(winner.claim(by: .hedge))
        XCTAssertFalse(winner.claim(by: .stream))  // a late stream frame is dropped
        XCTAssertEqual(winner, .hedge)
    }
}
