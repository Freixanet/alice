import Foundation

/// The `alice://pair` deep link a Hermes shows as a QR code, either scanned
/// by the system camera or pasted by hand. The format is the contract in
/// docs/pairing.md; the Mac helper builds it in scripts/pairing-protocol.mjs.
///
/// Parsing is fail-closed like GatewayOrigin: anything that is not exactly
/// the documented v1 envelope is refused rather than guessed at. This code is
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

    /// Seconds-since-epoch is an integer in the wire contract. Keeping it an
    /// integer here also keeps the Swift and Node parsers on the same grammar.
    private struct Offer: Decodable {
        let c: String
        let t: String
        let e: Int64
        let pr: String?
    }

    static func parse(_ text: String, now: Date = Date()) throws -> PairingPayload {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "alice",
              url.host?.lowercased() == "pair"
        else { throw ParseError.notPairing }

        // A versioned wire format should have one spelling. Duplicate query
        // keys, extra fields, paths and fragments create parser disagreement
        // between implementations and are refused instead of given precedence.
        guard url.path.isEmpty, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw ParseError.malformed }
        let queryItems = components.queryItems ?? []
        guard queryItems.count == 2 else { throw ParseError.malformed }
        var values: [String: String] = [:]
        for item in queryItems {
            guard ["v", "p"].contains(item.name),
                  values[item.name] == nil,
                  let value = item.value
            else { throw ParseError.malformed }
            values[item.name] = value
        }

        guard let version = values["v"] else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let encoded = values["p"], encoded.count <= 4096,
              let payload = decodeBase64URL(encoded)
        else { throw ParseError.malformed }

        let offer: Offer
        do {
            offer = try JSONDecoder().decode(Offer.self, from: payload)
        } catch {
            throw ParseError.malformed
        }

        guard let claimURL = URL(string: offer.c),
              let scheme = claimURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              claimURL.host != nil,
              claimURL.user == nil,
              claimURL.password == nil,
              !offer.t.isEmpty,
              offer.t.count <= 512
        else { throw ParseError.malformed }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(offer.e))
        guard expiresAt > now else { throw ParseError.expired }

        let profile = offer.pr?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingPayload(
            claimURL: claimURL,
            token: offer.t,
            expiresAt: expiresAt,
            profileName: profile?.isEmpty == false ? profile : nil
        )
    }

    /// Strict RFC 4648 §5: url-safe alphabet only, no padding accepted and no
    /// non-zero leftover bits. Foundation's decoder is intentionally lenient,
    /// so round-tripping the bytes back to their canonical spelling is what
    /// makes the final check strict and matches Node's decoder.
    private static func decodeBase64URL(_ text: String) -> Data? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isBase64URLCharacter })
        else { return nil }

        var padded = text
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(
            base64Encoded: padded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
        ) else { return nil }

        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == text ? data : nil
    }
}

private extension Character {
    var isBase64URLCharacter: Bool {
        isASCII && (isLetter || isNumber || self == "-" || self == "_")
    }
}
