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
            recommended: (row["recommended"] as? Bool) == true, why: text("why"), shipping: text("shipping"), condition: text("condition"))
    }
}

struct PurchaseOptionSet: Hashable, Sendable {
    let key: String
    let options: [PurchaseOption]
    /// The option the person chose, once they did.
    let chosen: String?

    static let toolName = "purchase_options"
    /// The plugin shows the cards as soon as the formats are checked: that call's result names
    /// the set (`set`), so the cards do not wait for the model to call `purchase_options`.
    static let verifyToolName = "purchase_verify"

    static func isTool(_ name: String) -> Bool { name == toolName }
    static func isCardTool(_ name: String) -> Bool { name == toolName || name == verifyToolName }

    /// The calls of a reply that carry cards, one per set: a verification that showed them and the
    /// model's own `purchase_options` for the same set are the same cards.
    static func cardCalls(_ tools: [Message.ToolCall]) -> [Message.ToolCall] {
        var seen = Set<String>()
        return tools.filter { call in
            guard isCardTool(call.name), call.status == .done, let key = key(fromDetail: call.detail) else { return false }
            return seen.insert(key).inserted
        }
    }

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

/// An option set the plugin showed in a chat, by when it showed it (`purchase_flow.sets_between`).
struct PurchaseSetSummary: Hashable, Sendable {
    let key: String
    let at: Date
    let chosen: String?
    /// Other keys the same set answers to (the one the app computes from the model's arguments).
    var aliases: [String] = []

    /// Whether a card already drawn under `keys` is this set.
    func isAmong(_ keys: Set<String>) -> Bool { keys.contains(key) || aliases.contains(where: keys.contains) }

    static func parse(_ row: [String: Any]) -> PurchaseSetSummary? {
        guard let key = row["key"] as? String, let at = row["at"] as? Double else { return nil }
        return PurchaseSetSummary(key: key, at: Date(timeIntervalSince1970: at), chosen: row["chosen"] as? String,
                                  aliases: row["aliases"] as? [String] ?? [])
    }
}

/// The turn each reply answers, as the span between the request before it and the request after
/// it: the cards the plugin showed in that span belong under that reply, whether or not the
/// model's call for them is in the transcript (the plugin showed them itself at verification, or
/// the model answered from memory and called nothing). One window per turn, on its last reply.
enum PurchaseTurnWindows {
    static func windows(messages: [Message]) -> [String: ClosedRange<Date>] {
        var result: [String: ClosedRange<Date>] = [:]
        var since: Date?
        var lastReply: Message?
        func close(at end: Date) {
            if let reply = lastReply, let since {
                result[reply.id] = since...end
            }
            lastReply = nil
        }
        for message in messages {
            if message.role == .user {
                close(at: message.createdAt)
                since = message.createdAt
            } else if message.role == .assistant, since != nil {
                lastReply = message
            }
        }
        close(at: .distantFuture)
        return result
    }
}

extension DashboardClient {
    /// The sets shown in `session` during `window`, oldest first.
    func purchaseSets(session: String, window: ClosedRange<Date>) async throws -> [PurchaseSetSummary] {
        let encoded = session.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var path = "api/plugins/alice/purchase/sets?session=\(encoded)&since=\(window.lowerBound.timeIntervalSince1970)"
        if window.upperBound != .distantFuture { path += "&until=\(window.upperBound.timeIntervalSince1970)" }
        let object = try await get(path)
        return (object["sets"] as? [[String: Any]] ?? []).compactMap(PurchaseSetSummary.parse)
    }

    /// The verified options for `key`; nil when the plugin no longer has them.
    func purchaseOptions(_ key: String, session: String) async throws -> PurchaseOptionSet? {
        do {
            return PurchaseOptionSet.parse(try await get("api/plugins/alice/purchase/options/\(key)?session=\(session.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"))
        } catch DashboardClient.Failure.http(404, _) {
            return nil
        }
    }
}
