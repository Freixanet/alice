import CryptoKit
import Foundation

/// Exact one-use proof-of-possession challenge from an authenticated,
/// Alice-administered enrollment service — NOT from Hermes or a QR payload.
/// Validation does not attest this device or authenticate the Alice account.
enum SecureRunnerEnrollmentContract {
    enum Rejection: Error, Equatable {
        case malformed
        case wrongScope
        case wrongPublicKey
        case expired
    }

    struct Challenge: Codable, Equatable, Sendable {
        let purpose: String
        let tenant: String
        let session: String
        let account: String
        let installation: String
        let publicKeySHA256: String
        let operation: String
        let expectedVersion: Int
        let nonce: String
        let expiresAt: Int

        enum CodingKeys: String, CodingKey {
            case purpose, tenant, session, account, installation
            case publicKeySHA256 = "public_key_sha256"
            case operation
            case expectedVersion = "expected_version"
            case nonce
            case expiresAt = "expires_at"
        }
    }

    private static let allFields: Set<String> = [
        "purpose", "tenant", "session", "account", "installation",
        "public_key_sha256", "operation", "expected_version", "nonce", "expires_at"
    ]

    static func checkedProofBytes(
        challengeData: Data, publicKeyPEM: String,
        tenant: String, session: String, account: String, installation: String,
        generation: Int, now: Int
    ) throws -> Data {
        guard challengeData.count <= 8_192,
              let payload = try? JSONSerialization.jsonObject(with: challengeData),
              let object = payload as? [String: Any],
              Set(object.keys) == allFields,
              let challenge = try? JSONDecoder().decode(
                  Challenge.self, from: challengeData),
              challenge.purpose == "alice-r02-device-enroll-v1",
              challenge.operation == "enroll" || challenge.operation == "rotate",
              challenge.expectedVersion >= 0,
              !challenge.nonce.isEmpty, challenge.nonce.utf8.count <= 120,
              challenge.nonce.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }), challenge.publicKeySHA256.utf8.count == 64,
              challenge.publicKeySHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw Rejection.malformed
        }
        guard challenge.tenant == tenant,
              challenge.session == session,
              challenge.account == account,
              challenge.installation == installation,
              (challenge.operation == "enroll" && challenge.expectedVersion == 0
                  && generation == 1)
              || (challenge.operation == "rotate" && challenge.expectedVersion >= 1
                  && generation == challenge.expectedVersion + 1) else {
            throw Rejection.wrongScope
        }
        guard challenge.expiresAt > now,
              now >= challenge.expiresAt - 180 else {
            throw Rejection.expired
        }
        let digest = SHA256.hash(data: Data(publicKeyPEM.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == challenge.publicKeySHA256 else {
            throw Rejection.wrongPublicKey
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(challenge)
    }
}
