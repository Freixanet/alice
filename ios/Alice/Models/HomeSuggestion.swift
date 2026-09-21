import Foundation

/// One thing worth doing, derived from state Alice already has.
///
/// Shown on the empty home. It is not a notification: the phone is not awake
/// often enough to promise one, and a suggestion must not invent an alert.
struct HomeSuggestion: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case routines
        case notes
        case agents
        case conversation(String)
        case usage
    }

    var id: String
    var title: String
    var symbol: String
    var action: Action
}

/// A note that still has something unresolved, reduced to what the home row needs.
struct HomeNotePrompt: Equatable, Sendable {
    var id: String
    var label: String
}

/// The home's short list of things that need a person.
///
/// Order is fixed: someone waiting, a failed routine, a chat with no answer,
/// an open question, heavy recent usage, then a morning briefing when the
/// routine list is known and none exists. At most three. Usage and the
/// briefing stay quiet unless the caller already has those facts.
enum HomeSuggestions {
    static let unansweredAfter: TimeInterval = 120
    static let failureWindow: TimeInterval = 7 * 24 * 60 * 60
    static let heavyTokens = 2_000_000

    static func make(
        events: [AliceEvent] = [],
        conversations: [Conversation] = [],
        questions: [HomeNotePrompt] = [],
        routineNames: [String]? = nil,
        recentTokens: Int? = nil,
        now: Date = Date(),
        limit: Int = 3
    ) -> [HomeSuggestion] {
        var rows: [HomeSuggestion] = []
        var claimedChats = Set<String>()

        let waiting = events
            .filter { $0.kind == .needsInput && $0.standing != .resolved && $0.standing != .gone }
            .sorted { $0.occurred > $1.occurred }
        if let event = waiting.first {
            let chat = event.reference.conversationID
            if let chat { claimedChats.insert(chat) }
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

        let quiet = conversations
            .filter { unanswered($0, now: now) && !claimedChats.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let chat = quiet.first {
            rows.append(HomeSuggestion(
                id: "unanswered-\(chat.id)",
                title: chat.title.isEmpty ? "A chat is still waiting" : "\(chat.title) is still waiting",
                symbol: "bubble.left",
                action: .conversation(chat.id)
            ))
        }

        if let note = questions.first(where: { !$0.label.isEmpty }) {
            rows.append(HomeSuggestion(
                id: "question-\(note.id)",
                title: note.label,
                symbol: "note.text",
                action: .notes
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

    private static func unanswered(_ chat: Conversation, now: Date) -> Bool {
        guard let last = chat.messages.last(where: { !$0.interim }) else { return false }
        if chat.messages.contains(where: \.pending) { return false }
        guard last.role == .user else { return false }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return now.timeIntervalSince(last.createdAt) >= unansweredAfter
    }

    private static func hasBriefing(_ names: [String]) -> Bool {
        names.contains { name in
            let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return folded.contains("brief") || folded.contains("morning") || folded.contains("manana")
        }
    }
}
