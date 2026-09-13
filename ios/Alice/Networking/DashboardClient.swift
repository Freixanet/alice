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
        /// Reached, but it did not answer in time. Not the same as unreachable:
        /// some requests are answered only when the work is done.
        case timedOut
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
            case .timedOut:
                "The dashboard took too long to answer."
            case .unreadable:
                "The dashboard sent something this app could not read."
            }
        }
    }

    private var credentials: Credentials?
    private var signedIn = false
    /// Bumped every time a login succeeds. A caller that met a 401 hands back
    /// the age of the session it used; if the session has already been
    /// replaced since, there is nothing left to re-establish.
    private var sessionAge = 0
    /// The login in flight, if any, so concurrent callers wait on one attempt
    /// instead of each starting their own.
    private var signInTask: Task<Int, Error>?

    /// Its own session so the login cookie is kept here and nowhere else.
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            config.timeoutIntervalForRequest = 15
            return URLSession(configuration: config)
        }()
    }

    func use(_ credentials: Credentials?) {
        self.credentials = credentials
        signedIn = false
        signInTask?.cancel()
        signInTask = nil
        sessionAge += 1
    }

    var isConfigured: Bool { credentials != nil }

    /// Reads an object, signing in first and once more if the session has
    /// lapsed — they are stateless and do not survive the agent restarting.
    func get(_ path: String) async throws -> [String: Any] {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return try await fetch(path)
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
            return try await fetch(path)
        }
    }

    /// Some dashboard routes — notably current Hermes' cron list — return a
    /// top-level JSON array rather than an object. Keep that shape instead of
    /// coercing it to an empty dictionary and making the UI say "no routines".
    func rows(_ path: String, shape: BodyShape) async throws -> JSONRows {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return JSONRows(try await fetchRows(path, shape: shape))
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
            return JSONRows(try await fetchRows(path, shape: shape))
        }
    }

    /// Establishes a dashboard session, at most one attempt at a time, and
    /// reports the age of the session the caller may now use.
    ///
    /// Hermes throttles `auth/password-login` to ten attempts a minute per
    /// address and counts the successful ones too. Every entry point here
    /// used to test `signedIn` and then await the login, and an actor lets
    /// the next call in at that await — so one screen fanning six requests
    /// out in parallel sent six logins, and a lapsed session sent six more on
    /// the way back. Two such screens inside a minute spent the whole budget
    /// and locked the phone out of its own dashboard with a 429.
    ///
    /// Pass `replacing:` after a 401 to force a fresh login — unless someone
    /// else has already replaced that session, in which case the caller
    /// should simply retry against theirs.
    @discardableResult
    private func authenticate(replacing stale: Int? = nil) async throws -> Int {
        if let stale {
            if stale != sessionAge { return sessionAge }
            signedIn = false
        } else if signedIn {
            return sessionAge
        }
        if let inFlight = signInTask { return try await inFlight.value }

        let task = Task<Int, Error> {
            try await performSignIn()
            return markSignedIn()
        }
        signInTask = task
        defer { if signInTask == task { signInTask = nil } }
        return try await task.value
    }

    private func markSignedIn() -> Int {
        signedIn = true
        sessionAge += 1
        return sessionAge
    }

    private func performSignIn() async throws {
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
        case 200..<300: return
        case 401, 403, 422: throw Failure.rejected
        // The throttle Hermes puts on the login route. Say so, because the
        // remedy is to wait rather than to check the password again.
        case 429: throw Failure.http(429, detail: "Too many sign-ins. Try again in a minute.")
        default: throw Failure.http(http.statusCode)
        }
    }

    /// Writes go through the same signed-in session as reads.
    @discardableResult
    func send(
        _ method: String, _ path: String, _ body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return try await fetch(path, method: method, body: body)
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
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
        // An empty body is a real answer from a route that returns nothing.
        // Anything else must be the object it claims to be: reading a JSON
        // array — or an HTML error page a proxy answered 200 with — as an
        // empty dictionary made every listing built from it report that the
        // agent has nothing, which is a different statement entirely.
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.unreadable
        }
        guard let fields = object as? [String: Any] else { throw Failure.unreadable }
        return fields
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // A screen went away mid-request. That is not the dashboard
            // failing to answer, and a dismissed view must not leave an error
            // behind saying it was.
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            // "Did not answer — it only listens on your own network" was said
            // to someone on their own network whose request had simply outlasted
            // the wait: Hermes answers "run now" only once the run is over.
            throw Failure.timedOut
        } catch {
            throw Failure.unreachable
        }
    }

    /// Authenticated raw transport for binary downloads and multipart uploads.
    /// JSON routes continue through `get`/`send`; this exists only where the
    /// dashboard response is intentionally not a JSON object. Internal so
    /// feature-specific extensions can reuse the exact dashboard auth/session.
    func raw(
        _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return try await fetchRaw(method, path, body: body, contentType: contentType)
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
            return try await fetchRaw(method, path, body: body, contentType: contentType)
        }
    }

    /// Authenticated upload from a file-backed request body. This keeps large
    /// multipart transfers off the heap and reuses the same session cookies as
    /// every other dashboard request.
    func rawUpload(
        _ method: String, _ path: String, bodyFile: URL, contentType: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return try await fetchRawUpload(method, path, bodyFile: bodyFile, contentType: contentType)
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
            return try await fetchRawUpload(method, path, bodyFile: bodyFile, contentType: contentType)
        }
    }

    private func fetchRawUpload(
        _ method: String, _ path: String, bodyFile: URL, contentType: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard let credentials, let url = Self.url(credentials.url, path) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, detail: Self.detail(from: data))
        }
        return (data, http)
    }

    /// Authenticated file download. URLSession writes the response to disk so
    /// downloading a large remote file does not first allocate its full size
    /// in Alice's process.
    func rawDownload(_ path: String) async throws -> (URL, HTTPURLResponse) {
        guard credentials != nil else { throw Failure.notConfigured }
        let age = try await authenticate()
        do {
            return try await fetchRawDownload(path)
        } catch Failure.http(401, _) {
            _ = try await authenticate(replacing: age)
            return try await fetchRawDownload(path)
        }
    }

    private func fetchRawDownload(_ path: String) async throws -> (URL, HTTPURLResponse) {
        guard let credentials, let url = Self.url(credentials.url, path) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Failure.http(http.statusCode, detail: Self.detail(from: data))
        }
        return (temporaryURL, http)
    }

    private func fetchRaw(
        _ method: String, _ path: String, body: Data?, contentType: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let credentials, let url = Self.url(credentials.url, path) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, detail: Self.detail(from: data))
        }
        return (data, http)
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

struct MemoryProviderExternalDependency: Identifiable, Hashable, Sendable {
    var id: String { name + "|" + install + "|" + check }
    var name: String
    var install: String
    var check: String
}

struct MemoryProviderSetupInfo: Hashable, Sendable {
    var pipDependencies: [String]
    var externalDependencies: [MemoryProviderExternalDependency]
    var requiredEnvironment: [String]
    var dependenciesInstalled: Bool
}

struct MemoryProviderStatusSnapshot: Hashable, Sendable {
    var active: String
    var providers: [MemoryProvider]
    var setup: [String: MemoryProviderSetupInfo]
    var builtinMemoryBytes: Int64
    var builtinUserBytes: Int64
}

struct MemoryProviderFieldOption: Identifiable, Hashable, Sendable {
    var id: String { value }
    var value: String
    var label: String
    var detail: String
}

struct MemoryProviderField: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var label: String
    var kind: String
    var detail: String
    var info: String
    var placeholder: String
    var required: Bool
    var value: String
    var isSet: Bool
    var options: [MemoryProviderFieldOption]
    var url: String
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var when: [String: String]
    var inline: Bool
    var group: String

    var isSecret: Bool { kind == "secret" }
}

struct MemoryProviderConfiguration: Hashable, Sendable {
    var name: String
    var label: String
    var docsURL: String
    var surface: String
    var fields: [MemoryProviderField]
    var setup: MemoryProviderSetupInfo?
}

struct MemoryProviderSetupResult: Identifiable, Hashable, Sendable {
    var id: String { kind + "|" + name + "|" + command }
    var kind: String
    var name: String
    var status: String
    var command: String
    var returnCode: Int?
    var stdout: String
    var stderr: String
}

struct MemoryProviderSetupResponse: Hashable, Sendable {
    var ok: Bool
    var provider: String
    var results: [MemoryProviderSetupResult]
}

struct MemoryProviderOAuthStatus: Hashable, Sendable {
    var state: String
    var detail: String
    var connected: Bool
    var auth: String?
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

struct AuxiliaryModelAssignment: Identifiable, Hashable, Sendable {
    var id: String { task }
    var task: String
    var provider: String
    var model: String
    var baseURL: String

