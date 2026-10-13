import Foundation
import XCTest
@testable import Alice

final class SecureRunnerStatusClientTests: XCTestCase {
    private func status(
        _ state: String, receipt: [String: Any]? = nil,
        tenant: String = "tenant-fixture", session: String = "session-fixture"
    ) throws -> Data {
        var object: [String: Any] = [
            "job_id": "fake-job", "tenant": tenant, "session": session,
            "status": state, "payment_environment": "fictional_only",
            "can_submit_payment": false
        ]
        if let receipt { object["fictional_receipt"] = receipt }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func read(_ data: Data) throws -> SecureRunnerStatusClient.Observation {
        try SecureRunnerStatusClient.interpret(
            data, jobID: "fake-job", tenant: "tenant-fixture",
            session: "session-fixture")
    }

    func testReadOnlyStatusesNeverAuthorizeCheckout() throws {
        for (source, expected) in [
            ("awaiting_approval", SecureRunnerDisplayStatus.pending),
            ("approved", .pending),
            ("dispatching", .unknown),
            ("unknown", .unknown),
            ("human_only", .handoff),
            ("researching", .unverified)
        ] {
            let result = try read(status(source))
            XCTAssertEqual(result.status, expected)
            XCTAssertTrue(result.isFictionalOnly)
            XCTAssertFalse(result.status.allowsCheckout)
            XCTAssertNil(result.fictionalOrderID)
        }
    }

    func testRejectsFakeConfirmationAndCrossTenant() throws {
        XCTAssertThrowsError(try read(status("confirmed")))
        XCTAssertThrowsError(try read(status("confirmed", receipt: [
            "order_id": "invented", "checkout_id": "invented",
            "amount_minor": 2499, "currency": "EUR"
        ])))
        XCTAssertThrowsError(try read(status("unknown", receipt: [
            "order_id": "fake", "checkout_id": "fake",
            "amount_minor": 2499, "currency": "EUR"
        ])))
        XCTAssertThrowsError(try read(status("unknown", tenant: "other-tenant")))
        XCTAssertThrowsError(try read(status("unknown", session: "other-session")))
        XCTAssertThrowsError(try read(status("confirmed_simulated")))
    }

    func testOnlyExactFictionalCheckoutAndReceiptCanConfirm() throws {
        let checkout: [String: Any] = [
            "merchant": "Alice Fictional HTTPS Merchant",
            "sku": "FAKE-ALICE-1", "variant": "standard", "quantity": 1,
            "recipient": "Fictional recipient",
            "merchant_id": "alice-fictional-merchant-v1", "subtotal_minor": 2000,
            "tax_minor": 499, "shipping_minor": 0, "discount_minor": 0,
            "amount_minor": 2499, "currency": "EUR", "checkout_id": "test-id-001"
        ]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: status("confirmed"))
                                    as? [String: Any])
        object["checkout"] = checkout
        object["fictional_receipt"] = [
            "order_id": "fake-order-001", "checkout_id": "test-id-001",
            "amount_minor": 2499, "currency": "EUR"
        ]
        func encoded() throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
        let verified = try read(encoded())
        XCTAssertEqual(verified.status, .confirmed)
        XCTAssertEqual(verified.fictionalOrderID, "fake-order-001")
        XCTAssertFalse(verified.status.allowsCheckout)

        object["fictional_receipt"] = [
            "order_id": "fake-order-001", "checkout_id": "test-id-001",
            "amount_minor": 9999, "currency": "EUR"
        ]
        XCTAssertThrowsError(try read(encoded()))
        object["checkout"] = checkout.merging(["irrelevant": "injection"]) { _, new in new }
        XCTAssertThrowsError(try read(encoded()))
    }
}
