import Foundation

/// Something the reader attached to a message.
///
/// The bytes live with the conversation rather than as a file reference: a
/// photo picked from the library can be deleted from it, and a conversation
/// that then shows a broken thumbnail is worse than one that carries its own
/// copy. Images are downscaled before they get here.
struct Attachment: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case image, file
    }

    let id: String
    var name: String
    var mime: String
    var kind: Kind
    var data: Data

    /// What the OpenAI-compatible content array expects for an image.
    var dataURL: String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// The contents, if this is something a model can read as text. Mirrors
    /// the web client, which inlines text files into the prompt rather than
    /// pretending the agent can open an attachment.
    var textContents: String? {
        let textual = mime.hasPrefix("text/")
            || mime.range(of: "json|javascript|typescript|xml|yaml|csv",
                          options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: "\\.(md|markdown|json|csv|ts|tsx|js|jsx|py|html|css|xml|ya?ml|txt)$",
                          options: [.regularExpression, .caseInsensitive]) != nil
        guard textual, let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.prefix(50_000))
    }
}

/// One turn in a conversation. Mirrors the web model closely enough that a
/// conversation exported from one client reads correctly in the other.
struct Message: Identifiable, Hashable, Sendable, Codable {
    enum Role: String, Hashable, Sendable, Codable {
        case user, assistant
    }

    struct ToolCall: Identifiable, Hashable, Sendable, Codable {
        enum Status: String, Hashable, Sendable, Codable {
            case start, done
        }

        let id: String
        var name: String
        var status: Status
        var detail: String?
    }

    /// Hermes sometimes finishes the reply without a matching `done` for the
    /// last tool. Those leftovers must not keep a "Reading a page…" line.
    mutating func closeOpenTools() {
        for i in tools.indices where tools[i].status != .done {
            tools[i].status = .done
        }
    }

    /// The reply has stopped: nothing is still running, and how long it took is
    /// written down before `pending` is cleared.
    ///
    /// Measured from when the turn was made, which is when the person sent it.
    /// A reply recovered hours later — the phone slept mid-answer, and the
    /// answer was found on the next read — would otherwise be stamped with the
    /// length of the nap, so anything past an hour is left unsaid rather than
    /// reported as thinking time.
    mutating func settle(at moment: Date = Date()) {
        if pending, thoughtSeconds == nil {
            let took = moment.timeIntervalSince(createdAt)
            if took >= 0, took <= 3600 { thoughtSeconds = Int(took.rounded()) }
        }
        pending = false
        closeOpenTools()
    }

    enum RunStatus: String, Hashable, Sendable, Codable {
        case started
        case queued
        case running
        case waitingForApproval = "waiting_for_approval"
        case stopping
        case completed
        case failed
        case cancelled
        case interrupted

        var isTerminal: Bool {
            self == .completed || self == .failed || self == .cancelled || self == .interrupted
        }
    }

    enum ApprovalChoice: String, CaseIterable, Hashable, Sendable, Codable {
        case once
        case session
        case always
        case deny
    }

    struct Approval: Hashable, Sendable, Codable {
        var runID: String
        /// Exact approval request identity when Hermes supplies one. Required
        /// by room-scoped `/v1/runs/{id}/approval`; optional for older runs.
        var requestID: String? = nil
        var title: String
        var detail: String?
        var command: String?
        var choices: [ApprovalChoice]
        /// UI/network state is optional so conversations written before this
        /// field existed continue to decode without a migration.
        var resolving: Bool?
        var error: String?
        /// Hermes' safety check recommended refusing this one.
        var smartDenied: Bool? = nil
        /// Asked over the dashboard socket, which is where the answer goes —
        /// not to the gateway's runs, whatever kind of chat it appeared in.
        var viaSocket: Bool? = nil

