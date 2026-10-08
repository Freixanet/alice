import Foundation

/// Keep the option token in the submitted/persisted message, but show only the person's choice.
enum PurchaseChoice {
    private static let pattern = #"^(\s*(?:@[\w-]+\s+)?)\[elecci[oó]n:([0-9a-f]{8}-[1-9][0-9]*)\]\s*"#

    static func id(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[range])
    }

    static func display(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let visible = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        return visible.replacingOccurrences(of: #"\s*\[cantidad:[0-9]+\]"#, with: "", options: .regularExpression)
    }
}
