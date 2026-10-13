import Foundation

/// Alice-owned fictional HTTPS contract, independent of Hermes pairing and
/// Hermes gateway credentials. The caller MUST obtain a separately authenticated
/// Alice-human credential. No account provider or live endpoint is provisioned.
/// It reads synthetic receipts and can forward a separate validated human
/// signature, but cannot commit or initiate payment. Never a real PSP client.
struct SecureRunnerStatusClient {
    enum Failure: Error, Equatable {
        case invalidEndpoint
        case invalidCredential
        case invalidResponse
        case identityMismatch
        case notAuthorized
    }

    struct Observation: Sendable {
        let status: SecureRunnerDisplayStatus
        let checkout: SecureRunnerApprovalContract.Checkout?
        /// Only a validated, exact fictional challenge may be forwarded to
        /// SecureRunnerDeviceSigner after separate explicit user review.
        let checkoutData: Data?
        let approvalChallengeData: Data?
        /// A separate fictional merchant ledger matched the durable ASR entry.
        /// Never present this as evidence of a real PSP payment.
        let fictionalOrderID: String?
        let isFictionalOnly: Bool
    }

    private struct Response: Decodable {
        let jobID: String
        let tenant: String
        let session: String
        let status: String
        let paymentEnvironment: String
        let canSubmitPayment: Bool
        let checkout: SecureRunnerApprovalContract.Checkout?
        let approvalChallenge: SecureRunnerApprovalContract.Challenge?
        let fictionalReceipt: FictionalReceipt?

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", tenant, session, status
            case paymentEnvironment = "payment_environment"
            case canSubmitPayment = "can_submit_payment"
            case checkout
            case approvalChallenge = "approval_challenge"
            case fictionalReceipt = "fictional_receipt"
        }
    }

    private struct FictionalReceipt: Decodable {
        let orderID: String
        let checkoutID: String
        let amountMinor: Int
        let currency: String

        enum CodingKeys: String, CodingKey {
            case orderID = "order_id"
            case checkoutID = "checkout_id"
            case amountMinor = "amount_minor"
            case currency
        }
    }

    /// Decode only Alice's tenant/session-bound synthetic result; an arbitrary
    /// Hermes "confirmed" event must never be accepted as a status feed.
    static func interpret(
        _ data: Data, jobID: String, tenant: String, session: String
    ) throws -> Observation {
        guard data.count <= 16_384,
              let root = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              Set(root.keys).isSubset(of: [
                  "job_id", "tenant", "session", "status", "payment_environment",
                  "can_submit_payment", "checkout", "approval_challenge",
                  "fictional_receipt"
              ]),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.paymentEnvironment == "fictional_only",
              !response.canSubmitPayment else {
            throw Failure.invalidResponse
        }
        guard response.jobID == jobID, response.tenant == tenant,
              response.session == session else { throw Failure.identityMismatch }

        let status: SecureRunnerDisplayStatus
        switch response.status {
        case "awaiting_approval", "approved": status = .pending
        case "unknown", "dispatching": status = .unknown
        case "human_only", "handoff_pending_close",
             "completed_by_human_simulated": status = .handoff
        case "confirmed":
            status = .confirmed
        case "researching", "selecting", "cart_ready", "stopped":
            status = .unverified
        default:
            throw Failure.invalidResponse
        }

        var originalCheckout: Data?
        if let checkout = response.checkout {
            // Validate the ORIGINAL nested object, not a re-encoded subset:
            // JSONDecoder otherwise silently drops attacker-supplied fields.
            guard let raw = root["checkout"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: raw),
                  let verified = try? SecureRunnerApprovalContract.parseCheckout(encoded),
                  verified == checkout else {
                throw Failure.invalidResponse
            }
            originalCheckout = encoded
        }
        var originalChallenge: Data?
        if response.approvalChallenge != nil {
            guard response.status == "awaiting_approval",
                  let checkoutData = originalCheckout,
                  let raw = root["approval_challenge"] as? [String: Any],
                  let challengeData = try? JSONSerialization.data(withJSONObject: raw),
                  let checked = try? SecureRunnerApprovalContract.checkedChallengeBytes(
                      checkoutData: checkoutData, challengeData: challengeData,
                      expectedJobID: jobID, expectedTenant: tenant,
                      expectedSession: session,
                      now: Int(Date().timeIntervalSince1970)),
                  !checked.isEmpty else { throw Failure.invalidResponse }
            originalChallenge = challengeData
        }
        if let raw = root["fictional_receipt"] {
            guard let receipt = raw as? [String: Any],
                  Set(receipt.keys) == ["order_id", "checkout_id", "amount_minor", "currency"]
            else { throw Failure.invalidResponse }
        }
        if status == .confirmed {
            guard let receipt = response.fictionalReceipt,
                  let checkout = response.checkout,
                  !receipt.orderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  receipt.orderID.utf8.count <= 120,
                  receipt.checkoutID == checkout.checkoutID,
                  receipt.amountMinor == checkout.amountMinor,
                  receipt.currency == checkout.currency else {
                // A missing or conflicting receipt must never show confirmed.
                throw Failure.invalidResponse
            }
        } else if response.fictionalReceipt != nil {
            throw Failure.invalidResponse
        }
        return Observation(
            status: status, checkout: response.checkout,
            checkoutData: originalCheckout, approvalChallengeData: originalChallenge,
            fictionalOrderID: response.fictionalReceipt?.orderID,
            isFictionalOnly: true
        )
    }

    private let session: URLSession
    private let trustedAliceOrigin: URL

    /// Only the trusted Alice application configuration can select this
    /// origin. No per-job Hermes URL, QR text or merchant URL is permitted.
    /// Until Alice provisions its independent account/IdP authority, there
    /// must be NO caller creating this client in an active purchase flow.
    init(trustedAliceOrigin: URL, testProtocolClasses: [AnyClass]? = nil) throws {
        guard trustedAliceOrigin.scheme?.lowercased() == "https",
              trustedAliceOrigin.host != nil,
              trustedAliceOrigin.user == nil, trustedAliceOrigin.password == nil,
              trustedAliceOrigin.query == nil, trustedAliceOrigin.fragment == nil,
              trustedAliceOrigin.path.isEmpty || trustedAliceOrigin.path == "/" else {
            throw Failure.invalidEndpoint
        }
        self.trustedAliceOrigin = trustedAliceOrigin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = testProtocolClasses ?? configuration.protocolClasses
        // Always enforce redirect denial, including an injected test protocol
        // configuration; supplying a custom URLSession could silently drop it.
        self.session = URLSession(
            configuration: configuration,
            delegate: SecureRunnerNoRedirects(), delegateQueue: nil
        )
    }

    /// Cannot create a charge, request an approval, or reconcile an UNKNOWN.
    /// Tokens and URLs must come from a trusted Alice IdP, never a Hermes QR.
    func status(
        baseURL: URL, humanBearer: String,
        jobID: String, tenant: String, session ownerSession: String
    ) async throws -> Observation {
        guard baseURL == trustedAliceOrigin,
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw Failure.invalidEndpoint
        }
        guard humanBearer.utf8.count >= 32, humanBearer.utf8.count <= 4096,
              humanBearer.utf8.allSatisfy({ (33...126).contains($0) }),
              !humanBearer.contains(":") else { throw Failure.invalidCredential }
        let url = baseURL.appendingPathComponent("v1/human-status")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + humanBearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["job_id": jobID])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw Failure.notAuthorized
        }
        guard http.statusCode == 200 else { throw Failure.invalidResponse }
        return try Self.interpret(data, jobID: jobID, tenant: tenant, session: ownerSession)
    }

    /// Human-authenticated transport of ALREADY validated signature bytes.
    /// It does NOT generate a signature, prompt Face ID or submit a purchase.
    /// The caller must display the exact checkout and receive an explicit
    /// human action before invoking the separately protected device signer.
    func submitFictionalHumanSignature(
        baseURL: URL, humanBearer: String, jobID: String,
        tenant: String, ownerSession: String, checkoutID: String,
        signature: String
    ) async throws {
        guard baseURL == trustedAliceOrigin,
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw Failure.invalidEndpoint
        }
        guard humanBearer.utf8.count >= 32, humanBearer.utf8.count <= 4096,
              humanBearer.utf8.allSatisfy({ (33...126).contains($0) }),
              !humanBearer.contains(":") else { throw Failure.invalidCredential }
        guard !jobID.isEmpty, jobID.utf8.count <= 160,
              jobID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }),
              (64...192).contains(signature.utf8.count),
              signature.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { throw Failure.invalidResponse }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/human-approve"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + humanBearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "job_id": jobID, "signature": signature
        ])
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw Failure.notAuthorized
        }
        guard http.statusCode == 200, body.count <= 2048,
              let object = try? JSONSerialization.jsonObject(with: body)
                  as? [String: Any],
              Set(object.keys) == ["status", "checkout_id", "job_id", "tenant", "session"],
              object["status"] as? String == "approved",
              object["checkout_id"] as? String == checkoutID,
              object["job_id"] as? String == jobID,
              object["tenant"] as? String == tenant,
              object["session"] as? String == ownerSession
        else { throw Failure.invalidResponse }
    }
}

private final class SecureRunnerNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