        /// Hermes' own statement of what makes this risky.
        ///
        /// Not in the same place on both routes: a run keeps the tool's name in
        /// `title` ("terminal") and sends the statement as `description`, which
        /// arrives here as `detail`; a bot chat carries it as the title. Reading
        /// only the title explained every run approval as "terminal".
        var hermesDescription: String? {
            if let detail, !detail.isEmpty { return detail }
            return ["Approval needed", "Hermes needs approval"].contains(title) ? nil : title
        }
    }

    let id: String
    var role: Role
    var content: String
    var createdAt: Date
    var pending: Bool = false
    var tools: [ToolCall] = []
    /// How long the agent worked on this reply, in whole seconds, measured when
    /// it stopped. Kept with the message so the trace above it still says what
    /// it took after the app is relaunched.
    var thoughtSeconds: Int? = nil
    var error: String?
    /// Set when the failure was a model limit, so the bubble can say whether
    /// waiting is worth it rather than showing one generic apology.
    var errorLimit: ModelLimit?
    var incomplete: Bool = false
    var attachments: [Attachment] = []
    var botName: String? = nil
    /// Set on a routine's report shown as the bot's message (`RoutineDelivery`).
    /// Never stored with that role: the transcript keeps Hermes' own turn.
    var routineName: String? = nil
    /// Set on another agent's message shown in a bot's chat (`AgentMessages`):
    /// that agent's handle. Hermes stores it as a turn addressed to the bot.
    var fromAgent: String? = nil
    /// Durable Hermes run state. Optional fields preserve compatibility with
    /// conversations saved by older builds.
    var runID: String? = nil
    var runStatus: RunStatus? = nil
    var approval: Approval? = nil
    /// The id this turn has in the Hermes session it belongs to, when it came
    /// from there. Alice's own `id` is a UUID it minted locally; this is the
    /// agent's, and it is what makes merging a transcript idempotent — two
    /// reads of the same turn are the same turn, however the text was
    /// re-rendered in between.
    var remoteID: String? = nil
    /// A turn this device has that the agent's transcript does not.
    ///
    /// Set on messages inherited from a bot chat Alice kept before it learned
    /// to read the canonical one. They are kept visible and never replayed
    /// into Hermes — the agent has no record of them, and inventing one would
    /// put words in its mouth.
    var localOnly: Bool = false
    /// What a reply that has not arrived is waiting on, said in words.
    ///
    /// A busy bot takes a message without starting on it — folded into the
    /// task it is running, or queued behind it — and a phone that locks
    /// mid-reply stops hearing about it. Both looked exactly like a bot
    /// thinking, or, once the app came back, like a failure.
    var deliveryNote: String? = nil
    /// A reply this device stopped watching before it arrived. The bot may
    /// still be working; the next read of its chat replaces this placeholder
    /// with the answer once there is one.
    var awaitingRemote: Bool = false
    /// The exact user turn this assistant placeholder belongs to.
    var replyToMessageID: String? = nil
    /// Exact text submitted to Hermes when it differs from the visible bubble
    /// (for example, gateway-side @file: refs). Used only to correlate the
    /// canonical transcript back to this local message.
    var remoteMatchContent: String? = nil
    /// A reply from an agent named with `@` in another chat. The turn went into
    /// that agent's own Hermes session — the one its chat uses — kept here so
    /// the reply can be found there if this device stops watching it.
    var mentionProfile: String? = nil
    /// Exact bare names chosen from the @ menu. Optional in older archives;
    /// a repeated plain word must not become another highlighted invocation.
    var selectedMentionRanges: [NSRange] = []
    var mentionSessionID: String? = nil
    /// Narration the model said on the way to a tool call, kept as its own
    /// bubble so the tool does not wipe it. Optional so archives written
    /// before this field existed still decode.
    var interim: Bool = false
    /// Last `status.update` on this reply, for the line above the bubble.
    var lastStatus: String? = nil
    /// Tokens and model calls from `message.complete.usage`, when Hermes sent them.
    var usage: MessageUsage? = nil
    /// Tappable options under a slash-command reply. Empty on ordinary turns,
    /// and absent from archives written before a reply could offer a choice.
    var slashChoices: [SlashChoice] = []
    /// `/model` opens the model screen. A catalogue does not belong in the transcript.
    var offersModelChoice: Bool = false
    /// The steps the agent set itself for this task (`TaskPlan`), on the
    /// newest reply of the task only.
    var plan: TaskPlan? = nil

