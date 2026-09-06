import Foundation
import Security

/// Where the Hermes key lives on the phone.
///
/// This is the one asset worth protecting: whoever holds it can act as you
/// through your agent. It goes into the Keychain behind the device passcode or
/// Face ID, is never written to `UserDefaults`, never logged, and never leaves
/// the device except in the `Authorization` header of a request to the address
/// you configured.
///
/// `ThisDeviceOnly` accessibility means it is excluded from backups and never
/// syncs, so a restore on another phone cannot carry it along.
enum KeyStore {
    private static let service = "com.freixanet.alice.hermes"
    /// The gateway key. A second entry holds the dashboard password, which is
    /// a different secret for a different half of the agent.
    static let gatewayAccount = "gateway-key"

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error \(status)"
            }
        }
    }

    /// Replaces an existing secret in place. Delete-then-add is deliberately
    /// avoided: if an add ever fails (locked keychain, entitlement change,
    /// storage error), the previous working credential must still be there.
    static func save(_ key: String, account: String = gatewayAccount) throws {
        let data = Data(key.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Failure.keychain(updateStatus)
        }

        var add = lookup
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.keychain(addStatus) }
    }

    static func read(account: String = gatewayAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func clear(account: String = gatewayAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
