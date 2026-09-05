import Foundation

/// A skill or toolset as the management surface reports it.
struct CatalogRow: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var label: String
    var detail: String
    /// Nil when the server does not report state at all. A gateway serving
    /// `/v1/skills` sends only a name, a description and a category — reading
    /// that as `false` put a hundred skills behind switches that said they
    /// were off, which was not something the agent had said.
    var enabled: Bool?
    var group: String?
    /// Tool names for a toolset; empty for a skill.
    var tools: [String] = []
    /// Present on toolsets that need keys they do not have.
    var configured: Bool?
}

/// A scheduled job as Hermes reports it.
struct JobRow: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var prompt: String
    /// Already in words from the server — "every 10m", "0 9 * * 1-5" — so the
    /// app does not reinvent cron parsing to say something the agent has
    /// already said.
    var schedule: String
    var enabled: Bool
    var lastStatus: String?
    var lastError: String?
    var lastRun: Date?
    var nextRun: Date?
}

/// A run of the agent as the server recorded it — from the phone, the web,
/// a messaging channel or a scheduled job alike.
struct SessionRow: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var preview: String
    var source: String?
    var model: String?
    var messageCount: Int
    var toolCallCount: Int
    var inputTokens: Int
    var outputTokens: Int
    /// Nil where the provider bills by subscription and reports nothing.
    var cost: Double?
    var lastActive: Date?

    var tokens: Int { inputTokens + outputTokens }
}

extension HermesClient {
    /// Reads a management collection.
    ///
    /// These live under `/api/*`, which is a different surface from the agent
    /// API at `/v1/*` — a build can serve one and not the other, which is why
    /// every screen checks before it asks.
    private func managementList(_ path: String) async throws -> [[String: Any]] {
        try await managementList(paths: [path])
    }

    /// Reads the first of these paths the server answers.
    ///
    /// The caller passes the manifest's own route first and the historical
    /// ones after it. Hardcoding `/api/skills` meant a gateway that serves
    /// `/v1/skills` — and says so in its manifest — returned 404 for a
    /// hundred installed skills.
    private func managementList(paths: [String]) async throws -> [[String: Any]] {
        var lastFailure: Error = Failure.badResponse
        for path in paths {
            do {
                return try await managementRows(path)
            } catch let failure as Failure {
                if case let .http(status, _, _) = failure, status == 404 {
                    lastFailure = failure
                    continue
                }
                throw failure
            }
        }
        throw lastFailure
    }

    private func managementRows(_ path: String) async throws -> [[String: Any]] {
        let (data, response) = try await session.data(for: try request(path))
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = HermesClient.detail(from: data)
                ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(
                status: http.statusCode,
                detail: detail,
                limit: ModelLimitClassifier.classify(status: http.statusCode, message: detail)
            )
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        if let rows = object as? [[String: Any]] { return rows }
        if let map = object as? [String: Any] {
            for key in ["skills", "toolsets", "jobs", "items", "data", "results"] {
                if let rows = map[key] as? [[String: Any]] { return rows }
            }
        }
        return []
    }

    func skills(_ manifest: Manifest?) async throws -> [CatalogRow] {
        HermesClient.parseCatalog(
            try await managementList(paths: routes(manifest, "skills", "api/skills", "v1/skills")),
            kind: .skill
        )
    }

    func toolsets(_ manifest: Manifest?) async throws -> [CatalogRow] {
        HermesClient.parseCatalog(
            try await managementList(
                paths: routes(manifest, "toolsets", "api/tools/toolsets", "v1/toolsets")
            ),
            kind: .toolset
        )
    }

    func mcpServers(_ manifest: Manifest?) async throws -> [CatalogRow] {
        HermesClient.parseCatalog(
            try await managementList(
                paths: routes(manifest, "mcp_servers", "api/mcp/servers", "v1/mcp/servers")
            ),
            kind: .toolset
        )
    }

    /// The manifest's route first, then the paths older builds used.
    private func routes(
        _ manifest: Manifest?, _ name: String, _ fallbacks: String...
    ) -> [String] {
        var paths = manifest?.path(name).map { [$0] } ?? []
        for fallback in fallbacks where !paths.contains(fallback) {
            paths.append(fallback)
        }
        return paths
    }

    /// Flips a skill on or off. Hermes owns the state; the row is refreshed
    /// from the response rather than assumed, so a rejected toggle does not
    /// leave the interface lying about what is enabled.
    func toggleSkill(name: String, enabled: Bool) async throws {
        var request = try self.request("api/skills/toggle", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["name": name, "enabled": enabled]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = HermesClient.detail(from: data) ?? "Hermes refused the change."
            throw Failure.http(status: status, detail: detail, limit: nil)
        }
    }

