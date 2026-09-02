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

    private func fetch(_ path: String) async throws -> [String: Any] {
        guard let credentials else { throw Failure.notConfigured }
        let request = URLRequest(url: credentials.url.appending(path: path))
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
    }
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
