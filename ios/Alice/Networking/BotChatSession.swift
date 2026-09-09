import Foundation

/// One profile's canonical Bot Chat, as the agent reports it.
///
/// Hermes gives every bot profile exactly one forever-chat, titled `Bot Chat`,
/// and its identity is that title — the sessions table holds at most one row
/// with it. Cron delivery (`deliver: bot-chat`), bot-to-bot messages and any
/// other surface all write there, which is why it is the only transcript worth
/// showing for a bot.
struct CanonicalBotChat: Equatable, Sendable {
    /// The durable registry row.
    let id: String
    /// The live tip, when a compression lineage has moved the conversation
    /// onto a fresh row. Reads and sends address this one; `id` stays the
    /// stable name for the chat.
    let resolvedID: String

    init(id: String, resolvedID: String? = nil) {
        self.id = id
        self.resolvedID = resolvedID ?? id
    }
}

/// Where a bot chat's canonical session and transcript come from.
///
/// A protocol rather than a concrete client because the reachable transport
/// depends on how this agent is configured — see `BotChatTransport` — and
/// because the merge rules below are the part worth testing, which they cannot
/// be against a live server.
protocol BotChatSessionSource: Sendable {
    /// The profile's canonical Bot Chat, or nil when it has none yet.
    func canonicalBotChat(profile: String) async throws -> CanonicalBotChat?

    /// Creates the profile's canonical Bot Chat, or returns the one that
    /// already exists.
    ///
    /// Must be safe to call concurrently: the title is unique server-side, so
    /// a loser re-reads rather than ending up with a second forever-chat.
    func createCanonicalBotChat(profile: String) async throws -> CanonicalBotChat

    /// The persisted turns of one session, oldest first.
    func transcript(
        profile: String, sessionID: String
    ) async throws -> [BotChatTurn]
}

/// One persisted turn, in the shape every transport reduces to.
struct BotChatTurn: Equatable, Sendable {
    let id: String
    let role: Message.Role
    let content: String
    let createdAt: Date
}

/// Resolves a bot's canonical chat and keeps Alice's copy of it honest.
///
/// The whole point is that Hermes owns the transcript. Alice keeps a local
/// `Conversation` because the screen needs something to draw between reads and
/// when the network is gone, but it is a cache of a remote thing, not a second
/// conversation that happens to look similar.
struct BotChatSync: Sendable {
    let source: BotChatSessionSource

    init(source: BotChatSessionSource) {
        self.source = source
    }

    /// The canonical session for a profile, creating it only if there is none.
    ///
    /// Reused rather than recreated: opening a bot twice must not leave two
    /// forever-chats behind, and the create path exists for a profile that has
    /// never been talked to.
    func resolve(profile: String) async throws -> CanonicalBotChat {
        if let existing = try await source.canonicalBotChat(profile: profile) {
            return existing
        }
        return try await source.createCanonicalBotChat(profile: profile)
    }

    /// The canonical transcript, merged into what this device already had.
    ///
    /// Throws rather than returning an empty transcript when the read fails —
    /// the caller keeps showing its cache. A fetch failure is news about the
    /// network, and drawing it as a bot with nothing to say is the same defect
    /// as "No routines yet" over a dashboard that never answered.
    func refresh(
        profile: String, into conversation: Conversation
    ) async throws -> Conversation {
        let chat = try await resolve(profile: profile)
        let turns = try await source.transcript(
            profile: profile, sessionID: chat.resolvedID
        )
        var updated = conversation
        updated.hermesSessionID = chat.resolvedID
        updated.messages = Self.merge(turns, into: conversation.messages, botName: profile)
        return updated
    }

    /// Folds the agent's transcript into the local one.
    ///
    /// The rules, in order of what they protect:
    ///
    /// - **Remote turns win, keyed by their own id.** Merging the same read
    ///   twice changes nothing, and a cron report that arrives while the app
    ///   is closed appears exactly once however many times the chat is
    ///   reopened. Never keyed by text: two identical daily briefings are two
    ///   messages, and a re-rendered one is still the same message.
    /// - **Anything still in flight survives.** A streaming assistant
    ///   placeholder, a turn waiting on an approval, a user message just sent
    ///   and not yet persisted — none of those are in the agent's transcript
    ///   yet, and dropping them would erase the reply being typed.
    /// - **Local-only history survives, marked.** A chat Alice kept before it
    ///   read the canonical one has turns the agent never saw. They stay
    ///   visible and stay flagged; nothing replays them into Hermes.
    /// - **Order is by time**, with remote turns settling ties, so the list
    ///   does not reshuffle between reads.
    static func merge(
        _ remote: [BotChatTurn], into local: [Message], botName: String? = nil
    ) -> [Message] {
        // What the agent has now. A local copy of one of these is replaced by
        // the agent's version rather than kept alongside it.
        var byRemoteID: [String: Message] = [:]
        var order: [String] = []
        for turn in remote where byRemoteID[turn.id] == nil {
            order.append(turn.id)
            byRemoteID[turn.id] = Message(
                id: turn.id,
                role: turn.role,
                content: turn.content,
                createdAt: turn.createdAt,
                botName: turn.role == .assistant ? botName : nil,
                remoteID: turn.id
            )
        }

        // Local turns the agent has no record of. `pending`, an unresolved
        // approval or an unacknowledged send are in flight; everything else is
        // history from before this device read the canonical chat.
        var carried: [Message] = []
        for message in local {
            if let remoteID = message.remoteID, byRemoteID[remoteID] != nil { continue }
            var kept = message
            if kept.role == .assistant, kept.botName == nil {
                kept.botName = botName
            }
            if !message.isInFlight && message.remoteID == nil {
                kept.localOnly = true
            }
            carried.append(kept)
        }

        let remoteMessages = order.compactMap { byRemoteID[$0] }
        // Stable: equal timestamps keep the agent's turn ahead of a local one,
        // so an optimistic send settles below the reply it prompted rather
        // than jumping over it on the next read.
        let merged = (remoteMessages.map { (0, $0) } + carried.map { (1, $0) })
            .enumerated()
            .sorted { left, right in
                let (leftIndex, leftItem) = left
                let (rightIndex, rightItem) = right
                if leftItem.1.createdAt != rightItem.1.createdAt {
                    return leftItem.1.createdAt < rightItem.1.createdAt
                }
                if leftItem.0 != rightItem.0 { return leftItem.0 < rightItem.0 }
                return leftIndex < rightIndex
            }
            .map(\.element.1)
        return merged
    }
}

extension Message {
    /// A turn the agent cannot have persisted yet.
    var isInFlight: Bool {
        if pending { return true }
        if let approval, approval.resolving != true { return true }
        if let runStatus, !runStatus.isTerminal { return true }
        return false
    }
}
