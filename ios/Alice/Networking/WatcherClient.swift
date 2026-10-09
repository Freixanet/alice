import Foundation

struct WatcherSnapshot: Decodable, Sendable {
    struct Watcher: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let source: String
        let status: String
        let reason: String?
        let pending: Int
        struct Configuration: Decodable, Sendable {
            let query: String?
            let every_minutes: Int?
        }
        let config: Configuration?

        var needsEmailFilter: Bool {
            source == "email" && (config?.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    struct Route: Codable, Sendable {
        var provider: String
        var model: String
        var base_url: String
        var api_key_env: String
    }
    struct Notice: Decodable, Identifiable, Sendable {
        let id: String
        let message: String
    }
    struct Morning: Codable, Sendable {
        var enabled: Bool
        var time: String
        var timezone: String
    }
    struct Usage: Decodable, Sendable {
        struct Day: Decodable, Identifiable, Sendable {
            let date: String
            let proactive: Int
            let briefing: Int
            let total: Int
            var id: String { date }
        }
        let today: Day
        let days: [Day]
        let timezone: String
        let available: Bool
    }
    let morning: Morning?
    let usage: Usage?
    let watchers: [Watcher]
    let route: Route?
    let setup_required: Bool
    let feedback: [String: [String]]
    let notices: [Notice]
}

struct WatcherClient: Sendable {
    let dashboard: DashboardClient
    func morning(_ settings: WatcherSnapshot.Morning) async throws {
        try await dashboard.send("PUT", "api/plugins/alice/watchers/morning", [
            "enabled": settings.enabled, "time": settings.time, "timezone": settings.timezone
        ])
    }
    func load() async throws -> WatcherSnapshot { try await dashboard.watcherSnapshot() }
    func configure(_ route: WatcherSnapshot.Route) async throws { try await dashboard.configureWatcherRoute(route) }
    func action(_ action: String, id: String) async throws -> String { try await dashboard.watcherAction(action, id: id) }
    func feedback(_ kind: String, value: String, remove: Bool = false) async throws {
        try await dashboard.watcherFeedback(kind, value: value, remove: remove)
    }
}

extension DashboardClient {
    func watcherSnapshot() async throws -> WatcherSnapshot {
        let object = try await get("api/plugins/alice/watchers")
        return try JSONDecoder().decode(WatcherSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func configureWatcherRoute(_ route: WatcherSnapshot.Route) async throws {
        try await send("PUT", "api/plugins/alice/watchers/route", [
            "provider": route.provider, "model": route.model,
            "base_url": route.base_url, "api_key_env": route.api_key_env
        ])
    }

    func watcherAction(_ action: String, id: String) async throws -> String {
        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw Failure.unreadable }
        let object = try await send("POST", "api/plugins/alice/watchers/\(id)/actions", ["action": action])
        guard action == "dry_run" else { return "" }
        // Diagnostic data is displayed as text, never evaluated as markup or actions.
        let rows = object["results"] as? [[String: Any]] ?? []
        return WatcherWords.preview(rows)
    }

    func watcherFeedback(_ kind: String, value: String, remove: Bool) async throws {
        try await send("PUT", "api/plugins/alice/watchers/feedback", ["kind": kind, "value": value, "remove": remove])
    }
}
