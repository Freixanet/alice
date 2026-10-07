import CryptoKit
import Foundation

/// The options a chat showed with `purchase_options` (steps 5–6 of buying, docs/purchases.md).
///
/// The call's arguments are what the model proposed; the plugin keeps only what it could verify
/// (a real https page, in stock, priced in the person's currency) under a key both sides compute
/// the same way — the first eight hex characters of the SHA-256 of the pages, variants, quantities, prices
/// and currencies (`purchase_flow.set_key`). The card draws the plugin's list, never the arguments, so an
/// option the plugin left out is never offered.
struct PurchaseOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let merchant: String
    let variant: String
    let qty: Int
    let price: String
    let image: URL?
    let url: URL?
    let recommended: Bool
    let why: String
    var shipping: String = ""
    var condition: String = ""
    var promotionalPrice: String = ""
    var promotionCode: String = ""
    var coupon: String = ""

    var hasPromotion: Bool { !promotionalPrice.isEmpty && !promotionCode.isEmpty }
    var displayPrice: String { hasPromotion ? promotionalPrice : price }
    var previousPrice: String? { hasPromotion ? price : nil }

    func couponLabel(_ language: ChatLanguage) -> String? {
        let code = hasPromotion ? promotionCode : coupon
        guard !code.isEmpty else { return nil }
        return language.pick("Coupon: \(code)", "Cupón: \(code)")
    }

    /// What the person's tap sends: the plugin starts this option's errand from the id.
    var choice: String {
        let shop = merchant.isEmpty ? "" : " · \(merchant)"
        let kind = variant.isEmpty ? "" : " (\(variant))"
        return "[elección:\(id)] \(title)\(kind)\(shop) · \(price)"
    }

    static func parse(_ row: [String: Any]) -> PurchaseOption? {
        guard let id = row["id"] as? String, let title = row["title"] as? String, !title.isEmpty else { return nil }
        func text(_ key: String) -> String { (row[key] as? String) ?? "" }
        func https(_ key: String) -> URL? {
            let raw = text(key)
            return raw.hasPrefix("https://") ? URL(string: raw) : nil
        }
        return PurchaseOption(
            id: id, title: title, merchant: text("merchant"), variant: text("variant"),
            qty: (row["qty"] as? Int) ?? 1, price: text("price"), image: https("image"), url: https("url"),
            recommended: (row["recommended"] as? Bool) == true, why: text("why"), shipping: text("shipping"), condition: text("condition"),
            promotionalPrice: text("promotional_price"), promotionCode: text("promotion_code"), coupon: text("coupon"))
    }
}

struct PurchaseOptionSet: Hashable, Sendable {
    let key: String
    let options: [PurchaseOption]
    /// The option the person chose, once they did.
    let chosen: String?

    func recommendation(_ language: ChatLanguage) -> String? {
        guard let best = options.first(where: \.recommended) else { return nil }
        let name = best.variant.isEmpty || best.title.localizedCaseInsensitiveContains(best.variant)
            ? best.title : "\(best.title) · \(best.variant)"
        // One option is not a choice: nothing to «open a card to choose» between.
        if options.count == 1 {
            return language.pick("It's the one that matches: \(name).", "Es la que encaja: \(name).")
        }
        let recommendation = language.pick("I recommend \(name).", "Te recomiendo \(name).")
        return recommendation + "\n" + language.pick("Open a card to choose your product.", "Abre una tarjeta para elegir el producto.")
    }

    static let toolName = "purchase_options"

    static func isTool(_ name: String) -> Bool { name == toolName }

    static func parse(_ object: [String: Any]) -> PurchaseOptionSet? {
        guard let key = object["key"] as? String else { return nil }
        let options = (object["options"] as? [[String: Any]] ?? []).compactMap(PurchaseOption.parse)
        return PurchaseOptionSet(key: key, options: options, chosen: object["chosen"] as? String)
    }

    /// The set's key from the call's arguments (`AppStore.toolDetail` keeps them as JSON).
    static func key(fromDetail detail: String?) -> String? {
        guard let data = detail?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let result = object["result"] as? [String: Any], let key = result["set"] as? String { return key }
        let args = object["args"] as? [String: Any] ?? object
        guard let raw = args["options"] as? [Any] else { return nil }
        let options = raw.compactMap { $0 as? [String: Any] }.prefix(1000)
        guard !options.isEmpty else { return nil }
        return key(options: Array(options))
    }

    static func key(pages: [String]) -> String {
        key(options: pages.map { ["url": $0] })
    }

    static func key(options: [[String: Any]]) -> String {
        let rows = options.map { row in
            func text(_ name: String) -> String {
                ((row[name] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let quantity = (row["qty"] as? Int) ?? 1
            return [text("url"), text("variant"), String(quantity == 0 ? 1 : quantity), text("price"), text("currency")]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

}

extension DashboardClient {
    /// The verified options for `key`; nil when the plugin no longer has them.
    func purchaseOptions(_ key: String, session: String) async throws -> PurchaseOptionSet? {
        do {
            return PurchaseOptionSet.parse(try await get("api/plugins/alice/purchase/options/\(key)?session=\(session.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"))
        } catch DashboardClient.Failure.http(404, _) {
            return nil
        }
    }
}
