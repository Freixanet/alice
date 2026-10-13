import XCTest
@testable import Alice

final class SecureRunnerDisplayStatusTests: XCTestCase {
    func testAllStatusesAreReadOnlyAndNeverClaimFaceIDAsAuthorization() {
        XCTAssertEqual(Set(SecureRunnerDisplayStatus.allCases),
                       [.unverified, .researching, .cartReady, .pending, .approved,
                        .rejected, .unknown, .confirmed, .handoff])
        for status in SecureRunnerDisplayStatus.allCases {
            XCTAssertFalse(status.allowsCheckout)
            XCTAssertFalse(status.title(.spanish).isEmpty)
            XCTAssertFalse(status.explanation(.spanish).isEmpty)
        }
        XCTAssertTrue(SecureRunnerDisplayStatus.unknown.explanation(.spanish).contains("No reintentes"))
        XCTAssertTrue(SecureRunnerDisplayStatus.handoff.explanation(.spanish).contains("navegador cerrado"))
        XCTAssertTrue(SecureRunnerDisplayStatus.unverified.explanation(.spanish).contains("Face ID"))
    }
}
