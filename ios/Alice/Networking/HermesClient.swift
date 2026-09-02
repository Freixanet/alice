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
        // system default of a minute. The web client settled on twelve.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
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

    // MARK: - Requests

    /// Shared by the streaming transport in `HermesChatStream`.
    func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let endpoint else { throw Failure.unreachable }
        guard let url = URL(string: path, relativeTo: endpoint.url) else {
            throw Failure.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        request.setValue(endpoint.key, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
    func models() async throws -> [ModelOption] {
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
        for path in [
            "api/model/options?include_unconfigured=1",
            "api/model/options",
            "api/models",
        ] {
            do {
                let found = try await modelList(path, timeout: 4)
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

    static func parseManifest(_ object: [String: Any]) -> Manifest {
        var advertised: [String] = []
        if let list = object["capabilities"] as? [String] {
            advertised = list
        } else if let map = object["capabilities"] as? [String: Any] {
            advertised = map.compactMap { key, value in
                (value as? Bool) == true ? key : nil
            }
        }
        if let extra = object["advertised"] as? [String] {
            advertised.append(contentsOf: extra)
        }
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
            advertised: advertised
        )
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
