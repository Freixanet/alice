import Foundation

/// Source events never become executable buttons. The only action is a chat reply.
struct ProactiveMessage: Codable, Hashable, Sendable {
    let happened: String
    let matters: String
    let reply: String

    static func parse(_ text: String) -> Self? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["happened", "matters", "reply"]),
              let happened = object["happened"] as? String,
              let matters = object["matters"] as? String,
              let reply = object["reply"] as? String
        else { return nil }
        let values = [happened, matters, reply].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }), values[0].count <= 800,
              values[1].count <= 800, values[2].count <= 240,
              !values[2].hasPrefix("/"), !values[2].contains("\n")
        else { return nil }
        return Self(happened: values[0], matters: values[1], reply: values[2])
    }

    static func fallback(_ text: String) -> Self {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            happened: plain.isEmpty || plain.hasPrefix("{")
                ? String(localized: "Alice found an update to review.") : plain,
            matters: String(localized: "It may need your attention."),
            reply: String(localized: "Help me review this update.")
        )
    }
}
