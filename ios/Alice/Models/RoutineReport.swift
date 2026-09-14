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

/// How a bot's chat shows its routines: each report once, as the bot's message.
///
/// Stock Hermes hands the report to the bot as a turn addressed to it, and the
/// bot answers that turn — copying the report word for word, or commenting on
/// it in another voice. Drawn as they are, one routine came out as a card and
/// then the same report again, or a note about it in a different format, and
/// a failed run twice over. So the report is shown the way the bot would have
/// sent it, and the bot's answer to it is left out until the person writes
/// again. Only the presentation changes: the transcript keeps Hermes' turns.
enum RoutineDelivery {
    static func present<Messages: Sequence>(
        _ messages: Messages, botName: String?
    ) -> [Message] where Messages.Element == Message {
        var shown: [Message] = []
        var answeringRoutine = false
        for message in messages {
            switch message.role {
            case .user:
                if let report = RoutineReport(message.content) {
                    var delivered = message
                    delivered.role = .assistant
                    delivered.content = report.body
                    delivered.botName = botName
                    delivered.routineName = report.name
                    shown.append(delivered)
                    answeringRoutine = true
                } else {
                    shown.append(message)
                    answeringRoutine = false
                }
            case .assistant:
                // A decision the bot is waiting on still needs the person.
                if answeringRoutine, message.approval == nil { continue }
                shown.append(message)
            }
        }
        return shown
    }
}