    var isAutomatic: Bool { provider.isEmpty || provider.lowercased() == "auto" }
}

struct AuxiliaryModelsSnapshot: Hashable, Sendable {
    var mainProvider: String
    var mainModel: String
    var tasks: [AuxiliaryModelAssignment]
}

struct RecommendedModelDefault: Hashable, Sendable {
    var provider: String
    var model: String
    var freeTier: Bool?
}

struct MoAModelSlot: Hashable, Sendable {
    var provider: String
    var model: String
    var reasoningEffort: String?
    var enabled: Bool
}

struct MoAPreset: Hashable, Sendable {
    var referenceModels: [MoAModelSlot]
    var aggregator: MoAModelSlot
    var referenceTemperature: Double?
    var aggregatorTemperature: Double?
    var referenceTimeout: Double?
    var degradedReferencePolicy: String
    var maxTokens: Int
    var referenceMaxTokens: Int?
    var fanout: String?
    var enabled: Bool
}

struct MoAConfiguration: Sendable {
    var defaultPreset: String
    var activePreset: String
    var presets: [String: MoAPreset]
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

/// A file or directory exposed by Hermes' managed Files surface. The server
/// applies its own root and sensitive-file policy; Alice never bypasses it.
struct ManagedRemoteFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int?
    var modified: Date?
    var mimeType: String?
}

struct ManagedFilesListing: Hashable, Sendable {
    var root: String?
    var path: String
    var parent: String?
    var lockedRoot: String?
    var canChangePath: Bool
    var entries: [ManagedRemoteFile]
}

struct ManagedFileContents: Hashable, Sendable {
    var name: String
    var path: String
    var size: Int
    var mimeType: String
    var data: Data
}

/// One configurable credential exposed by Hermes for a messaging channel.
struct MessagingEnvField: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var required: Bool
    var isSet: Bool
    var redactedValue: String?
    var detail: String
    var prompt: String
    var help: String
    var docsURL: String?
    var isPassword: Bool
    var advanced: Bool
}

struct MessagingHomeChannel: Hashable, Sendable {
    var platform: String
    var chatID: String
    var name: String
    var threadID: String?
}

/// A gateway messaging adapter exactly as Hermes reports it. The list is
/// dynamic so new upstream adapters appear in Alice without an app update.
struct MessagingPlatform: Identifiable, Hashable, Sendable {
    struct WhatsAppSetup: Hashable, Sendable {
        var mode: String
        var allowedUsersSet: Bool
        var homeChannelSet: Bool
    }

    var id: String
    var name: String
    var detail: String
    var docsURL: String
    var enabled: Bool
    var configured: Bool
    var gatewayRunning: Bool
    var state: String
    var errorCode: String?
    var errorMessage: String?
    var updatedAt: String?
    var homeChannel: MessagingHomeChannel?
    var whatsappSetup: WhatsAppSetup?
    var envVars: [MessagingEnvField]
}

struct MessagingPlatformsSnapshot: Hashable, Sendable {
    var envPath: String
    var gatewayStartCommand: String
    var platforms: [MessagingPlatform]
}

struct MessagingPlatformTestResult: Hashable, Sendable {
    var ok: Bool
    var state: String
    var message: String
}

struct TelegramOnboardingStart: Hashable, Sendable {
    var pairingID: String
    var suggestedUsername: String
    var deepLink: String
    var qrPayload: String
    var expiresAt: String
}

struct TelegramOnboardingStatus: Hashable, Sendable {
    var status: String
    var expiresAt: String
    var botUsername: String?
    var ownerUserID: String?
}

struct ChannelApplyResult: Hashable, Sendable {
    var ok: Bool
    var platform: String
    var needsRestart: Bool
    var restartStarted: Bool
    var restartError: String?
    var botUsername: String?
}

struct WhatsAppOnboardingSession: Hashable, Sendable {
    var pairingID: String
    var status: String
    var qrPayload: String?
    var expiresAt: String
    var mode: String
    var allowedUsers: String
    var accountID: String?
    var accountName: String?
    var accountPhone: String?
    var error: String?
}

struct GatewayActionResult: Hashable, Sendable {
    var ok: Bool
    var pid: Int?
    var name: String
}


struct MCPServerConfiguration: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var transport: String
    var url: String?
    var command: String?
    var args: [String]
    /// Values are intentionally redacted by Hermes. Alice never treats them
    /// as reusable secrets or writes them back implicitly.
    var env: [String: String]
    var auth: String?
    var enabled: Bool
    var tools: [String]?
}

struct MCPToolInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var detail: String
    var schemaCharacters: Int?
}

struct MCPServerTestResult: Hashable, Sendable {
    var ok: Bool
    var error: String?
    var tools: [MCPToolInfo]
    var prompts: Int
    var resources: Int
}

struct MCPCatalogEnvField: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var prompt: String
    var required: Bool
}

struct MCPCatalogEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var detail: String
    var source: String
    var transport: String
    var authType: String
    var requiredEnv: [MCPCatalogEnvField]
    var command: String?
    var args: [String]
    var url: String?
    var installURL: String?
    var installRef: String?
    var bootstrap: [String]
    var defaultEnabledTools: [String]?
    var postInstall: String
    var needsInstall: Bool
    var installed: Bool
    var enabled: Bool
}

struct MCPCatalogDiagnostic: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(kind)|\(message)" }
    var name: String
    var kind: String
    var message: String
}

struct MCPCatalogSnapshot: Hashable, Sendable {
    var entries: [MCPCatalogEntry]
    var diagnostics: [MCPCatalogDiagnostic]
}

struct MCPOAuthFlow: Hashable, Sendable {
    var flowID: String
    var serverName: String
    var status: String
    var authorizationURL: String?
    var error: String?
    var tools: [MCPToolInfo]
}

struct MCPCatalogInstallResult: Hashable, Sendable {
    var ok: Bool
    var name: String
    var background: Bool
    var action: String?
}

/// One machine-global webhook subscription. Hermes never returns its HMAC
/// secret from list calls; `secretSet` only says whether one exists.
struct WebhookSubscription: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var detail: String
    var events: [String]
    var deliver: String
    var deliverOnly: Bool
    var deliverChatID: String?
    var prompt: String
    var script: String
    var skills: [String]
    var createdAt: String?
    var url: String
    var secretSet: Bool
    var enabled: Bool
}

struct WebhooksSnapshot: Hashable, Sendable {
    var enabled: Bool
    var baseURL: String
    var subscriptions: [WebhookSubscription]
}

struct WebhookEnableResult: Hashable, Sendable {
    var ok: Bool
    var enabled: Bool
    var needsRestart: Bool
    var restartStarted: Bool
    var restartAction: String?
    var restartPID: Int?
    var restartError: String?
}

/// Create is the only response that contains the route secret. Alice keeps it
/// only in the presenting sheet so it can be copied once, never in app state.
struct WebhookCreation: Hashable, Sendable {
    var subscription: WebhookSubscription
    var secret: String
}

struct HermesHealthStatus: Hashable, Sendable {
    var ok: Bool
    var version: String
    var authRequired: Bool
}

struct HermesSystemComponent: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var status: String
    var state: String?
    var configured: Int?
    var connected: Int?
}

/// One messaging channel as Hermes' gateway last recorded it.
///
/// `/api/status` rolls these up into a single "platforms: degraded", which
/// cannot say which channel is broken. The per-channel map beside it can, and
/// the machine-wide reading folds in assistants that run their own gateway
/// under `<profile>:<platform>`.
struct HermesPlatformHealth: Hashable, Sendable {
    var key: String
    var profile: String
    var platform: String
    var state: String
    var errorCode: String?
    var errorMessage: String?

    /// Hermes' own list of healthy platform states (`_HEALTHY_PLATFORM_STATES`).
    var isHealthy: Bool { ["connected", "running", "ok"].contains(state) }
}

struct HermesSystemStatus: Hashable, Sendable {
    var version: String
    var releaseDate: String
    var overall: String
    var gatewayRunning: Bool
    var gatewayState: String
    var gatewayExitReason: String?
    var gatewayUpdatedAt: String?
    var activeSessions: Int
    var activeAgents: Int
    var gatewayBusy: Bool
    var gatewayDrainable: Bool
    var authRequired: Bool
    var canUpdateHermes: Bool
    var profiles: [String]
    var gatewayMode: String
    var memoryPressure: String
    var diskPressure: String
    var diskUsedPercent: Double?
    var components: [HermesSystemComponent]
    var platforms: [HermesPlatformHealth] = []
}

struct HermesSystemStats: Hashable, Sendable {
    struct Resource: Hashable, Sendable {
        var total: Int64
        var used: Int64
        var free: Int64
        var percent: Double
    }
    var os: String
    var osRelease: String
    var platform: String
    var arch: String
    var hostname: String
    var pythonVersion: String
    var pythonImplementation: String
    var hermesVersion: String
    var cpuCount: Int?
    var cpuPercent: Double?
    var loadAverage: [Double]
    var uptimeSeconds: Int?
    var memory: Resource?
    var disk: Resource?
    var psutil: Bool
}

struct HermesActionStart: Hashable, Sendable {
    var ok: Bool
    var pid: Int?
    var name: String
    var archive: String?
}

struct HermesActionStatus: Hashable, Sendable {
    var name: String
    var running: Bool
    var exitCode: Int?
    var pid: Int?
    var lines: [String]
}

struct HermesCheckpointSession: Identifiable, Hashable, Sendable {
    var id: String { session }
    var session: String
    var files: Int
    var bytes: Int64
}

struct HermesCheckpoints: Hashable, Sendable {
    var sessions: [HermesCheckpointSession]
    var totalBytes: Int64
}

