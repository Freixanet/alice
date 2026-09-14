import Foundation

/// A routine's output, as stock Hermes hands it to a bot's chat.
///
/// Hermes' `bot-chat` delivery writes the report into the bot's chat as a turn
/// addressed to the bot — a bracketed header naming the routine, a blank line,
/// then the report — and the bot answers it. The header is Hermes' own wording
/// (`cron/scheduler_delivery.py`). Only its fixed opening is relied on, so a
/// change to the instruction that follows the routine's name still parses.
struct RoutineReport: Equatable, Sendable {
    let name: String
    let body: String
}

extension RoutineReport {
    private static let opening = "[Cronjob \""
    private static let afterName = "\" output — scheduled job, not the user."

    init?(_ text: String) {
        guard text.hasPrefix(Self.opening),
              let nameEnd = text.range(of: Self.afterName),
              let headerEnd = text[nameEnd.upperBound...].firstIndex(of: "]")
        else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: Self.opening.count)..<nameEnd.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = text[text.index(after: headerEnd)...]
        self.init(
            name: name,
            body: String(rest.drop(while: \.isNewline)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
