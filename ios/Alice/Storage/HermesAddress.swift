import Foundation

/// What Alice will accept as a Hermes gateway address.
///
/// Someone can type a bare host, a host and port, or a full URL. Plain HTTP is
/// limited to local, private and Tailscale destinations; a public host must
/// authenticate and encrypt with HTTPS.
enum HermesAddress {
    static func normalize(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        var value = text
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              scheme == "https" || allowsPrivateHTTP(host: host)
        else { return nil }
        if components.path.isEmpty { components.path = "/" }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func allowsPrivateHTTP(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || (!host.contains(".") && !host.contains(":")) {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 100 && (64...127).contains(octets[1]))
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }

        // Loopback, link-local and unique-local IPv6. Tailscale's IPv6 range
        // is unique-local and therefore included without accepting public IPv6.
        guard host.contains(":") else { return false }
        return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
    }

    static func connectionError(_ text: String) -> String {
        var value = text
        if !value.contains("://") { value = "http://" + value }
        if let components = URLComponents(string: value),
           components.scheme?.lowercased() == "http",
           let host = components.host, !host.isEmpty,
           !allowsPrivateHTTP(host: host) {
            return "Use HTTPS for a Hermes address outside your local network or tailnet."
        }
        return "Check the address."
    }
}