    /// A model catalogue was stored as one chip per model. Those replies open
    /// the picker instead of painting the chat with buttons.
    var choosesModelInAPicker: Bool {
        if offersModelChoice { return true }
        return slashChoices.count > 1
            && slashChoices.allSatisfy { $0.command.hasPrefix("/model set ") }
    }

    /// Decoded field by field, every optional one at a time.
    ///
    /// A default on a non-optional property does **not** make the synthesized
    /// decoder tolerant of a missing key — it still demands one, and throws
    /// `keyNotFound` when an archive written before the field existed does not
    /// carry it. Adding `localOnly` that way threw on the first message of the
    /// first conversation, which the loader swallowed and then persisted over.
    /// Nothing here may depend on a key an older build had no reason to write.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        role = try box.decode(Role.self, forKey: .role)
        content = try box.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try box.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        pending = try box.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        tools = try box.decodeIfPresent([ToolCall].self, forKey: .tools) ?? []
        thoughtSeconds = try box.decodeIfPresent(Int.self, forKey: .thoughtSeconds)
        error = try box.decodeIfPresent(String.self, forKey: .error)
        errorLimit = try box.decodeIfPresent(ModelLimit.self, forKey: .errorLimit)
        incomplete = try box.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        attachments = try box.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        botName = try box.decodeIfPresent(String.self, forKey: .botName)
        runID = try box.decodeIfPresent(String.self, forKey: .runID)
        runStatus = try box.decodeIfPresent(RunStatus.self, forKey: .runStatus)
        approval = try box.decodeIfPresent(Approval.self, forKey: .approval)
        remoteID = try box.decodeIfPresent(String.self, forKey: .remoteID)
        localOnly = try box.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        deliveryNote = try box.decodeIfPresent(String.self, forKey: .deliveryNote)
        awaitingRemote = try box.decodeIfPresent(Bool.self, forKey: .awaitingRemote) ?? false
        replyToMessageID = try box.decodeIfPresent(String.self, forKey: .replyToMessageID)
        remoteMatchContent = try box.decodeIfPresent(String.self, forKey: .remoteMatchContent)
        mentionProfile = try box.decodeIfPresent(String.self, forKey: .mentionProfile)
        selectedMentionRanges = try box.decodeIfPresent([NSRange].self, forKey: .selectedMentionRanges) ?? []
        mentionSessionID = try box.decodeIfPresent(String.self, forKey: .mentionSessionID)
        interim = try box.decodeIfPresent(Bool.self, forKey: .interim) ?? false
        lastStatus = try box.decodeIfPresent(String.self, forKey: .lastStatus)
        usage = try box.decodeIfPresent(MessageUsage.self, forKey: .usage)
        slashChoices = try box.decodeIfPresent([SlashChoice].self, forKey: .slashChoices) ?? []
        offersModelChoice = try box.decodeIfPresent(Bool.self, forKey: .offersModelChoice) ?? false
        plan = try box.decodeIfPresent(TaskPlan.self, forKey: .plan)
    }

    init(
        id: String, role: Role, content: String, createdAt: Date,
        pending: Bool = false, tools: [ToolCall] = [], error: String? = nil,
        errorLimit: ModelLimit? = nil, incomplete: Bool = false,
        attachments: [Attachment] = [], botName: String? = nil,
        runID: String? = nil, runStatus: RunStatus? = nil,
        approval: Approval? = nil, remoteID: String? = nil,
        localOnly: Bool = false, deliveryNote: String? = nil,
        awaitingRemote: Bool = false, replyToMessageID: String? = nil,
        remoteMatchContent: String? = nil,
        mentionProfile: String? = nil,
        selectedMentionRanges: [NSRange] = [],
        interim: Bool = false
    ) {
        self.mentionProfile = mentionProfile
        self.selectedMentionRanges = selectedMentionRanges
        self.deliveryNote = deliveryNote
        self.awaitingRemote = awaitingRemote
        self.replyToMessageID = replyToMessageID
        self.remoteMatchContent = remoteMatchContent
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.pending = pending
        self.tools = tools
        self.error = error
        self.errorLimit = errorLimit
        self.incomplete = incomplete
        self.attachments = attachments
        self.botName = botName
        self.runID = runID
        self.runStatus = runStatus
        self.approval = approval
        self.remoteID = remoteID
        self.localOnly = localOnly
        self.interim = interim
    }
}

