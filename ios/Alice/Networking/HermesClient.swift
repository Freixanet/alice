import Foundation
import OSLog

/// Talks to a Hermes agent directly, with no server of ours in between.
///
/// Native code has no same-origin rule to satisfy, so the phone can reach the
/// agent on your network or over Tailscale without a proxy — which also means
/// the key never travels anywhere but to the address you configured.
actor HermesClient {
    struct Endpoint: Sendable, Equatable {
        var url: URL
        var key: String
    }

    struct Manifest: Sendable, Equatable {
        var version: String?
        var capabilities: Set<String> = []
        var advertised: [String] = []
        /// The routes the server publishes, by name. Hermes does not serve
        /// every collection from the same place — this build answers skills on
        /// `/v1/skills` while another serves `/api/skills` — and it says which
        /// in its own manifest. Asking it beats guessing.
        var endpoints: [String: String] = [:]

        func path(_ name: String) -> String? {
            endpoints[name].map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        }

        func supports(_ capability: String) -> Bool {
            capabilities.contains(capability)
        }
    }

    struct ModelOption: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var provider: String?
        var providerName: String?
    }

    enum Failure: Error, LocalizedError {
        case badResponse
        case http(status: Int, detail: String, limit: ModelLimit?)
        case unreachable
        case timedOut
        case offline
        case blockedByPolicy

        var errorDescription: String? {
            switch self {
            case .badResponse: "Hermes sent something Alice could not read."
            case let .http(_, detail, _): detail
            case .unreachable: "Couldn’t reach that address from this iPhone."
            case .timedOut:
                "Hermes didn’t answer in time. If it is on a private network, "
                    + "check this iPhone can reach it."
            case .offline: "This iPhone has no network connection."
            case .blockedByPolicy:
                "iOS refused an unencrypted connection to that address." 
            }
        }
    }

    /// Turns a URL-loading error into something that names what went wrong,
    /// rather than surfacing "The request timed out" with no idea whose fault
    /// that was.
    static func describe(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorNotConnectedToInternet: return .offline
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed, NSURLErrorNetworkConnectionLost:
            return .unreachable
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .blockedByPolicy
        default: return .unreachable
        }
    }

    let session: URLSession
    private var endpoint: Endpoint?

    init(session: URLSession? = nil) {
        // A Hermes that is unreachable should say so in seconds, not after the
        // system default of a minute. The web client settled on twelve — but
        // that is the budget for a probe, not for an answer. A reply can take
        // far longer than twelve seconds to begin, and the resource cap of
        // thirty would have cut off any reply still streaming after half a
        // minute. Both are lifted here and the short budget is asked for
        // per-request where it belongs.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: configuration)
    }

    func connect(to endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    func disconnect() {
        endpoint = nil
    }

    var isConnected: Bool { endpoint != nil }

    /// What a probe or a list read is given before it is called unreachable.
    static let probeTimeout: TimeInterval = 12
    /// What an answer is given. Hermes retries a failing provider three times
    /// before it reports back, which alone outruns the probe budget.
    static let replyTimeout: TimeInterval = 120

    // MARK: - Requests

    /// Shared by the streaming transport in `HermesChatStream`.
    func request(
        _ path: String,
        method: String = "GET",
        profile: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let endpoint else { throw Failure.unreachable }
        // No `p/<profile>/` prefix. This gateway serves no such route, so
        // every mentioned message paid for a 404 and a full retry before the
        // reply could start. The header below is the polite way to ask; a
        // build that honours it will, and one that does not simply ignores it.
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: cleanPath, relativeTo: endpoint.url) else {
            throw Failure.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        request.setValue(endpoint.key, forHTTPHeaderField: "X-Hermes-Session-Token")
        if let profile {
            request.setValue(profile, forHTTPHeaderField: "X-Hermes-Profile")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Probes and list reads keep the short budget; a chat does not.
        request.timeoutInterval = timeout ?? Self.probeTimeout
        return request
    }

    /// Reads what this build can do. Alice gates its screens on the answer
    /// rather than assuming a feature is present.
    func capabilities() async throws -> Manifest {
        let (data, response) = try await session.data(for: try request("v1/capabilities"))
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, response: http)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.badResponse }
        return Self.parseManifest(object)
    }

    /// Every model this Hermes can reach.
    ///
    /// `/v1/models` is the OpenAI-compatible surface and answers with the one
    /// model the agent presents to that API — on a Hermes fronting a hundred
    /// models across six providers it still returns exactly one. The full
    /// picker lives on the management surface, so ask there first and keep
    /// `/v1/models` as the fallback for a build that has no picker.
    func models(refreshing: Bool = false) async throws -> [ModelOption] {
        // `/v1/models` is the one surface every build serves, so ask it first
        // and have something to show immediately. It answers with the single
        // model the agent presents to OpenAI-compatible clients.
        var baseline: [ModelOption] = []
        do {
            baseline = try await modelList("v1/models")
            Self.trace("v1/models -> \(baseline.count) models")
        } catch {
            Self.trace("v1/models -> \(error.localizedDescription)")
        }

        // The full picker lives on the management surface, which plenty of
        // deployments do not expose at this address — a Tailscale Serve rule
        // that proxies `/v1` and nothing else simply swallows these, so they
        // get a short leash rather than the full request timeout.
        // Order and timeout come from measuring a real agent: the plain
        // options endpoint answered in 0.34s with 135 models across 54
        // providers, while asking it to include unconfigured ones took 5.36s —
        // past the leash these probes were on, so the fast, sufficient answer
        // was never reached.
        // Asking to refresh is not the same as asking again. The plain
        // options endpoint answers from a computed cache, and that cache had
        // every one of Nous's models marked unavailable — a stale reading of
        // an account without credits — which emptied the provider out of the
        // picker entirely. The same call with `refresh=1` came back with the
        // list intact and nothing marked unavailable, including the free
        // models the cached answer had dropped. It is slower, so it is only
        // asked for when somebody actually pulls to refresh.
        var paths = ["api/model/options"]
        if refreshing { paths.insert("api/model/options?refresh=1", at: 0) }
        paths += ["api/model/options?include_unconfigured=1", "api/models"]

        for path in paths {
            do {
                let found = try await modelList(path, timeout: 10)
                Self.trace("\(path) -> \(found.count) models")
                if found.count > baseline.count { return found }
            } catch {
                Self.trace("\(path) -> \(error.localizedDescription)")
            }
        }
        return baseline
    }

    private func modelList(
        _ path: String, timeout: TimeInterval? = nil
    ) async throws -> [ModelOption] {
        var call = try request(path)
        if let timeout { call.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: call)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        Self.trace("\(path) -> HTTP \(http.statusCode), \(data.count) bytes")
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, response: http)
        }
        return Self.parseModels(data)
    }

    /// Says which endpoint answered and how. Which of these a given Hermes
    /// serves is documented nowhere, so an empty picker should name the reason
    /// rather than leave it to be guessed at.
    nonisolated static func trace(_ line: String) {
        Logger(subsystem: "com.freixanet.alice", category: "models")
            .notice("\(line)")
        FileHandle.standardError.write(Data(("[alice] " + line + "\n").utf8))
    }

    // MARK: - Failure shaping

    private func failure(
        status: Int, data: Data, response: HTTPURLResponse
    ) -> Failure {
        let detail = Self.detail(from: data) ?? "Hermes returned \(status)."
        let limit = ModelLimitClassifier.classify(
            status: status,
            message: detail,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )
        return .http(status: status, detail: detail, limit: limit)
    }

    /// Best-effort read of a Hermes error body, so a spent quota is never
    /// flattened into a generic connection failure.
    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["detail", "message", "error"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
            if let nested = object[key] as? [String: Any],
               let text = nested["message"] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - Parsing

    /// Reads what a Hermes says it can do.
    ///
    /// It does not say it under one key. The running gateway advertises
    /// nothing called `capabilities` at all — it publishes a `features` map of
    /// 29 flags and an `endpoints` map of 28 routes, and reading only
    /// `capabilities` is why the phone believed a fully-featured agent could
    /// do nothing. This mirrors the web's `collectAdvertised`: every source
    /// is read, and an endpoint the server publishes counts as a capability,
    /// because publishing the route is the server saying it serves it.
    ///
    /// A flag whose value is an object counts too — `runs_idempotency` is
    /// `{supported, durable, retention_seconds}`, not `true` — while a flag
    /// explicitly `false` does not.
    static func parseManifest(_ object: [String: Any]) -> Manifest {
        var advertised: [String] = []
        var routes: [String: String] = [:]

        for key in ["capabilities", "features", "toolsets"] {
            if let list = object[key] as? [String] {
                advertised.append(contentsOf: list)
            } else if let map = object[key] as? [String: Any] {
                for (name, value) in map {
                    if value as? Bool == true || value is [String: Any] {
                        advertised.append(name)
                    }
                }
            }
        }
        if let list = object["advertised"] as? [String] {
            advertised.append(contentsOf: list)
        }
        if let endpoints = object["endpoints"] as? [String: Any] {
            for (name, value) in endpoints {
                guard let route = value as? [String: Any],
                      route["method"] is String,
                      let path = route["path"] as? String
                else { continue }
                advertised.append(name)
                routes[name] = path
            }
        }

        advertised = orderedUnique(advertised)
        let normalized = advertised.map {
            $0.lowercased().replacingOccurrences(
                of: "[ .-]", with: "_", options: .regularExpression
            )
        }
        let version = ["version", "hermes_version", "agent_version"]
            .compactMap { object[$0] as? String }
            .first { !$0.isEmpty }
        return Manifest(
            version: version,
            capabilities: Set(normalized),
            advertised: advertised,
            endpoints: routes
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Hermes answers `/v1/models` in one of two shapes.
    ///
    /// The one it actually uses nests every model under a `providers` array,
    /// each with its own slug, display name and list of models it cannot serve
    /// right now. Reading only the OpenAI-style `data` array — which is what
    /// this did first — found a single entry and hid the hundred behind it.
    static func parseModels(_ data: Data) -> [ModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        describeModelPayload(object)

        if let map = object as? [String: Any],
           let providers = map["providers"] as? [[String: Any]] {
            return parseProviders(providers)
        }

        let rows: [[String: Any]]
        if let map = object as? [String: Any] {
            rows = (map["data"] as? [[String: Any]])
                ?? (map["models"] as? [[String: Any]])
                ?? []
        } else {
            rows = (object as? [[String: Any]]) ?? []
        }
        return rows.compactMap { option(from: $0) }
    }

    private static func parseProviders(_ providers: [[String: Any]]) -> [ModelOption] {
        var models: [ModelOption] = []
        for provider in providers {
            guard let slug = (provider["slug"] as? String)?.trimmingCharacters(
                in: .whitespaces
            ), !slug.isEmpty else { continue }
            let name = (provider["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? prettify(slug)
            let listed = (provider["models"] as? [Any]) ?? []
            // A provider can advertise a model it cannot currently serve;
            // offering it would only produce a failed reply.
            let unavailable = Set((provider["unavailable_models"] as? [String]) ?? [])
            for item in listed {
                guard var model = option(from: item, provider: slug, providerName: name),
                      !unavailable.contains(model.id)
                else { continue }
                model.provider = slug
                model.providerName = name
                models.append(model)
            }
        }
        return models
    }

    /// A model arrives either as a bare id or as an object carrying a label.
    private static func option(
        from raw: Any, provider: String? = nil, providerName: String? = nil
    ) -> ModelOption? {
        if let id = raw as? String, !id.isEmpty {
            return ModelOption(
                id: id, label: prettify(id),
                provider: provider, providerName: providerName
            )
        }
        guard let row = raw as? [String: Any] else { return nil }
        let id = (row["id"] as? String) ?? (row["name"] as? String) ?? ""
        guard !id.isEmpty else { return nil }
        return ModelOption(
            id: id,
            label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? prettify(id),
            provider: (row["provider"] as? String) ?? provider,
            providerName: (row["providerName"] as? String)
                ?? (row["provider_name"] as? String) ?? providerName
        )
    }

    /// Reports the shape `/v1/models` came back in.
    ///
    /// Which shape a Hermes uses is not documented anywhere, and reading the
    /// wrong one silently produced a one-item picker on an agent serving a
    /// hundred models. This says what arrived, so the next mismatch is visible
    /// rather than inferred.
    private static func describeModelPayload(_ object: Any) {
        let log = Logger(subsystem: "com.freixanet.alice", category: "models")
        // Also to stderr, so `devicectl --console` shows it without the
        // unified log, which cannot be streamed from a physical device here.
        func say(_ line: String) {
            log.notice("\(line)")
            FileHandle.standardError.write(Data(("[alice] " + line + "\n").utf8))
        }
        if let map = object as? [String: Any] {
            let keys = map.keys.sorted().joined(separator: ", ")
            if let providers = map["providers"] as? [[String: Any]] {
                let counts = providers.map { provider -> String in
                    let slug = (provider["slug"] as? String) ?? "?"
                    let n = (provider["models"] as? [Any])?.count ?? 0
                    return "\(slug):\(n)"
                }
                say("models payload: object keys [\(keys)] providers \(counts.joined(separator: " "))")
            } else {
                let data = (map["data"] as? [Any])?.count
                let models = (map["models"] as? [Any])?.count
                say("models payload: object keys [\(keys)] data=\(data ?? -1) models=\(models ?? -1)")
            }
        } else if let list = object as? [Any] {
            say("models payload: top-level array of \(list.count)")
        } else {
            say("models payload: unrecognised root")
        }
    }

    /// `openai/gpt-5.6-luna` reads as "Gpt 5.6 Luna" in the picker.
    static func prettify(_ id: String) -> String {
        let tail = id.split(separator: "/").last.map(String.init) ?? id
        return tail
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
