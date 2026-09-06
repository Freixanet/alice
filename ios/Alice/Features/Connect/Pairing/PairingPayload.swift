import Foundation

/// The `alice://pair` deep link a Hermes shows as a QR code, either scanned
/// by the system camera or pasted by hand. The format is the contract in
/// docs/pairing.md; the Mac helper builds it in scripts/pairing-protocol.mjs.
///
/// Parsing is fail-closed like GatewayOrigin: anything that is not exactly
/// the documented v1 shape is refused rather than guessed at. This code is
/// the front door for anything a camera has ever pointed at.
struct PairingPayload: Equatable {
    /// Where the one-time token is exchanged for the real configuration.
    let claimURL: URL
    let token: String
    let expiresAt: Date
    /// The Hermes profile this link is for. Informational — the claim
    /// response is the authority on what gets configured.
    let profileName: String?

    enum ParseError: Error, LocalizedError, Equatable {
        case notPairing
        case unsupportedVersion
        case malformed
        case expired

        var errorDescription: String? {
            switch self {
            case .notPairing:
                "This is not an Alice pairing code."
            case .unsupportedVersion:
                "This pairing code was made for a different version of Alice."
            case .malformed:
                "This pairing code is incomplete or damaged."
            case .expired:
                "This pairing code has expired. Ask your Hermes for a fresh one."
            }
        }
    }

    /// The offer carries seconds-since-epoch and unpadded base64url —
    /// both decoded by hand rather than trusted to lenient defaults.
    private struct Offer: Decodable {
        let c: String
        let t: String
        let e: Double
        let pr: String?
    }

    static func parse(_ text: String, now: Date = Date()) throws -> PairingPayload {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "alice",
              url.host?.lowercased() == "pair"
        else { throw ParseError.notPairing }

        guard let version = url.queryItems["v"] else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }

        guard let encoded = url.queryItems["p"], !encoded.isEmpty,
              let payload = decodeBase64URL(encoded)
        else { throw ParseError.malformed }
        // The signature travels with the link but only the issuer can check
        // it; v1 trusts the claim endpoint instead (docs/pairing.md §1).
        guard url.queryItems["s"] != nil else { throw ParseError.malformed }

        let offer: Offer
        do {
            offer = try JSONDecoder().decode(Offer.self, from: payload)
        } catch {
            throw ParseError.malformed
        }
        guard let claimURL = URL(string: offer.c),
              let scheme = claimURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw ParseError.malformed }
        guard !offer.t.isEmpty else { throw ParseError.malformed }

        let expiresAt = Date(timeIntervalSince1970: offer.e)
        guard expiresAt > now else { throw ParseError.expired }

        return PairingPayload(
            claimURL: claimURL,
            token: offer.t,
            expiresAt: expiresAt,
            profileName: offer.pr
        )
    }

    /// Strict RFC 4648 §5: url-safe alphabet only, no padding accepted,
    /// no leftover bits. `Data(base64Encoded:)` would silently accept most
    /// of what these rules forbid.
    private static func decodeBase64URL(_ text: String) -> Data? {
        if text.isEmpty || text.contains("+") || text.contains("/") || text.contains("=") {
            return nil
        }
        var padded = text
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/"))
    }
}

private extension URL {
    /// `URLComponents` spelling of query items, kept off the main type so the
    /// payload struct reads as the protocol and not as plumbing.
    var queryItems: [String: String] {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var items: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            items[item.name] = item.value
        }
        return items
    }
}
