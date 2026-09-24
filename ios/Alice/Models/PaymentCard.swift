import Foundation

/// An agent at a payment page with no card for it ends its reply with
/// `[Añadir tarjeta](alice://connect/card?origin=https://sis.redsys.es&profile=default)`.
/// The card is then given in a native form and kept in Hermes' vault on the Mac,
/// bound to that page's site; Hermes fills it after the person confirms, and the
/// numbers never go through the chat or the agent.
struct PaymentCardOffer: Hashable, Sendable {
    let origin: String
    let profile: String

    /// The payment page's site, as the person reads it.
    var host: String {
        URL(string: origin)?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? origin
    }

    /// The offer in a connect link's service part (`card?origin=…&profile=…`), or nil.
    nonisolated static func parse(_ service: String) -> PaymentCardOffer? {
        guard service.hasPrefix("card?"),
              let items = URLComponents(string: "alice://x/\(service)")?.queryItems,
              let raw = items.first(where: { $0.name == "origin" })?.value,
              let url = URL(string: raw), url.scheme == "https", let host = url.host(), !host.isEmpty
        else { return nil }
        let origin = "https://\(host)" + (url.port.map { ":\($0)" } ?? "")
        let profile = items.first(where: { $0.name == "profile" })?.value ?? "default"
        guard profile.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return PaymentCardOffer(origin: origin, profile: profile)
    }
}

/// A card saved in the vault: what the plugin ever sends back.
struct SavedCard: Identifiable, Hashable, Sendable {
    let handle: String
    let label: String
    let origin: String?

    var id: String { handle }

    init?(_ object: [String: Any]) {
        guard let handle = object["handle"] as? String, let label = object["label"] as? String else { return nil }
        self.handle = handle
        self.label = label
        origin = object["origin"] as? String
    }
}

/// What the person types in the card form. Held only while the form is open.
struct PaymentCardFields: Sendable {
    var number = ""
    var name = ""
    var expiry = ""
    var cvc = ""

    var digits: String { number.filter(\.isNumber) }

    /// Month and full year from "MM/AA", "MM/AAAA" or "MMAA".
    var expiryParts: (month: Int, year: Int)? {
        let parts = expiry.split(whereSeparator: { !$0.isNumber }).map(String.init)
        let pair: (String, String)
        if parts.count == 2 { pair = (parts[0], parts[1]) }
        else if parts.count == 1, parts[0].count == 4 || parts[0].count == 6 {
            pair = (String(parts[0].prefix(2)), String(parts[0].dropFirst(2)))
        } else { return nil }
        guard let month = Int(pair.0), let rawYear = Int(pair.1), (1...12).contains(month) else { return nil }
        let year = rawYear < 100 ? 2000 + rawYear : rawYear
        return (month, year)
    }

    func isValid(now: Date = .now) -> Bool {
        guard (12...19).contains(digits.count), Self.luhn(digits),
              let expiry = expiryParts,
              (3...4).contains(cvc.filter(\.isNumber).count)
        else { return false }
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        return (expiry.year, expiry.month) >= (today.year ?? 0, today.month ?? 0)
    }

    var body: [String: Any] {
        var body: [String: Any] = ["card_number": digits, "cvc": cvc.filter(\.isNumber)]
        if let expiry = expiryParts {
            body["exp_month"] = String(format: "%02d", expiry.month)
            body["exp_year"] = String(expiry.year)
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { body["cardholder_name"] = name }
        return body
    }

    /// The number grouped in fours as it is typed.
    static func grouped(_ text: String) -> String {
        let digits = String(text.filter(\.isNumber).prefix(19))
        return stride(from: 0, to: digits.count, by: 4).map { start in
            let from = digits.index(digits.startIndex, offsetBy: start)
            return String(digits[from..<(digits.index(from, offsetBy: 4, limitedBy: digits.endIndex) ?? digits.endIndex)])
        }.joined(separator: " ")
    }

    static func luhn(_ digits: String) -> Bool {
        var total = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            total += value
        }
        return total % 10 == 0
    }
}

/// Hermes' confirmation before it writes a saved card into a checkout
/// (`Fill payment card 'Visa ···4242' on https://shop.example`). It is the one
/// yes a purchase needs, so it is asked as that — pay or cancel — and never
/// offers to stop asking.
struct PaymentApproval: Hashable, Sendable {
    let card: String
    let site: String

    init?(command: String?) {
        guard let command, command.hasPrefix("Fill payment card '"),
              let close = command.range(of: "' on ", options: .backwards)
        else { return nil }
        card = String(command[command.index(command.startIndex, offsetBy: "Fill payment card '".count)..<close.lowerBound])
        let origin = String(command[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        site = URL(string: origin)?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? origin
    }
}
