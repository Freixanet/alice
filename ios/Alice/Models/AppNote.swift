import Foundation

/// What the app tells the agent on its own — "the card is saved, carry on" —
/// after the person finishes something in a card. It travels as a chat turn,
/// because that is how an agent hears anything, but the person did not write
/// it, so the chat never shows it as theirs.
enum AppNote {
    static let prefix = "[Alice app] "

    static func text(_ note: String) -> String { prefix + note }

    /// Also when it went to an agent asked with `@` (`@inbox [Alice app] …`).
    static func isNote(_ text: String) -> Bool {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("@"), let space = body.firstIndex(of: " ") {
            body = body[body.index(after: space)...]
        }
        return body.hasPrefix(prefix.trimmingCharacters(in: .whitespaces))
    }
}
