import Foundation

/// Complete OpenIntelligentUI snapshot carried by normal Hermes chat text.
/// No new persisted fields: existing transcripts/sync retain the original fence.
struct InteractiveArtifact: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let initialHeight: Int
    let placeholderMessages: [String]
    let css: String
    let html: String
    let jsFunctions: String
    let jsExpressions: String

    static let fields: Set<String> = ["title", "summary", "initialHeight", "placeholderMessages", "css", "html", "jsFunctions", "jsExpressions"]

    /// Wire compatibility for two harmless model formatting variations. Keep
    /// executable content, all field limits and the strict contract validator intact.
    static func fromChatJSON(_ json: String) throws -> Self {
        guard json.utf8.count <= 700_000, let data = json.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.coderInvalidValue) }
        if let type = object["type"] {
            guard type as? String == "alice-interactive" else { throw CocoaError(.coderInvalidValue) }
            object.removeValue(forKey: "type")
        }
        if let messages = object["placeholderMessages"] as? [String], messages.count == 1 {
            // Loading copy is presentation metadata, not an execution capability.
            object["placeholderMessages"] = [messages[0], messages[0]]
        }
        return try Self(json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    init(json: String) throws {
        guard json.utf8.count <= 700_000,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.fields else { throw CocoaError(.coderInvalidValue) }
        self = try JSONDecoder().decode(Self.self, from: data)
        let strings = [(title, 160), (summary, 2000), (css, 20000), (html, 80000), (jsFunctions, 60000), (jsExpressions, 10000)]
        guard strings.allSatisfy({ $0.0.unicodeScalars.count <= $0.1 && !$0.0.contains("```") && !$0.0.contains("\0") }),
              [title, summary, html].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (180...900).contains(initialHeight), (2...4).contains(placeholderMessages.count),
              placeholderMessages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 120 }),
              html.range(of: #"<\s*(?:script|style|iframe|object|embed|form|meta|base)\b|type\s*=\s*['"]?password\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { throw CocoaError(.coderInvalidValue) }
    }
}
