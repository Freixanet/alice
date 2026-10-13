import CryptoKit
import Foundation
import XCTest
@testable import Alice

final class SecureRunnerEnrollmentContractTests: XCTestCase {
    private let publicPEM = "-----BEGIN PUBLIC KEY-----\nFICTIONAL_KEY_ONLY\n-----END PUBLIC KEY-----\n"

    private func challenge(
        account: String = "alice-account",
        installation: String = "fixture-install",
        operation: String = "enroll",
        version: Int = 0,
        expires: Int = 1_180,
        keyExpires: Int = 4_600,
        keyDigest: String? = nil
    ) throws -> Data {
        let digest = SHA256.hash(data: Data(publicPEM.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: [
            "purpose": "alice-r02-device-enroll-v1",
            "tenant": "fixture-tenant", "session": "fixture-session",
            "account": account, "installation": installation,
            "public_key_sha256": keyDigest ?? digest,
            "operation": operation, "expected_version": version,
            "key_expires_at": keyExpires,
            "nonce": "fixture-nonce", "expires_at": expires
        ])
    }

    private func proof(
        _ data: Data, pem: String? = nil, generation: Int = 1
    ) throws -> Data {
        try SecureRunnerEnrollmentContract.checkedProofBytes(
            challengeData: data, publicKeyPEM: pem ?? publicPEM,
            tenant: "fixture-tenant", session: "fixture-session",
            account: "alice-account", installation: "fixture-install",
            generation: generation, now: 1_000)
    }

    func testOnlyExactKeyAndAccountCanProduceProofBytes() throws {
        let expected = try proof(challenge())
        XCTAssertTrue(String(decoding: expected, as: UTF8.self)
            .contains("\"purpose\":\"alice-r02-device-enroll-v1\""))
        XCTAssertThrowsError(try proof(challenge(account: "attacker")))
        XCTAssertThrowsError(try proof(challenge(installation: "other-install")))
        XCTAssertThrowsError(try proof(challenge(), pem: "different public PEM"))
        XCTAssertThrowsError(try proof(challenge(expires: 999)))
        XCTAssertThrowsError(try proof(challenge(keyExpires: 999)))
        XCTAssertThrowsError(try proof(challenge(keyExpires: 40_000_000)))
    }

    func testRotationRequiresNewGenerationAndExactVersion() throws {
        let rotated = try challenge(operation: "rotate", version: 1)
        XCTAssertThrowsError(try proof(rotated, generation: 1))
        XCTAssertFalse(try proof(rotated, generation: 2).isEmpty)
        XCTAssertThrowsError(try proof(challenge(operation: "enroll", version: 2)))
        XCTAssertThrowsError(try proof(challenge(operation: "rotate", version: 0)))
    }
}
