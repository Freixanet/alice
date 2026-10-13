import Foundation

/// Alice-owned read-only HTTPS contract, independent of Hermes pairing and
/// Hermes gateway credentials. The caller MUST obtain a separately authenticated
/// Alice-human credential. No account provider or live endpoint is provisioned.
/// This fixture protocol can report fictional receipts only, never real payments.
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
        let fictionalReceipt: FictionalReceipt?

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", tenant, session, status
            case paymentEnvironment = "payment_environment"
            case canSubmitPayment = "can_submit_payment"
            case checkout
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
                  "can_submit_payment", "checkout", "fictional_receipt"
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

        if let checkout = response.checkout {
            // Validate the ORIGINAL nested object, not a re-encoded subset:
            // JSONDecoder otherwise silently drops attacker-supplied fields.
            guard let raw = root["checkout"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: raw),
                  let verified = try? SecureRunnerApprovalContract.parseCheckout(encoded),
                  verified == checkout else {
                throw Failure.invalidResponse
            }
        }
        if let raw = root["fictional_receipt"] {
            guard let receipt = raw as? [String: Any],
                  Set(receipt.keys) == ["order_id", "checkout_id", "amount_minor", "currency"]
            else { throw Failure.invalidResponse }
        }
        if status == .confirmed {
            guard let receipt = response.fictionalReceipt,
                  let checkout = response.checkout,
                  !receipt.orderID.isEmpty, receipt.orderID.utf8.count <= 120,
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
            fictionalOrderID: response.fictionalReceipt?.orderID,
            isFictionalOnly: true
        )
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: SecureRunnerNoRedirects(),
                delegateQueue: nil
            )
        }
    }

    /// Cannot create a charge, request an approval, or reconcile an UNKNOWN.
    /// Tokens and URLs must come from a trusted Alice IdP, never a Hermes QR.
    func status(
        baseURL: URL, humanBearer: String,
        jobID: String, tenant: String, session ownerSession: String
    ) async throws -> Observation {
        guard baseURL.scheme?.lowercased() == "https",
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
