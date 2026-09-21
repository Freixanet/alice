import Foundation

/// A bot's row in Agents: when it last replied, and the opening of what it
/// said — the way a messaging app lists its threads.
struct BotChatPreview: Equatable, Sendable {
    /// The opening of the latest reply with text, on one line.
    let line: String?
    /// When the latest finished reply arrived, if its time is known.
    let repliedAt: Date?
    /// The newest time among finished replies: anything after the chat was
    /// last opened is unread.
    let newestReplyAt: Date?

    static let empty = BotChatPreview(line: nil, repliedAt: nil, newestReplyAt: nil)

    init(line: String?, repliedAt: Date?, newestReplyAt: Date?) {
        self.line = line
        self.repliedAt = repliedAt
        self.newestReplyAt = newestReplyAt
    }

    /// Read from the chat as it is shown (`RoutineDelivery`), so the row
    /// quotes what the chat itself displays.
    init(_ conversation: Conversation, botName: String, quietRuns: [QuietRoutineRun]) {
        let shown = RoutineDelivery.present(
            conversation.messages, botName: botName, quietRuns: quietRuns,
            agentAnswers: Set(conversation.agentAnswerIDs ?? [])
        )
        let finished = shown.filter {
            $0.role == .assistant && !$0.pending && MessageTime.isKnown($0.createdAt)
        }
        repliedAt = finished.last?.createdAt
        newestReplyAt = finished.map(\.createdAt).max()
        line = shown.last {
            $0.role == .assistant && !$0.pending
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.flatMap { Self.oneLine($0.content) }
    }

    /// A reply often starts with a heading or a list, so the raw first line
    /// can be a lone "#" or a bullet. Newlines collapse to spaces and the
    /// markdown that only makes sense in a rendered block is dropped.
    static func oneLine(_ content: String) -> String? {
        let line = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "^[#>*\\-\\s]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // Well past what one line shows; the label truncates the rest.
        return String(line.prefix(160))
    }
}

/// Previews kept per bot, read again only when its chat changed.
///
/// Agents redraws whenever any chat changes, and each row used to present
/// its bot's whole history twice — for the time and for the snippet — on
/// every redraw: a list of twenty bots with long chats re-read thousands of
/// messages for a token streaming somewhere else.
@MainActor
final class BotChatPreviews {
    /// What a preview depends on. Replies are added at the end, and an edit
    /// or a stream changes the last message; answers and quiet runs change
    /// what the chat shows.
    private struct Key: Equatable {
        let count: Int
        let lastID: String?
        let lastContent: Int
        let lastPending: Bool
        let answers: Int
        let quietRuns: [String]
    }

    private var cache: [String: (key: Key, preview: BotChatPreview)] = [:]

    func preview(
        for conversation: Conversation, botName: String, quietRuns: [QuietRoutineRun]
    ) -> BotChatPreview {
        let last = conversation.messages.last
        let key = Key(
            count: conversation.messages.count,
            lastID: last?.id,
            lastContent: last?.content.hashValue ?? 0,
            lastPending: last?.pending ?? false,
            answers: conversation.agentAnswerIDs?.count ?? 0,
            quietRuns: quietRuns.map(\.id)
        )
        let slot = "\(conversation.id)|\(botName)"
        if let hit = cache[slot], hit.key == key { return hit.preview }
        let preview = BotChatPreview(conversation, botName: botName, quietRuns: quietRuns)
        cache[slot] = (key, preview)
        return preview
    }
}
