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
    var errandID: String? = nil

    /// Why a code is asked and where it went, from what the shop's page said (`code_delivery` in
    /// the plugin). Never a guessed destination: without one it says so, and names the account.
    static func codeDelivery(site: String?, channel: String?, destination: String?, account: String?) -> String {
        let shop = site.map { $0.replacingOccurrences(of: "www.", with: "") } ?? String(localized: "The shop")
        let means: String? = switch channel {
        case "email": String(localized: "by email")
        case "sms": String(localized: "by SMS")
        case "whatsapp": String(localized: "by WhatsApp")
        case "authenticator": String(localized: "in your authenticator app")
        default: nil
        }
        let asked = String(localized: "\(shop) asks for a verification code to continue.")
        if let means, let destination {
            return asked + " " + String(localized: "It was sent \(means) to \(destination).")
        }
        if let means {
            return asked + " " + String(localized: "It was sent \(means).")
        }
        if let account {
            return asked + " " + String(localized: "The page does not say where it was sent; your account there is \(account).")
        }
        return asked + " " + String(localized: "The page does not say where it was sent.")
    }

    static func parse(_ payload: [String: Any]) -> SecureRequest? {
        guard let id = payload["request_id"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch payload["kind"] as? String {
        case "vault.save_login":
            guard let origin = text("origin") else { return nil }
            return SecureRequest(id: id, kind: .saveLogin(origin: origin, site: text("site") ?? origin), errandID: text("errand_id"))
        case "vault.code":
            let hint = text("hint") ?? codeDelivery(site: text("site"), channel: text("delivery_channel"),
                                                    destination: text("delivery_destination"),
                                                    account: text("account_hint"))
            return SecureRequest(id: id, kind: .code(site: text("site"), hint: hint), errandID: text("errand_id"))
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
