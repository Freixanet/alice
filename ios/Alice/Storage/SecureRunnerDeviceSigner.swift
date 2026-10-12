import CryptoKit
import Foundation
import Security

/// Alice-side hardware key adapter. It has NO network, checkout, Hermes tool,
/// enrollment-authority or payment privileges and is NOT enabled in the UI.
/// A future authenticated Alice transport must enroll/revoke its public key.
/// Secure Enclave with .userPresence requires device authentication, which
/// may be Face ID, Touch ID or passcode; it does NOT establish remote human
/// identity, account ownership or an attested device.
@MainActor
enum SecureRunnerDeviceSigner {
    enum Failure: Error {
        case invalidScope
        case hardwareUnavailable
        case keyNotEnrolled
        case invalidPublicKey
        case signatureUnavailable
    }

    /// Scope is never chosen by an agent or a QR code. The future Alice IdP
    /// must validate account, tenant and installation before key enrollment.
    private static func tag(
        tenant: String, account: String, installation: String
    ) throws -> Data {
        let values = [tenant, account, installation]
        guard values.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 120
                && $0.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0)
                        || [45, 46, 58, 64, 95].contains($0)
                }
        }) else {
            throw Failure.invalidScope
        }
        let raw = values.joined(separator: "|").data(using: .utf8)!
        let digest = SHA256.hash(data: raw)
        return Data("com.freixanet.alice.r02.".utf8) + Data(digest)
    }

    private static func existingKey(tag: Data) throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = item,
              CFGetTypeID(key) == SecKeyGetTypeID() else {
            throw Failure.hardwareUnavailable
        }
        return (key as! SecKey)
    }

    private static func pem(for privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw Failure.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              raw.count == 65, raw.first == 0x04 else {
            throw Failure.invalidPublicKey
        }
        // X9.63 uncompressed P-256 point, wrapped in the standard SPKI
        // DER header accepted by OpenSSL's public-only P256 verifier.
        let spkiHeader: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48,
            0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
            0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        ]
        let encoded = (Data(spkiHeader) + raw).base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 64).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(64, encoded.count - offset))
            return String(encoded[start..<end])
        }
        return "-----BEGIN PUBLIC KEY-----\n"
            + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----\n"
    }

    /// Only an explicit, separately authenticated device-enrollment flow
    /// should invoke this. There is no private-key export or software fallback.
    static func publicKeyForEnrollment(
        tenant: String, account: String, installation: String
    ) throws -> String {
        let keyTag = try tag(tenant: tenant, account: account, installation: installation)
        if let current = try existingKey(tag: keyTag) {
            return try pem(for: current)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .userPresence], &error
        ) else {
            throw Failure.hardwareUnavailable
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access
            ]
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure.hardwareUnavailable
        }
        return try pem(for: privateKey)
    }

    /// Sign ONLY a validated exact Alice checkout + challenge; no arbitrary
    /// data signing API is exposed. It does not create keys or submit orders.
    /// The signed DER ECDSA bytes match Python's P256 public-key verification.
    static func signValidatedConsent(
        checkoutData: Data, challengeData: Data,
        tenant: String, session: String, jobID: String,
        account: String, installation: String, now: Int
    ) throws -> String {
        let bytes = try SecureRunnerApprovalContract.checkedChallengeBytes(
            checkoutData: checkoutData, challengeData: challengeData,
            expectedJobID: jobID, expectedTenant: tenant,
            expectedSession: session, now: now)
        let keyTag = try tag(tenant: tenant, account: account, installation: installation)
        guard let privateKey = try existingKey(tag: keyTag) else {
            throw Failure.keyNotEnrolled
        }
        guard SecKeyIsAlgorithmSupported(
            privateKey, .sign, .ecdsaSignatureMessageX962SHA256
        ) else {
            throw Failure.signatureUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256,
            bytes as CFData, &error
        ) as Data? else {
            throw Failure.signatureUnavailable
        }
        return der.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
