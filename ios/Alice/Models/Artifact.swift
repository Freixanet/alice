import Foundation

/// Something the agent produced or pointed at during a session.
struct Artifact: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case image, file, link

        var title: String {
            switch self {
            case .image: "Images"
            case .file: "Files"
            case .link: "Links"
            }
        }

        var symbol: String {
            switch self {
            case .image: "photo"
            case .file: "doc"
            case .link: "link"
            }
        }
    }

    var id: String { "\(kind.rawValue):\(value)" }
    let kind: Kind
    /// The path or URL exactly as it appeared.
    let value: String
    var session: String
    var tool: String?
    var when: Date?

    /// The last path component, which is what anybody actually reads.
    var name: String {
        guard kind != .link else {
            return URL(string: value)?.host ?? value
        }
        return value.split(separator: "/").last.map(String.init) ?? value
    }
}

/// Finds the artifacts in a session's messages.
///
/// Hermes has no index of these — its own gallery works the same way, by
/// reading back what the agent said and pulling the paths and links out of
/// it. That makes over-detection the risk, not under-detection: a path
/// mentioned in passing looks exactly like one that was written. Only the
/// output of tools that create files is scanned, and only absolute paths.
/// Reading a file used to count as making one: `read_file` results are the
/// file's own text, full of paths the agent never produced.
enum ArtifactScanner {
    /// Tools whose results name a file the agent made or changed.
    static let creatingTools: Set<String> = [
        "write_file", "patch", "image_generate", "text_to_speech",
    ]

    /// Extensions worth showing. Without an allowlist, `com.apple.Safari` and
    /// `icutz44l.dat` come back as files, because a dotted system path is
    /// shaped exactly like a document.
    private static let keptExtensions = Set([
        "md", "markdown", "txt", "pdf", "csv", "json", "html", "xml", "yml", "yaml",
        "py", "ts", "tsx", "js", "jsx", "sh", "swift", "rs", "go", "sql",
        "zip", "xlsx", "xls", "docx", "pptx",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic",
        "mp3", "mp4", "mov", "wav", "m4a",
    ])

    private static let imageExtensions = Set([
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic",
    ])

    /// Files whose names say they hold a secret. A gallery is a list of
    /// things worth opening, and a path to somebody's credentials is neither
    /// worth opening nor worth advertising.
    private static let secretish = [
        "auth", "cred", "token", "secret", "password", "keychain", "id_rsa", ".env",
    ]

    /// Places whose contents the agent passed through rather than produced.
    /// The first pass over a real machine returned Safari's cache and the
    /// tzdata directory, which are not anybody's idea of an artifact.
    private static let ignoredPathParts = [
        "/.hermes/cache/", "/Library/", "/System/", "/private/var/",
        "/var/folders/", "/node_modules/", "/.git/", "/Caches/",
        "/.cache/", "/site-packages/", "/DerivedData/",
    ]

    // No backslash in the character class: a path read out of JSON runs
    // straight into the next line's escape and swallows it.
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?:/Users/|/tmp/|~/)[^\s"'`,;\\)\]]{2,200}\.[A-Za-z0-9]{1,6}"#
    )
    private static let linkPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s"'`,;\\)\]<>]{4,300}"#
    )

    static func scan(
        _ messages: [HermesClient.StoredMessage], session: String
    ) -> [Artifact] {
        var found: [String: Artifact] = [:]

        for message in messages {
            // The reader's own words are not artifacts, and neither is a
            // path the agent merely read out of a prompt.
            guard message.role != "user" else { continue }
            let text = message.content
            guard !text.isEmpty else { continue }

            for value in matches(Self.pathPattern, in: text)
            where Self.creatingTools.contains(message.toolName ?? "") {
                let ext = value.split(separator: ".").last.map { $0.lowercased() } ?? ""
                guard keptExtensions.contains(ext), !isIgnored(value),
                      !isSecretish(value)
                else { continue }
                let kind: Artifact.Kind = imageExtensions.contains(ext) ? .image : .file
                add(Artifact(kind: kind, value: value, session: session,
                             tool: message.toolName, when: message.timestamp), to: &found)
            }
            // Links only from what the agent said in its own voice. Tool
            // output carries every result of every search — two thousand of
            // them from fifteen sessions, which is a haystack, not a gallery.
            // What it chose to hand over is the part worth keeping.
            for value in matches(Self.linkPattern, in: text)
            where message.toolName == nil && message.role == "assistant" {
                let url = trimTrailing(value)
                guard isWorthKeeping(url) else { continue }
                add(Artifact(kind: .link, value: url, session: session,
                             tool: message.toolName, when: message.timestamp), to: &found)
            }
        }
        return Array(found.values)
    }

    private static func isIgnored(_ path: String) -> Bool {
        ignoredPathParts.contains { path.contains($0) }
    }

    private static func isSecretish(_ path: String) -> Bool {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        return secretish.contains { name.contains($0) }
    }

    /// A page somebody could open, not the plumbing of a request.
    private static func isWorthKeeping(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host, host.contains(".") else { return false }
        if host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("100.") {
            return false
        }
        return !url.contains("/api/") && !url.contains("/v1/")
    }

    /// Keeps the first sighting: the earliest mention is the one that made it.
    private static func add(_ artifact: Artifact, to found: inout [String: Artifact]) {
        if found[artifact.id] == nil { found[artifact.id] = artifact }
    }

    private static func matches(_ pattern: NSRegularExpression?, in text: String) -> [String] {
        guard let pattern else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Prose puts full stops after URLs; the URL does not end in one.
    private static func trimTrailing(_ value: String) -> String {
        var result = value
        while let last = result.last, ".,;:!?".contains(last) {
            result.removeLast()
        }
        return result
    }
}
