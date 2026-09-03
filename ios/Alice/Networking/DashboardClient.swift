import Foundation

/// The Hermes dashboard: a second surface, on its own port, with its own login.
///
/// The gateway the rest of the app talks to serves the conversation and the
/// catalogues. Projects, Memory and the usage figures live only here, and
/// this half will not answer a bearer key — it wants a session, which it
/// mints from a username and password and keeps in a cookie.
///
/// Hermes refuses to listen anywhere but loopback until an auth provider is
/// configured, so an install without one simply has no dashboard to reach.
/// That is a setting on the agent, not something a client can work around.
actor DashboardClient {
    struct Credentials: Sendable, Equatable {
        var url: URL
        var username: String
        var password: String
    }

    enum Failure: Error, LocalizedError {
        case notConfigured
        case rejected
        case http(Int)
        case unreachable

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Add your Hermes dashboard in Connect to see this."
            case .rejected:
                "The dashboard did not accept that username and password."
            case let .http(status):
                "The dashboard returned \(status)."
            case .unreachable:
                "The dashboard did not answer. It only listens on your own network."
            }
        }
    }

    private var credentials: Credentials?
    private var signedIn = false

    /// Its own session so the login cookie is kept here and nowhere else.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    func use(_ credentials: Credentials?) {
        self.credentials = credentials
        signedIn = false
    }

    var isConfigured: Bool { credentials != nil }

    /// Reads a collection, signing in first and once more if the session has
    /// lapsed — they are stateless and do not survive the agent restarting.
    func get(_ path: String) async throws -> [String: Any] {
        guard credentials != nil else { throw Failure.notConfigured }
        if !signedIn { try await signIn() }
        do {
            return try await fetch(path)
        } catch Failure.http(401) {
            signedIn = false
            try await signIn()
            return try await fetch(path)
        }
    }

    private func signIn() async throws {
        guard let credentials else { throw Failure.notConfigured }
        var request = URLRequest(url: credentials.url.appending(path: "auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `basic` is the provider the username/password plugin registers under.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "basic",
            "username": credentials.username,
            "password": credentials.password,
        ])

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200..<300: signedIn = true
        case 401, 403, 422: throw Failure.rejected
        default: throw Failure.http(http.statusCode)
        }
    }

    /// Writes go through the same signed-in session as reads.
    @discardableResult
    func send(
        _ method: String, _ path: String, _ body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard credentials != nil else { throw Failure.notConfigured }
        if !signedIn { try await signIn() }
        do {
            return try await fetch(path, method: method, body: body)
        } catch Failure.http(401) {
            signedIn = false
            try await signIn()
            return try await fetch(path, method: method, body: body)
        }
    }

    private func fetch(
        _ path: String, method: String = "GET", body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let credentials, let url = Self.url(credentials.url, path) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Joins a path — with or without a query — onto the dashboard's address.
    ///
    /// `appending(path:)` escapes the whole string, so a "?" in it becomes
    /// %3F and the query arrives as part of the path. Anything with a query
    /// has to be resolved as a relative URL instead.
    private static func url(_ base: URL, _ path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard trimmed.contains("?") else { return base.appending(path: trimmed) }
        let root = base.absoluteString.hasSuffix("/")
            ? base
            : URL(string: base.absoluteString + "/") ?? base
        return URL(string: trimmed, relativeTo: root)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
    }
}

/// A Hermes profile — what the desktop client calls a bot.
///
/// A bot is not a separate kind of thing: it is a profile with its own SOUL,
/// model, skills and sessions. Everything the desktop shows under Bot Mode is
/// this, which is why it can be built here at all.
struct BotRow: Identifiable, Hashable, Sendable, Codable {
    var id: String { name }
    let name: String
    var displayName: String
    var detail: String
    var model: String?
    var provider: String?
    var skills: Int
    var isDefault: Bool
    var gatewayRunning: Bool
    var active: Bool
}

