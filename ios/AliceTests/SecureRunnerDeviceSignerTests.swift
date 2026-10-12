import XCTest
@testable import Alice

final class SecureRunnerDeviceSignerTests: XCTestCase {
    /// No simulator Secure Enclave, Keychain writes or real-device credentials
    /// are required. This rejects a malformed installation before any key API.
    @MainActor
    func testInvalidPairingScopeFailsWithoutCreatingAKey() {
        XCTAssertThrowsError(try SecureRunnerDeviceSigner.publicKeyForEnrollment(
            tenant: "fixture-tenant", session: "fixture-session",
            account: "fixture-account",
            installation: "../untrusted-path"))
        XCTAssertThrowsError(try SecureRunnerDeviceSigner.publicKeyForEnrollment(
            tenant: "", session: "fixture-session",
            account: "fixture-account", installation: "fixture-install"))
    }
}