struct Conversation: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// When it was last opened, which is not when it was last written to: a
    /// conversation you reread today should come back before one you replied
    /// in last week. Absent on anything saved before this was recorded.
    var openedAt: Date?
    /// Kept at the top of the drawer, above everything else.
    var pinned: Bool = false
    /// Last known Hermes Project display name. Kept for archive compatibility
    /// and immediate UI feedback only: authoritative membership is derived by
    /// Hermes from the session's cwd and the Project's workspace folders.
    var project: String?
    var messages: [Message] = []
    var botName: String? = nil
    /// The canonical Hermes session this chat *is*, once resolved.
    ///
    /// Deliberately not `id`: that one is Alice's, minted before any agent was
    /// asked, and overloading it to mean both identities is how a local UUID
    /// ended up being sent as a Hermes session key — which made every bot chat
    /// a private conversation with the default profile instead of the bot's
    /// own forever-chat.
    var hermesSessionID: String? = nil
    /// The bot a recovered conversation belongs to *on screen only*.
    ///
    /// Ownership and routing used to be the same field, and they are not the
    /// same thing any more. A conversation recovered from before Alice read
    /// canonical Bot Chats was a default-profile session wearing a synthetic
    /// persona: it is that bot's history to the reader, and to nobody else.
    /// Setting `botName` would route sends into the bot's real session and
    /// splice two agents' conversations together; leaving both nil filed the
    /// history under Home, where it does not belong either.
    var legacyBotName: String? = nil
    /// A team: a shared chat with several bots (`channelBots`). The name is
    /// from when a channel was a chat; a channel is now a folder (`BotChannel`).
    var isChannel: Bool? = false
    var channelBots: [String]? = []
    /// The channel a team belongs to.
    var teamChannelID: String? = nil
    /// Hermes rows in this bot chat that answer something it asked another
    /// agent (`AgentMessages.delegations`). Any other agent's message here is
    /// that agent asking this one, and is not shown.
    var agentAnswerIDs: [String]? = nil

    /// Same contract as `Message.init(from:)`: every key an older build might
    /// not have written is optional here, so a new field can never turn an
    /// existing archive into a decode failure.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        createdAt = try box.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try box.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        openedAt = try box.decodeIfPresent(Date.self, forKey: .openedAt)
        pinned = try box.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        project = try box.decodeIfPresent(String.self, forKey: .project)
        messages = try box.decodeIfPresent([Message].self, forKey: .messages) ?? []
        botName = try box.decodeIfPresent(String.self, forKey: .botName)
        legacyBotName = try box.decodeIfPresent(String.self, forKey: .legacyBotName)
        hermesSessionID = try box.decodeIfPresent(String.self, forKey: .hermesSessionID)
        isChannel = try box.decodeIfPresent(Bool.self, forKey: .isChannel)
        channelBots = try box.decodeIfPresent([String].self, forKey: .channelBots)
        teamChannelID = try box.decodeIfPresent(String.self, forKey: .teamChannelID)
        agentAnswerIDs = try box.decodeIfPresent([String].self, forKey: .agentAnswerIDs)
    }

    init(
        id: String, title: String, createdAt: Date, updatedAt: Date,
        openedAt: Date? = nil, pinned: Bool = false, project: String? = nil,
        messages: [Message] = [], botName: String? = nil,
        legacyBotName: String? = nil,
        hermesSessionID: String? = nil, isChannel: Bool? = false,
        channelBots: [String]? = [], teamChannelID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.openedAt = openedAt
        self.pinned = pinned
        self.project = project
        self.messages = messages
        self.botName = botName
        self.legacyBotName = legacyBotName
        self.hermesSessionID = hermesSessionID
        self.isChannel = isChannel
        self.channelBots = channelBots
        self.teamChannelID = teamChannelID
    }

    /// The profile a turn typed here is sent to, if any.
    ///
    /// The routing identity, and the only one. Never `legacyBotName`: that
    /// bot never held this conversation.
    var routedBotName: String? {
        guard let botName, !botName.isEmpty else { return nil }
        return botName
    }

    /// The bot this conversation is filed under on screen, routed or not.
    var owningBotName: String? { routedBotName ?? legacyBotName }

    /// Filed under a bot rather than under Home. Display only.
    var isBotOwnedConversation: Bool {
        owningBotName != nil || isChannel == true
    }

    /// A live chat with a bot: it routes, and it has a canonical session to
    /// read and write. A recovered legacy thread is not one of these.
    var isCanonicalBotChat: Bool {
        routedBotName != nil && isChannel != true
    }

    /// Alice's own chat, continuing in a Hermes session over the dashboard
    /// socket rather than as gateway runs.
    var isHomeSessionChat: Bool {
        routedBotName == nil && legacyBotName == nil && isChannel != true
            && hermesSessionID != nil
    }

    /// Recovered history, kept for reading. Sending into it would resume a
    /// simulated default-profile session, or worse, be redirected into the
    /// bot's real one.
    var isRecoveredHistory: Bool {
        routedBotName == nil && legacyBotName != nil
    }

    /// Filed under a bot on screen.
    ///
    /// Kept as the name every screen already uses, but it now means ownership
    /// and nothing else — every send path asks `routedBotName`.
    var isBotChat: Bool { isBotOwnedConversation }

    static func blank(title: String = "New chat") -> Conversation {
        let now = Date()
        return Conversation(
            id: UUID().uuidString, title: title, createdAt: now, updatedAt: now
        )
    }
}