/// A named workspace, with how much of the agent's time it has taken.
struct ProjectRow: Identifiable, Hashable, Sendable {
    let id: String
    var label: String
    var path: String?
    var sessions: Int
    var tokens: Int
    var lastActive: Date?
}

/// One of the places the agent can keep what it remembers.
struct MemoryProvider: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    var detail: String
    var status: String
    var available: Bool
    var configured: Bool
    var active: Bool
}

/// What the agent has spent, as the dashboard totals it.
struct UsageReport: Sendable {
    struct Model: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        var provider: String?
        var inputTokens: Int
        var outputTokens: Int
        var sessions: Int
        var calls: Int
        var tokens: Int { inputTokens + outputTokens }
    }

    struct Tool: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        var count: Int
        var share: Double
    }

    var days: Int
    var sessions: Int
    var calls: Int
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double
    var models: [Model]
    var tools: [Tool]
    var tokens: Int { inputTokens + outputTokens }
}

extension DashboardClient {
    func bots() async throws -> [BotRow] {
        // Sequential rather than concurrent: `[String: Any]` is not Sendable,
        // so it cannot cross out of the actor in parallel, and two small reads
        // over a local network are not worth a wrapper type.
        let object = try await get("api/profiles")
        let activeObject = try await get("api/profiles/active")
        let active = (activeObject["active"] as? String)
            ?? (activeObject["current"] as? String)
        let rows = (object["profiles"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return BotRow(
                name: name,
                displayName: (row["display_name"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? name,
                detail: (row["description"] as? String) ?? "",
                model: row["model"] as? String,
                provider: row["provider"] as? String,
                skills: (row["skill_count"] as? Int) ?? 0,
                isDefault: (row["is_default"] as? Bool) ?? false,
                gatewayRunning: (row["gateway_running"] as? Bool) ?? false,
                active: name == active
            )
        }
    }

    /// The bot's standing instructions. `exists` is false for a profile that
    /// has never been given one, which is different from an empty one.
    func soul(_ name: String) async throws -> (text: String, exists: Bool) {
        let object = try await get("api/profiles/\(name)/soul")
        return ((object["content"] as? String) ?? "", (object["exists"] as? Bool) ?? false)
    }

    func setSoul(_ name: String, _ content: String) async throws {
        try await send("PUT", "api/profiles/\(name)/soul", ["content": content])
    }

    func setDescription(_ name: String, _ text: String) async throws {
        try await send("PUT", "api/profiles/\(name)/description", ["description": text])
    }

    func activate(_ name: String) async throws {
        try await send("POST", "api/profiles/active", ["name": name])
    }

    func createBot(name: String, description: String) async throws {
        var body: [String: Any] = ["name": name]
        if !description.isEmpty { body["description"] = description }
        try await send("POST", "api/profiles", body)
    }

    func deleteBot(_ name: String) async throws {
        try await send("DELETE", "api/profiles/\(name)")
    }

    /// The scheduled jobs belonging to one bot.
    ///
    /// The dashboard's copy of the cron list carries a `profile` on each job,
    /// which the gateway's does not — so this is the only place a routine can
    /// be tied to the bot that owns it.
    func routines(for profile: String) async throws -> [JobRow] {
        try await allRoutines()[profile] ?? []
    }

    /// Every routine, grouped by the bot that owns it, in one request.
    func allRoutines() async throws -> [String: [JobRow]] {
        let object = try await get("api/cron/jobs")
        let rows = (object["jobs"] as? [[String: Any]]) ?? []
        var grouped: [String: [JobRow]] = [:]
        for row in rows {
            guard let id = row["id"] as? String,
                  let profile = row["profile"] as? String
            else { continue }
            let schedule = row["schedule"] as? [String: Any]
            grouped[profile, default: []].append(
                JobRow(
                    id: id,
                    name: (row["name"] as? String) ?? id,
                    prompt: (row["prompt"] as? String) ?? "",
                    schedule: (row["schedule_display"] as? String)
                        ?? (schedule?["display"] as? String)
                        ?? (schedule?["expr"] as? String) ?? "",
                    enabled: (row["enabled"] as? Bool) ?? false,
                    lastStatus: row["last_status"] as? String,
                    lastError: (row["last_error"] as? String).flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    lastRun: HermesClient.date(row["last_run_at"]),
                    nextRun: HermesClient.date(row["next_run_at"])
                )
            )
        }
        return grouped
    }

    /// Creates a scheduled job owned by one bot.
    ///
    /// Two things the first version got wrong, both of which made every
    /// create fail with a 422 that was then swallowed: `schedule` is a plain
    /// string, not `{"expr": …}`, and the profile is a query parameter — the
    /// body has no field for it, so a job sent that way would have landed on
    /// whichever profile the dashboard was scoped to.
    func createRoutine(
        for profile: String, name: String, prompt: String, schedule: String
    ) async throws {
        let scoped = profile.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? profile
        try await send("POST", "api/cron/jobs?profile=\(scoped)", [
            "name": name,
            "prompt": prompt,
            "schedule": schedule,
            "enabled": true,
        ])
    }

    /// Writes the bot out as a shareable template and reports where it landed.
    func exportBot(_ name: String) async throws -> String? {
        let object = try await send("POST", "api/profiles/\(name)/export")
        return (object["path"] as? String) ?? (object["file"] as? String)
    }

    func rename(_ name: String, to newName: String) async throws {
        try await send("PATCH", "api/profiles/\(name)", ["new_name": newName])
    }

    func projects() async throws -> [ProjectRow] {
        let object = try await get("api/profiles/projects/tree")
        let rows = (object["projects"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ProjectRow(
                id: id,
                label: (row["label"] as? String) ?? id,
                path: row["path"] as? String,
                sessions: (row["sessionCount"] as? Int) ?? 0,
                tokens: (row["totalTokens"] as? Int) ?? 0,
                lastActive: (row["lastActive"] as? Double).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func memory() async throws -> [MemoryProvider] {
        let object = try await get("api/memory")
        let active = (object["active"] as? String) ?? ""
        let rows = (object["providers"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return MemoryProvider(
                name: name,
                detail: (row["description"] as? String) ?? "",
                status: (row["status"] as? String) ?? "",
                available: (row["available"] as? Bool) ?? false,
                configured: (row["configured"] as? Bool) ?? false,
                active: name == active
            )
        }
    }

    func usage() async throws -> UsageReport {
        let object = try await get("api/analytics/usage")
        let totals = (object["totals"] as? [String: Any]) ?? [:]
        let models = ((object["by_model"] as? [[String: Any]]) ?? []).compactMap { row -> UsageReport.Model? in
            guard let name = row["model"] as? String else { return nil }
            return UsageReport.Model(
                name: name,
                provider: row["provider"] as? String,
                inputTokens: (row["input_tokens"] as? Int) ?? 0,
                outputTokens: (row["output_tokens"] as? Int) ?? 0,
                sessions: (row["sessions"] as? Int) ?? 0,
                calls: (row["api_calls"] as? Int) ?? 0
            )
        }
        let tools = ((object["tools"] as? [[String: Any]]) ?? []).compactMap { row -> UsageReport.Tool? in
            guard let name = row["tool"] as? String else { return nil }
            return UsageReport.Tool(
                name: name,
                count: (row["count"] as? Int) ?? 0,
                share: ((row["percentage"] as? Double) ?? 0) / 100
            )
        }
        return UsageReport(
            days: (object["period_days"] as? Int) ?? 30,
            sessions: (totals["total_sessions"] as? Int) ?? 0,
            calls: (totals["total_api_calls"] as? Int) ?? 0,
            inputTokens: (totals["total_input"] as? Int) ?? 0,
            outputTokens: (totals["total_output"] as? Int) ?? 0,
            cost: (totals["total_actual_cost"] as? Double)
                ?? (totals["total_estimated_cost"] as? Double) ?? 0,
            models: models.sorted { $0.tokens > $1.tokens },
            tools: tools.sorted { $0.count > $1.count }
        )
    }
}
