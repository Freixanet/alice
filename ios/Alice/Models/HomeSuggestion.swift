import Foundation

/// One thing worth doing, derived from state Alice already has.
///
/// Shown on the empty home. It is not a notification: the phone is not awake
/// often enough to promise one, and a suggestion must not invent an alert.
struct HomeSuggestion: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case routines
        case notes
        /// One note, opened in the editor.
        case note(String)
        case agents
        case conversation(String)
        case usage
        /// Alice's own chat, where she writes first (`AppStore.openToday`).
        case today
        /// One agent's chat, by profile.
        case agent(String)
    }

    var id: String
    var title: String
    var symbol: String
    var action: Action
}

/// An agent with something new since its chat was last opened.
struct HomeAgentNews: Equatable, Sendable {
    var slug: String
    var name: String
}

/// A note that still has something unresolved, reduced to what the home row needs.
struct HomeNotePrompt: Equatable, Sendable {
    var id: String
    var label: String
}

/// The home's short list of things that need a person.
///
/// Order is fixed: a request Hermes is still holding, a failed routine, an
/// open question, heavy recent usage, then a morning briefing when the routine
/// list is known and none exists. At most three. A chat that merely ends on
/// the person's message is not waiting. Usage and the briefing stay quiet
/// unless the caller already has those facts.
enum HomeSuggestions {
    static let failureWindow: TimeInterval = 7 * 24 * 60 * 60
    static let heavyTokens = 2_000_000

    static func make(
        events: [AliceEvent] = [],
        questions: [HomeNotePrompt] = [],
        routineNames: [String]? = nil,
        recentTokens: Int? = nil,
        todayUnread: Bool = false,
        agentsWithNews: [HomeAgentNews] = [],
        now: Date = Date(),
        limit: Int = 3
    ) -> [HomeSuggestion] {
        var rows: [HomeSuggestion] = []

        // What Alice started on her own comes first: it is why she is proactive.
        if todayUnread {
            rows.append(HomeSuggestion(
                id: "today", title: "Alice wrote to you", symbol: "sun.max", action: .today
            ))
        }

        let waiting = events
            .filter { $0.kind == .needsInput && $0.standing == .waiting }
            .sorted { $0.occurred > $1.occurred }
        if let event = waiting.first {
            let chat = event.reference.conversationID
            rows.append(HomeSuggestion(
                id: "waiting",
                title: event.title.isEmpty ? "Something is waiting on you" : event.title,
                symbol: "questionmark.bubble",
                action: chat.map(HomeSuggestion.Action.conversation) ?? .agents
            ))
        }

        let failed = events.filter {
            $0.kind == .automationFailed && now.timeIntervalSince($0.occurred) <= failureWindow
        }
        if !failed.isEmpty {
            let title = failed.count == 1
                ? (failed[0].title.isEmpty ? "A routine failed" : failed[0].title)
                : "\(failed.count) routines need a look"
            rows.append(HomeSuggestion(
                id: "routines-failed",
                title: title,
                symbol: "exclamationmark.triangle",
                action: .routines
            ))
        }

        // While you were away: the agents with something new, by name.
        if !agentsWithNews.isEmpty {
            let names = agentsWithNews.prefix(2).map(\.name).joined(separator: " and ")
            let more = agentsWithNews.count > 2 ? " and \(agentsWithNews.count - 2) more" : ""
            rows.append(HomeSuggestion(
                id: "agents-news",
                title: "New from \(names)\(more)",
                symbol: "person.2",
                action: agentsWithNews.count == 1 ? .agent(agentsWithNews[0].slug) : .agents
            ))
        }

        if let note = questions.first(where: { !$0.label.isEmpty }) {
            rows.append(HomeSuggestion(
                id: "question-\(note.id)",
                title: note.label,
                symbol: "note.text",
                action: .note(note.id)
            ))
        }

        if let recentTokens, recentTokens >= heavyTokens {
            rows.append(HomeSuggestion(
                id: "usage",
                title: "Usage has been high lately",
                symbol: "chart.bar",
                action: .usage
            ))
        }

        if let routineNames, !hasBriefing(routineNames) {
            rows.append(HomeSuggestion(
                id: "briefing",
                title: "Set a morning briefing",
                symbol: "sun.horizon",
                action: .routines
            ))
        }

        return Array(rows.prefix(max(limit, 0)))
    }

    private static func hasBriefing(_ names: [String]) -> Bool {
        names.contains { name in
            let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return folded.contains("brief") || folded.contains("morning") || folded.contains("manana")
        }
    }
}
