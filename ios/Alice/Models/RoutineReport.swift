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

    /// Hermes' own notice that a routine could not finish, said in Spanish.
    ///
    /// When a run fails, the report Hermes hands over is its English log line —
    /// "⚠️ Cron 'Radar IA' failed: provider rate limit. Fallback chain was
    /// exhausted…" — or the agent's guardrail message. Nil for a real report.
    static func failure(in body: String) -> String? {
        let cause: String
        if body.hasPrefix("⚠️ Cron '"), let failed = body.range(of: "' failed:") {
            let reason = body[failed.upperBound...].lowercased()
            if reason.contains("rate limit") || reason.contains("429") || reason.contains("quota") {
                cause = "el modelo de IA ha llegado a su límite de uso. Se volverá a intentar en la próxima ejecución."
            } else if reason.contains("timed out") || reason.contains("timeout") {
                cause = "tardó demasiado y se detuvo."
            } else if reason.contains("401") || reason.contains("auth") || reason.contains("api key") {
                cause = "el proveedor de IA no aceptó la clave."
            } else {
                cause = "algo falló en Hermes."
            }
        } else if body.hasPrefix("I stopped retrying") {
            cause = "una herramienta falló varias veces seguidas."
        } else {
            return nil
        }
        return "⚠️ La rutina no se pudo completar: " + cause
    }
}

/// Chollometro's source titles are user-written, and its model occasionally
/// returns an unbalanced or missing Markdown delimiter. Keep the data intact
/// while making the title line before each deal URL structurally consistent.
enum ChollometroReport {
    struct Deal: Equatable, Sendable {
        let title: String
        let detail: String?
        let url: URL
    }

    static func normalizedMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices where index + 1 < lines.count {
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            guard URL(string: next)?.scheme?.hasPrefix("http") == true else { continue }

            let raw = lines[index].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let plain = raw.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }

