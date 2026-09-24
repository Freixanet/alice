import Foundation

/// Something only the person can type, asked by Hermes as a server request and
/// answered in a secure card: a login for a site the agent is signing into, the
/// one-time code a site sent, a password manager's master password, or a key.
/// The answer goes straight back to Hermes — its vault or `.env` — and never
/// into the conversation, the transcript or the logs.
struct SecureRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Hermes' vault: identifier and password, bound to this exact origin.
        case saveLogin(origin: String, site: String)
        case code(site: String?, hint: String?)
        case unlock(manager: String)
        case secret(name: String, prompt: String)
    }

    /// The request's own id (`srq-…`): the answer is addressed to it.
    let id: String
    let kind: Kind

    static func parse(_ payload: [String: Any]) -> SecureRequest? {
        guard let id = payload["request_id"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch payload["kind"] as? String {
        case "vault.save_login":
            guard let origin = text("origin") else { return nil }
            return SecureRequest(id: id, kind: .saveLogin(origin: origin, site: text("site") ?? origin))
        case "vault.code":
            return SecureRequest(id: id, kind: .code(site: text("site"), hint: text("hint")))
        case "vault.unlock_prompt":
            return SecureRequest(id: id, kind: .unlock(manager: text("display_name") ?? text("backend") ?? ""))
        case "secret":
            guard let name = text("env_var") else { return nil }
            return SecureRequest(id: id, kind: .secret(name: name, prompt: text("prompt") ?? ""))
        default:
            return nil
        }
    }

    /// Hermes reads a login as JSON `{identifier, password}`.
    static func loginAnswer(identifier: String, password: String) -> String {
        let object = ["identifier": identifier, "password": password]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
