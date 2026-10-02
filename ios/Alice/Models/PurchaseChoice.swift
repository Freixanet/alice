import Foundation

/// Keep the option token in the submitted/persisted message, but show only the person's choice.
enum PurchaseChoice {
    /// The plugin numbers options from 1 with no upper bound (`purchase_flow.CHOICE`); the cards page
    /// them six at a time, so the seventh is `…-7`, not a different kind of message.
    private static let pattern = #"^(\s*(?:@[\w-]+\s+)?)\[elecci[oó]n:([0-9a-f]{8}-[1-9][0-9]*)\]\s*"#
    /// The units the person picked travel at the end of the same message (`[cantidad:2]`).
    private static let quantityPattern = #"\s*\[cantidad:([0-9]+)\]\s*$"#

    static func id(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[range])
    }

    static func quantity(in text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: quantityPattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func display(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var shown = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                        withTemplate: "$1")
        if id(in: text) != nil, let units = try? NSRegularExpression(pattern: quantityPattern) {
            shown = units.stringByReplacingMatches(in: shown, range: NSRange(shown.startIndex..., in: shown),
                                                   withTemplate: "")
        }
        return shown
    }
}