/// Events the chat transport yields while a reply streams in.
enum ChatEvent: Sendable {
    case delta(String)
    case tool(id: String, name: String, status: Message.ToolCall.Status, detail: String?)
    case run(id: String, status: Message.RunStatus, output: String?)
    case approval(Message.Approval)
    case failure(message: String, limit: ModelLimit?)
    /// Commentary beside a tool, when Hermes did not already stream it.
    case interim(String)
    /// A live status line from Hermes (`status.update`).
    case status(String)
    /// The agent's plan for the task changed (`TaskPlan`).
    case plan(TaskPlanChange)
}

/// Whether two stretches of a turn are the same words, so an interim
/// frame that repeats streamed deltas is not sealed as a second bubble.
/// Tokens and calls Hermes reported for one finished reply.
struct MessageUsage: Hashable, Sendable, Codable {
    var model: String?
    var input: Int = 0
    var output: Int = 0
    var reasoning: Int = 0
    var total: Int = 0
    var calls: Int = 0
    var seconds: Int?
    /// Prompt tokens Hermes reused from cache, when it reported a count.
    var cacheRead: Int = 0
    /// Cache hit percent from `usage.cache_hit_pct`, when there was no count.
    var cacheHitPercent: Int? = nil

    enum CodingKeys: String, CodingKey {
        case model, input, output, reasoning, total, calls, seconds
        case cacheRead, cacheHitPercent
    }