            if let separator = plain.range(of: " — ") {
                let title = plain[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let detail = plain[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                lines[index] = detail.isEmpty
                    ? "**\(title)**"
                    : "**\(title)** — \(detail)"
            } else {
                lines[index] = "**\(plain)**"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The routine's strict two-line format as data Alice can render with a
    /// real button instead of exposing a long raw URL. Nil leaves unexpected
    /// output untouched rather than hiding any part of it.
    static func deals(in text: String) -> [Deal]? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count.isMultiple(of: 2) else { return nil }

        var deals: [Deal] = []
        for index in stride(from: 0, to: lines.count, by: 2) {
            let raw = lines[index].replacingOccurrences(of: "**", with: "")
            guard let url = URL(string: lines[index + 1]),
                  url.scheme?.hasPrefix("http") == true
            else { return nil }

            if let separator = raw.range(of: " — ") {
                let title = raw[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let detail = raw[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return nil }
                deals.append(Deal(title: title, detail: detail.isEmpty ? nil : detail, url: url))
            } else {
                guard !raw.isEmpty else { return nil }
                deals.append(Deal(title: raw, detail: nil, url: url))
            }
        }
        return deals
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
    /// The card for a run that found nothing (`QuietRoutineRun`).
    static let noNews = "Sin novedades: la rutina se ejecutó y no encontró nada nuevo que contar."

    /// - Parameter agentAnswers: the rows of this chat that answer something it
    ///   asked another agent (`Conversation.agentAnswerIDs`).
    static func present<Messages: Sequence>(
        _ messages: Messages, botName: String?, quietRuns: [QuietRoutineRun] = [],
        agentAnswers: Set<String> = []
    ) -> [Message] where Messages.Element == Message {
        var shown = reports(Array(messages), botName: botName, agentAnswers: agentAnswers)
        // Runs without news leave nothing in the transcript; their cards go
        // where they happened, among the turns around them.
        for run in quietRuns.sorted(by: { $0.finishedAt < $1.finishedAt }) {
            var card = Message(
                id: "quiet:\(run.id)", role: .assistant, content: noNews,
                createdAt: run.finishedAt, botName: botName
            )
            card.routineName = run.routineName
            guard !shown.contains(where: { $0.id == card.id }) else { continue }
            let index = shown.firstIndex {
                MessageTime.isKnown($0.createdAt) && $0.createdAt > run.finishedAt
            } ?? shown.endIndex
            shown.insert(card, at: index)
        }
        return shown
    }

    private static func reports(
        _ messages: [Message], botName: String?, agentAnswers: Set<String>
    ) -> [Message] {
        var shown: [Message] = []
        // The bot answering a turn that was not the person's — a routine's
        // report, or Hermes' notice that a delivery to another agent finished.
        // Left out until the person writes again.
        var answeringHandover = false
        // Another agent's answer is on screen since the person last wrote.
        var heardFromAgent = false
        // The agents whose answers are on screen since the person last wrote.
        var answeredBy: Set<String> = []
        // The agents that wrote to *this* chat asking for something. What this
        // agent sends back is a delivery to them, and Hermes' notice for it
        // names them exactly as one for an answer would. Kept for the whole
        // chat: the notice can arrive long after the request.
        var requesters: Set<String> = []
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                if let report = RoutineReport(message.content) {
                    var delivered = message
                    delivered.role = .assistant
                    delivered.content = RoutineReport.failure(in: report.body) ?? report.body
                    delivered.botName = botName
                    delivered.routineName = report.name
                    shown.append(delivered)
                    answeringHandover = true
                } else if let incoming = AgentMessages.incoming(message.content) {
                    guard AgentMessages.isAnswer(at: index, in: messages, answers: agentAnswers) else {
                        // Another agent asking this one. The exchange is
                        // theirs: the person follows it in the chat that
                        // asked, so neither the request nor this agent's
                        // answer to it shows here.
                        answeringHandover = true
                        requesters.insert(incoming.handle)
                        continue
                    }
                    // Another agent answering, not the person: its own card.
                    var delivered = message
                    delivered.role = .assistant
                    delivered.content = incoming.body
                    delivered.botName = botName
                    delivered.fromAgent = incoming.handle
                    shown.append(delivered)
                    answeredBy.insert(incoming.handle)
                    answeringHandover = false
                    heardFromAgent = true
                } else if let notice = AgentMessages.notice(message.content) {
                    // Hermes telling the bot, with the shell's output attached.
                    // Once the answer itself is on screen, what the bot says
                    // about the delivery only repeats it.
                    if let handle = notice.handle, requesters.contains(handle) {
                        // This agent's own answer on its way back to whoever
                        // asked: a notice says who a delivery went to, never
                        // that they answered. Its output is that chat's, and
                        // so is what this agent says about having delivered.
                        answeringHandover = true
                    } else if notice.succeeded,
                       let handle = notice.handle,
                       !answeredBy.contains(handle),
                       let body = AgentMessages.noticeAnswer(message.content) {
                        // The answer came back only inside the notice. It is
                        // still that agent's answer, so it gets the same card
                        // as one that arrived on its own.
                        var delivered = message
                        delivered.role = .assistant
                        delivered.content = body
                        delivered.botName = botName
                        delivered.fromAgent = handle
                        shown.append(delivered)
                        answeredBy.insert(handle)
                        answeringHandover = false
                        heardFromAgent = true
                    } else if notice.succeeded {
                        answeringHandover = heardFromAgent
                    } else {
                        var failed = message
                        failed.role = .assistant
                        failed.content = AgentMessages.failure(to: notice.handle)
                        failed.botName = botName
                        shown.append(failed)
                        answeringHandover = false
                    }
                } else {
                    shown.append(message)
                    answeringHandover = false
                    heardFromAgent = false
                    answeredBy = []
                }
            case .assistant:
                // A decision the bot is waiting on still needs the person.
                if answeringHandover, message.approval == nil { continue }
                shown.append(message)
            }
        }
        return shown
    }
}
