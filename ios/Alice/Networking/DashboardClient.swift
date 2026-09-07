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
    func rows(_ path: String, shape: BodyShape) async throws -> JSONRows {
        guard credentials != nil else { throw Failure.notConfigured }
        if !signedIn { try await signIn() }
        do {
            return JSONRows(try await fetchRows(path, shape: shape))
        } catch Failure.http(401, _) {
            signedIn = false
            try await signIn()
            return JSONRows(try await fetchRows(path, shape: shape))
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

    private func fetchRows(
        _ path: String, shape: BodyShape
    ) async throws -> [[String: Any]] {
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
        return try Self.rows(from: data, shape: shape)
    }

    /// What a listing body is allowed to look like, decided by the route that
    /// answered rather than by trying every shape on every reply.
    ///
    /// Mixing them let a malformed answer from one route pass as a valid empty
    /// listing in another's shape: `api/cron/jobs` returns a bare array, and a
    /// `{}` from it used to read as "no routines" because the legacy
    /// envelope's tolerance was applied to it.
    enum BodyShape: Sendable {
        /// `api/cron/jobs?profile=all` — a bare JSON array.
        case array
        /// The web UI's `api/crons` — `{"jobs": [...]}`.
        case legacyEnvelope
    }

    static func rows(from data: Data, shape: BodyShape) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.unreadable
        }
        switch shape {
        case .array:
            guard let rows = object as? [[String: Any]] else { throw Failure.unreadable }
            return rows
        case .legacyEnvelope:
            if let rows = object as? [[String: Any]] { return rows }
            guard let map = object as? [String: Any] else { throw Failure.unreadable }
            for key in ["jobs", "items", "data", "results"] {
                if let rows = map[key] as? [[String: Any]] { return rows }
            }
            throw Failure.unreadable
        }
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

/// The part of Hermes Bot Mode metadata Alice understands.
///
/// Hermes persists this namespace in `profile.yaml` as
/// `ui_meta["hermes-bots"]`.  Every field is optional on purpose: an old
/// profile with no Bot Mode metadata is still a perfectly valid legacy bot,
/// and `nil` is different from an explicit `false` when Alice migrates an old
/// local preference onto the profile.
struct BotMetadata: Hashable, Sendable, Codable {
    var title: String? = nil
    var description: String? = nil
    var hidden: Bool? = nil
    var pinned: Bool? = nil
    var sectionID: String? = nil
    var color: String? = nil
    var custom: Bool? = nil
    var groups: [String]? = nil
    var group: String? = nil
    var imageKind: String? = nil
    var shape: String? = nil
    var created: Double? = nil
    var revision: Int = 0
    var present: Bool = false
}

/// A Hermes profile as Alice's bot roster sees it.
///
/// Named profiles are the compatibility boundary used by Hermes Bot Mode: new
/// profiles carry `hermes-bots` metadata, while profiles created before Bot
/// Mode may not.  Alice deliberately keeps those legacy named profiles in the
/// roster.  The one exception is the installation's `is_default` profile —
/// that is Alice/Home and never a secondary bot.
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
    var metadata: BotMetadata = .init()

    var hidden: Bool { metadata.hidden ?? false }
    var pinned: Bool { metadata.pinned ?? false }
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
        return try Self.bots(from: object, active: active)
    }

    /// The profiles body as bots.
    ///
    /// `GET /api/profiles` always answers `{"profiles": [...]}`, falling back
    /// to a directory scan rather than to a body without the key. One without
    /// it is malformed, and reading it as [] used to put "no bots" on screen
    /// for an agent that has four.
    static func bots(from object: [String: Any], active: String?) throws -> [BotRow] {
        guard let rows = object["profiles"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let bots: [BotRow] = rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }

            let uiMeta = row["ui_meta"] as? [String: Any]
            let rawMeta = uiMeta?["hermes-bots"] as? [String: Any]
            let revisions = row["ui_meta_revisions"] as? [String: Any]
            let revision = Self.int(revisions?["hermes-bots"]) ?? 0
            let metaTitle = Self.nonEmpty(rawMeta?["title"] as? String)
            let profileDisplayName = Self.nonEmpty(row["display_name"] as? String)
            let rowTitle = Self.nonEmpty(row["title"] as? String)
            let metaDescription = Self.nonEmpty(rawMeta?["description"] as? String)
            let profileDescription = (row["description"] as? String) ?? ""

            return BotRow(
                name: name,
                // Same identity order as Hermes Bot Mode: a Bot Mode title
                // wins, then the profile's presentation name, then a row title
                // from older gateways, finally the canonical profile id.
                displayName: metaTitle ?? profileDisplayName ?? rowTitle ?? name,
                detail: metaDescription ?? profileDescription,
                model: row["model"] as? String,
                provider: row["provider"] as? String,
                skills: Self.int(row["skill_count"]) ?? 0,
                isDefault: (row["is_default"] as? Bool) ?? false,
                gatewayRunning: (row["gateway_running"] as? Bool) ?? false,
                active: name == active,
                metadata: BotMetadata(
                    title: metaTitle,
                    description: metaDescription,
                    hidden: rawMeta?["hidden"] as? Bool,
                    pinned: rawMeta?["pinned"] as? Bool,
                    sectionID: Self.nonEmpty(rawMeta?["sectionId"] as? String),
                    color: Self.nonEmpty(rawMeta?["color"] as? String),
                    custom: rawMeta?["custom"] as? Bool,
                    groups: rawMeta?["groups"] as? [String],
                    group: Self.nonEmpty(rawMeta?["group"] as? String),
                    imageKind: Self.nonEmpty(rawMeta?["imageKind"] as? String),
                    shape: Self.nonEmpty(rawMeta?["shape"] as? String),
                    created: Self.double(rawMeta?["created"]),
                    revision: revision,
                    present: rawMeta != nil
                )
            )
        }
        // Rows arrived and none of them had a name: a shape problem, not an
        // agent without bots.
        if !rows.isEmpty && bots.isEmpty { throw Failure.unreadable }
        return bots
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    /// Where the dashboard lives, for callers that must build their own URL —
    /// the WebSocket, which cannot be expressed as a path on this client.
    var baseURL: URL? { credentials?.url }

    /// A single-use ticket for the JSON-RPC WebSocket.
    ///
    /// A WebSocket upgrade cannot carry an Authorization header, so the agent
    /// mints a thirty-second, single-use ticket for an already-authenticated
    /// session and the socket presents it in the query. This reuses the
    /// dashboard login Alice already has — the password stays in the Keychain
    /// where `connectDashboard` put it, and never reaches the socket layer,
    /// a URL, a log or a preference.
    func webSocketTicket() async throws -> String {
        let object = try await send("POST", "api/auth/ws-ticket", nil)
        guard let ticket = object["ticket"] as? String, !ticket.isEmpty else {
            throw Failure.unreadable
        }
        return ticket
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

    func setModel(_ name: String, provider: String, model: String) async throws {
        try await send(
            "PUT", "api/profiles/\(name)/model",
            ["provider": provider, "model": model]
        )
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
        try await Self.routines(reading: self)
    }

    /// One route per contract, in the order they should be tried.
    static let routeContracts: [(path: String, shape: BodyShape, ownership: Ownership)] = [
        ("api/cron/jobs?profile=all", .array, .canonical),
        ("api/crons?all_profiles=1", .legacyEnvelope, .legacyWebUI),
    ]

    /// The listing, from whichever route answers.
    ///
    /// A route that answers is the answer, empty included. The fallback exists
    /// for an agent that does not serve the canonical route at all — a 404 —
    /// not for one that serves it and has nothing to report. Trying the legacy
    /// route after a valid canonical `[]` and taking its rows would replace a
    /// true answer with an older contract's.
    static func routines(
        reading reader: DashboardRowReading
    ) async throws -> [String: [JobRow]] {
        var lastFailure: Error?

        for contract in routeContracts {
            let found: [[String: Any]]
            do {
                found = try await reader.rows(contract.path, shape: contract.shape).rows
            } catch {
                // Only an absent route is a reason to try an older one.
                if let failure = error as? Failure,
                   case let .http(status, _) = failure, status == 404 {
                    lastFailure = failure
                    continue
                }
                throw error
            }

            let grouped = group(found, ownership: contract.ownership)
            // Rows arrived and none of them could be placed. That is a shape
            // problem; reporting it as an agent with no routines would put a
            // parse failure on screen as a fact about the bots.
            if !found.isEmpty && grouped.isEmpty { throw Failure.unreadable }
            return grouped
        }

        throw lastFailure ?? Failure.unreadable
    }

    /// Cron rows keyed by the bot that owns them.
    ///
    /// The key has to be the profile's own name, because that is what
    /// `routines(for:)` is asked for and what `BotRow.name` holds — a bot
    /// carries a separate `displayName` for the screen. A row keyed by
    /// anything else is a routine no one can find, which is the shape the
    /// original bug took.
    /// Which field on a row says whose routine it is, which is not the same
    /// question on every route.
    enum Ownership: Sendable {
        /// `api/cron/jobs`. `_annotate_cron_job` sets `profile` and
        /// `profile_name` to one canonical profile name and sends no
        /// `owner_profile`; a row carrying one that disagrees is two contracts
        /// mixed, and picking either would attribute a real routine to a bot
        /// that may not own it.
        case canonical
        /// The web UI's listing, where `owner_profile` is documented as the
        /// profile home the row came from and the persisted `profile` says
        /// where the job executes — so they may differ by design.
        case legacyWebUI
    }

    static func group(
        _ rows: [[String: Any]], ownership: Ownership
    ) -> [String: [JobRow]] {
        var grouped: [String: [JobRow]] = [:]
        for row in rows {
            guard let owner = owner(of: row, ownership: ownership),
                  var job = HermesClient.jobRow(from: row)
            else { continue }
            job.profile = owner
            grouped[owner, default: []].append(job)
        }
        return grouped
    }

    private static func owner(
        of row: [String: Any], ownership: Ownership
    ) -> String? {
        func text(_ key: String) -> String? {
            guard let value = row[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        switch ownership {
        case .canonical:
            // `profile` is the canonical name `_cron_profile_home` resolved,
            // so it wins outright — a `profile_name` that differs is a display
            // name from another surface, and the slug is what a bot is looked
            // up by. Rejecting the row over that disagreement would hide a
            // routine whose owner is perfectly well known.
            //
            // `owner_profile` is different: this route never sends it, so a
            // row carrying one that disagrees is two contracts mixed, and
            // there is no demonstrated rule saying which wins. Filing it under
            // either would attribute a real routine to a bot that may not own
            // it, so it is not filed at all.
            guard let name = text("profile") ?? text("profile_name") else { return nil }
            if let owner = text("owner_profile"), owner != name { return nil }
            return name
        case .legacyWebUI:
            return text("owner_profile") ?? text("profile") ?? text("profile_name")
        }
    }

    /// Creates a scheduled job owned by one bot.
    ///
    /// `schedule` is a plain string and the profile is a query parameter; the
    /// body has no field for it. That keeps the routine in the selected
    /// profile's isolated cron store.
    func createRoutine(
        for profile: String, name: String, prompt: String, schedule: String,
        deliver: String = "local"
    ) async throws {
        let scoped = Self.queryValue(profile)
        try await send("POST", "api/cron/jobs?profile=\(scoped)", [
            "name": name,
            "prompt": prompt,
            "schedule": schedule,
            "deliver": deliver,
            "enabled": true,
        ])
    }

    /// Edit only the routine fields Alice owns. Hermes merges these into the
    /// stored job, so advanced fields (skills, toolsets, model, scripts, etc.)
    /// survive an edit made on the phone.
    func updateRoutine(
        _ id: String, profile: String, name: String, prompt: String,
        schedule: String, deliver: String
    ) async throws {
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        try await send("PUT", "api/cron/jobs/\(job)?profile=\(scoped)", [
            "updates": [
                "name": name, "prompt": prompt, "schedule": schedule, "deliver": deliver,
            ],
        ])
    }

    func pauseRoutine(_ id: String, profile: String) async throws {
        try await routineAction("pause", id: id, profile: profile)
    }

    func resumeRoutine(_ id: String, profile: String) async throws {
        try await routineAction("resume", id: id, profile: profile)
    }

    func triggerRoutine(_ id: String, profile: String) async throws {
        try await routineAction("trigger", id: id, profile: profile)
    }

    func deleteRoutine(_ id: String, profile: String) async throws {
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        try await send("DELETE", "api/cron/jobs/\(job)?profile=\(scoped)")
    }

    private func routineAction(_ action: String, id: String, profile: String) async throws {
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        try await send("POST", "api/cron/jobs/\(job)/\(action)?profile=\(scoped)")
    }

    func routineRuns(_ id: String, profile: String, limit: Int = 20) async throws -> [RoutineRun] {
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        let object = try await get(
            "api/cron/jobs/\(job)/runs?profile=\(scoped)&limit=\(max(1, min(limit, 100)))"
        )
        return try Self.routineRuns(from: object)
    }

    static func routineRuns(from object: [String: Any]) throws -> [RoutineRun] {
        guard let rows = object["runs"] as? [[String: Any]] else { throw Failure.unreadable }
        let parsed = rows.compactMap { row -> RoutineRun? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let cost = (row["actual_cost_usd"] as? NSNumber)?.doubleValue
                ?? (row["estimated_cost_usd"] as? NSNumber)?.doubleValue
                ?? row["actual_cost_usd"] as? Double
                ?? row["estimated_cost_usd"] as? Double
            return RoutineRun(
                id: id,
                title: (row["title"] as? String) ?? id,
                preview: (row["preview"] as? String) ?? "",
                startedAt: HermesClient.date(row["started_at"]),
                endedAt: HermesClient.date(row["ended_at"]),
                endReason: (row["end_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                model: (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                inputTokens: HermesClient.int(row["input_tokens"]) ?? 0,
                outputTokens: HermesClient.int(row["output_tokens"]) ?? 0,
                cost: cost,
                isActive: (row["is_active"] as? Bool) ?? false
            )
        }
        if !rows.isEmpty && parsed.isEmpty { throw Failure.unreadable }
        return parsed
    }

    func routineDeliveryTargets() async throws -> [RoutineDeliveryTarget] {
        try Self.deliveryTargets(from: await get("api/cron/delivery-targets"))
    }

    /// The scheduler interprets wall-clock expressions in the owning profile's
    /// Hermes timezone. Empty means the Hermes host's local timezone.
    func routineTimezone(for profile: String) async throws -> String {
        let config = try await get("api/config?profile=\(Self.queryValue(profile))")
        return (config["timezone"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func deliveryTargets(from object: [String: Any]) throws -> [RoutineDeliveryTarget] {
        guard let rows = object["targets"] as? [[String: Any]] else { throw Failure.unreadable }
        let parsed = rows.compactMap { row -> RoutineDeliveryTarget? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return RoutineDeliveryTarget(
                id: id,
                name: (row["name"] as? String) ?? id,
                homeTargetSet: (row["home_target_set"] as? Bool) ?? (id == "local")
            )
        }
        if !rows.isEmpty && parsed.isEmpty { throw Failure.unreadable }
        return parsed
    }

    private static func queryValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    private static func pathSegment(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
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

/// A JSON `data` array crossing an isolation boundary.
///
/// `[[String: Any]]` is not `Sendable`, but what `JSONSerialization` puts in
/// one is: value types all the way down, freshly made per read and handed on
/// without being kept. The wrapper carries that promise explicitly rather than
/// spreading `@unchecked` over every signature.
struct JSONRows: @unchecked Sendable {
    let rows: [[String: Any]]
    init(_ rows: [[String: Any]]) { self.rows = rows }
}

/// Reads one listing body. `DashboardClient` in the app; a stub in tests, so
/// the order routes are tried in can be checked without a server.
protocol DashboardRowReading: Sendable {
    func rows(
        _ path: String, shape: DashboardClient.BodyShape
    ) async throws -> JSONRows
}

extension DashboardClient: DashboardRowReading {}