    /// The scheduled jobs.
    ///
    /// The gateway's own manifest goes first, as everywhere else here: it is
    /// the server saying where its routes are, and a guess that precedes it
    /// can only be wrong more often. That matters more than one wasted round
    /// trip, because `managementList` takes the first path that answers at
    /// all and rethrows anything that is not a 404 — so a guessed path an
    /// agent answers with 401 or 500 would break a listing that works.
    /// Probed unauthenticated against this gateway: `api/jobs` answers 401,
    /// so it is there; `api/cron/jobs` and `api/cron` answer 404, so they are
    /// not. The two that exist lead. Note this listing is the gateway's, and
    /// the gateway serves one profile — another bot's routines are not absent
    /// here because of a parsing fault but because they are not this
    /// gateway's to report. Cross-profile listing is `DashboardClient`.
    func jobs(_ manifest: Manifest?) async throws -> [JobRow] {
        var paths: [String] = []
        if let advertised = manifest?.path("jobs") { paths.append(advertised) }
        for fallback in [
            "api/jobs", "api/cron/jobs?profile=all", "api/cron/jobs", "api/cron",
        ] where !paths.contains(fallback) {
            paths.append(fallback)
        }
        let rows = try await managementList(paths: paths)
        return rows.compactMap(Self.jobRow(from:))
    }

    /// One cron row, accepting both the current plain-string schedule and the
    /// nested schedule shape used by older builds/dashboard adapters.
    static func jobRow(from row: [String: Any]) -> JobRow? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let scheduleObject = row["schedule"] as? [String: Any]
        let scheduleText = (row["schedule_display"] as? String)
            ?? (row["schedule"] as? String)
            ?? (scheduleObject?["display"] as? String)
            ?? (scheduleObject?["expr"] as? String)
            ?? ""
        return JobRow(
            id: id,
            name: (row["name"] as? String) ?? id,
            prompt: (row["prompt"] as? String) ?? "",
            schedule: scheduleText,
            enabled: (row["enabled"] as? Bool) ?? false,
            lastStatus: row["last_status"] as? String,
            lastError: (row["last_error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lastRun: HermesClient.date(row["last_run_at"]),
            nextRun: HermesClient.date(row["next_run_at"])
        )
    }

    /// Hermes sends times as ISO-8601 on some surfaces and Unix timestamps on
    /// others. Accept both instead of dropping the next/last-run fields.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Every run the server has kept, newest first.
    ///
    /// One page of 500 covers an install with 129 of them, and `has_more`
    /// says when it does not — so the caller is told the list is partial
    /// rather than quietly shown a slice.
    func sessions(limit: Int = 500) async throws -> (rows: [SessionRow], complete: Bool) {
        let (data, response) = try await session.data(
            for: try request("api/sessions?limit=\(limit)")
        )
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = HermesClient.detail(from: data)
                ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return ([], true) }

        let parsed = rows.compactMap { row -> SessionRow? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let cost = (row["actual_cost_usd"] as? Double)
                ?? (row["estimated_cost_usd"] as? Double)
            return SessionRow(
                id: id,
                title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Untitled",
                preview: (row["preview"] as? String) ?? "",
                source: row["source"] as? String,
                model: row["model"] as? String,
                messageCount: (row["message_count"] as? Int) ?? 0,
                toolCallCount: (row["tool_call_count"] as? Int) ?? 0,
                inputTokens: (row["input_tokens"] as? Int) ?? 0,
                outputTokens: (row["output_tokens"] as? Int) ?? 0,
                cost: (cost ?? 0) > 0 ? cost : nil,
                lastActive: HermesClient.date(row["last_active"])
                    ?? HermesClient.date(row["started_at"])
            )
        }
        return (parsed, (object["has_more"] as? Bool) != true)
    }

    /// One turn as the server stored it, with the tool that produced it.
    struct StoredMessage: Sendable {
        var role: String
        var content: String
        var toolName: String?
        var timestamp: Date?
    }

    /// The messages of one session. Whole sessions run to hundreds of turns
    /// and hundreds of kilobytes, so callers scan a bounded number of them.
    func messages(_ sessionID: String) async throws -> [StoredMessage] {
        let (data, response) = try await session.data(
            for: try request("api/sessions/\(sessionID)/messages")
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw Failure.badResponse }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return [] }
        return rows.map { row in
            StoredMessage(
                role: (row["role"] as? String) ?? "",
                content: (row["content"] as? String) ?? "",
                toolName: row["tool_name"] as? String,
                timestamp: HermesClient.date(row["timestamp"])
            )
        }
    }

    enum CatalogKind { case skill, toolset }

    static func parseCatalog(_ rows: [[String: Any]], kind: CatalogKind) -> [CatalogRow] {
        rows.compactMap { row in
            let name = (row["name"] as? String) ?? (row["id"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let tools = (row["tools"] as? [String]) ?? []
            return CatalogRow(
                id: name,
                name: name,
                label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? prettify(name),
                detail: (row["description"] as? String) ?? "",
                enabled: row["enabled"] as? Bool,
                group: (row["group"] as? String) ?? (row["platform"] as? String),
                tools: tools,
                configured: row["configured"] as? Bool
            )
        }
    }
}
