import Foundation

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

        var errorDescription: String? {
            switch self {
            case .badResponse: "Hermes sent something Alice could not read."
            case let .http(_, detail, _): detail
            case .unreachable: "Couldn’t reach Hermes."
            }
        }
    }

    let session: URLSession
    private var endpoint: Endpoint?

    init(session: URLSession = .shared) {
        self.session = session
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

    func models() async throws -> [ModelOption] {
        let (data, response) = try await session.data(for: try request("v1/models"))
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, response: http)
        }
        return Self.parseModels(data)
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

    static func parseModels(_ data: Data) -> [ModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let map = object as? [String: Any], let list = map["data"] as? [[String: Any]] {
            rows = list
        } else if let list = object as? [[String: Any]] {
            rows = list
        } else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ModelOption(
                id: id,
                label: (row["label"] as? String) ?? Self.prettify(id),
                provider: row["provider"] as? String,
                providerName: row["providerName"] as? String
            )
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
