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
    private static let account = "gateway-key"

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

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func read() -> String? {
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
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