struct HermesLogSnapshot: Hashable, Sendable {
    var file: String
    var lines: [String]
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
        let object = try await get("api/profiles/\(Self.pathSegment(name))/soul")
        return ((object["content"] as? String) ?? "", (object["exists"] as? Bool) ?? false)
    }

    func setSoul(_ name: String, _ content: String) async throws {
        try await send("PUT", "api/profiles/\(Self.pathSegment(name))/soul", ["content": content])
    }

    func setDescription(_ name: String, _ text: String) async throws {
        try await send("PUT", "api/profiles/\(Self.pathSegment(name))/description", ["description": text])
    }

    func setModel(_ name: String, provider: String, model: String) async throws {
        try await send(
            "PUT", "api/profiles/\(Self.pathSegment(name))/model",
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
        try await send("DELETE", "api/profiles/\(Self.pathSegment(name))")
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

    /// Gives an automation a model of its own.
    ///
    /// One without follows the assistant's default, and Hermes refuses to run
    /// it once that default has changed — `[drift_skip]` — until the parts that
    /// changed are fixed. Only the parts given are sent; Hermes merges them
    /// into the stored job.
    func pinRoutineModel(
        _ id: String, profile: String, provider: String?, model: String?
    ) async throws {
        var updates: [String: Any] = [:]
        if let provider, !provider.isEmpty { updates["provider"] = provider }
        if let model, !model.isEmpty { updates["model"] = model }
        guard !updates.isEmpty else { throw Failure.unreadable }
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        try await send("PUT", "api/cron/jobs/\(job)?profile=\(scoped)", ["updates": updates])
    }

    /// Releases an automation's model pin, so it follows its assistant's model
    /// again. Hermes stores an empty value as no pin.
    func followProfileModel(_ id: String, profile: String) async throws {
        let scoped = Self.queryValue(profile)
        let job = Self.pathSegment(id)
        try await send(
            "PUT", "api/cron/jobs/\(job)?profile=\(scoped)",
            ["updates": ["provider": "", "model": ""]]
        )
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
        // `.urlQueryAllowed` permits the separators, so a value carrying one
        // would arrive as a second parameter — or, for "+", as a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func pathSegment(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Writes the bot out as a shareable template and reports where it landed.
    func exportBot(_ name: String) async throws -> String? {
        let object = try await send("POST", "api/profiles/\(Self.pathSegment(name))/export", [:])
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
        return (object["archive"] as? String) ?? (object["path"] as? String) ?? (object["file"] as? String)
    }

    func rename(_ name: String, to newName: String) async throws {
        try await send("PATCH", "api/profiles/\(Self.pathSegment(name))", ["new_name": newName])
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

    /// Every skill in a profile, with the state the agent actually holds.
    ///
    /// The gateway's `/v1/skills` is a name-and-description listing: it does
    /// not say which skills are switched off, so a catalogue built from it can
    /// only leave the switches out. The dashboard's listing carries `enabled`,
    /// and is scoped to a profile, which is what this screen is about.
    ///
    /// The route answers with a bare JSON array, so it is read as rows rather
    /// than through `get`.
    func skills(profile: String?) async throws -> [CatalogRow] {
        var path = "api/skills"
        if let profile, !profile.isEmpty {
            path += "?profile=\(Self.queryValue(profile))"
        }
        return HermesClient.parseCatalog(
            try await rows(path, shape: .array).rows, kind: .skill
        )
    }

    /// Switches a skill on or off for a profile.
    func setSkillEnabled(_ name: String, enabled: Bool, profile: String?) async throws {
        var body: [String: Any] = ["name": name, "enabled": enabled]
        if let profile, !profile.isEmpty { body["profile"] = profile }
        _ = try await send("PUT", "api/skills/toggle", body)
    }

    /// A skill is its `SKILL.md`, frontmatter and all — so that is what is
    /// read and what is written back. Anything cleverer would be this app
    /// deciding what a skill may say.
    func skillContent(_ name: String, profile: String? = nil) async throws -> String {
        var path = "api/skills/content?name=\(Self.queryValue(name))"
        if let profile, !profile.isEmpty {
            path += "&profile=\(Self.queryValue(profile))"
        }
        let object = try await get(path)
        guard let content = object["content"] as? String else {
            throw Failure.http(404)
        }
        return content
    }

    /// Writes a skill back.
    ///
    /// Hermes separates the two writes: creating a skill goes through the
    /// agent's own `skill_manage` path, which builds the directory, while
    /// editing one replaces the `SKILL.md` of a skill that already exists.
    /// Sending an edit to the create route makes a second skill; sending a
    /// creation to the edit route is a 404. So the caller says which it is.
    func saveSkill(
        name: String, content: String, isNew: Bool, profile: String? = nil
    ) async throws {
        var body: [String: Any] = ["name": name, "content": content]
        if let profile, !profile.isEmpty { body["profile"] = profile }
        if isNew {
            _ = try await send("POST", "api/skills", body)
        } else {
            _ = try await send("PUT", "api/skills/content", body)
        }
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
        profile: String, provider: String, model: String,
        baseURL: String = "", apiKey: String = "", confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        let object = try await send(
            "POST", "api/model/set?profile=\(Self.queryValue(profile))",
            Self.modelAssignmentBody(
                scope: "main", provider: provider, model: model,
                baseURL: baseURL, apiKey: apiKey, confirmExpensive: confirmExpensive
            )
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

    static func modelAssignmentBody(
        scope: String, provider: String, model: String, task: String = "",
        baseURL: String = "", apiKey: String = "", confirmExpensive: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "scope": scope, "provider": provider, "model": model,
            "task": task, "confirm_expensive_model": confirmExpensive,
        ]
        if !baseURL.isEmpty { body["base_url"] = baseURL }
        if !apiKey.isEmpty { body["api_key"] = apiKey }
        return body
    }

    func auxiliaryModels(profile: String) async throws -> AuxiliaryModelsSnapshot {
        try Self.auxiliaryModels(
            from: await get("api/model/auxiliary?profile=\(Self.queryValue(profile))")
        )
    }

    static func auxiliaryModels(from object: [String: Any]) throws -> AuxiliaryModelsSnapshot {
        guard let rows = object["tasks"] as? [[String: Any]],
              let main = object["main"] as? [String: Any]
        else { throw Failure.unreadable }
        let tasks = try rows.map { row -> AuxiliaryModelAssignment in
            guard let task = nonEmpty(row["task"] as? String),
                  let provider = row["provider"] as? String,
                  let model = row["model"] as? String,
                  let baseURL = row["base_url"] as? String
            else { throw Failure.unreadable }
            return .init(task: task, provider: provider, model: model, baseURL: baseURL)
        }
        return .init(
            mainProvider: main["provider"] as? String ?? "",
            mainModel: main["model"] as? String ?? "",
            tasks: tasks
        )
    }

    func setAuxiliaryModel(
        profile: String, task: String, provider: String, model: String,
        baseURL: String = "", apiKey: String = "", confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        let object = try await send(
            "POST", "api/model/set?profile=\(Self.queryValue(profile))",
            Self.modelAssignmentBody(
                scope: "auxiliary", provider: provider, model: model, task: task,
                baseURL: baseURL, apiKey: apiKey, confirmExpensive: confirmExpensive
            )
        )
        return Self.modelAssignmentResult(from: object)
    }

    func resetAuxiliaryModels(profile: String) async throws -> ModelAssignmentResult {
        try await setAuxiliaryModel(
            profile: profile, task: "__reset__", provider: "auto", model: ""
        )
    }

    func recommendedModelDefault(provider: String) async throws -> RecommendedModelDefault {
        try Self.recommendedModelDefault(
            from: await get("api/model/recommended-default?provider=\(Self.queryValue(provider))")
        )
    }

    static func recommendedModelDefault(from object: [String: Any]) throws -> RecommendedModelDefault {
        guard let provider = object["provider"] as? String,
              let model = object["model"] as? String
        else { throw Failure.unreadable }
        return .init(provider: provider, model: model, freeTier: object["free_tier"] as? Bool)
    }

    func moaConfiguration(profile: String) async throws -> MoAConfiguration {
        try Self.moaConfiguration(
            from: await get("api/model/moa?profile=\(Self.queryValue(profile))")
        )
    }

    static func moaConfiguration(from object: [String: Any]) throws -> MoAConfiguration {
        guard let defaultPreset = object["default_preset"] as? String,
              let activePreset = object["active_preset"] as? String,
              let rawPresets = object["presets"] as? [String: Any]
        else { throw Failure.unreadable }
        var presets: [String: MoAPreset] = [:]
        for (name, raw) in rawPresets {
            guard let row = raw as? [String: Any] else { throw Failure.unreadable }
            presets[name] = try Self.moaPreset(from: row)
        }
        guard !presets.isEmpty else { throw Failure.unreadable }
        return .init(defaultPreset: defaultPreset, activePreset: activePreset, presets: presets)
    }

    private static func moaPreset(from row: [String: Any]) throws -> MoAPreset {
        guard let refs = row["reference_models"] as? [[String: Any]],
              let aggregator = row["aggregator"] as? [String: Any],
              let policy = row["degraded_reference_policy"] as? String,
              let maxTokens = int(row["max_tokens"]),
              let enabled = row["enabled"] as? Bool
        else { throw Failure.unreadable }
        return .init(
            referenceModels: try refs.map(Self.moaSlot(from:)),
            aggregator: try Self.moaSlot(from: aggregator),
            referenceTemperature: double(row["reference_temperature"]),
            aggregatorTemperature: double(row["aggregator_temperature"]),
            referenceTimeout: double(row["reference_timeout"]),
            degradedReferencePolicy: policy,
            maxTokens: maxTokens,
            referenceMaxTokens: int(row["reference_max_tokens"]),
            fanout: nonEmpty(row["fanout"] as? String),
            enabled: enabled
        )
    }

    private static func moaSlot(from row: [String: Any]) throws -> MoAModelSlot {
        guard let provider = row["provider"] as? String,
              let model = row["model"] as? String
        else { throw Failure.unreadable }
        return .init(
            provider: provider, model: model,
            reasoningEffort: nonEmpty(row["reasoning_effort"] as? String),
            enabled: (row["enabled"] as? Bool) ?? true
        )
    }

    static func moaBody(_ config: MoAConfiguration, profile: String) -> [String: Any] {
        var presets: [String: Any] = [:]
        for (name, preset) in config.presets { presets[name] = moaPresetBody(preset) }
        return [
            "default_preset": config.defaultPreset,
            "active_preset": config.activePreset,
            "presets": presets,
            "profile": profile,
        ]
    }

    private static func moaPresetBody(_ preset: MoAPreset) -> [String: Any] {
        [
            "reference_models": preset.referenceModels.map(moaSlotBody),
            "aggregator": moaSlotBody(preset.aggregator),
            "reference_temperature": preset.referenceTemperature ?? NSNull(),
            "aggregator_temperature": preset.aggregatorTemperature ?? NSNull(),
            "reference_timeout": preset.referenceTimeout ?? NSNull(),
            "degraded_reference_policy": preset.degradedReferencePolicy,
            "max_tokens": preset.maxTokens,
            "reference_max_tokens": preset.referenceMaxTokens ?? NSNull(),
            "fanout": preset.fanout ?? NSNull(),
            "enabled": preset.enabled,
        ]
    }

    private static func moaSlotBody(_ slot: MoAModelSlot) -> [String: Any] {
        var body: [String: Any] = [
            "provider": slot.provider, "model": slot.model, "enabled": slot.enabled,
        ]
        if let effort = nonEmpty(slot.reasoningEffort) { body["reasoning_effort"] = effort }
        return body
    }

    func saveMoAConfiguration(_ config: MoAConfiguration, profile: String) async throws -> MoAConfiguration {
        let object = try await send(
            "PUT", "api/model/moa?profile=\(Self.queryValue(profile))",
            Self.moaBody(config, profile: profile)
        )
        return try Self.moaConfiguration(from: object)
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
        try await memoryProviderStatus().providers
    }

    func memoryProviderStatus() async throws -> MemoryProviderStatusSnapshot {
        try Self.memoryProviderStatus(from: await get("api/memory"))
    }

    static func memoryProviderStatus(from object: [String: Any]) throws -> MemoryProviderStatusSnapshot {
        guard let active = object["active"] as? String,
              let rows = object["providers"] as? [[String: Any]],
              let builtin = object["builtin_files"] as? [String: Any] else { throw Failure.unreadable }
        var providers: [MemoryProvider] = []
        var setup: [String: MemoryProviderSetupInfo] = [:]
        for row in rows {
            guard let name = nonEmpty(row["name"] as? String),
                  let status = row["status"] as? String,
                  let available = row["available"] as? Bool,
                  let configured = row["configured"] as? Bool else { throw Failure.unreadable }
            providers.append(MemoryProvider(
                name: name, detail: row["description"] as? String ?? "", status: status,
                available: available, configured: configured, active: name == active
            ))
            if let rawSetup = row["setup"] as? [String: Any] {
                setup[name] = try memorySetupInfo(from: rawSetup)
            }
        }
        return MemoryProviderStatusSnapshot(
            active: active, providers: providers, setup: setup,
            builtinMemoryBytes: Int64(int(builtin["memory"]) ?? 0),
            builtinUserBytes: Int64(int(builtin["user"]) ?? 0)
        )
    }

    func memoryProviderConfiguration(_ name: String, profile: String) async throws -> MemoryProviderConfiguration {
        let path = "api/memory/providers/\(Self.pathSegment(name))/config?profile=\(Self.queryValue(profile))"
        return try Self.memoryProviderConfiguration(from: await get(path), surface: "legacy")
    }

    static func memoryProviderConfiguration(
        from object: [String: Any], surface: String
    ) throws -> MemoryProviderConfiguration {
        guard let name = object["name"] as? String, !name.isEmpty,
              let label = object["label"] as? String,
              let rows = object["fields"] as? [[String: Any]] else { throw Failure.unreadable }
        let parsed = try rows.map { row -> MemoryProviderField in
            guard let key = nonEmpty(row["key"] as? String),
                  let fieldLabel = row["label"] as? String,
                  let kind = row["kind"] as? String,
                  let isSet = row["is_set"] as? Bool else { throw Failure.unreadable }
            let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> MemoryProviderFieldOption? in
                guard let value = option["value"] as? String else { return nil }
                return .init(value: value, label: option["label"] as? String ?? value, detail: option["description"] as? String ?? "")
            }
            let when = (row["when"] as? [String: Any] ?? [:]).mapValues(Self.memoryFieldString)
            return MemoryProviderField(
                key: key, label: fieldLabel, kind: kind == "bool" ? "boolean" : kind,
                detail: row["description"] as? String ?? "", info: row["info"] as? String ?? "",
                placeholder: row["placeholder"] as? String ?? "", required: row["required"] as? Bool ?? false,
                value: memoryFieldString(row["value"]), isSet: isSet, options: options,
                url: row["url"] as? String ?? "", minimum: double(row["minimum"]), maximum: double(row["maximum"]),
                step: double(row["step"]), when: when, inline: row["inline"] as? Bool ?? false,
                group: row["group"] as? String ?? ""
            )
        }
        // Hermes 0.21.0 can emit the same legacy schema key twice (currently
        // Hindsight repeats api_key/api_url). SwiftUI Identifiable rows and
        // Dictionary(uniqueKeysWithValues:) both require uniqueness. Keep the
        // original order and let the later server row win for that key.
        var fields: [MemoryProviderField] = []
        var fieldIndex: [String: Int] = [:]
        for field in parsed {
            if let index = fieldIndex[field.key] {
                fields[index] = field
            } else {
                fieldIndex[field.key] = fields.count
                fields.append(field)
            }
        }
        let setup = try (object["setup"] as? [String: Any]).map(memorySetupInfo(from:))
        return MemoryProviderConfiguration(
            name: name, label: label, docsURL: object["docs_url"] as? String ?? "",
            surface: surface, fields: fields, setup: setup
        )
    }

    private static func memoryFieldString(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) { return string }
        return String(describing: value)
    }

    static func memorySetupInfo(from object: [String: Any]) throws -> MemoryProviderSetupInfo {
        guard let pip = object["pip_dependencies"] as? [String],
              let externalRows = object["external_dependencies"] as? [[String: Any]],
              let required = object["required_env"] as? [String],
              let installed = object["dependencies_installed"] as? Bool else { throw Failure.unreadable }
        let external = try externalRows.map { row -> MemoryProviderExternalDependency in
            guard let name = row["name"] as? String, let install = row["install"] as? String,
                  let check = row["check"] as? String else { throw Failure.unreadable }
            return .init(name: name, install: install, check: check)
        }
        return .init(pipDependencies: pip, externalDependencies: external, requiredEnvironment: required, dependenciesInstalled: installed)
    }

    func saveMemoryProviderConfiguration(
        _ name: String, profile: String, surface: String, values: [String: String]
    ) async throws {
        var path = "api/memory/providers/\(Self.pathSegment(name))/config?profile=\(Self.queryValue(profile))"
        if surface == "declared" { path += "&surface=declared" }
        _ = try await send("PUT", path, ["values": values])
    }

    func activateMemoryProvider(_ name: String, profile: String) async throws {
        _ = try await send(
            "PUT", "api/memory/providers/\(Self.pathSegment(name))/config?profile=\(Self.queryValue(profile))",
            ["values": [String: String]()]
        )
    }

    func useBuiltinMemoryProvider(profile: String) async throws {
        _ = try await send("PUT", "api/config?profile=\(Self.queryValue(profile))", [
            "config": ["memory": ["provider": ""]]
        ])
    }

    func setupMemoryProvider(_ name: String) async throws -> MemoryProviderSetupResponse {
        let object = try await send(
            "POST", "api/memory/providers/\(Self.pathSegment(name))/setup", ["values": [String: String]()]
        )
        return try Self.memoryProviderSetupResponse(from: object)
    }

    static func memoryProviderSetupResponse(from object: [String: Any]) throws -> MemoryProviderSetupResponse {
        guard let ok = object["ok"] as? Bool, let provider = object["provider"] as? String,
              let rows = object["results"] as? [[String: Any]] else { throw Failure.unreadable }
        let results = try rows.map { row -> MemoryProviderSetupResult in
            guard let kind = row["kind"] as? String, let name = row["name"] as? String,
                  let status = row["status"] as? String, let command = row["command"] as? String,
                  let stdout = row["stdout"] as? String, let stderr = row["stderr"] as? String else { throw Failure.unreadable }
            return .init(
                kind: kind, name: name, status: status, command: command, returnCode: int(row["returncode"]),
                stdout: stdout, stderr: stderr
            )
        }
        return .init(ok: ok, provider: provider, results: results)
    }

    func memoryProviderOAuthStatus(_ name: String, profile: String) async throws -> MemoryProviderOAuthStatus? {
        do {
            return try Self.memoryProviderOAuthStatus(from: await get(
                "api/memory/providers/\(Self.pathSegment(name))/oauth/status?profile=\(Self.queryValue(profile))"
            ))
        } catch Failure.http(404, _) {
            return nil
        }
    }

    func startMemoryProviderOAuth(_ name: String, profile: String) async throws -> MemoryProviderOAuthStatus {
        try Self.memoryProviderOAuthStatus(from: await send(
            "POST", "api/memory/providers/\(Self.pathSegment(name))/oauth/start?profile=\(Self.queryValue(profile))", [:]
        ))
    }

    static func memoryProviderOAuthStatus(from object: [String: Any]) throws -> MemoryProviderOAuthStatus {
        guard let state = object["state"] as? String, let connected = object["connected"] as? Bool else { throw Failure.unreadable }
        return .init(state: state, detail: object["detail"] as? String ?? "", connected: connected, auth: object["auth"] as? String)
    }

    // MARK: Managed files

    func managedFiles(path: String? = nil) async throws -> ManagedFilesListing {
        let route: String
        if let path, !path.isEmpty {
            route = "api/files?path=\(Self.fileQueryValue(path))"
        } else {
            route = "api/files"
        }
        return try Self.managedFilesListing(from: await get(route))
    }

    func managedFile(path: String) async throws -> ManagedFileContents {
        let object = try await get("api/files/read?path=\(Self.fileQueryValue(path))")
        return try Self.managedFileContents(from: object)
    }

    private static func fileQueryValue(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        // A file path is a single query value. Query separators that are legal
        // in a URL are not legal unescaped inside that value.
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    @discardableResult
    func createManagedDirectory(path: String) async throws -> ManagedRemoteFile {
        let object = try await send("POST", "api/files/mkdir", ["path": path])
        guard let row = object["entry"] as? [String: Any],
              let entry = Self.managedFileEntry(from: row) else { throw Failure.unreadable }
        return entry
    }

    @discardableResult
    func uploadManagedFile(
        path: String, data: Data, mimeType: String = "application/octet-stream", overwrite: Bool = true
    ) async throws -> ManagedRemoteFile {
        // This is the managed API's JSON upload route. It is intentionally used
        // for the Files picker here because iOS already hands Alice the bytes;
        // Hermes still enforces its configured managed-file size/root policy.
        let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        let object = try await send("POST", "api/files/upload", [
            "path": path, "data_url": dataURL, "overwrite": overwrite,
        ])
        guard let row = object["entry"] as? [String: Any],
              let entry = Self.managedFileEntry(from: row) else { throw Failure.unreadable }
        return entry
    }

    func deleteManagedFile(path: String, recursive: Bool = false) async throws {
        _ = try await send("DELETE", "api/files", ["path": path, "recursive": recursive])
    }

    static func managedFilesListing(from object: [String: Any]) throws -> ManagedFilesListing {
        guard let path = object["path"] as? String,
              let rows = object["entries"] as? [[String: Any]] else { throw Failure.unreadable }
        let entries = rows.compactMap(managedFileEntry(from:))
        if !rows.isEmpty && entries.count != rows.count { throw Failure.unreadable }
        return ManagedFilesListing(
            root: object["root"] as? String,
            path: path,
            parent: object["parent"] as? String,
            lockedRoot: object["locked_root"] as? String,
            canChangePath: object["can_change_path"] as? Bool ?? false,
            entries: entries
        )
    }

    static func managedFileEntry(from row: [String: Any]) -> ManagedRemoteFile? {
        guard let name = row["name"] as? String, !name.isEmpty,
              let path = row["path"] as? String, !path.isEmpty,
              let isDirectory = row["is_directory"] as? Bool else { return nil }
        let rawSize = int(row["size"])
        let modified = double(row["mtime"]).map { Date(timeIntervalSince1970: $0) }
        return ManagedRemoteFile(
            name: name, path: path, isDirectory: isDirectory,
            size: rawSize, modified: modified, mimeType: row["mime_type"] as? String
        )
    }

    static func managedFileContents(from object: [String: Any]) throws -> ManagedFileContents {
        guard let name = object["name"] as? String,
              let path = object["path"] as? String,
              let mimeType = object["mime_type"] as? String,
              let dataURL = object["data_url"] as? String,
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].lowercased().contains(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { throw Failure.unreadable }
        return ManagedFileContents(
            name: name, path: path, size: int(object["size"]) ?? data.count,
            mimeType: mimeType, data: data
        )
    }

    // MARK: MCP administration

    func mcpServers(profile: String = "default") async throws -> [MCPServerConfiguration] {
        let object = try await get("api/mcp/servers?profile=\(Self.queryValue(profile))")
        return try Self.mcpServers(from: object)
    }

    func mcpCatalog(profile: String = "default") async throws -> MCPCatalogSnapshot {
        let object = try await get("api/mcp/catalog?profile=\(Self.queryValue(profile))")
        return try Self.mcpCatalog(from: object)
    }

    func addMCPServer(
        name: String, profile: String = "default", url: String? = nil,
        command: String? = nil, args: [String] = [], env: [String: String] = [:],
        auth: String? = nil, bearerToken: String? = nil
    ) async throws -> MCPServerConfiguration {
        var body: [String: Any] = ["name": name, "profile": profile]
        if let url { body["url"] = url }
        if let command { body["command"] = command }
        if !args.isEmpty { body["args"] = args }
        if !env.isEmpty { body["env"] = env }
        if let auth, auth != "none" { body["auth"] = auth }
        if let bearerToken { body["bearer_token"] = bearerToken }
        let object = try await send(
            "POST", "api/mcp/servers?profile=\(Self.queryValue(profile))", body
        )
        guard let server = Self.mcpServer(from: object) else { throw Failure.unreadable }
        return server
    }

    func setMCPServerEnabled(
        _ name: String, enabled: Bool, profile: String = "default"
    ) async throws {
        _ = try await send(
            "PUT",
            "api/mcp/servers/\(Self.pathSegment(name))/enabled?profile=\(Self.queryValue(profile))",
            ["enabled": enabled, "profile": profile]
        )
    }

    func deleteMCPServer(_ name: String, profile: String = "default") async throws {
        _ = try await send(
            "DELETE", "api/mcp/servers/\(Self.pathSegment(name))?profile=\(Self.queryValue(profile))"
        )
    }

    func testMCPServer(
        _ name: String, profile: String = "default"
    ) async throws -> MCPServerTestResult {
        let object = try await send(
            "POST", "api/mcp/servers/\(Self.pathSegment(name))/test?profile=\(Self.queryValue(profile))"
        )
        return try Self.mcpTestResult(from: object)
    }

    func startMCPOAuth(
        _ name: String, profile: String = "default"
    ) async throws -> MCPOAuthFlow {
        let object = try await send(
            "POST", "api/mcp/servers/\(Self.pathSegment(name))/auth?profile=\(Self.queryValue(profile))"
        )
        return try Self.mcpOAuthFlow(from: object)
    }

    func mcpOAuthStatus(
        _ flowID: String, profile: String = "default"
    ) async throws -> MCPOAuthFlow {
        let object = try await get(
            "api/mcp/oauth/flows/\(Self.pathSegment(flowID))?profile=\(Self.queryValue(profile))"
        )
        return try Self.mcpOAuthFlow(from: object)
    }

    func cancelMCPOAuth(_ flowID: String, profile: String = "default") async throws {
        _ = try await send(
            "DELETE", "api/mcp/oauth/flows/\(Self.pathSegment(flowID))?profile=\(Self.queryValue(profile))"
        )
    }

    func installMCPCatalogEntry(
        _ name: String, env: [String: String], profile: String = "default", enable: Bool = true
    ) async throws -> MCPCatalogInstallResult {
        let object = try await send(
            "POST", "api/mcp/catalog/install?profile=\(Self.queryValue(profile))",
            ["name": name, "env": env, "enable": enable, "profile": profile]
        )
        guard let ok = object["ok"] as? Bool,
              let installedName = object["name"] as? String,
              let background = object["background"] as? Bool else { throw Failure.unreadable }
        return MCPCatalogInstallResult(
            ok: ok, name: installedName, background: background, action: object["action"] as? String
        )
    }

    static func mcpServers(from object: [String: Any]) throws -> [MCPServerConfiguration] {
        guard let rows = object["servers"] as? [[String: Any]] else { throw Failure.unreadable }
        let parsed = rows.compactMap(mcpServer(from:))
        if parsed.count != rows.count { throw Failure.unreadable }
        return parsed
    }

    static func mcpServer(from row: [String: Any]) -> MCPServerConfiguration? {
        guard let name = row["name"] as? String, !name.isEmpty,
              let transport = row["transport"] as? String, !transport.isEmpty,
              let args = row["args"] as? [String],
              let env = row["env"] as? [String: String],
              let enabled = row["enabled"] as? Bool else { return nil }
        let tools: [String]?
        if row.keys.contains("tools") {
            if row["tools"] is NSNull { tools = nil }
            else if let value = row["tools"] as? [String] { tools = value }
            else { return nil }
        } else {
            tools = nil
        }
        return MCPServerConfiguration(
            name: name, transport: transport, url: row["url"] as? String,
            command: row["command"] as? String, args: args, env: env,
            auth: row["auth"] as? String, enabled: enabled, tools: tools
        )
    }

    static func mcpTestResult(from object: [String: Any]) throws -> MCPServerTestResult {
        guard let ok = object["ok"] as? Bool,
              let rows = object["tools"] as? [[String: Any]] else { throw Failure.unreadable }
        let tools = rows.compactMap(mcpTool(from:))
        if tools.count != rows.count { throw Failure.unreadable }
        return MCPServerTestResult(
            ok: ok, error: object["error"] as? String, tools: tools,
            prompts: int(object["prompts"]) ?? 0, resources: int(object["resources"]) ?? 0
        )
    }

    static func mcpOAuthFlow(from object: [String: Any]) throws -> MCPOAuthFlow {
        guard let flowID = object["flow_id"] as? String, !flowID.isEmpty,
              let serverName = object["server_name"] as? String, !serverName.isEmpty,
              let status = object["status"] as? String, !status.isEmpty else { throw Failure.unreadable }
        let rows = (object["tools"] as? [[String: Any]]) ?? []
        let tools = rows.compactMap(mcpTool(from:))
        if tools.count != rows.count { throw Failure.unreadable }
        return MCPOAuthFlow(
            flowID: flowID, serverName: serverName, status: status,
            authorizationURL: object["authorization_url"] as? String,
            error: object["error"] as? String, tools: tools
        )
    }

    private static func mcpTool(from row: [String: Any]) -> MCPToolInfo? {
        guard let name = row["name"] as? String, !name.isEmpty else { return nil }
        return MCPToolInfo(
            name: name, detail: row["description"] as? String ?? "",
            schemaCharacters: int(row["schema_chars"])
        )
    }

    static func mcpCatalog(from object: [String: Any]) throws -> MCPCatalogSnapshot {
        guard let rows = object["entries"] as? [[String: Any]],
              let diagnosticRows = object["diagnostics"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let entries = rows.compactMap(mcpCatalogEntry(from:))
        let diagnostics = diagnosticRows.compactMap(mcpCatalogDiagnostic(from:))
        if entries.count != rows.count || diagnostics.count != diagnosticRows.count {
            throw Failure.unreadable
        }
        return MCPCatalogSnapshot(entries: entries, diagnostics: diagnostics)
    }

    static func mcpCatalogEntry(from row: [String: Any]) -> MCPCatalogEntry? {
        guard let name = row["name"] as? String, !name.isEmpty,
              let transport = row["transport"] as? String,
              let authType = row["auth_type"] as? String,
              let envRows = row["required_env"] as? [[String: Any]],
              let args = row["args"] as? [String],
              let bootstrap = row["bootstrap"] as? [String],
              let postInstall = row["post_install"] as? String,
              let needsInstall = row["needs_install"] as? Bool,
              let installed = row["installed"] as? Bool,
              let enabled = row["enabled"] as? Bool else { return nil }
        let requiredEnv = envRows.compactMap { raw -> MCPCatalogEnvField? in
            guard let envName = raw["name"] as? String, !envName.isEmpty,
                  let prompt = raw["prompt"] as? String,
                  let required = raw["required"] as? Bool else { return nil }
            return MCPCatalogEnvField(name: envName, prompt: prompt, required: required)
        }
        if requiredEnv.count != envRows.count { return nil }
        let defaultTools: [String]?
        if row.keys.contains("default_enabled") {
            if row["default_enabled"] is NSNull { defaultTools = nil }
            else if let value = row["default_enabled"] as? [String] { defaultTools = value }
            else { return nil }
        } else { defaultTools = nil }
        return MCPCatalogEntry(
            name: name, detail: row["description"] as? String ?? "",
            source: row["source"] as? String ?? "", transport: transport, authType: authType,
            requiredEnv: requiredEnv, command: row["command"] as? String, args: args,
            url: row["url"] as? String, installURL: row["install_url"] as? String,
            installRef: row["install_ref"] as? String, bootstrap: bootstrap,
            defaultEnabledTools: defaultTools, postInstall: postInstall,
            needsInstall: needsInstall, installed: installed, enabled: enabled
        )
    }

    private static func mcpCatalogDiagnostic(from row: [String: Any]) -> MCPCatalogDiagnostic? {
        guard let name = row["name"] as? String,
              let kind = row["kind"] as? String,
              let message = row["message"] as? String else { return nil }
        return MCPCatalogDiagnostic(name: name, kind: kind, message: message)
    }

    // MARK: Webhooks

    func webhooks() async throws -> WebhooksSnapshot {
        try Self.webhooks(from: await get("api/webhooks"))
    }

    func enableWebhooks() async throws -> WebhookEnableResult {
        let object = try await send("POST", "api/webhooks/enable")
        guard let ok = object["ok"] as? Bool,
              let enabled = object["enabled"] as? Bool,
              let needsRestart = object["needs_restart"] as? Bool else {
            throw Failure.unreadable
        }
        return WebhookEnableResult(
            ok: ok,
            enabled: enabled,
            needsRestart: needsRestart,
            restartStarted: object["restart_started"] as? Bool ?? false,
            restartAction: object["restart_action"] as? String,
            restartPID: Self.int(object["restart_pid"]),
            restartError: object["restart_error"] as? String
        )
    }

    func createWebhook(
        name: String,
        description: String = "",
        events: [String] = [],
        prompt: String = "",
        script: String = "",
        skills: [String] = [],
        deliver: String = "log",
        deliverOnly: Bool = false,
        deliverChatID: String = "",
        secret: String? = nil
    ) async throws -> WebhookCreation {
        let body = Self.webhookCreateBody(
            name: name,
            description: description,
            events: events,
            prompt: prompt,
            script: script,
            skills: skills,
            deliver: deliver,
            deliverOnly: deliverOnly,
            deliverChatID: deliverChatID,
            secret: secret
        )
        let object = try await send("POST", "api/webhooks", body)
        guard let returnedSecret = object["secret"] as? String, !returnedSecret.isEmpty else {
            throw Failure.unreadable
        }
        return WebhookCreation(
            subscription: try Self.webhookSubscription(from: object),
            secret: returnedSecret
        )
    }

    func setWebhookEnabled(_ name: String, enabled: Bool) async throws {
        let object = try await send(
            "PUT", "api/webhooks/\(Self.pathSegment(name))/enabled", ["enabled": enabled]
        )
        guard object["ok"] as? Bool == true,
              object["enabled"] as? Bool == enabled else { throw Failure.unreadable }
    }

    func deleteWebhook(_ name: String) async throws {
        let object = try await send("DELETE", "api/webhooks/\(Self.pathSegment(name))")
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    static func webhookCreateBody(
        name: String,
        description: String = "",
        events: [String] = [],
        prompt: String = "",
        script: String = "",
        skills: [String] = [],
        deliver: String = "log",
        deliverOnly: Bool = false,
        deliverChatID: String = "",
        secret: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "name": name,
            "events": events,
            "skills": skills,
            "deliver": deliver,
            "deliver_only": deliverOnly,
        ]
        if !description.isEmpty { body["description"] = description }
        if !prompt.isEmpty { body["prompt"] = prompt }
        if !script.isEmpty { body["script"] = script }
        if !deliverChatID.isEmpty { body["deliver_chat_id"] = deliverChatID }
        if let secret, !secret.isEmpty { body["secret"] = secret }
        return body
    }

    static func webhooks(from object: [String: Any]) throws -> WebhooksSnapshot {
        guard let enabled = object["enabled"] as? Bool,
              let baseURL = object["base_url"] as? String,
              let rawSubscriptions = object["subscriptions"] as? [[String: Any]] else {
            throw Failure.unreadable
        }
        let subscriptions = try rawSubscriptions.map(webhookSubscription(from:))
        return WebhooksSnapshot(enabled: enabled, baseURL: baseURL, subscriptions: subscriptions)
    }

    static func webhookSubscription(from row: [String: Any]) throws -> WebhookSubscription {
        guard let name = row["name"] as? String, !name.isEmpty,
              let detail = row["description"] as? String,
              let events = row["events"] as? [String],
              let deliver = row["deliver"] as? String,
              let deliverOnly = row["deliver_only"] as? Bool,
              let prompt = row["prompt"] as? String,
              let script = row["script"] as? String,
              let skills = row["skills"] as? [String],
              let url = row["url"] as? String,
              let secretSet = row["secret_set"] as? Bool,
              let enabled = row["enabled"] as? Bool else {
            throw Failure.unreadable
        }
        return WebhookSubscription(
            name: name,
            detail: detail,
            events: events,
            deliver: deliver,
            deliverOnly: deliverOnly,
            deliverChatID: nil,
            prompt: prompt,
            script: script,
            skills: skills,
            createdAt: row["created_at"] as? String,
            url: url,
            secretSet: secretSet,
            enabled: enabled
        )
    }

    // MARK: System / health / operations

    func health() async throws -> HermesHealthStatus {
        let object = try await get("api/health")
        guard let ok = object["ok"] as? Bool,
              let version = object["version"] as? String else { throw Failure.unreadable }
        return HermesHealthStatus(
            ok: ok, version: version, authRequired: object["auth_required"] as? Bool ?? false
        )
    }

    /// `nil` asks for the machine-wide reading, which is the only one that
    /// includes the channels of assistants running their own gateway.
    func systemStatus(profile: String? = "default") async throws -> HermesSystemStatus {
        let path = profile.map { "api/status?profile=\(Self.queryValue($0))" } ?? "api/status"
        let object = try await get(path)
        var status = try Self.systemStatus(from: object)
        status.platforms = Self.platformHealth(from: object)
        return status
    }

    static func platformHealth(from object: [String: Any]) -> [HermesPlatformHealth] {
        guard let rows = object["gateway_platforms"] as? [String: Any] else { return [] }
        return rows.keys.sorted().compactMap { key -> HermesPlatformHealth? in
            guard let row = rows[key] as? [String: Any],
                  let state = (row["state"] as? String)?.lowercased(), !state.isEmpty
            else { return nil }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            return HermesPlatformHealth(
                key: key,
                profile: parts.count == 2 ? parts[0] : "default",
                platform: parts.count == 2 ? parts[1] : key,
                state: state,
                errorCode: (row["error_code"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                errorMessage: (row["error_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    func systemStats() async throws -> HermesSystemStats {
        try Self.systemStats(from: await get("api/system/stats"))
    }

    func gatewayAction(_ verb: String, profile: String = "default") async throws -> HermesActionStart {
        guard ["start", "stop", "restart"].contains(verb) else { throw Failure.unreadable }
        let object = try await send(
            "POST", "api/gateway/\(verb)?profile=\(Self.queryValue(profile))"
        )
        return try Self.actionStart(from: object, fallbackName: "gateway-\(verb)")
    }

    func runDoctor() async throws -> HermesActionStart {
        try Self.actionStart(from: await send("POST", "api/ops/doctor"), fallbackName: "doctor")
    }

    func runSecurityAudit() async throws -> HermesActionStart {
        try Self.actionStart(
            from: await send("POST", "api/ops/security-audit"), fallbackName: "security-audit"
        )
    }

    func runPromptSize() async throws -> HermesActionStart {
        try Self.actionStart(
            from: await send("POST", "api/ops/prompt-size"), fallbackName: "prompt-size"
        )
    }

    func runDump() async throws -> HermesActionStart {
        try Self.actionStart(from: await send("POST", "api/ops/dump"), fallbackName: "dump")
    }

    func runBackup() async throws -> HermesActionStart {
        try Self.actionStart(
            from: await send("POST", "api/ops/backup", [:]), fallbackName: "backup"
        )
    }

    func restoreBackup(path: String, force: Bool = true) async throws -> HermesActionStart {
        try Self.actionStart(
            from: await send("POST", "api/ops/import", ["archive": path, "force": force]),
            fallbackName: "import"
        )
    }

    func restoreBackup(
        data: Data, filename: String, force: Bool = true
    ) async throws -> HermesActionStart {
        let boundary = "AliceHermesBackup-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"force\"\r\n\r\n")
        append(force ? "true\r\n" : "false\r\n")
        append("--\(boundary)\r\n")
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
            .replacingOccurrences(of: "\"", with: "-")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n")
        append("Content-Type: application/zip\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        let (responseData, _) = try await raw(
            "POST", "api/ops/import-upload", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw Failure.unreadable
        }
        return try Self.actionStart(from: object, fallbackName: "import")
    }

    func downloadBackup(_ archive: String) async throws -> Data {
        let (data, _) = try await raw(
            "GET", "api/ops/backup/download?archive=\(Self.fileQueryValue(archive))"
        )
        return data
    }

    func actionStatus(_ name: String, lines: Int = 400) async throws -> HermesActionStatus {
        let safeLines = max(1, min(lines, 2000))
        let object = try await get(
            "api/actions/\(Self.pathSegment(name))/status?lines=\(safeLines)"
        )
        return try Self.actionStatus(from: object)
    }

    func logs(
        file: String = "agent", lines: Int = 200, search: String = ""
    ) async throws -> HermesLogSnapshot {
        let safeLines = max(1, min(lines, 500))
        var route = "api/logs?file=\(Self.fileQueryValue(file))&lines=\(safeLines)"
        if !search.isEmpty { route += "&search=\(Self.fileQueryValue(search))" }
        return try Self.logSnapshot(from: await get(route))
    }

    func checkpoints() async throws -> HermesCheckpoints {
        try Self.checkpoints(from: await get("api/ops/checkpoints"))
    }

    func pruneCheckpoints() async throws -> HermesActionStart {
        try Self.actionStart(
            from: await send("POST", "api/ops/checkpoints/prune"),
            fallbackName: "checkpoints-prune"
        )
    }

    static func systemStatus(from object: [String: Any]) throws -> HermesSystemStatus {
        guard let version = object["version"] as? String,
              let gatewayRunning = object["gateway_running"] as? Bool else {
            throw Failure.unreadable
        }
        let rawComponents = object["components"] as? [String: Any] ?? [:]
        var components: [HermesSystemComponent] = []
        for name in rawComponents.keys.sorted() {
            guard let row = rawComponents[name] as? [String: Any],
                  let status = row["status"] as? String else { throw Failure.unreadable }
            components.append(HermesSystemComponent(
                name: name, status: status, state: row["state"] as? String,
                configured: int(row["configured"]), connected: int(row["connected"])
            ))
        }
        let memory = object["memory"] as? [String: Any]
        let disk = object["disk"] as? [String: Any]
        return HermesSystemStatus(
            version: version,
            releaseDate: object["release_date"] as? String ?? "",
            overall: object["overall"] as? String ?? (gatewayRunning ? "ok" : "degraded"),
            gatewayRunning: gatewayRunning,
            gatewayState: object["gateway_state"] as? String ?? (gatewayRunning ? "running" : "stopped"),
            gatewayExitReason: object["gateway_exit_reason"] as? String,
            gatewayUpdatedAt: object["gateway_updated_at"] as? String,
            activeSessions: int(object["active_sessions"]) ?? 0,
            activeAgents: int(object["active_agents"]) ?? 0,
            gatewayBusy: object["gateway_busy"] as? Bool ?? false,
            gatewayDrainable: object["gateway_drainable"] as? Bool ?? false,
            authRequired: object["auth_required"] as? Bool ?? false,
            canUpdateHermes: object["can_update_hermes"] as? Bool ?? true,
            profiles: object["profiles"] as? [String] ?? [],
            gatewayMode: object["gateway_mode"] as? String ?? "",
            memoryPressure: memory?["pressure"] as? String ?? "unknown",
            diskPressure: disk?["pressure"] as? String ?? "unknown",
            diskUsedPercent: double(disk?["used_percent"]),
            components: components
        )
    }

    static func systemStats(from object: [String: Any]) throws -> HermesSystemStats {
        guard let os = object["os"] as? String,
              let arch = object["arch"] as? String,
              let hostname = object["hostname"] as? String,
              let hermesVersion = object["hermes_version"] as? String else {
            throw Failure.unreadable
        }
        func resource(_ raw: Any?) -> HermesSystemStats.Resource? {
            guard let row = raw as? [String: Any] else { return nil }
            func i64(_ key: String) -> Int64 {
                if let value = row[key] as? Int { return Int64(value) }
                if let value = row[key] as? NSNumber { return value.int64Value }
                return 0
            }
            return .init(
                total: i64("total"), used: i64("used"),
                free: row["free"] != nil ? i64("free") : i64("available"),
                percent: double(row["percent"]) ?? 0
            )
        }
        return HermesSystemStats(
            os: os, osRelease: object["os_release"] as? String ?? "",
            platform: object["platform"] as? String ?? "", arch: arch, hostname: hostname,
            pythonVersion: object["python_version"] as? String ?? "",
            pythonImplementation: object["python_impl"] as? String ?? "",
            hermesVersion: hermesVersion, cpuCount: int(object["cpu_count"]),
            cpuPercent: double(object["cpu_percent"]),
            loadAverage: (object["load_avg"] as? [NSNumber])?.map(\.doubleValue)
                ?? (object["load_avg"] as? [Double]) ?? [],
            uptimeSeconds: int(object["uptime_seconds"]),
            memory: resource(object["memory"]), disk: resource(object["disk"]),
            psutil: object["psutil"] as? Bool ?? false
        )
    }

    static func actionStart(
        from object: [String: Any], fallbackName: String
    ) throws -> HermesActionStart {
        guard let ok = object["ok"] as? Bool else { throw Failure.unreadable }
        return HermesActionStart(
            ok: ok, pid: int(object["pid"]), name: object["name"] as? String ?? fallbackName,
            archive: object["archive"] as? String
        )
    }

    static func actionStatus(from object: [String: Any]) throws -> HermesActionStatus {
        guard let name = object["name"] as? String,
              let running = object["running"] as? Bool,
              let lines = object["lines"] as? [String] else { throw Failure.unreadable }
        return HermesActionStatus(
            name: name, running: running, exitCode: int(object["exit_code"]),
            pid: int(object["pid"]), lines: lines
        )
    }

    static func checkpoints(from object: [String: Any]) throws -> HermesCheckpoints {
        guard let rows = object["sessions"] as? [[String: Any]] else { throw Failure.unreadable }
        let sessions = rows.compactMap { row -> HermesCheckpointSession? in
            guard let session = row["session"] as? String, !session.isEmpty else { return nil }
            let bytes: Int64
            if let value = row["bytes"] as? Int { bytes = Int64(value) }
            else if let value = row["bytes"] as? NSNumber { bytes = value.int64Value }
            else { bytes = 0 }
            return HermesCheckpointSession(
                session: session, files: int(row["files"]) ?? 0, bytes: bytes
            )
        }
        if !rows.isEmpty && sessions.count != rows.count { throw Failure.unreadable }
        let totalBytes: Int64
        if let value = object["total_bytes"] as? Int { totalBytes = Int64(value) }
        else if let value = object["total_bytes"] as? NSNumber { totalBytes = value.int64Value }
        else { totalBytes = sessions.reduce(0) { $0 + $1.bytes } }
        return HermesCheckpoints(sessions: sessions, totalBytes: totalBytes)
    }

    static func logSnapshot(from object: [String: Any]) throws -> HermesLogSnapshot {
        guard let file = object["file"] as? String,
              let lines = object["lines"] as? [String] else { throw Failure.unreadable }
        return HermesLogSnapshot(file: file, lines: lines)
    }

    // MARK: Messaging channels

    func messagingPlatforms(profile: String = "default") async throws -> MessagingPlatformsSnapshot {
        let object = try await get("api/messaging/platforms?profile=\(Self.queryValue(profile))")
        return try Self.messagingPlatforms(from: object)
    }

    func updateMessagingPlatform(
        _ id: String, profile: String = "default", enabled: Bool? = nil,
        env: [String: String] = [:], clearEnv: [String] = []
    ) async throws {
        var body: [String: Any] = ["profile": profile, "env": env, "clear_env": clearEnv]
        if let enabled { body["enabled"] = enabled }
        _ = try await send(
            "PUT",
            "api/messaging/platforms/\(Self.pathSegment(id))?profile=\(Self.queryValue(profile))",
            body
        )
    }

    func testMessagingPlatform(
        _ id: String, profile: String = "default"
    ) async throws -> MessagingPlatformTestResult {
        let object = try await send(
            "POST",
            "api/messaging/platforms/\(Self.pathSegment(id))/test?profile=\(Self.queryValue(profile))"
        )
        guard let ok = object["ok"] as? Bool,
              let state = object["state"] as? String,
              let message = object["message"] as? String else { throw Failure.unreadable }
        return MessagingPlatformTestResult(ok: ok, state: state, message: message)
    }

    func startTelegramOnboarding(botName: String = "Hermes Agent") async throws -> TelegramOnboardingStart {
        let object = try await send(
            "POST", "api/messaging/telegram/onboarding/start", ["bot_name": botName]
        )
        return try Self.telegramOnboardingStart(from: object)
    }

    func telegramOnboardingStatus(_ pairingID: String) async throws -> TelegramOnboardingStatus {
        try Self.telegramOnboardingStatus(
            from: await get("api/messaging/telegram/onboarding/\(Self.pathSegment(pairingID))")
        )
    }

    func applyTelegramOnboarding(
        _ pairingID: String, allowedUserIDs: [String], profile: String = "default"
    ) async throws -> ChannelApplyResult {
        let object = try await send(
            "POST",
            "api/messaging/telegram/onboarding/\(Self.pathSegment(pairingID))/apply",
            ["allowed_user_ids": allowedUserIDs, "profile": profile]
        )
        return try Self.channelApplyResult(from: object)
    }

    func cancelTelegramOnboarding(_ pairingID: String) async throws {
        _ = try await send(
            "DELETE", "api/messaging/telegram/onboarding/\(Self.pathSegment(pairingID))"
        )
    }

    func startWhatsAppOnboarding(
        mode: String, allowedUsers: String, profile: String = "default"
    ) async throws -> WhatsAppOnboardingSession {
        let object = try await send(
            "POST", "api/messaging/whatsapp/onboarding/start",
            ["mode": mode, "allowed_users": allowedUsers, "profile": profile]
        )
        return try Self.whatsAppOnboardingSession(from: object)
    }

    func whatsAppOnboardingStatus(_ pairingID: String) async throws -> WhatsAppOnboardingSession {
        try Self.whatsAppOnboardingSession(
            from: await get("api/messaging/whatsapp/onboarding/\(Self.pathSegment(pairingID))")
        )
    }

    func applyWhatsAppOnboarding(
        _ pairingID: String, mode: String, allowedUsers: String, profile: String = "default"
    ) async throws -> ChannelApplyResult {
        let object = try await send(
            "POST",
            "api/messaging/whatsapp/onboarding/\(Self.pathSegment(pairingID))/apply",
            ["mode": mode, "allowed_users": allowedUsers, "profile": profile]
        )
        return try Self.channelApplyResult(from: object)
    }

    func cancelWhatsAppOnboarding(_ pairingID: String) async throws {
        _ = try await send(
            "DELETE", "api/messaging/whatsapp/onboarding/\(Self.pathSegment(pairingID))"
        )
    }

    func restartGateway(profile: String = "default") async throws -> GatewayActionResult {
        let object = try await send(
            "POST", "api/gateway/restart?profile=\(Self.queryValue(profile))"
        )
        guard let ok = object["ok"] as? Bool else { throw Failure.unreadable }
        return GatewayActionResult(
            ok: ok, pid: Self.int(object["pid"]), name: object["name"] as? String ?? "gateway-restart"
        )
    }

    static func messagingPlatforms(from object: [String: Any]) throws -> MessagingPlatformsSnapshot {
        guard let rows = object["platforms"] as? [[String: Any]] else { throw Failure.unreadable }
        let platforms = rows.compactMap(messagingPlatform(from:))
        if !rows.isEmpty && platforms.count != rows.count { throw Failure.unreadable }
        return MessagingPlatformsSnapshot(
            envPath: object["env_path"] as? String ?? "",
            gatewayStartCommand: object["gateway_start_command"] as? String ?? "",
            platforms: platforms
        )
    }

    static func messagingPlatform(from row: [String: Any]) -> MessagingPlatform? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let name = row["name"] as? String, !name.isEmpty,
              let enabled = row["enabled"] as? Bool,
              let configured = row["configured"] as? Bool,
              let gatewayRunning = row["gateway_running"] as? Bool,
              let state = row["state"] as? String,
              let envRows = row["env_vars"] as? [[String: Any]] else { return nil }
        let envVars = envRows.compactMap(messagingEnvField(from:))
        if envVars.count != envRows.count { return nil }
        var home: MessagingHomeChannel?
        if let raw = row["home_channel"] as? [String: Any],
           let platform = raw["platform"] as? String {
            let chat = (raw["chat_id"] as? String) ?? raw["chat_id"].map(String.init(describing:)) ?? ""
            home = MessagingHomeChannel(
                platform: platform, chatID: chat, name: raw["name"] as? String ?? chat,
                threadID: (raw["thread_id"] as? String) ?? raw["thread_id"].map(String.init(describing:))
            )
        }
        var whatsapp: MessagingPlatform.WhatsAppSetup?
        if let raw = row["whatsapp_setup"] as? [String: Any] {
            whatsapp = .init(
                mode: raw["mode"] as? String ?? "",
                allowedUsersSet: raw["allowed_users_set"] as? Bool ?? false,
                homeChannelSet: raw["home_channel_set"] as? Bool ?? false
            )
        }
        return MessagingPlatform(
            id: id, name: name, detail: row["description"] as? String ?? "",
            docsURL: row["docs_url"] as? String ?? "", enabled: enabled, configured: configured,
            gatewayRunning: gatewayRunning, state: state, errorCode: row["error_code"] as? String,
            errorMessage: row["error_message"] as? String, updatedAt: row["updated_at"] as? String,
            homeChannel: home, whatsappSetup: whatsapp, envVars: envVars
        )
    }

    static func messagingEnvField(from row: [String: Any]) -> MessagingEnvField? {
        guard let key = row["key"] as? String, !key.isEmpty,
              let required = row["required"] as? Bool,
              let isSet = row["is_set"] as? Bool else { return nil }
        return MessagingEnvField(
            key: key, required: required, isSet: isSet, redactedValue: row["redacted_value"] as? String,
            detail: row["description"] as? String ?? "", prompt: row["prompt"] as? String ?? key,
            help: row["help"] as? String ?? "", docsURL: row["url"] as? String,
            isPassword: row["is_password"] as? Bool ?? false, advanced: row["advanced"] as? Bool ?? false
        )
    }

    static func telegramOnboardingStart(from object: [String: Any]) throws -> TelegramOnboardingStart {
        guard let pairingID = object["pairing_id"] as? String, !pairingID.isEmpty,
              let deepLink = object["deep_link"] as? String, !deepLink.isEmpty,
              let qrPayload = object["qr_payload"] as? String, !qrPayload.isEmpty,
              let expiresAt = object["expires_at"] as? String, !expiresAt.isEmpty else { throw Failure.unreadable }
        return TelegramOnboardingStart(
            pairingID: pairingID, suggestedUsername: object["suggested_username"] as? String ?? "",
            deepLink: deepLink, qrPayload: qrPayload, expiresAt: expiresAt
        )
    }

    static func telegramOnboardingStatus(from object: [String: Any]) throws -> TelegramOnboardingStatus {
        guard let status = object["status"] as? String, ["waiting", "ready"].contains(status),
              let expiresAt = object["expires_at"] as? String else { throw Failure.unreadable }
        return TelegramOnboardingStatus(
            status: status, expiresAt: expiresAt, botUsername: object["bot_username"] as? String,
            ownerUserID: object["owner_user_id"] as? String
        )
    }

    static func whatsAppOnboardingSession(from object: [String: Any]) throws -> WhatsAppOnboardingSession {
        guard let pairingID = object["pairing_id"] as? String, !pairingID.isEmpty,
              let status = object["status"] as? String, !status.isEmpty,
              let expiresAt = object["expires_at"] as? String, !expiresAt.isEmpty,
              let mode = object["mode"] as? String, !mode.isEmpty,
              let allowedUsers = object["allowed_users"] as? String else { throw Failure.unreadable }
        return WhatsAppOnboardingSession(
            pairingID: pairingID, status: status, qrPayload: object["qr_payload"] as? String,
            expiresAt: expiresAt, mode: mode, allowedUsers: allowedUsers,
            accountID: object["account_id"] as? String, accountName: object["account_name"] as? String,
            accountPhone: object["account_phone"] as? String, error: object["error"] as? String
        )
    }

    static func channelApplyResult(from object: [String: Any]) throws -> ChannelApplyResult {
        guard let ok = object["ok"] as? Bool, let platform = object["platform"] as? String else {
            throw Failure.unreadable
        }
        return ChannelApplyResult(
            ok: ok, platform: platform, needsRestart: object["needs_restart"] as? Bool ?? false,
            restartStarted: object["restart_started"] as? Bool ?? false,
            restartError: object["restart_error"] as? String, botUsername: object["bot_username"] as? String
        )
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
