import Foundation

/// Exchanges a pairing token for the real configuration, exactly once, on
/// the endpoint the QR's deep link named (docs/pairing.md §2).
struct PairingClient {
    struct Claimed: Equatable {
        let profileName: String?
        let profileDisplayName: String?
        let gatewayURLText: String
        let gatewayKey: String
        let dashboardURLText: String?
        let dashboardUsername: String?
        let dashboardPassword: String?
    }

    enum Failure: Error, LocalizedError {
        /// 410/404 — the QR sat too long or someone paired already.
        case stale
        /// 403 — this network may not claim; the helper only serves the tailnet.
        case forbidden
        case badResponse
        case http(status: Int)
        case unreachable
        case timedOut
        case tailnetUnavailable
        case offline

        var errorDescription: String? {
            switch self {
            case .stale:
                "That QR has expired or was already used. Open the Hermes dashboard and show a fresh code (Alice tab → Show pairing code)."
            case .forbidden:
                "Your Hermes accepts pairing requests from its own network only. Join the same Tailscale and try again."
            case .badResponse:
                "Hermes sent pairing information Alice could not safely use."
            case let .http(status):
                "Hermes answered with an unexpected error (\(status))."
            case .unreachable:
                "Couldn't reach that address from this iPhone."
            case .timedOut:
                "The pairing request timed out."
            case .tailnetUnavailable:
                "Couldn't reach Hermes over Tailscale. Open Tailscale on this iPhone, make sure it is connected to the same tailnet as the device running Hermes, then try again with a new QR code."
            case .offline:
                "This iPhone has no network connection."
            }
        }
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // A pairing claim is one small request; nothing here needs to
            // outlive the sheet that started it. Redirects are refused: the QR
            // named the one endpoint allowed to receive its bearer token.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: PairingNoRedirects(),
                delegateQueue: nil
            )
        }
    }

    func claim(_ payload: PairingPayload, deviceName: String) async throws -> Claimed {
        var request = URLRequest(url: payload.claimURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The Alice plugin's claim route is authenticated by Hermes' own
        // token seam, which reads a bearer header; the body keeps the token too
        // for Hermes installs that serve the claim from their own code.
        request.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(
            ClaimRequest(token: payload.token, deviceName: deviceName)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.describe(error, claimURL: payload.claimURL)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }

        switch http.statusCode {
        case 200:
            break
        case 410: throw Failure.stale
        case 403: throw Failure.forbidden
        // 401: Hermes' token seam recognised no pairing code — it expired with
        // a restart of the dashboard, or never existed. Same meaning as 404.
        case 404, 401: throw Failure.stale
        default: throw Failure.http(status: http.statusCode)
        }

        // The response carries long-lived credentials. Keep the accepted shape
        // deliberately small and validate every endpoint before any of it is
        // committed to AppStore/Keychain.
        guard data.count <= 64 * 1024 else { throw Failure.badResponse }
        let body: ClaimResponse
        do {
            body = try JSONDecoder().decode(ClaimResponse.self, from: data)
        } catch {
            throw Failure.badResponse
        }

        guard let gatewayURL = validatedServiceURL(
            body.gateway.url, relativeToClaim: payload.claimURL
        ), !body.gateway.key.isEmpty, body.gateway.key.utf8.count <= 8 * 1024 else {
            throw Failure.badResponse
        }

        var dashboardURL: String?
        var dashboardUsername: String?
        var dashboardPassword: String?
        if let dashboard = body.dashboard {
            guard let validated = validatedServiceURL(
                dashboard.url, relativeToClaim: payload.claimURL
            ), !dashboard.username.isEmpty,
               dashboard.username.utf8.count <= 4 * 1024,
               !dashboard.password.isEmpty,
               dashboard.password.utf8.count <= 8 * 1024 else {
                throw Failure.badResponse
            }
            dashboardURL = validated.absoluteString
            dashboardUsername = dashboard.username
            dashboardPassword = dashboard.password
        }

        let profile = body.profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = body.profileDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Claimed(
            profileName: profile?.isEmpty == false ? profile : payload.profileName,
            profileDisplayName: displayName?.isEmpty == false ? displayName : nil,
            gatewayURLText: gatewayURL.absoluteString,
            gatewayKey: body.gateway.key,
            dashboardURLText: dashboardURL,
            dashboardUsername: dashboardUsername,
            dashboardPassword: dashboardPassword
        )
    }

    /// Pairing v1 is one Mac. The claim endpoint may use a different port from
    /// the gateway/dashboard, but it must not hand Alice off to another host,
    /// smuggle a path/query into the base URL, or downgrade an HTTPS claim.
    private func validatedServiceURL(_ text: String, relativeToClaim claim: URL) -> URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host == claim.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        if claim.scheme?.lowercased() == "https", scheme != "https" { return nil }
        return url
    }

    /// The claim request is a fixed little shape; keys are the contract's.
    private struct ClaimRequest: Encodable {
        let token: String
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case token
            case deviceName = "device_name"
        }
    }

    private struct ClaimResponse: Decodable {
        struct Gateway: Decodable {
            let url: String
            let key: String
        }

        struct Dashboard: Decodable {
            let url: String
            let username: String
            let password: String
        }

        let profile: String?
        let profileDisplayName: String?
        let gateway: Gateway
        let dashboard: Dashboard?

        enum CodingKeys: String, CodingKey {
            case profile
            case profileDisplayName = "profile_display_name"
            case gateway
            case dashboard
        }
    }

    /// Same mapping HermesClient uses for its own requests, so a claim that
    /// fails for transport reasons reads like every other failure here.
    static func describe(_ error: Error, claimURL: URL? = nil) -> Failure {
        if let failure = error as? Failure { return failure }
        guard let urlError = error as? URLError else { return .unreachable }
        if urlError.code == .notConnectedToInternet { return .offline }

        if isTailnetHost(claimURL?.host), [
            URLError.timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
        ].contains(urlError.code) {
            return .tailnetUnavailable
        }

        switch urlError.code {
        case .timedOut: return .timedOut
        default: return .unreachable
        }
    }

    private static func isTailnetHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

/// A pairing token is a bearer credential. Unlike an ordinary web request,
/// there is no useful redirect here: the QR already named its destination.
/// Refusing every redirect means a 30x cannot walk that token to another host.
private final class PairingNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
