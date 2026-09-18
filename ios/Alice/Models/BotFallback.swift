import Foundation

/// One hop in a profile's Hermes `fallback_providers` chain.
///
/// The agent page edits the first hop. Extra hops, when they exist, stay in
/// place unless the person clears the fallback entirely.
struct BotFallbackEntry: Hashable, Sendable, Equatable {
    var provider: String
    var model: String
    var baseURL: String?

    var option: HermesClient.ModelOption {
        HermesClient.ModelOption(
            id: model,
            label: HermesClient.prettify(model),
            provider: provider,
            providerName: nil
        )
    }

    var payload: [String: Any] {
        var row: [String: Any] = ["provider": provider, "model": model]
        if let baseURL, !baseURL.isEmpty { row["base_url"] = baseURL }
        return row
    }

    static func from(option: HermesClient.ModelOption) -> BotFallbackEntry? {
        let model = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = option.provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty, !provider.isEmpty else { return nil }
        return BotFallbackEntry(provider: provider, model: model, baseURL: nil)
    }
}

/// Official Hermes fallback chain: `fallback_providers` first, then a leftover
/// legacy `fallback_model`, matching `hermes_cli.fallback_config.get_fallback_chain`.
enum BotFallbackChain {
    /// Effective chain from a GET `/api/config` body.
    static func parse(from object: [String: Any]) -> [BotFallbackEntry] {
        var chain: [BotFallbackEntry] = []
        var seen = Set<String>()
        for key in ["fallback_providers", "fallback_model"] {
            for entry in entries(object[key]) {
                let identity = "\(entry.provider.lowercased())|\(entry.model.lowercased())|\((entry.baseURL ?? "").lowercased())"
                if seen.insert(identity).inserted {
                    chain.append(entry)
                }
            }
        }
        return chain
    }

    /// Replace the first hop, or drop the whole chain when `entry` is nil.
    /// Remaining hops after the first stay when a new first hop is set.
    static func replacingFirst(
        _ chain: [BotFallbackEntry], with entry: BotFallbackEntry?
    ) -> [BotFallbackEntry] {
        guard let entry else { return [] }
        return [entry] + Array(chain.dropFirst())
    }

    /// PUT `/api/config` body. Lists replace under Hermes' deep-merge; an
    /// empty `fallback_model` list also knocks out the legacy singular key,
    /// which that merge cannot delete.
    static func putBody(_ chain: [BotFallbackEntry]) -> [String: Any] {
        [
            "config": [
                "fallback_providers": chain.map(\.payload),
                "fallback_model": [] as [Any],
            ]
        ]
    }

    static func isChange(
        _ option: HermesClient.ModelOption?, from chain: [BotFallbackEntry]
    ) -> Bool {
        let current = chain.first
        guard let option else { return current != nil }
        guard let next = BotFallbackEntry.from(option: option) else { return true }
        guard let current else { return true }
        return current.provider != next.provider || current.model != next.model
    }

    private static func entries(_ raw: Any?) -> [BotFallbackEntry] {
        if let row = raw as? [String: Any] {
            return [row].compactMap(entry(from:))
        }
        if let rows = raw as? [[String: Any]] {
            return rows.compactMap(entry(from:))
        }
        return []
    }

    private static func entry(from row: [String: Any]) -> BotFallbackEntry? {
        let provider = (row["provider"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (row["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        let base = (row["base_url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BotFallbackEntry(
            provider: provider,
            model: model,
            baseURL: (base?.isEmpty == false) ? base : nil
        )
    }
}
