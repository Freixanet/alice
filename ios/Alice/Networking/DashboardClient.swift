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

/// One folder that belongs to a first-class Hermes project.
struct ProjectFolder: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var label: String?
    var isPrimary: Bool
    var added: Date?
}

/// A first-class Hermes project. Projects are per-profile workspaces, not
/// arbitrary chat folders: sessions belong to one when their cwd sits under
/// one of these folders.
struct NamedProject: Identifiable, Hashable, Sendable {
    let id: String
    var slug: String
    var name: String
    var detail: String
    var icon: String?
    var colour: String?
    var board: String?
    var primaryPath: String?
    var created: Date?
    var archived: Bool
    var folders: [ProjectFolder]
}

/// One project node from Hermes' authoritative session tree. `isAuto` means
/// the workspace was inferred from session cwd/repository data rather than
/// created as a named Project.
struct ProjectRow: Identifiable, Hashable, Sendable {
    let id: String
    var label: String
    var path: String?
    var sessions: Int
    var tokens: Int
    var lastActive: Date?
    var isAuto: Bool = false
    var isHome: Bool = false
    var colour: String? = nil
    var profile: String? = nil
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

/// The curated built-in memory actually injected by Hermes into future
/// sessions. `user` maps to USER.md and `memory` maps to MEMORY.md.
struct MemoryTarget: Identifiable, Hashable, Sendable {
    let id: String
    var label: String
    var enabled: Bool
    var entries: [String]
    var used: Int
    var limit: Int
}

struct MemorySnapshot: Hashable, Sendable {
    var profile: String
    var provider: String
    var targets: [MemoryTarget]
}

/// What the agent has spent, as the dashboard totals it.
struct UsageReport: Sendable {
    struct Model: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        var provider: String?
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int = 0
        var reasoningTokens: Int = 0
        var estimatedCost: Double = 0
        var actualCost: Double = 0
        var sessions: Int
        var calls: Int
        var tokens: Int { inputTokens + outputTokens }
        var cost: Double { actualCost > 0 ? actualCost : estimatedCost }
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
    var cacheReadTokens: Int = 0
    var reasoningTokens: Int = 0
    var cost: Double
    var models: [Model]
    var tools: [Tool]
    var tokens: Int { inputTokens + outputTokens }
}


/// The configured model Hermes will use for new sessions in one profile.
struct ProfileModelInfo: Hashable, Sendable {
    struct Capabilities: Hashable, Sendable {
        var tools = false
        var vision = false
        var reasoning = false
        var contextWindow = 0
        var maxOutputTokens = 0
        var family = ""
    }

    var model = ""
    var provider = ""
    var autoContextLength = 0
    var configuredContextLength = 0
    var effectiveContextLength = 0
    var capabilities = Capabilities()
}

/// One provider row from Hermes' own model inventory. Unconfigured providers
/// stay present so Alice can explain how to connect them instead of hiding
/// them and pretending the model does not exist.
struct InferenceProvider: Identifiable, Hashable, Sendable {
    var id: String { slug }
    var slug: String
    var name: String
    var models: [String]
    var totalModels: Int
    var authenticated: Bool
    var isCurrent: Bool
    var isUserDefined: Bool
    var source: String
    var warning: String
}

struct OAuthProviderState: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var flow: String
    var loggedIn: Bool
    var source: String
    var expiresAt: String
    var error: String
    var cliCommand: String
    var docsURL: String
    var disconnectable: Bool
    var disconnectHint: String
}

struct ProviderCredential: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var provider: String
    var providerLabel: String
    var detail: String
    var url: String
    var isSet: Bool
    var redactedValue: String
    var isPassword: Bool
    var advanced: Bool
}

struct CredentialValidation: Hashable, Sendable {
    var ok: Bool
    var reachable: Bool
    var message: String
}

struct OAuthLogin: Hashable, Sendable {
    var provider: String
    var sessionID: String
    var flow: String
    var userCode: String
    var verificationURL: String
    var expiresIn: Int
    var pollInterval: Int
}

