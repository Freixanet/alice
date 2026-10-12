import Foundation
import XCTest
@testable import Alice

final class SecureRunnerApprovalContractTests: XCTestCase {
    private func checkoutData(recipient: String = "Fictional recipient",
                              tax: Int = 0, amount: Int = 4_998) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "merchant": "Alice Fictional HTTPS Merchant",
            "sku": "FAKE-ALICE-1", "variant": "standard", "quantity": 2,
            "recipient": recipient, "merchant_id": "alice-fictional-merchant-v1",
            "subtotal_minor": 4_998, "tax_minor": tax,
            "shipping_minor": 0, "discount_minor": 0,
            "amount_minor": amount, "currency": "EUR",
            "checkout_id": "fictional-checkout-1"
        ])
    }

    private func challengeData(digest: String, expires: Int = 1_180,
                               session: String = "fixture-session") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "job_id": "fixture-job", "tenant": "fixture-tenant",
            "session": session, "snapshot_digest": digest,
            "nonce": "fixture-nonce", "expires_at": expires
        ])
    }

    private func expectedCheckoutDigest() -> String {
        // Independently generated with Python json.dumps(sort_keys=True,
        // separators=(',', ':'), ensure_ascii=False), then hashlib.sha256.
        "cd58c3d6c9896c1f562fd5bac0276bb846653038e2410a3e8788888d4e388b23"
    }

    private func checked(_ checkout: Data, _ challenge: Data, now: Int = 1_000) throws -> Data {
        try SecureRunnerApprovalContract.checkedChallengeBytes(
            checkoutData: checkout, challengeData: challenge,
            expectedJobID: "fixture-job", expectedTenant: "fixture-tenant",
            expectedSession: "fixture-session", now: now)
    }

    func testExactPythonCheckoutAndChallengeByteContract() throws {
        let checkedBytes = try checked(
            checkoutData(), challengeData(digest: expectedCheckoutDigest()))
        let verified = try SecureRunnerApprovalContract.parseChallenge(checkedBytes)
        XCTAssertEqual(verified.snapshotDigest, expectedCheckoutDigest())
        XCTAssertEqual(verified.jobID, "fixture-job")
        XCTAssertFalse(String(decoding: checkedBytes, as: UTF8.self).contains("recipient"))
        XCTAssertEqual(String(decoding: checkedBytes, as: UTF8.self),
            "{\"expires_at\":1180,\"job_id\":\"fixture-job\",\"nonce\":\"fixture-nonce\",\"session\":\"fixture-session\",\"snapshot_digest\":\"\(expectedCheckoutDigest())\",\"tenant\":\"fixture-tenant\"}")
    }

    func testTamperedAmountRecipientAndSessionAreDenied() throws {
        let valid = try challengeData(digest: expectedCheckoutDigest())
        XCTAssertThrowsError(try checked(
            checkoutData(recipient: "Another recipient"), valid))
        XCTAssertThrowsError(try checked(
            checkoutData(tax: 1, amount: 4_999), valid))
        XCTAssertThrowsError(try checked(
            checkoutData(), challengeData(digest: expectedCheckoutDigest(), session: "other")))
    }

    func testExpiryExtraPropertiesAndMalformedDigestAreDenied() throws {
        XCTAssertThrowsError(try checked(
            checkoutData(), challengeData(digest: expectedCheckoutDigest(), expires: 999)))
        XCTAssertThrowsError(try checked(
            checkoutData(), challengeData(digest: String(repeating: "x", count: 64))))
        let malformed = try JSONSerialization.data(withJSONObject: [
            "job_id": "fixture-job", "tenant": "fixture-tenant",
            "session": "fixture-session", "snapshot_digest": expectedCheckoutDigest(),
            "nonce": "fixture-nonce", "expires_at": 1_180, "checkout_commit": true
        ])
        XCTAssertThrowsError(try checked(checkoutData(), malformed))
    }
}
