import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import Alice

private final class FictionalRequestCapture: @unchecked Sendable {
    static let shared = FictionalRequestCapture()
    private let lock = NSLock()
    private var latest: URLRequest?

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        latest = request
    }

    func take() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        let request = latest
        latest = nil
        return request
    }
}

/// Pure in-process URLProtocol fixture: never resolves DNS or submits payment.
private final class FictionalURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "alice-fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        FictionalRequestCapture.shared.record(request)
        let responseStatus = (request.url?.path == "/v1/human-cancel"
            && request.value(forHTTPHeaderField: "Authorization")
                == "Bearer " + String(repeating: "u", count: 48)) ? 409 : 200
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: responseStatus,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else { client?.urlProtocol(self, didFailWithError:
            URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        if url.path == "/v1/human-status" {
            body = "{\"job_id\":\"fictional-job-01\",\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"status\":\"unknown\",\"payment_environment\":\"fictional_only\",\"can_submit_payment\":false}"
        } else if url.path == "/v1/human-enrollment-begin" {
            let expiry = Int(Date().timeIntervalSince1970) + 120
            body = "{\"purpose\":\"alice-r02-device-enroll-v1\",\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"account\":\"fixture-account\",\"installation\":\"fixture-installation\",\"public_key_sha256\":\"\(String(repeating: "a", count: 64))\",\"operation\":\"enroll\",\"expected_version\":0,\"key_expires_at\":\(expiry + 86_400),\"nonce\":\"fixture-nonce\",\"expires_at\":\(expiry)}"
        } else if url.path == "/v1/human-enrollment-complete" {
            body = "{\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"account\":\"fixture-account\",\"installation\":\"fixture-installation\",\"version\":1,\"status\":\"enrolled_fixture_only\"}"
        } else if url.path == "/v1/human-cancel" {
            body = "{\"status\":\"stopped\",\"job_id\":\"fictional-job-01\",\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"browser_cleanup_verified\":true}"
        } else {
            body = "{\"status\":\"approved\",\"job_id\":\"fictional-job-01\",\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"checkout_id\":\"fixture-checkout\"}"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SecureRunnerStatusClientTests: XCTestCase {
    @MainActor
    func testR02UIHasNoAuthenticatedAccountSessionByDefault() {
        XCTAssertNil(EnvironmentValues().secureRunnerAuthenticatedChannel)
    }

    @MainActor
    func testInAppStatusRequiresExactAuthenticatedScopeBeforeNetwork() async throws {
        let origin = try XCTUnwrap(URL(string: "https://alice-fixture.invalid"))
        let channel = try SecureRunnerAuthenticatedChannel(
            trustedAliceOrigin: origin, humanBearer: String(repeating: "t", count: 48),
            jobID: "fictional-job-01", tenant: "fixture-t", ownerSession: "fixture-s",
            account: "alice-fixture", installation: "install-fixture",
            enrolledKeyVersion: nil, testProtocolClasses: [FictionalURLProtocol.self])
        _ = FictionalRequestCapture.shared.take()

        do {
            _ = try await channel.status(
                errandID: "attacker-job", markedR02: true, hermesOriginSession: "fixture-s")
            XCTFail("A different Hermes job was allowed to fetch authenticated status")
        } catch SecureRunnerStatusClient.Failure.identityMismatch {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        do {
            _ = try await channel.status(
                errandID: "fictional-job-01", markedR02: false, hermesOriginSession: "fixture-s")
            XCTFail("Legacy checkout was allowed to fetch an R02 status")
        } catch SecureRunnerStatusClient.Failure.identityMismatch {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        do {
            _ = try await channel.status(
                errandID: "fictional-job-01", markedR02: true, hermesOriginSession: "other-session")
            XCTFail("A different Hermes session was allowed to reuse account context")
        } catch SecureRunnerStatusClient.Failure.identityMismatch {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        do {
            _ = try await channel.status(
                errandID: "fictional-job-01", markedR02: true, hermesOriginSession: "")
            XCTFail("A missing Hermes session was treated as authenticated scope")
        } catch SecureRunnerStatusClient.Failure.identityMismatch {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        let result = try await channel.status(
            errandID: "fictional-job-01", markedR02: true, hermesOriginSession: "fixture-s")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.isFictionalOnly)
        XCTAssertFalse(result.status.allowsCheckout)
        let request = try XCTUnwrap(FictionalRequestCapture.shared.take())
        XCTAssertEqual(request.url?.absoluteString, "https://alice-fixture.invalid/v1/human-status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer " + String(repeating: "t", count: 48))
        XCTAssertEqual(request.httpMethod, "POST")
    }

    @MainActor
    func testR02ConsentCannotSignWithoutVerifiedEnrollmentAndChallenge() async throws {
        let origin = try XCTUnwrap(URL(string: "https://alice-fixture.invalid"))
        let channel = try SecureRunnerAuthenticatedChannel(
            trustedAliceOrigin: origin, humanBearer: String(repeating: "t", count: 48),
            jobID: "fictional-job-01", tenant: "fixture-t", ownerSession: "fixture-s",
            account: "alice-fixture", installation: "install-fixture",
            enrolledKeyVersion: nil, testProtocolClasses: [FictionalURLProtocol.self])
        let unverified = try SecureRunnerStatusClient.interpret(
            Data("{\"job_id\":\"fictional-job-01\",\"tenant\":\"fixture-t\",\"session\":\"fixture-s\",\"status\":\"awaiting_approval\",\"payment_environment\":\"fictional_only\",\"can_submit_payment\":false}".utf8),
            jobID: "fictional-job-01", tenant: "fixture-t", session: "fixture-s")
        _ = FictionalRequestCapture.shared.take()
        do {
            try await channel.approveReviewedFictionalCheckout(unverified)
            XCTFail("Consent proceeded without verified enrollment and reviewed challenge")
        } catch SecureRunnerStatusClient.Failure.notAuthorized {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
    }

    func testFictionalEnrollmentTransportRejectsUntrustedOriginAndWrongAck() async throws {
        let origin = try XCTUnwrap(URL(string: "https://alice-fixture.invalid"))
        let other = try XCTUnwrap(URL(string: "https://attacker-fixture.invalid"))
        let client = try SecureRunnerStatusClient(
            trustedAliceOrigin: origin, testProtocolClasses: [FictionalURLProtocol.self])
        let bearer = String(repeating: "t", count: 48)
        let syntheticPEM = "-----BEGIN PUBLIC KEY-----\n"
            + String(repeating: "A", count: 160) + "\n-----END PUBLIC KEY-----\n"
        _ = FictionalRequestCapture.shared.take()
        do {
            _ = try await client.beginFictionalDeviceEnrollment(
                baseURL: other, humanBearer: bearer, publicPEM: syntheticPEM,
                keyExpiresAt: Int(Date().timeIntervalSince1970) + 86_400)
            XCTFail("Enrollment sent an Alice credential to an untrusted HTTPS origin")
        } catch SecureRunnerStatusClient.Failure.invalidEndpoint {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        let challenge = try await client.beginFictionalDeviceEnrollment(
            baseURL: origin, humanBearer: bearer, publicPEM: syntheticPEM,
            keyExpiresAt: Int(Date().timeIntervalSince1970) + 86_400)
        XCTAssertNotNil(FictionalRequestCapture.shared.take())
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: challenge) as? [String: Any])
        do {
            try await client.completeFictionalDeviceEnrollment(
                baseURL: origin, humanBearer: bearer, challengeData: challenge,
                signature: String(repeating: "A", count: 88),
                tenant: "fixture-t", ownerSession: "fixture-s",
                account: "fixture-account", installation: "fixture-installation",
                expectedVersion: 2)
            XCTFail("Wrong version in fake enrollment acknowledgement was accepted")
        } catch SecureRunnerStatusClient.Failure.invalidResponse {
            XCTAssertNotNil(FictionalRequestCapture.shared.take())
        }
        try await client.completeFictionalDeviceEnrollment(
            baseURL: origin, humanBearer: bearer, challengeData: challenge,
            signature: String(repeating: "A", count: 88),
            tenant: "fixture-t", ownerSession: "fixture-s",
            account: "fixture-account", installation: "fixture-installation",
            expectedVersion: 1)
        XCTAssertNotNil(FictionalRequestCapture.shared.take())
        // This tests only fixture transport matching, never possession proof
        // or enrollment by a genuine independent Alice identity provider.
    }

    func testHumanCancellationIsBoundToTrustedOriginAndExactServerAck() async throws {
        let origin = try XCTUnwrap(URL(string: "https://alice-fixture.invalid"))
        let attacker = try XCTUnwrap(URL(string: "https://attacker-fixture.invalid"))
        let client = try SecureRunnerStatusClient(
            trustedAliceOrigin: origin, testProtocolClasses: [FictionalURLProtocol.self])
        let bearer = String(repeating: "t", count: 48)
        _ = FictionalRequestCapture.shared.take()
        do {
            _ = try await client.cancelFictionalJob(
                baseURL: attacker, humanBearer: bearer, jobID: "fictional-job-01",
                tenant: "fixture-t", ownerSession: "fixture-s")
            XCTFail("Sent human cancellation credential to attacker origin")
        } catch SecureRunnerStatusClient.Failure.invalidEndpoint {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        do {
            _ = try await client.cancelFictionalJob(
                baseURL: origin, humanBearer: bearer, jobID: "fictional-job-01",
                tenant: "fixture-t", ownerSession: "other-session")
            XCTFail("Accepted human cancellation acknowledgment for wrong session")
        } catch SecureRunnerStatusClient.Failure.invalidResponse {
            XCTAssertNotNil(FictionalRequestCapture.shared.take())
        }
        let browserClosed = try await client.cancelFictionalJob(
            baseURL: origin, humanBearer: bearer, jobID: "fictional-job-01",
            tenant: "fixture-t", ownerSession: "fixture-s")
        XCTAssertTrue(browserClosed)
        let request = try XCTUnwrap(FictionalRequestCapture.shared.take())
        XCTAssertEqual(request.url?.absoluteString, "https://alice-fixture.invalid/v1/human-cancel")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + bearer)
        let raw: Data
        if let direct = request.httpBody {
            raw = direct
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                guard count > 0 else { break }
                received.append(contentsOf: chunk[..<count])
            }
            raw = received
        } else {
            XCTFail("Fixture cancellation request had no HTTP body or body stream")
            return
        }
        let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: String])
        XCTAssertEqual(requestJSON, ["job_id": "fictional-job-01"])
        // Synthetic 409 is an uncertain dispatch outcome. Never report an
        // HTTP response loss/409 as a successful cancellation or resubmit.
        do {
            _ = try await client.cancelFictionalJob(
                baseURL: origin, humanBearer: String(repeating: "u", count: 48),
                jobID: "fictional-job-01", tenant: "fixture-t",
                ownerSession: "fixture-s")
            XCTFail("Unknown fictional merchant outcome was called cancelled")
        } catch SecureRunnerStatusClient.Failure.outcomeUnknown {
            XCTAssertNotNil(FictionalRequestCapture.shared.take())
        }
    }

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
            ("approved", .approved),
            ("dispatching", .unknown),
            ("unknown", .unknown),
            ("human_only", .handoff),
            ("researching", .researching),
            ("selecting", .researching),
            ("cart_ready", .cartReady),
            ("stopped", .rejected)
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

    func testHumanChallengeIsBoundToExactFictionalCheckoutAndSession() throws {
        let checkout: [String: Any] = [
            "merchant": "Alice Fictional HTTPS Merchant", "sku": "FAKE-ALICE-1",
            "variant": "standard", "quantity": 1, "recipient": "Fictional recipient",
            "merchant_id": "alice-fictional-merchant-v1", "subtotal_minor": 2000,
            "tax_minor": 499, "shipping_minor": 0, "discount_minor": 0,
            "amount_minor": 2499, "currency": "EUR", "checkout_id": "test-id-001"
        ]
        let checkoutData = try JSONSerialization.data(withJSONObject: checkout)
        let typed = try SecureRunnerApprovalContract.parseCheckout(checkoutData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let exactDigest = SHA256.hash(data: try encoder.encode(typed))
            .map { String(format: "%02x", $0) }.joined()
        let now = Int(Date().timeIntervalSince1970)
        let challenge: [String: Any] = [
            "job_id": "fake-job", "tenant": "tenant-fixture", "session": "session-fixture",
            "snapshot_digest": exactDigest, "nonce": "fixture-nonce",
            "expires_at": now + 180
        ]
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with:
            status("awaiting_approval")) as? [String: Any])
        payload["checkout"] = checkout
        payload["approval_challenge"] = challenge
        func encoded() throws -> Data {
            try JSONSerialization.data(withJSONObject: payload)
        }
        let accepted = try read(encoded())
        XCTAssertEqual(accepted.status, .pending)
        XCTAssertEqual(accepted.checkout, typed)
        XCTAssertNotNil(accepted.checkoutData)
        XCTAssertNotNil(accepted.approvalChallengeData)
        XCTAssertFalse(accepted.status.allowsCheckout)

        payload["approval_challenge"] = challenge.merging([
            "session": "other-session"
        ]) { _, replacement in replacement }
        XCTAssertThrowsError(try read(encoded()))
        payload["approval_challenge"] = challenge.merging([
            "snapshot_digest": String(repeating: "0", count: 64)
        ]) { _, replacement in replacement }
        XCTAssertThrowsError(try read(encoded()))
        payload["approval_challenge"] = challenge.merging([
            "expires_at": now - 1
        ]) { _, replacement in replacement }
        XCTAssertThrowsError(try read(encoded()))
        payload["approval_challenge"] = challenge
        payload["checkout"] = checkout.merging(["amount_minor": 4999]) { _, new in new }
        XCTAssertThrowsError(try read(encoded()))
        payload["checkout"] = checkout
        payload["status"] = "approved"
        XCTAssertThrowsError(try read(encoded()))
    }

    func testHumanSignatureTransportIsScopedAndNeverPostsPayment() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://alice-fixture.invalid"))
        let client = try SecureRunnerStatusClient(
            trustedAliceOrigin: endpoint, testProtocolClasses: [FictionalURLProtocol.self])
        let humanBearer = String(repeating: "t", count: 48)
        let signature = String(repeating: "a", count: 88)
        _ = FictionalRequestCapture.shared.take()

        try await client.submitFictionalHumanSignature(
            baseURL: endpoint, humanBearer: humanBearer,
            jobID: "fictional-job-01", tenant: "fixture-t",
            ownerSession: "fixture-s", checkoutID: "fixture-checkout",
            signature: signature)
        let request = try XCTUnwrap(FictionalRequestCapture.shared.take())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://alice-fixture.invalid/v1/human-approve")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer " + humanBearer)
        let raw: Data
        if let direct = request.httpBody {
            raw = direct
        } else if let stream = request.httpBodyStream {
            // URLSession transforms HTTPBody into a stream when invoking an
            // in-process URLProtocol; this is not another network request.
            stream.open()
            defer { stream.close() }
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                guard count > 0 else { break }
                received.append(contentsOf: chunk[..<count])
            }
            raw = received
        } else {
            XCTFail("Fixture request had no HTTP body or body stream")
            return
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: String])
        XCTAssertEqual(body, ["job_id": "fictional-job-01", "signature": signature])
        XCTAssertNil(raw.range(of: Data("checkout".utf8)))
        XCTAssertNil(raw.range(of: Data("payment".utf8)))

        let insecure = try XCTUnwrap(URL(string: "http://alice-fixture.invalid"))
        do {
            try await client.submitFictionalHumanSignature(
                baseURL: insecure, humanBearer: humanBearer,
                jobID: "fictional-job-01", tenant: "fixture-t",
                ownerSession: "fixture-s", checkoutID: "fixture-checkout",
                signature: signature)
            XCTFail("Insecure origin was accepted")
        } catch SecureRunnerStatusClient.Failure.invalidEndpoint {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
        // Even a TLS URL is an exfiltration destination if Hermes could
        // substitute it at call-time: the trusted origin is pinned at init.
        let attacker = try XCTUnwrap(URL(string: "https://fake-agent.invalid"))
        do {
            try await client.submitFictionalHumanSignature(
                baseURL: attacker, humanBearer: humanBearer,
                jobID: "fictional-job-01", tenant: "fixture-t",
                ownerSession: "fixture-s", checkoutID: "fixture-checkout",
                signature: signature)
            XCTFail("Untrusted HTTPS origin was accepted")
        } catch SecureRunnerStatusClient.Failure.invalidEndpoint {
            XCTAssertNil(FictionalRequestCapture.shared.take())
        }
    }
}