    init(
        model: String? = nil, input: Int = 0, output: Int = 0, reasoning: Int = 0,
        total: Int = 0, calls: Int = 0, seconds: Int? = nil,
        cacheRead: Int = 0, cacheHitPercent: Int? = nil
    ) {
        self.model = model
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.total = total
        self.calls = calls
        self.seconds = seconds
        self.cacheRead = cacheRead
        self.cacheHitPercent = cacheHitPercent
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        model = try box.decodeIfPresent(String.self, forKey: .model)
        input = try box.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try box.decodeIfPresent(Int.self, forKey: .output) ?? 0
        reasoning = try box.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        total = try box.decodeIfPresent(Int.self, forKey: .total) ?? 0
        calls = try box.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        seconds = try box.decodeIfPresent(Int.self, forKey: .seconds)
        cacheRead = try box.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheHitPercent = try box.decodeIfPresent(Int.self, forKey: .cacheHitPercent)
    }

    static func parse(_ payload: [String: Any]) -> MessageUsage? {
        guard let bag = dictionary(payload["usage"]) else { return nil }
        let model = (bag["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let input = int(bag["input"]) > 0 ? int(bag["input"]) : int(bag["prompt"])
        let output = int(bag["output"]) > 0 ? int(bag["output"]) : int(bag["completion"])
        let reasoning = int(bag["reasoning"])
        let total = int(bag["total"])
        let calls = int(bag["calls"])
        let cacheRead = int(bag["cache_read"]) > 0
            ? int(bag["cache_read"]) : int(bag["cache_read_tokens"])
        let cacheHit = int(bag["cache_hit_pct"])
        if (model == nil || model?.isEmpty == true)
            && input == 0 && output == 0 && reasoning == 0 && total == 0 && calls == 0
            && cacheRead == 0 && cacheHit == 0 {
            return nil
        }
        return MessageUsage(
            model: (model?.isEmpty == false) ? model : nil,
            input: input, output: output, reasoning: reasoning,
            total: total > 0 ? total : input + output + reasoning,
            calls: calls,
            cacheRead: cacheRead,
            cacheHitPercent: cacheHit > 0 ? cacheHit : nil
        )
    }

    /// Developer-mode line under a finished reply.
    static func footer(usage: MessageUsage?, tools: Int, seconds: Int?) -> String? {
        guard usage != nil || tools > 0 || (seconds ?? 0) > 0 else { return nil }
        var parts: [String] = []
        if let model = usage?.model, !model.isEmpty { parts.append(model) }
        if let calls = usage?.calls, calls > 0 { parts.append("\(calls) LLM") }
        parts.append(tools == 1 ? "1 tool" : "\(tools) tools")
        if let usage {
            parts.append("in \(usage.input)")
            parts.append("out \(usage.output)")
            parts.append("think \(usage.reasoning)")
            if usage.cacheRead > 0 {
                parts.append("cached \(usage.cacheRead)")
            } else if let percent = usage.cacheHitPercent, percent > 0 {
                parts.append("cached \(percent)%")
            }
        }
        if let seconds, seconds > 0 { parts.append("\(seconds) s") }
        return parts.joined(separator: " · ")
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let bag = value as? [String: Any] { return bag }
        if let bag = value as? [String: String] { return bag }
        if let bag = value as? NSDictionary {
            var mapped: [String: Any] = [:]
            for (key, item) in bag {
                if let name = key as? String { mapped[name] = item }
            }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }
}

enum TurnNarration {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isDuplicate(_ text: String, of existing: String) -> Bool {
        let incoming = normalized(text)
        let have = normalized(existing)
        guard !incoming.isEmpty else { return true }
        return incoming == have || have.hasPrefix(incoming) || incoming.hasPrefix(have)
    }
}
