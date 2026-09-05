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
        case http(Int, detail: String? = nil)
        case unreachable
        /// A 200 whose body could not be read as the listing it should be.
        /// Distinct from an empty listing, which is a real answer.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Add your Hermes dashboard in Connect to see this."
            case .rejected:
                "The dashboard did not accept that username and password."
            case let .http(status, detail):
                if let detail, !detail.isEmpty {
                    "The dashboard returned \(status): \(detail)"
                } else {
                    "The dashboard returned \(status)."
                }
            case .unreachable:
                "The dashboard did not answer. It only listens on your own network."
            case .unreadable:
                "The dashboard sent something this app could not read."
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

    /// Reads an object, signing in first and once more if the session has
    /// lapsed — they are stateless and do not survive the agent restarting.
    func get(_ path: String) async throws -> [String: Any] {
        guard credentials != nil else { throw Failure.notConfigured }
        if !signedIn { try await signIn() }
        do {
            return try await fetch(path)
        } catch Failure.http(401, _) {
            signedIn = false
            try await signIn()
            return try await fetch(path)
        }
    }

    /// Some dashboard routes — notably current Hermes' cron list — return a
    /// top-level JSON array rather than an object. Keep that shape instead of
    /// coercing it to an empty dictionary and making the UI say "no routines".
    func getRows(_ path: String) async throws -> [[String: Any]] {
        guard credentials != nil else { throw Failure.notConfigured }
        if !signedIn { try await signIn() }
        do {
            return try await fetchRows(path)
        } catch Failure.http(401, _) {
            signedIn = false
            try await signIn()
            return try await fetchRows(path)
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
        } catch Failure.http(401, _) {
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
            // Carry whatever the server said. Throwing the bare number left
            // every failure looking identical — "the dashboard returned 405"
            // and nothing about which of its rules had been broken, which is
            // most of what you need to know.
            throw Failure.http(http.statusCode, detail: Self.detail(from: data))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func fetchRows(_ path: String) async throws -> [[String: Any]] {
        guard let credentials, let url = Self.url(credentials.url, path) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, detail: Self.detail(from: data))
        }
        // An unreadable body is not an empty listing. Returning [] here put a
        // parse failure on screen as "no routines", which is a claim about the
        // bot rather than about the answer.
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.unreadable
        }
        if let rows = object as? [[String: Any]] { return rows }
        if let map = object as? [String: Any] {
            for key in ["jobs", "items", "data", "results"] {
                if let rows = map[key] as? [[String: Any]] { return rows }
            }
            // An object with none of those keys and no rows in it is an empty
            // listing in the shape this agent's older surfaces use.
            if map.isEmpty || map["jobs"] != nil { return [] }
        }
        throw Failure.unreadable
    }

    /// Best-effort read of whatever the dashboard put in the body.
    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.count > 200 ? nil : text
        }
        for key in ["error", "detail", "message"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
            if let nested = object[key] as? [String: Any],
               let text = nested["message"] as? String, !text.isEmpty { return text }
        }
        return nil
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
/// A project somebody made and named, which can be renamed and removed.
struct NamedProject: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var colour: String?
    var created: Date?
}

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
    func routines(for profile: String) async throws -> [JobRow] {
        try await allRoutines()[profile] ?? []
    }

    /// Every routine grouped by the bot that owns it.
    ///
    /// Verified against this agent's own source, not inferred. `hermes serve`
    /// registers `@router.get("/api/cron/jobs")` with `profile: str = "all"`
    /// (`hermes_cli/web_routers/cron.py`), and for `all` it walks every
    /// profile home and concatenates, so the reply is a bare JSON array.
    /// `api/crons` belongs to the separate web UI, which this client does not
    /// talk to; asking this agent for it gets a FastAPI 404, which is what
    /// used to leave every bot reporting no routines at all.
    ///
    /// `_annotate_cron_job` stamps each row with `profile` and `profile_name`,
    /// both set to the same canonical profile name — the directory slug, from
    /// a scan validated by `normalize_profile_name`, never a display name. It
    /// sets no `owner_profile`; that field comes from the web UI's own
    /// listing, where it is the authoritative one, so it still leads.
    func allRoutines() async throws -> [String: [JobRow]] {
        let paths = ["api/cron/jobs?profile=all", "api/crons?all_profiles=1"]
        var rows: [[String: Any]] = []
        var hadSuccessfulRead = false
        var lastFailure: Error?

        for path in paths {
            do {
                let found = try await getRows(path)
                hadSuccessfulRead = true
                rows = found
                if !found.isEmpty { break }
            } catch {
                // Once a route has answered, its list is the answer — empty
                // included. The older route is consulted only in case that
                // answer was empty, so whatever it says when it fails must not
                // turn a bot with no routines into an error.
                if hadSuccessfulRead { break }
                if let failure = error as? Failure,
                   case let .http(status, _) = failure, status == 404 {
                    lastFailure = failure
                    continue
                }
                throw error
            }
        }
        if !hadSuccessfulRead, let lastFailure { throw lastFailure }

        return Self.group(rows)
    }

    /// Cron rows keyed by the bot that owns them.
    ///
    /// The key has to be the profile's own name, because that is what
    /// `routines(for:)` is asked for and what `BotRow.name` holds — a bot
    /// carries a separate `displayName` for the screen. A row keyed by
    /// anything else is a routine no one can find, which is the shape the
    /// original bug took.
    static func group(_ rows: [[String: Any]]) -> [String: [JobRow]] {
        var grouped: [String: [JobRow]] = [:]
        for row in rows {
            let owner = ["owner_profile", "profile", "profile_name"]
                .lazy
                .compactMap { row[$0] as? String }
                .first { !$0.isEmpty }
            guard let owner, let job = HermesClient.jobRow(from: row) else { continue }
            grouped[owner, default: []].append(job)
        }
        return grouped
    }

    /// Creates a scheduled job owned by one bot.
    ///
    /// `schedule` is a plain string and the profile is a query parameter; the
    /// body has no field for it. That keeps the routine in the selected
    /// profile's isolated cron store.
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

    /// The projects somebody made, as opposed to the ones the session tree
    /// implies. These are the only ones that can be created or renamed.
    func namedProjects() async throws -> [NamedProject] {
        let object = try await get("api/projects")
        let rows = (object["projects"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["project_id"] as? String else { return nil }
            return NamedProject(
                id: id,
                name: (row["name"] as? String) ?? id,
                colour: row["color"] as? String,
                created: (row["created_at"] as? Double)
                    .map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func createProject(name: String, colour: String?) async throws {
        var body: [String: Any] = ["name": name]
        if let colour { body["color"] = colour }
        _ = try await send("POST", "api/projects/create", body)
    }

    func renameProject(_ id: String, to name: String, colour: String?) async throws {
        var body: [String: Any] = ["project_id": id, "name": name]
        if let colour { body["color"] = colour }
        _ = try await send("POST", "api/projects/rename", body)
    }

    func deleteProject(_ id: String) async throws {
        _ = try await send("POST", "api/projects/delete", ["project_id": id])
    }

    /// A skill is its `SKILL.md`, frontmatter and all — so that is what is
    /// read and what is written back. Anything cleverer would be this app
    /// deciding what a skill may say.
    func skillContent(_ name: String) async throws -> String {
        let escaped = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? name
        let object = try await get("api/skills/content?name=\(escaped)")
        guard let content = object["content"] as? String else {
            throw Failure.http(404)
        }
        return content
    }

    func saveSkill(name: String, content: String) async throws {
        _ = try await send("POST", "api/skills/save", ["name": name, "content": content])
    }

    func deleteSkill(_ name: String) async throws {
        _ = try await send("POST", "api/skills/delete", ["name": name])
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
