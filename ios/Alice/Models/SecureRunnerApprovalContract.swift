import CryptoKit
import Foundation

/// Read-only contract for *future* Alice-authenticated checkout consent.
///
/// Never accept an untrusted Hermes errand, agent answer, QR payload or model
/// output as an authenticated Alice challenge. This verifies byte-level
/// checkout binding, not user presence, Secure Enclave or payment authority.
enum SecureRunnerApprovalContract {
    enum Rejection: Error, Equatable {
        case invalidJSON
        case invalidCheckout
        case invalidChallenge
        case expired
        case identityMismatch
        case checkoutMismatch
    }

    /// The precise fictional checkout snapshot serialized by Python core._canonical.
    /// Payment cards and private keys are intentionally absent.
    struct Checkout: Codable, Equatable, Sendable {
        let merchant: String
        let sku: String
        let variant: String
        let quantity: Int
        let recipient: String
        let merchantID: String
        let subtotalMinor: Int
        let taxMinor: Int
        let shippingMinor: Int
        let discountMinor: Int
        let amountMinor: Int
        let currency: String
        let checkoutID: String

        enum CodingKeys: String, CodingKey {
            case merchant, sku, variant, quantity, recipient
            case merchantID = "merchant_id"
            case subtotalMinor = "subtotal_minor"
            case taxMinor = "tax_minor"
            case shippingMinor = "shipping_minor"
            case discountMinor = "discount_minor"
            case amountMinor = "amount_minor"
            case currency
            case checkoutID = "checkout_id"
        }
    }

    struct Challenge: Codable, Equatable, Sendable {
        let jobID: String
        let tenant: String
        let session: String
        let snapshotDigest: String
        let nonce: String
        let expiresAt: Int

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case tenant, session
            case snapshotDigest = "snapshot_digest"
            case nonce
            case expiresAt = "expires_at"
        }
    }

    private static let checkoutKeys: Set<String> = [
        "merchant", "sku", "variant", "quantity", "recipient", "merchant_id",
        "subtotal_minor", "tax_minor", "shipping_minor", "discount_minor",
        "amount_minor", "currency", "checkout_id"
    ]
    private static let challengeKeys: Set<String> = [
        "job_id", "tenant", "session", "snapshot_digest", "nonce", "expires_at"
    ]

    /// Canonical UTF-8 for JSON objects with ASCII protocol property names.
    /// Python: json.dumps(value, sort_keys=True, separators=(',',':'), ensure_ascii=False)
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeExact<T: Decodable>(
        _ type: T.Type, from data: Data, keys: Set<String>
    ) throws -> T {
        guard data.count <= 8_192,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == keys,
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw Rejection.invalidJSON
        }
        return value
    }

    private static func asciiIdentifier(_ input: String, max: Int = 160) -> Bool {
        !input.isEmpty && input.utf8.count <= max
            && input.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private static func asciiScope(_ input: String) -> Bool {
        !input.isEmpty && input.utf8.count <= 120
            && input.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0)
                    || [45, 46, 58, 64, 95].contains($0)
            }
    }

    static func parseCheckout(_ data: Data) throws -> Checkout {
        let checkout: Checkout = try decodeExact(Checkout.self, from: data, keys: checkoutKeys)
        guard checkout.merchant == "Alice Fictional HTTPS Merchant",
              checkout.merchantID == "alice-fictional-merchant-v1",
              checkout.currency == "EUR",
              asciiIdentifier(checkout.checkoutID),
              asciiIdentifier(checkout.sku),
              asciiIdentifier(checkout.variant, max: 48),
              (1...5).contains(checkout.quantity),
              !checkout.recipient.isEmpty, checkout.recipient.utf8.count <= 250,
              [checkout.subtotalMinor, checkout.taxMinor, checkout.shippingMinor,
               checkout.discountMinor, checkout.amountMinor]
                .allSatisfy({ (0...100_000).contains($0) }),
              checkout.amountMinor > 0,
              checkout.subtotalMinor + checkout.taxMinor + checkout.shippingMinor
                  - checkout.discountMinor == checkout.amountMinor else {
            throw Rejection.invalidCheckout
        }
        return checkout
    }

    static func parseChallenge(_ data: Data) throws -> Challenge {
        let challenge: Challenge = try decodeExact(
            Challenge.self, from: data, keys: challengeKeys)
        guard asciiIdentifier(challenge.jobID),
              asciiScope(challenge.tenant),
              asciiScope(challenge.session),
              asciiIdentifier(challenge.nonce),
              challenge.snapshotDigest.utf8.count == 64,
              challenge.snapshotDigest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }), challenge.expiresAt > 0 else {
            throw Rejection.invalidChallenge
        }
        return challenge
    }

    /// Returns only bytes suitable for a *separate* hardware-backed consent
    /// component; no signing or checkout execution is performed by this model.
    static func checkedChallengeBytes(
        checkoutData: Data,
        challengeData: Data,
        expectedJobID: String,
        expectedTenant: String,
        expectedSession: String,
        now: Int
    ) throws -> Data {
        let checkout = try parseCheckout(checkoutData)
        let challenge = try parseChallenge(challengeData)
        guard challenge.jobID == expectedJobID,
              challenge.tenant == expectedTenant,
              challenge.session == expectedSession else {
            throw Rejection.identityMismatch
        }
        guard challenge.expiresAt > now, now >= challenge.expiresAt - 180 else {
            throw Rejection.expired
        }
        let checkoutBytes = try canonical(checkout)
        let digest = SHA256.hash(data: checkoutBytes)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == challenge.snapshotDigest else {
            throw Rejection.checkoutMismatch
        }
        return try canonical(challenge)
    }
}
