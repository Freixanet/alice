import Foundation

/// Exchanges a pairing token for the real configuration, exactly once, on
/// the endpoint the QR's deep link named (docs/pairing.md §2).
struct PairingClient {
    struct Claimed: Equatable {
        let profileName: String?
        let gatewayURLText: String
        let gatewayKey: String
        let dashboardURLText: String?
        let dashboardUsername: String?
        let dashboardPassword: String?
    }

    enum Failure: Error, LocalizedError {
        /// 410 — the QR sat too long or someone paired already.
        case stale
        /// 403 — this network may not claim; the helper only serves the tailnet.
        case forbidden
        case badResponse
        case http(status: Int)
        case unreachable
        case timedOut
        case offline

        var errorDescription: String? {
            switch self {
            case .stale:
                "That QR has expired or was already used. Run the pairing command on your Hermes again for a fresh one."
            case .forbidden:
                "Your Hermes accepts pairing requests from its own network only. Join the same Tailscale and try again."
            case .badResponse:
                "Hermes sent something Alice could not read."
            case let .http(status):
                "Hermes answered with an unexpected error (\(status))."
            case .unreachable:
                "Couldn't reach that address from this iPhone."
            case .timedOut:
                "The pairing request timed out."
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
            // outlive the sheet that started it.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func claim(_ payload: PairingPayload, deviceName: String) async throws -> Claimed {
        var request = URLRequest(url: payload.claimURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ClaimRequest(token: payload.token, deviceName: deviceName)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.describe(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }

        switch http.statusCode {
        case 200:
            break
        case 410: throw Failure.stale
        case 403: throw Failure.forbidden
        case 404: throw Failure.stale
        default: throw Failure.http(status: http.statusCode)
        }

        let body: ClaimResponse
        do {
            body = try JSONDecoder().decode(ClaimResponse.self, from: data)
        } catch {
            throw Failure.badResponse
        }
        return Claimed(
            profileName: body.profile ?? payload.profileName,
            gatewayURLText: body.gateway.url,
            gatewayKey: body.gateway.key,
            dashboardURLText: body.dashboard?.url,
            dashboardUsername: body.dashboard?.username,
            dashboardPassword: body.dashboard?.password
        )
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
        let gateway: Gateway
        let dashboard: Dashboard?
    }

    /// Same mapping HermesClient uses for its own requests, so a claim that
    /// fails for transport reasons reads like every other failure here.
    static func describe(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet: return .offline
        default: return .unreachable
        }
    }
}
