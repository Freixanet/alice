import Foundation

/// What the app will let a manifest ask for.
///
/// The manifest is something the agent says, not something it is allowed to
/// decide. These two questions stand alone, with nothing else in them, so
/// they can be answered in a test without a client, a key or a network.
enum GatewayOrigin {
    /// A manifest route, or nil if it is not one.
    ///
    /// The manifest is something the agent says, not something it is allowed
    /// to decide. A route given as an absolute URL keeps its own origin when
    /// resolved, and the request built from it carried the gateway key and the
    /// session token to whatever host it named — so a manifest reading
    /// `https://elsewhere.example/collect` was a instruction to hand the key
    /// over. Only a plain relative path is accepted: no scheme, no authority,
    /// no protocol-relative `//host`, and nothing climbing out with `..`.
    static func relativeRoute(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        guard !trimmed.hasPrefix("//") else { return nil }
        // A scheme is anything before the first ":" that a URL would treat as
        // one; simply refusing every colon before the first "/" covers
        // "https:", "javascript:", "data:" and the rest without guessing.
        if let colon = trimmed.firstIndex(of: ":"),
           let slash = trimmed.firstIndex(of: "/"),
           colon < slash {
            return nil
        }
        if !trimmed.contains("/"), trimmed.contains(":") { return nil }
        guard !trimmed.split(separator: "/").contains("..") else { return nil }
        // Control characters and whitespace inside a path are not a path.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
        else { return nil }
        return trimmed
    }

    /// Whether a resolved URL is still the gateway this client was given.
    ///
    /// Checked after resolution and before any credential is attached, so a
    /// route that slips past the parser cannot take the key with it.
    static func sameOrigin(_ url: URL, as base: URL) -> Bool {
        guard let a = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let b = URLComponents(url: base, resolvingAgainstBaseURL: true)
        else { return false }
        let portA = a.port ?? defaultPort(for: a.scheme)
        let portB = b.port ?? defaultPort(for: b.scheme)
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && portA == portB
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

}