struct OAuthPoll: Hashable, Sendable {
    var status: String
    var error: String
}

struct ModelAssignmentResult: Hashable, Sendable {
    struct StaleAux: Hashable, Sendable {
        var task: String
        var provider: String
        var model: String
    }
    var ok: Bool
    var confirmRequired: Bool
    var confirmMessage: String
    var provider: String
    var model: String
    var staleAux: [StaleAux]
}

/// Small, deliberately curated subset of config.yaml. Alice writes only these
/// keys back; every other Hermes setting survives untouched.
struct HermesConfiguration: Hashable, Sendable {
    var timezone = ""
    var approvalsMode = "smart"
    var serviceTier = ""
    var memoryEnabled = true
    var userProfileEnabled = true
    var compressionEnabled = true
    var compressionThreshold = 0.5
    var verifyGuidance = true
    var environmentProbe = true
}

struct BillingUsage: Hashable, Sendable {
    struct Bar: Hashable, Sendable {
        var kind = ""
        var remaining = ""
        var total = ""
        var spent = ""
        var percentUsed = 0.0
        var fillFraction = 0.0
    }
    var available = false
    var status = ""
    var planName = ""
    var renews = ""
    var subscriptionRemaining = ""
    var topupRemaining = ""
    var totalSpendable = ""
    var planBar: Bar?
    var topupBar: Bar?
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

    static func projectRows(
        from object: [String: Any], profile: String? = nil
    ) throws -> [ProjectRow] {
        guard let rows = object["projects"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let parsed = rows.compactMap { row -> ProjectRow? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ProjectRow(
                id: id,
                label: (row["label"] as? String) ?? (row["name"] as? String) ?? id,
                path: row["path"] as? String,
                sessions: Self.int(row["sessionCount"]) ?? 0,
                tokens: Self.int(row["totalTokens"]) ?? 0,
                lastActive: Self.double(row["lastActive"])
                    .map(Date.init(timeIntervalSince1970:)),
                isAuto: (row["isAuto"] as? Bool) ?? false,
                isHome: (row["isNoProject"] as? Bool) ?? false,
                colour: row["color"] as? String,
                profile: profile
            )
        }
        if !rows.isEmpty && parsed.isEmpty { throw Failure.unreadable }
        return parsed
    }

    static func namedProjects(from object: [String: Any]) throws -> [NamedProject] {
        guard let rows = object["projects"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let parsed = rows.compactMap { row -> NamedProject? in
            guard let id = (row["id"] as? String) ?? (row["project_id"] as? String),
                  !id.isEmpty else { return nil }
            let folders = (row["folders"] as? [[String: Any]] ?? []).compactMap { folder -> ProjectFolder? in
                guard let path = folder["path"] as? String, !path.isEmpty else { return nil }
                return ProjectFolder(
                    path: path,
                    label: Self.nonEmpty(folder["label"] as? String),
                    isPrimary: (folder["is_primary"] as? Bool)
                        ?? ((folder["is_primary"] as? NSNumber)?.boolValue ?? false),
                    added: Self.double(folder["added_at"])
                        .map(Date.init(timeIntervalSince1970:))
                )
            }
            let name = (row["name"] as? String) ?? id
            return NamedProject(
                id: id,
                slug: (row["slug"] as? String) ?? id,
                name: name,
                detail: (row["description"] as? String) ?? "",
                icon: Self.nonEmpty(row["icon"] as? String),
                colour: Self.nonEmpty(row["color"] as? String),
                board: Self.nonEmpty(row["board_slug"] as? String),
                primaryPath: Self.nonEmpty(row["primary_path"] as? String)
                    ?? folders.first(where: { $0.isPrimary })?.path
                    ?? folders.first?.path,
                created: Self.double(row["created_at"])
                    .map(Date.init(timeIntervalSince1970:)),
                archived: (row["archived"] as? Bool)
                    ?? ((row["archived"] as? NSNumber)?.boolValue ?? false),
                folders: folders
            )
        }
        if !rows.isEmpty && parsed.isEmpty { throw Failure.unreadable }
        return parsed
    }

    static func memorySnapshot(
        from object: [String: Any], profile: String
    ) throws -> MemorySnapshot {
        guard let rawTargets = object["targets"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let targets = rawTargets.compactMap { row -> MemoryTarget? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return MemoryTarget(
                id: id,
                label: (row["label"] as? String) ?? id.capitalized,
                enabled: (row["enabled"] as? Bool) ?? true,
                entries: (row["entries"] as? [String]) ?? [],
                used: Self.int(row["used"]) ?? 0,
                limit: Self.int(row["limit"]) ?? 0
            )
        }
        if !rawTargets.isEmpty && targets.isEmpty { throw Failure.unreadable }
        return MemorySnapshot(
            profile: profile,
            provider: (object["provider"] as? String) ?? "",
            targets: targets
        )
    }

    /// Cross-profile session-tree overview. Mutating first-class Projects uses
    /// the profile-scoped JSON-RPC surface in AppStore; the old REST mutation
    /// endpoints no longer exist in current Hermes.
    func projects() async throws -> [ProjectRow] {
        try Self.projectRows(from: try await get("api/profiles/projects/tree"))
    }

    /// Legacy read retained for older dashboards. Current Alice uses
    /// `projects.list` over the authenticated dashboard WebSocket instead.
    func namedProjects() async throws -> [NamedProject] {
        try Self.namedProjects(from: try await get("api/projects"))
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


    func profileModelInfo(profile: String) async throws -> ProfileModelInfo {
        let object = try await get("api/model/info?profile=\(Self.queryValue(profile))")
        return Self.profileModelInfo(from: object)
    }

    static func profileModelInfo(from object: [String: Any]) -> ProfileModelInfo {
        let caps = object["capabilities"] as? [String: Any] ?? [:]
        return ProfileModelInfo(
            model: object["model"] as? String ?? "",
            provider: object["provider"] as? String ?? "",
            autoContextLength: int(object["auto_context_length"]) ?? 0,
            configuredContextLength: int(object["config_context_length"]) ?? 0,
            effectiveContextLength: int(object["effective_context_length"]) ?? 0,
            capabilities: .init(
                tools: (caps["supports_tools"] as? Bool) ?? false,
                vision: (caps["supports_vision"] as? Bool) ?? false,
                reasoning: (caps["supports_reasoning"] as? Bool) ?? false,
                contextWindow: int(caps["context_window"]) ?? 0,
                maxOutputTokens: int(caps["max_output_tokens"]) ?? 0,
                family: caps["model_family"] as? String ?? ""
            )
        )
    }

    func inferenceProviders(profile: String, refreshing: Bool = false) async throws -> [InferenceProvider] {
        var path = "api/model/options?profile=\(Self.queryValue(profile))&include_unconfigured=1"
        if refreshing { path += "&refresh=1" }
        return Self.inferenceProviders(from: try await get(path))
    }

    static func inferenceProviders(from object: [String: Any]) -> [InferenceProvider] {
        let rows = object["providers"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let slug = nonEmpty(row["slug"] as? String) else { return nil }
            let unavailable = Set(row["unavailable_models"] as? [String] ?? [])
            let models = (row["models"] as? [Any] ?? []).compactMap { item -> String? in
                if let value = item as? String { return value }
                if let map = item as? [String: Any] {
                    return nonEmpty((map["id"] as? String) ?? (map["name"] as? String))
                }
                return nil
            }.filter { !unavailable.contains($0) }
            return InferenceProvider(
                slug: slug,
                name: nonEmpty(row["name"] as? String) ?? HermesClient.prettify(slug),
                models: models,
                totalModels: int(row["total_models"]) ?? models.count,
                authenticated: (row["authenticated"] as? Bool) ?? false,
                isCurrent: (row["is_current"] as? Bool) ?? false,
                isUserDefined: (row["is_user_defined"] as? Bool) ?? false,
                source: row["source"] as? String ?? "",
                warning: row["warning"] as? String ?? ""
            )
        }
    }

    func oauthProviderStates(profile: String) async throws -> [OAuthProviderState] {
        let object = try await get("api/providers/oauth?profile=\(Self.queryValue(profile))")
        return Self.oauthProviderStates(from: object)
    }

    static func oauthProviderStates(from object: [String: Any]) -> [OAuthProviderState] {
        (object["providers"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = nonEmpty(row["id"] as? String) else { return nil }
            let status = row["status"] as? [String: Any] ?? [:]
            return OAuthProviderState(
                id: id,
                name: nonEmpty(row["name"] as? String) ?? HermesClient.prettify(id),
                flow: row["flow"] as? String ?? "external",
                loggedIn: (status["logged_in"] as? Bool) ?? false,
                source: (status["source_label"] as? String) ?? (status["source"] as? String) ?? "",
                expiresAt: status["expires_at"] as? String ?? "",
                error: status["error"] as? String ?? "",
                cliCommand: row["cli_command"] as? String ?? "",
                docsURL: row["docs_url"] as? String ?? "",
                disconnectable: (row["disconnectable"] as? Bool) ?? false,
                disconnectHint: row["disconnect_hint"] as? String ?? ""
            )
        }
    }

    func providerCredentials(profile: String) async throws -> [ProviderCredential] {
        Self.providerCredentials(from: try await get("api/env?profile=\(Self.queryValue(profile))"))
    }

    static func providerCredentials(from object: [String: Any]) -> [ProviderCredential] {
        object.compactMap { key, raw -> ProviderCredential? in
            guard let row = raw as? [String: Any],
                  (row["category"] as? String) == "provider",
                  (row["channel_managed"] as? Bool) != true
            else { return nil }
            let provider = row["provider"] as? String ?? ""
            guard !provider.isEmpty else { return nil }
            return ProviderCredential(
                key: key,
                provider: provider,
                providerLabel: row["provider_label"] as? String ?? HermesClient.prettify(provider),
                detail: row["description"] as? String ?? "",
                url: row["url"] as? String ?? "",
                isSet: (row["is_set"] as? Bool) ?? false,
                redactedValue: row["redacted_value"] as? String ?? "",
                isPassword: (row["is_password"] as? Bool) ?? true,
                advanced: (row["advanced"] as? Bool) ?? false
            )
        }.sorted {
            if $0.provider == $1.provider { return $0.key < $1.key }
            return $0.provider < $1.provider
        }
    }

    func setMainModel(
        profile: String, provider: String, model: String, confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        let object = try await send(
            "POST", "api/model/set?profile=\(Self.queryValue(profile))",
            [
                "scope": "main", "provider": provider, "model": model,
                "confirm_expensive_model": confirmExpensive,
            ]
        )
        return Self.modelAssignmentResult(from: object)
    }

    static func modelAssignmentResult(from object: [String: Any]) -> ModelAssignmentResult {
        let stale = (object["stale_aux"] as? [[String: Any]] ?? []).map {
            ModelAssignmentResult.StaleAux(
                task: $0["task"] as? String ?? "",
                provider: $0["provider"] as? String ?? "",
                model: $0["model"] as? String ?? ""
            )
        }
        return ModelAssignmentResult(
            ok: (object["ok"] as? Bool) ?? false,
            confirmRequired: (object["confirm_required"] as? Bool) ?? false,
            confirmMessage: object["confirm_message"] as? String ?? "",
            provider: object["provider"] as? String ?? "",
            model: object["model"] as? String ?? "",
            staleAux: stale
        )
    }

    func validateProviderCredential(key: String, value: String) async throws -> CredentialValidation {
        let object = try await send("POST", "api/providers/validate", ["key": key, "value": value])
        return CredentialValidation(
            ok: (object["ok"] as? Bool) ?? false,
            reachable: (object["reachable"] as? Bool) ?? false,
            message: object["message"] as? String ?? ""
        )
    }

    func saveProviderCredential(profile: String, key: String, value: String) async throws {
        _ = try await send(
            "PUT", "api/env?profile=\(Self.queryValue(profile))",
            ["key": key, "value": value, "profile": profile]
        )
    }

    func removeProviderCredential(profile: String, key: String) async throws {
        _ = try await send(
            "DELETE", "api/env?profile=\(Self.queryValue(profile))",
            ["key": key, "profile": profile]
        )
    }

    func startOAuthLogin(provider: String, profile: String) async throws -> OAuthLogin {
        let object = try await send(
            "POST", "api/providers/oauth/\(Self.pathSegment(provider))/start?profile=\(Self.queryValue(profile))",
            [:]
        )
        return OAuthLogin(
            provider: provider,
            sessionID: object["session_id"] as? String ?? "",
            flow: object["flow"] as? String ?? "",
            userCode: object["user_code"] as? String ?? "",
            verificationURL: object["verification_url"] as? String ?? "",
            expiresIn: Self.int(object["expires_in"]) ?? 900,
            pollInterval: max(1, Self.int(object["poll_interval"]) ?? 5)
        )
    }

    func pollOAuth(provider: String, sessionID: String, profile: String) async throws -> OAuthPoll {
        let object = try await get(
            "api/providers/oauth/\(Self.pathSegment(provider))/poll/\(Self.pathSegment(sessionID))?profile=\(Self.queryValue(profile))"
        )
        return OAuthPoll(
            status: object["status"] as? String ?? "error",
            error: object["error_message"] as? String ?? ""
        )
    }

    func cancelOAuth(sessionID: String, profile: String) async throws {
        _ = try await send(
            "DELETE", "api/providers/oauth/sessions/\(Self.pathSegment(sessionID))?profile=\(Self.queryValue(profile))"
        )
    }

    func disconnectOAuth(provider: String, profile: String) async throws {
        _ = try await send(
            "DELETE", "api/providers/oauth/\(Self.pathSegment(provider))?profile=\(Self.queryValue(profile))"
        )
    }

    func hermesConfiguration(profile: String) async throws -> HermesConfiguration {
        Self.hermesConfiguration(from: try await get("api/config?profile=\(Self.queryValue(profile))"))
    }

    static func hermesConfiguration(from object: [String: Any]) -> HermesConfiguration {
        let approvals = object["approvals"] as? [String: Any] ?? [:]
        let agent = object["agent"] as? [String: Any] ?? [:]
        let memory = object["memory"] as? [String: Any] ?? [:]
        let compression = object["compression"] as? [String: Any] ?? [:]
        return HermesConfiguration(
            timezone: object["timezone"] as? String ?? "",
            approvalsMode: approvals["mode"] as? String ?? "smart",
            serviceTier: agent["service_tier"] as? String ?? "",
            memoryEnabled: (memory["memory_enabled"] as? Bool) ?? true,
            userProfileEnabled: (memory["user_profile_enabled"] as? Bool) ?? true,
            compressionEnabled: (compression["enabled"] as? Bool) ?? true,
            compressionThreshold: double(compression["threshold"]) ?? 0.5,
            verifyGuidance: (agent["verify_guidance"] as? Bool) ?? true,
            environmentProbe: (agent["environment_probe"] as? Bool) ?? true
        )
    }

    func saveHermesConfiguration(_ config: HermesConfiguration, profile: String) async throws {
        let body: [String: Any] = [
            "config": [
                "timezone": config.timezone,
                "approvals": ["mode": config.approvalsMode],
                "agent": [
                    "service_tier": config.serviceTier,
                    "verify_guidance": config.verifyGuidance,
                    "environment_probe": config.environmentProbe,
                ],
                "memory": [
                    "memory_enabled": config.memoryEnabled,
                    "user_profile_enabled": config.userProfileEnabled,
                ],
                "compression": [
                    "enabled": config.compressionEnabled,
                    "threshold": config.compressionThreshold,
                ],
            ]
        ]
        _ = try await send("PUT", "api/config?profile=\(Self.queryValue(profile))", body)
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

    func usage(profile: String = "default", days: Int = 30) async throws -> UsageReport {
        let safeDays = min(365, max(1, days))
        let object = try await get(
            "api/analytics/usage?days=\(safeDays)&profile=\(Self.queryValue(profile))"
        )
        let modelObject = try? await get(
            "api/analytics/models?days=\(safeDays)&profile=\(Self.queryValue(profile))"
        )
        return Self.usageReport(from: object, modelObject: modelObject, days: safeDays)
    }

    static func usageReport(
        from object: [String: Any], modelObject: [String: Any]? = nil, days: Int = 30
    ) -> UsageReport {
        let totals = (object["totals"] as? [String: Any]) ?? [:]
        let modelRows = (modelObject?["models"] as? [[String: Any]])
            ?? (object["by_model"] as? [[String: Any]]) ?? []
        let models = modelRows.compactMap { row -> UsageReport.Model? in
            guard let name = row["model"] as? String, !name.isEmpty else { return nil }
            return UsageReport.Model(
                name: name,
                provider: (row["provider"] as? String) ?? (row["billing_provider"] as? String),
                inputTokens: int(row["input_tokens"]) ?? 0,
                outputTokens: int(row["output_tokens"]) ?? 0,
                cacheReadTokens: int(row["cache_read_tokens"]) ?? 0,
                reasoningTokens: int(row["reasoning_tokens"]) ?? 0,
                estimatedCost: double(row["estimated_cost"]) ?? 0,
                actualCost: double(row["actual_cost"]) ?? 0,
                sessions: int(row["sessions"]) ?? 0,
                calls: int(row["api_calls"]) ?? 0
            )
        }
        let tools = ((object["tools"] as? [[String: Any]]) ?? []).compactMap { row -> UsageReport.Tool? in
            guard let name = (row["tool"] as? String) ?? (row["name"] as? String) else { return nil }
            let count = int(row["count"]) ?? int(row["total_count"]) ?? 0
            let percentage = double(row["percentage"]) ?? 0
            return UsageReport.Tool(name: name, count: count, share: percentage / 100)
        }
        return UsageReport(
            days: int(object["period_days"]) ?? days,
            sessions: int(totals["total_sessions"]) ?? 0,
            calls: int(totals["total_api_calls"]) ?? 0,
            inputTokens: int(totals["total_input"]) ?? 0,
            outputTokens: int(totals["total_output"]) ?? 0,
            cacheReadTokens: int(totals["total_cache_read"]) ?? 0,
            reasoningTokens: int(totals["total_reasoning"]) ?? 0,
            cost: {
                let actual = double(totals["total_actual_cost"]) ?? 0
                return actual > 0 ? actual : (double(totals["total_estimated_cost"]) ?? 0)
            }(),
            models: models.sorted { $0.tokens > $1.tokens },
            tools: tools.sorted { $0.count > $1.count }
        )
    }

    static func billingUsage(from object: [String: Any]) -> BillingUsage {
        func bar(_ raw: Any?) -> BillingUsage.Bar? {
            guard let row = raw as? [String: Any] else { return nil }
            return BillingUsage.Bar(
                kind: row["kind"] as? String ?? "",
                remaining: row["remaining_display"] as? String ?? "",
                total: row["total_display"] as? String ?? "",
                spent: row["spent_display"] as? String ?? "",
                percentUsed: double(row["pct_used"]) ?? 0,
                fillFraction: double(row["fill_fraction"]) ?? 0
            )
        }
        return BillingUsage(
            available: (object["available"] as? Bool) ?? false,
            status: object["status"] as? String ?? "",
            planName: object["plan_name"] as? String ?? "",
            renews: object["renews_display"] as? String ?? "",
            subscriptionRemaining: object["subscription_remaining_display"] as? String ?? "",
            topupRemaining: object["topup_remaining_display"] as? String ?? "",
            totalSpendable: object["total_spendable_display"] as? String ?? "",
            planBar: bar(object["plan_bar"]),
            topupBar: bar(object["topup_bar"])
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
