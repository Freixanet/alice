import Foundation
import Observation

/// Everything the interface reads. One observable object on the main actor,
/// which keeps the views free of their own state juggling and matches how the
/// web client centralises the same data.
@MainActor
@Observable
final class AppStore {
    // Preferences
    var theme: ThemeChoice = .system {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var accent: Accent = .stone {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    // Connection
    var gatewayURL: String = "" {
        didSet { defaults.set(gatewayURL, forKey: Keys.gateway) }
    }

    // The dashboard is a separate address with its own login. Kept apart from
    // the gateway because an install can have one without the other.
    var dashboardURL: String = "" {
        didSet { defaults.set(dashboardURL, forKey: Keys.dashboard) }
    }
    var dashboardUser: String = "" {
        didSet { defaults.set(dashboardUser, forKey: Keys.dashboardUser) }
    }
    private(set) var dashboardReady = false

    private(set) var isConnected = false
    private(set) var manifest: HermesClient.Manifest?
    private(set) var models: [HermesClient.ModelOption] = []
    var selectedModel: String? {
        didSet { defaults.set(selectedModel, forKey: Keys.model) }
    }

    /// The last few models picked, most recent first.
    ///
    /// Somebody who uses one or two models does not want to hunt for them
    /// among a hundred every time.
    var recentModels: [String] = [] {
        didSet { defaults.set(recentModels, forKey: Keys.recentModels) }
    }

    /// The provider the reader picked the model *under*.
    ///
    /// The picker groups by provider, so tapping a model under "Nous Portal"
    /// is choosing Nous — but the same model id is often served by several,
    /// and without this the agent was left to route it and sent an Anthropic
    /// model listed under Nous to OpenRouter, which billed for it and refused.
    var selectedProvider: String? {
        didSet { defaults.set(selectedProvider, forKey: Keys.provider) }
    }

    var connectionError: String?
    var isConnecting = false
    /// Why the model list is empty, when it is. A picker that just says "no
    /// models" leaves you with nowhere to go.
    private(set) var modelsError: String?
    private(set) var isLoadingModels = false
    /// Only `/v1/models` answered: one model, not the list.
    private(set) var modelListIsPartial = false

    // Conversations
    var conversations: [Conversation] = [.blank()] {
        didSet {
            refreshConversationShelves()
            refreshActiveChat()
            refreshBotNameSets()
        }
    }
    /// What the screen shows of the chat on it, kept apart from
    /// `conversations`.
    ///
    /// A view that read `activeConversation` depended on the whole array, so
    /// every change to any chat — a token streaming in, another agent's chat
    /// syncing in the background, a timestamp — redrew the app's shell, the
    /// composer and every message on screen. These are reassigned only when
    /// what they hold actually changed.
    struct ActiveChat: Equatable {
        var id: String?
        var botName: String?
        var routedBotName: String?
        var isChannel = false
        var isCanonicalBotChat = false
        var isRecoveredHistory = false
    }
    private(set) var activeChat = ActiveChat()
    /// The chat on screen, as `activeConversation`, but only reassigned when
    /// that chat changes.
    private(set) var shownConversation: Conversation?

    /// A chat by id for code that draws. The chat on screen comes from
    /// `shownConversation`, so a view asking about it is not tied to every
    /// other chat; any other is looked up in `conversations`.
    func conversation(_ id: String) -> Conversation? {
        if activeChat.id == id { return shownConversation }
        return conversations.first { $0.id == id }
    }

    private func refreshActiveChat() {
        let current = conversations.first { $0.id == activeID }
        let identity = ActiveChat(
            id: current?.id,
            botName: current?.botName,
            routedBotName: current?.routedBotName,
            isChannel: current?.isChannel == true,
            isCanonicalBotChat: current?.isCanonicalBotChat == true,
            isRecoveredHistory: current?.isRecoveredHistory == true
        )
        if identity != activeChat { activeChat = identity }
        if current != shownConversation { shownConversation = current }
    }
    /// Home chats for the drawer, kept still while a reply streams.
    private(set) var pinnedConversations: [Conversation] = []
    private(set) var recentConversations: [Conversation] = []
    private var conversationShelfFingerprint = 0

    /// Rebuilds the drawer lists only when membership or pins change.
    private func refreshConversationShelves() {
        let fingerprint = conversations.reduce(into: 0) { acc, chat in
            acc = acc &* 31 &+ chat.id.hashValue
            acc = acc &* 31 &+ chat.title.hashValue
            acc = acc &* 31 &+ (chat.pinned ? 1 : 0)
            acc = acc &* 31 &+ (chat.isBotChat ? 1 : 0)
        }
        guard fingerprint != conversationShelfFingerprint else { return }
        conversationShelfFingerprint = fingerprint
        pinnedConversations = conversations.filter { $0.pinned && !$0.isBotChat }
        recentConversations = conversations.filter { !$0.pinned && !$0.isBotChat }
    }
    var activeID: String? {
        didSet {
            defer { refreshActiveChat() }
            // An edit belongs to the chat it was started in.
            if activeID != oldValue, editingMessageID != nil { cancelEditing() }
            if activeID != oldValue { markMentionRepliesSeen(in: activeID) }
            guard activeID != oldValue,
                  let index = conversations.firstIndex(where: { $0.id == activeID })
            else { return }
            conversations[index].openedAt = Date()
        }
    }
    var draft: String = "" {
        didSet { draftMentions = DraftMention.rebased(draftMentions, from: oldValue, to: draft) }
    }
    /// Exact occurrences picked from the `@` menu. The `@` is gone from the
    /// text, so a slug alone would mark later ordinary uses of the same word.
    var draftMentions: [DraftMention] = []
    /// Waiting to go out with the next message.
    var draftAttachments: [Attachment] = []
    /// Chats with a reply under way. Each follows its own: one agent at work
    /// must not hold up — or offer Stop in — every other chat.
    private(set) var sendingConversations: Set<String> = []
    /// Whether the chat on screen has a reply under way.
    var isSending: Bool { activeID.map { sendingConversations.contains($0) } ?? false }
    @ObservationIgnored private var latencyStartedAt: [String: Date] = [:]
    @ObservationIgnored private var latencyLogged: [String: Set<String>] = [:]

    private let client = HermesClient()
    /// One socket for the whole app, built lazily once the dashboard is
    /// connected. The protocol addresses a session per call, so this is a
    /// transport, not a single global conversation — per-chat streaming can
    /// be layered on it without another transport rewrite.
    private var rpcClient: HermesRPCClient?
    /// Why a bot chat's transcript could not be re-read, keyed by conversation.
    /// Present means the list on screen may be behind the agent's.
    var botChatFailure: [String: String] = [:]
    /// Routine runs that finished with nothing to report, keyed by bot. Hermes
    /// sends nothing for those, and without a card a routine with no news and
    /// one that never ran look the same.
    ///
    /// Kept on the phone. Held only in memory, they were empty on every launch
    /// until a bot chat's full refresh finished: an agent's chat ended at an
    /// older failed run, with the later quiet ones missing, for as long as
    /// that took — or for good when the refresh failed.
    var quietRoutineRuns: [String: [QuietRoutineRun]] = [:] {
        didSet { persistQuietRuns() }
    }
    /// Run ids already read for silence, keyed by bot.
    private var judgedRoutineRuns: [String: Set<String>] = [:] {
        didSet { persistQuietRuns() }
    }
    @ObservationIgnored private var quietRunsLoaded = false
    private let dashboard = DashboardClient()
    private let defaults: UserDefaults
    /// Where conversations are kept (`FileConversationStorage`), apart from
    /// the small settings in `defaults`.
    private let conversationStorage: ConversationStorage
    /// The Face ID gate and per-note locks. Public surface is forwarded below
    /// so call sites keep `store.requireUnlock`-style access.
    let lock: AppLock
    private var streamTasks: [String: Task<Void, Never>] = [:]
    /// Tokens waiting to be drawn. Applied together so a fast reply does not
    /// rebuild the chat once per character.
    @ObservationIgnored private var pendingStreamText: [String: PendingStreamText] = [:]
    @ObservationIgnored private var streamFlush: Task<Void, Never>?
    private var persistGeneration = 0
    private var persistTask: Task<Void, Never>?
    private var conversationFingerprints: [String: Int] = [:]
    private var persistedConversationIDs: Set<String> = []
    private var protectedConversationIDs: Set<String> = []

    private enum Keys {
        static let quietRuns = "alice.quietRoutineRuns"
        static let judgedRuns = "alice.judgedRoutineRuns"
        static let phoneActions = "alice.phoneActions"
        static let theme = "alice.theme"
        static let accent = "alice.accent"
        static let gateway = "alice.gateway"
        static let model = "alice.model"
        static let provider = "alice.model.provider"
        static let recentModels = "alice.models.recent"
        static let dashboard = "alice.dashboard"
        static let dashboardUser = "alice.dashboard.user"
        static let marks = "alice.bot.marks"
        static let botSections = "alice.bot.sections"
        static let botCustomSections = "alice.bot.customSections"
        static let collapsedSections = "alice.bot.collapsedSections"
        static let pinnedBots = "alice.bot.pinned"
        static let unreadBots = "alice.bot.unread"
        static let unreadBotsVersion = "alice.bot.unread.version"
        static let hiddenBots = "alice.bot.hidden"
        static let retiredBotSlugs = "alice.bot.retiredSlugs"
        static let botModels = "alice.bot.models"
        static let recentBotModels = "alice.bot.models.recent"
        static let botNotifications = "alice.bot.notifications"
        static let botRoutines = "alice.bot.routines"
        static let botCustomNames = "alice.bot.customNames"
        static let botSectionOrder = "alice.bot.sectionOrder"
        static let botChannels = "alice.bot.channels"
        static let barkRelays = Notifier.barkRelaysKey
        static let homeShortcuts = "alice.home.shortcuts"
        static let botPlacementsApplied = "alice.bot.placementsApplied"
        static let unassignedExpanded = "alice.bot.unassignedExpanded"
        static let hiddenExpanded = "alice.bot.hiddenExpanded"
        static let homeCollapsed = "alice.bot.homeCollapsed"
        static let notesAsCards = "alice.notes.asCards"
        static let developerMode = "alice.developerMode"
        static let botChatClearedAt = "alice.bot.chatClearedAt"
        static let botOrder = "alice.bot.order"
        static let cachedBots = "alice.cached.bots"
        static let pendingBotModelSyncs = "alice.bot.model.pendingSyncs"
        static let eventWatermarks = "alice.events.watermarks"
        static let activity = "alice.events.activity"
        static let notesSnapshot = "alice.notes.snapshot"
        static let mutedRoutines = "alice.routines.muted"
        static let pinnedNotes = "alice.notes.pinned"
        static let noteFolders = "alice.notes.folders"
        static let noteFolderOf = "alice.notes.folderOf"
        static let notesSort = "alice.notes.sort"
        static let notesGroupByDate = "alice.notes.groupByDate"
        static let noteFolderParent = "alice.notes.folderParent"
        static let noteFolderOrder = "alice.notes.folderOrder"
        static let pinnedNoteFolders = "alice.notes.pinnedFolders"
        static let noteFolderSort = "alice.notes.folderSort"
        static let recentlyDeleted = "alice.notes.recentlyDeleted"
        static let activitySeen = "alice.events.activitySeen"
        static let agentsNoticesSeen = "alice.events.agentsNoticesSeen"
        static let routinesNoticesSeen = "alice.events.routinesNoticesSeen"
        static let dismissedAttention = "alice.events.dismissedAttention"
    }

    static let unassignedSectionKey = "__unassigned__"

    var botCustomNames: [String: String] = [:] {
        didSet { defaults.set(botCustomNames, forKey: Keys.botCustomNames) }
    }

    var botSectionOrder: [String] = [] {
        didSet { defaults.set(botSectionOrder, forKey: Keys.botSectionOrder) }
    }

    /// Presentation order for named bots. Hermes has no equivalent ordering
    /// field, so this remains an Alice UI preference just like sections.
    var botOrder: [String] = [] {
        didSet { defaults.set(botOrder, forKey: Keys.botOrder) }
    }

    var botSections: [String: String] = [:] {
        didSet { defaults.set(botSections, forKey: Keys.botSections) }
    }
    var botCustomSections: [String] = [] {
        didSet { defaults.set(botCustomSections, forKey: Keys.botCustomSections) }
    }
    /// Whether the Mac's notifier reaches this phone through Bark, so replies
    /// and routines are not also announced by Alice herself
    /// (`Notifier.relayedKinds`). Turned on by the first Bark notification
    /// opened — only Bark opens `alice://open` links — and switchable in
    /// Settings.
    var barkRelays: Bool = false {
        didSet { defaults.set(barkRelays, forKey: Keys.barkRelays) }
    }

    var collapsedSections: Set<String> = [] {
        didSet { defaults.set(Array(collapsedSections), forKey: Keys.collapsedSections) }
    }
    /// Channels on the Bots page (`BotChannel`), kept on this phone like
    /// sections.
    var botChannels: [BotChannel] = [] {
        didSet {
            refreshBotNameSets()
            if let data = try? JSONEncoder().encode(botChannels) {
                defaults.set(data, forKey: Keys.botChannels)
            }
        }
    }
    /// Pins on the empty home. Phone-only, like channels.
    var homeShortcuts: [HomeShortcut] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(homeShortcuts) {
                defaults.set(data, forKey: Keys.homeShortcuts)
            }
        }
    }
    /// The placement revision already applied to each agent
    /// (`BotChannel.applyingPlacements`), so it is applied only once.
    private var botPlacementsApplied: [String: Int] = [:] {
        didSet { defaults.set(botPlacementsApplied, forKey: Keys.botPlacementsApplied) }
    }
    /// Whether Unassigned and Hidden are open. Like every section, each stays
    /// as it was left until the person changes it.
    var unassignedExpanded = false {
        didSet { defaults.set(unassignedExpanded, forKey: Keys.unassignedExpanded) }
    }
    var hiddenExpanded = false {
        didSet { defaults.set(hiddenExpanded, forKey: Keys.hiddenExpanded) }
    }
    /// Home — the agents in no channel — folded shut.
    var homeCollapsed = false {
        didSet { defaults.set(homeCollapsed, forKey: Keys.homeCollapsed) }
    }
    /// Notes as cards rather than as a list, the way they were last left.
    var notesAsCards = false {
        didSet { defaults.set(notesAsCards, forKey: Keys.notesAsCards) }
    }
    /// Tokens and tool counts under a finished reply.
    var developerMode = false {
        didSet { defaults.set(developerMode, forKey: Keys.developerMode) }
    }
    /// How notes are ordered, and whether they sit under dates.
    ///
    /// One setting for every folder, not one per folder: a person who wants
    /// their notes by title wants them by title, and a folder that quietly
    /// disagreed with the one beside it would read as a bug.
    var notesSort: NotesSort = .dateCreated {
        didSet { defaults.set(notesSort.rawValue, forKey: Keys.notesSort) }
    }
    var notesGroupByDate = true {
        didSet { defaults.set(notesGroupByDate, forKey: Keys.notesGroupByDate) }
    }
    /// Which folder a folder sits inside, by id.
    ///
    /// Kept on the phone. The notes store an agent keeps is a flat set of
    /// folders — it files a note under one name and reads it back under that
    /// name — so nesting here is an arrangement of this screen, not a change to
    /// the store: a note in a subfolder is filed exactly as it was.
    var noteFolderParent: [String: String] = [:] {
        didSet { defaults.set(noteFolderParent, forKey: Keys.noteFolderParent) }
    }
    /// The person's arrangement of folders, by id. The store's own sequence
    /// is the fallback for anything not listed here.
    var noteFolderOrder: [String] = [] {
        didSet { defaults.set(noteFolderOrder, forKey: Keys.noteFolderOrder) }
    }
    var pinnedNoteFolders: Set<String> = [] {
        didSet { defaults.set(Array(pinnedNoteFolders), forKey: Keys.pinnedNoteFolders) }
    }
    var noteFolderSort: NoteFolderSort = .manual {
        didSet { defaults.set(noteFolderSort.rawValue, forKey: Keys.noteFolderSort) }
    }
    /// When each agent's chat was last cleared, so routine cards from before
    /// it do not come back into the empty chat.
    var botChatClearedAt: [String: Date] = [:] {
        didSet { defaults.set(botChatClearedAt, forKey: Keys.botChatClearedAt) }
    }
    var pinnedBots: Set<String> = [] {
        didSet { defaults.set(Array(pinnedBots), forKey: Keys.pinnedBots) }
    }
    var unreadBots: Set<String> = [] {
        didSet { defaults.set(Array(unreadBots), forKey: Keys.unreadBots) }
    }
    var hiddenBots: Set<String> = [] {
        didSet { defaults.set(Array(hiddenBots), forKey: Keys.hiddenBots) }
    }
    /// Profile ids Alice has deleted on this phone. Hermes can still hold a
    /// live WAL on a deleted home, so a new agent with a similar name must
    /// not reuse that slug or it inherits the old chat and can fail to write.
    var retiredBotSlugs: Set<String> = [] {
        didSet { defaults.set(Array(retiredBotSlugs), forKey: Keys.retiredBotSlugs) }
    }
    var botModels: [String: String] = [:] {
        didSet { defaults.set(botModels, forKey: Keys.botModels) }
    }

    private struct RecentBotModel: Codable, Equatable {
        let id: String
        let provider: String?
    }

    /// Models are remembered per profile. A global list makes a bot's picker
    /// advertise choices that were only ever used by a different assistant.
    private var recentBotModels: [String: [RecentBotModel]] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(recentBotModels) {
                defaults.set(data, forKey: Keys.recentBotModels)
            }
        }
    }
    var botNotifications: [String: Bool] = [:] {
        didSet { defaults.set(botNotifications, forKey: Keys.botNotifications) }
    }
    var cachedBots: [BotRow] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(cachedBots) {
                defaults.set(data, forKey: Keys.cachedBots)
            }
        }
    }

    /// First-hop fallback chain per profile, from GET `/api/config`. Not
    /// persisted: Hermes is the source of truth, and `BotRow` archives must
    /// not grow a new Codable field.
    var cachedBotFallbacks: [String: [BotFallbackEntry]] = [:]

    /// A profile model was saved, but one or more routines or its live chat
    /// have not caught up yet. Persist the old model too: without it, a retry
    /// after relaunch cannot tell a deliberate pin from one that should move
    /// with the bot.
    struct PendingBotModelSync: Codable, Equatable, Sendable {
        let previousModel: String?
        let previousProvider: String?
        let model: String
        let provider: String
    }

    private var pendingBotModelSyncs: [String: PendingBotModelSync] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(pendingBotModelSyncs) {
                defaults.set(data, forKey: Keys.pendingBotModelSyncs)
            }
        }
    }

    func botModelSyncPending(_ bot: String) -> Bool {
        pendingBotModelSyncs[bot] != nil
    }

    nonisolated static func modelSyncTransition(
        for bot: BotRow,
        cachedBots: [BotRow],
        model: String,
        provider: String
    ) -> PendingBotModelSync {
        let current = cachedBots.first(where: { $0.name == bot.name }) ?? bot
        return PendingBotModelSync(
            previousModel: current.model,
            previousProvider: current.provider,
            model: model,
            provider: provider
        )
    }

    /// True when the current roster came from Hermes' `profiles.list` Bot Mode
    /// protocol. In that mode presentation metadata belongs to the profile,
    /// not to this phone. The old UserDefaults sets remain only as a fallback
    /// for gateways that predate Bot Mode and as migration input.
    private(set) var botMetadataIsRemote = false

    var knownBotNames: [String] {
        var names = Set(cachedBots.map(\.name))
        names.formUnion(botMarks.keys)
        names.formUnion(botSections.keys)
        names.formUnion(botCustomNames.keys)
        names.formUnion(botModels.keys)
        names.formUnion(botNamesInChats)
        return Array(names).sorted()
    }

    /// The agents named by chats and channels, kept apart from them.
    ///
    /// `knownBotNames` walked every conversation and channel, so whatever read
    /// it — the drawer's titles, through `mentions` — was redrawn by every
    /// token streamed into any chat and every channel opened or shut. These
    /// change only when an agent comes or goes.
    private(set) var botNamesInChats: Set<String> = []

    private func refreshBotNameSets() {
        var names = Set<String>()
        for conv in conversations {
            if let b = conv.botName, !b.isEmpty { names.insert(b) }
            if let bots = conv.channelBots { names.formUnion(bots) }
        }
        for channel in botChannels { names.formUnion(channel.bots) }
        if names != botNamesInChats { botNamesInChats = names }
    }

    init(defaults: UserDefaults = .standard, conversationStorage: ConversationStorage? = nil) {
        self.defaults = defaults
        self.conversationStorage = conversationStorage ?? Self.conversationStorage(for: defaults)
        self.lock = AppLock(defaults: defaults)
        botMarks = (defaults.data(forKey: Keys.marks))
            .flatMap { try? JSONDecoder().decode([String: BotMark].self, from: $0) } ?? [:]
        botCustomSections = defaults.stringArray(forKey: Keys.botCustomSections) ?? []
        botSectionOrder = defaults.stringArray(forKey: Keys.botSectionOrder) ?? []
        botOrder = defaults.stringArray(forKey: Keys.botOrder) ?? []
        botSections = (defaults.dictionary(forKey: Keys.botSections) as? [String: String]) ?? [:]
        botChannels = (defaults.data(forKey: Keys.botChannels))
            .flatMap { try? JSONDecoder().decode([BotChannel].self, from: $0) } ?? []
        homeShortcuts = (defaults.data(forKey: Keys.homeShortcuts))
            .flatMap { try? JSONDecoder().decode([HomeShortcut].self, from: $0) } ?? []
        botPlacementsApplied = (defaults.dictionary(forKey: Keys.botPlacementsApplied) as? [String: Int]) ?? [:]
        unassignedExpanded = defaults.bool(forKey: Keys.unassignedExpanded)
        hiddenExpanded = defaults.bool(forKey: Keys.hiddenExpanded)
        homeCollapsed = defaults.bool(forKey: Keys.homeCollapsed)
        barkRelays = defaults.bool(forKey: Keys.barkRelays)
        notesAsCards = defaults.bool(forKey: Keys.notesAsCards)
        developerMode = defaults.bool(forKey: Keys.developerMode)
        notesSort = (defaults.string(forKey: Keys.notesSort).flatMap(NotesSort.init(rawValue:))) ?? .dateCreated
        // Grouped unless it was turned off: `bool(forKey:)` is false for a key
        // nobody has written, which would start everyone ungrouped.
        notesGroupByDate = defaults.object(forKey: Keys.notesGroupByDate) as? Bool ?? true
        noteFolderParent = (defaults.dictionary(forKey: Keys.noteFolderParent) as? [String: String]) ?? [:]
        noteFolderOrder = defaults.stringArray(forKey: Keys.noteFolderOrder) ?? []
        if let savedPins = defaults.stringArray(forKey: Keys.pinnedNoteFolders) {
            pinnedNoteFolders = Set(savedPins)
        }
        noteFolderSort = (defaults.string(forKey: Keys.noteFolderSort).flatMap(NoteFolderSort.init(rawValue:)))
            ?? .manual
        botChatClearedAt = (defaults.dictionary(forKey: Keys.botChatClearedAt) as? [String: Date]) ?? [:]
        activitySeen = defaults.object(forKey: Keys.activitySeen) as? Date ?? .distantPast
        agentsNoticesSeen = defaults.object(forKey: Keys.agentsNoticesSeen) as? Date ?? activitySeen
        routinesNoticesSeen = defaults.object(forKey: Keys.routinesNoticesSeen) as? Date ?? activitySeen
        if let savedCollapsed = defaults.stringArray(forKey: Keys.collapsedSections) {
            collapsedSections = Set(savedCollapsed)
        }
        if let savedPinned = defaults.stringArray(forKey: Keys.pinnedBots) {
            pinnedBots = Set(savedPinned)
        }
        if let savedUnread = defaults.stringArray(forKey: Keys.unreadBots) {
            unreadBots = Set(savedUnread)
        }
        // Older builds mixed a manual "Mark unread" preference with routine
        // runs rediscovered after launch. Clear that ambiguous legacy set
        // once; real unread replies are reconstructed from their timestamps,
        // and future manual marks remain untouched by later updates.
        if defaults.integer(forKey: Keys.unreadBotsVersion) < 2 {
            unreadBots.removeAll()
            defaults.set(2, forKey: Keys.unreadBotsVersion)
        }
        if let savedHidden = defaults.stringArray(forKey: Keys.hiddenBots) {
            hiddenBots = Set(savedHidden)
        }
        loadNoteFolders()
        if let savedPinned = defaults.stringArray(forKey: Keys.pinnedNotes) {
            pinnedNotes = Set(savedPinned)
        }
        if let savedMuted = defaults.stringArray(forKey: Keys.mutedRoutines) {
            mutedRoutines = Set(savedMuted)
        }
        if let savedRetired = defaults.stringArray(forKey: Keys.retiredBotSlugs) {
            retiredBotSlugs = Set(savedRetired)
        }
        if let savedModels = defaults.dictionary(forKey: Keys.botModels) as? [String: String] {
            botModels = savedModels
        }
        if let data = defaults.data(forKey: Keys.recentBotModels),
           let saved = try? JSONDecoder().decode(
               [String: [RecentBotModel]].self, from: data
           ) {
            recentBotModels = saved
        }
        if let savedNotifs = defaults.dictionary(forKey: Keys.botNotifications) as? [String: Bool] {
            botNotifications = savedNotifs
        }
        // Routines used to be mirrored locally; they are the agent's now.
        defaults.removeObject(forKey: Keys.botRoutines)
        botCustomNames = (defaults.dictionary(forKey: Keys.botCustomNames) as? [String: String]) ?? [:]
        if let data = defaults.data(forKey: Keys.cachedBots),
           let saved = try? JSONDecoder().decode([BotRow].self, from: data) {
            cachedBots = saved
        }
        if let data = defaults.data(forKey: Keys.pendingBotModelSyncs),
           let saved = try? JSONDecoder().decode(
               [String: PendingBotModelSync].self, from: data
           ) {
            pendingBotModelSyncs = saved
        }
        if let raw = defaults.string(forKey: Keys.theme),
           let value = ThemeChoice(rawValue: raw) { theme = value }
        dashboardURL = defaults.string(forKey: Keys.dashboard) ?? ""
        dashboardUser = defaults.string(forKey: Keys.dashboardUser) ?? ""
        if let raw = defaults.string(forKey: Keys.accent),
           let value = Accent(rawValue: raw) { accent = value }
        gatewayURL = defaults.string(forKey: Keys.gateway) ?? ""
        selectedModel = defaults.string(forKey: Keys.model)
        selectedProvider = defaults.string(forKey: Keys.provider)
        recentModels = defaults.stringArray(forKey: Keys.recentModels) ?? []
        loadConversations()
        loadActivity()
        loadQuietRuns()
        loadPhoneActions()
        if let data = defaults.data(forKey: Keys.notesSnapshot) {
            notesSnapshot = try? JSONDecoder().decode(NotesSnapshot.self, from: data)
        }
        restoreSalvagedConversationsIfPossible()
        migrateLegacyChannels()
        activeID = conversations.first(where: { !$0.isBotChat })?.id ?? conversations.first?.id
        refreshConversationShelves()
        refreshActiveChat()
        refreshBotNameSets()
        ensureTodayConversation()
        #if DEBUG
        warnIfPreferencesOverBudget()
        #endif
    }

    #if DEBUG
    /// Settings storage is rewritten whole by iOS on every change. Conversations
    /// kept there reached 3 MB and had cfprefsd write 4.3 GB in a day; a debug
    /// build says so in Settings if anything grows it past this again.
    private static let preferencesBudget = 256 * 1024

    private func warnIfPreferencesOverBudget() {
        guard defaults === UserDefaults.standard,
              let domain = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:)),
              let data = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0),
              data.count > Self.preferencesBudget
        else { return }
        let largest = domain.compactMap { key, value -> (String, Int)? in
            guard let bytes = try? PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0
            ) else { return nil }
            return (key, bytes.count)
        }.max { $0.1 < $1.1 }
        storageWarning = "Settings storage is \(data.count / 1024) KB, over its \(Self.preferencesBudget / 1024) KB budget"
            + (largest.map { " (largest: \($0.0), \($0.1 / 1024) KB)" } ?? "")
            + ". iOS rewrites it whole on every change; large data belongs in files."
    }
    #endif

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeID }
    }

    /// A model picked while a canonical Bot Chat is open belongs to that bot,
    /// not to Alice's global chat preference. Keeping the routing identity
    /// explicit prevents a model chip from promising one model while Hermes
    /// actually runs the profile's configured default.
    var activeBotProfileForModelSelection: String? {
        guard activeChat.isCanonicalBotChat else { return nil }
        return activeChat.routedBotName
    }

    var activeBotForModelSelection: BotRow? {
        guard let profile = activeBotProfileForModelSelection else { return nil }
        return cachedBots.first { $0.name == profile }
    }

    /// The catalogue row backing the model that the CURRENT chat will use.
    /// Provider is part of the identity: several catalogues expose the same
    /// model id through different providers with different billing/policies.
    var currentChatModelOption: HermesClient.ModelOption? {
        if activeBotProfileForModelSelection != nil {
            guard let bot = activeBotForModelSelection else { return nil }
            return botModelOption(for: bot)
        }
        guard let id = selectedModel else { return nil }
        if let provider = selectedProvider, !provider.isEmpty,
           let exact = models.first(where: { $0.id == id && $0.provider == provider }) {
            return exact
        }
        return models.first { $0.id == id }
    }

    var currentChatModelLabel: String? {
        if let option = currentChatModelOption { return option.label }
        if let profile = activeBotProfileForModelSelection {
            guard let id = botModel(for: profile), !id.isEmpty else { return nil }
            return HermesClient.prettify(id)
        }
        if let id = selectedModel, !id.isEmpty { return HermesClient.prettify(id) }
        return nil
    }

    func currentChatUses(_ option: HermesClient.ModelOption) -> Bool {
        if activeBotProfileForModelSelection != nil {
            guard let bot = activeBotForModelSelection, bot.model == option.id else { return false }
            guard let provider = bot.provider, !provider.isEmpty else { return true }
            return provider == option.provider
        }
        guard selectedModel == option.id else { return false }
        guard let provider = selectedProvider, !provider.isEmpty else { return true }
        return provider == option.provider
    }

    // MARK: - Connection

    /// Restores a saved connection on launch. The address is an ordinary
    /// preference; the key is read back from the Keychain and never held
    /// anywhere the interface can reach.
    func restoreConnection() async {
        guard !gatewayURL.isEmpty, let key = KeyStore.read() else { return }
        await connect(urlText: gatewayURL, key: key, persist: false)
    }

    func connect(urlText: String, key: String, persist: Bool = true) async {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = HermesAddress.normalize(trimmed) else {
            connectionError = HermesAddress.connectionError(trimmed)
            return
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        await client.connect(to: .init(url: url, key: key))
        modelList = .init()
        modelListIsPartial = false

        // Neither call is required on its own. A build can serve models without
        // a capability manifest, or a manifest while the model list is slow, and
        // failing the whole connection because one of them did not answer is
        // what left this spinning until the request timed out.
        var reachedSomething = false
        var firstFailure: Error?

        // Three tries, not one. A phone changing Wi-Fi cell, a gateway a
        // second from being ready, a packet lost on the tailnet — any of them
        // used to drop the connection outright and leave the address and key
        // to be typed again for something that was momentary.
        //
        // The model list is read at the same time, not after. On a cold
        // gateway the catalogue is the slow call — the comment on loadModels
        // has seen it take twenty seconds — and connecting used to sit
        // through the manifest first and only then start it. Neither needs
        // the other's answer.
        let modelsTask = Task { [weak self] in await self?.loadModels() ?? false }
        for attempt in 0..<3 {
            do {
                manifest = try await client.capabilities()
                reachedSomething = true
                firstFailure = nil
                break
            } catch {
                manifest = nil
                if firstFailure == nil { firstFailure = error }
                // No point retrying a key the agent has rejected.
                if case HermesClient.Failure.http(401, _, _) = error { break }
                if case HermesClient.Failure.http(403, _, _) = error { break }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(400 << attempt))
                }
            }
        }

        if await modelsTask.value { reachedSomething = true }

        if reachedSomething {
            isConnected = true
            connectionError = nil
            gatewayURL = url.absoluteString
            if persist { keep(key, account: KeyStore.gatewayAccount, what: "connection key") }
        } else {
            isConnected = false
            connectionError = PlainWords.describe(
                firstFailure ?? HermesClient.Failure.unreachable, doing: "connect to Hermes"
            )
            await client.disconnect()
        }
    }

    /// Reads the model list. Separate from connecting so it can be retried on
    /// its own: the agent is often reachable while this particular endpoint is
    /// not, and that should not cost you the connection.
    @discardableResult
    func loadModels(refreshing: Bool = false) async -> Bool {
        // One read at a time. Connecting and opening the picker both ask, and
        // on a cold gateway two catalogue builds at once slowed each other:
        // the read that took 21s had a second one queued behind it. A read in
        // flight is joined. A refresh asked for during a plain read waits for
        // it and then runs, because it is asking for something else.
        while let current = modelLoad {
            let joined = await current.task.value
            if !refreshing || current.refreshing { return joined }
        }
        let token = UUID()
        let task = Task { () -> Bool in
            let reached = await self.readModels(refreshing: refreshing)
            // Cleared from inside the task, before its value is delivered, so
            // a caller waiting on it never finds the finished read still
            // registered and waits on it again.
            if self.modelLoad?.token == token { self.modelLoad = nil }
            return reached
        }
        modelLoad = (token, refreshing, task)
        return await task.value
    }

    private func readModels(refreshing: Bool) async -> Bool {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let found = try await client.models(refreshing: refreshing)
            let outcome = ModelListPolicy.apply(found, refreshing: refreshing, to: modelList)
            modelList = outcome.state
            models = outcome.state.options
            modelListIsPartial = outcome.state.source == .fallback
            modelsError = models.isEmpty
                ? "This Hermes did not return a model list at that address."
                : nil
            if outcome.shouldRefresh {
                Task { [weak self] in _ = await self?.loadModels(refreshing: true) }
            }
            // A saved choice is kept even when the list does not currently
            // contain it. The catalogue arrives late, incomplete and sometimes
            // wrong — a provider missing from the cheap answer used to be
            // enough to overwrite the model somebody had chosen, so every
            // reconnection landed on whatever happened to be first in the
            // list. Only an empty choice gets filled in.
            if selectedModel == nil {
                selectedModel = models.first?.id
                selectedProvider = models.first?.provider
            }
            return !found.options.isEmpty
        } catch {
            modelList = .init()
            models = []
            modelListIsPartial = false
            modelsError = PlainWords.describe(error, doing: "load the model list")
            return false
        }
    }

    func disconnect() async {
        await client.disconnect()
        KeyStore.clear()
        isConnected = false
        manifest = nil
        models = []
        modelList = .init()
        modelListIsPartial = false
        gatewayURL = ""

        // “Disconnect and forget Hermes” means the whole installation. The
        // dashboard used to stay authenticated after the gateway was forgotten,
        // so the drawer could truthfully have no gateway and still claim
        // “Hermes connected” from a stale dashboardReady flag.
        await forgetDashboard()
    }

    /// Address policy lives in `HermesAddress`. Kept here so existing tests
    /// and call sites that named `AppStore.normalize` keep compiling.
    nonisolated static func normalize(_ text: String) -> URL? {
        HermesAddress.normalize(text)
    }

    // MARK: - Catalogs

    /// Reads one of the management collections. The screen owns the rows so a
    /// list the user is not looking at is never kept in memory or refreshed.
    func catalog(_ source: CatalogScreen.Source) async throws -> [CatalogRow] {
        switch source {
        case .skills: try await skillCatalog()
        case .toolsets: try await client.toolsets(manifest)
        case .addons: try await client.mcpServers(manifest)
        }
    }

    /// Skills, preferring the half of Hermes that knows whether one is on.
    ///
    /// The gateway lists skills but not their state, and serves no way to
    /// change it. The dashboard does both. When there is no dashboard
    /// configured the gateway listing is still worth showing — the switches
    /// simply stay out of it, which is what `CatalogRow.enabled == nil` means.
    /// The catalogue is not scoped to a bot on this screen, so neither is the
    /// request: with no profile Hermes answers for the home profile, which is
    /// the set the gateway listing showed before.
    private func skillCatalog() async throws -> [CatalogRow] {
        guard await dashboard.isConfigured else {
            return try await client.skills(manifest)
        }
        do {
            return try await dashboard.skills(profile: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await client.skills(manifest)
        }
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        try await dashboard.setSkillEnabled(name, enabled: enabled, profile: nil)
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].title = trimmed
        conversations[index].updatedAt = Date()
        persistConversations()
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned.toggle()
        conversations[index].updatedAt = Date()
        persistConversations()
    }

    /// Every routine on the agent, and how much of it the answer covers.
    ///
    /// The dashboard is the only source that sees across profiles, so it is
    /// the source. The gateway serves one profile and stands in only when no
    /// dashboard is configured — labelled `oneGatewayProfile`, because a list
    /// missing every named bot's routines must not be drawn as if it were
    /// everything. Errors travel; they are not flattened into an empty list.
    func scheduledRoutines() async throws -> RoutineListing {
        try await routineCatalog.everything()
    }

    /// The gateway's own profile. Kept for callers that mean this one gateway
    /// rather than the agent as a whole.
    func gatewayJobs() async throws -> [JobRow] {
        try await client.jobs(manifest)
    }

    private var routineCatalog: RoutineCatalog {
        RoutineCatalog(
            across: dashboardReady ? dashboard : nil,
            gateway: GatewayRoutines(client: client, manifest: manifest)
        )
    }

    func sessions() async throws -> (rows: [SessionRow], complete: Bool) {
        try await client.sessions()
    }

    // MARK: - Dashboard

    /// Remembers where the dashboard is and how to sign in to it. The password
    /// goes to the Keychain beside the gateway key, never to preferences.
    func connectDashboard(urlText: String, username: String, password: String) async -> String? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = HermesAddress.normalize(trimmed) else {
            return HermesAddress.connectionError(trimmed)
        }
        await resetDashboardRPC()
        await dashboard.use(
            .init(url: url, username: username, password: password)
        )
        do {
            _ = try await dashboard.memory()
        } catch {
            await dashboard.use(nil)
            dashboardReady = false
            return (error as? LocalizedError)?.errorDescription
                ?? "The dashboard did not answer."
        }
        dashboardURL = url.absoluteString
        dashboardUser = username
        keep(password, account: Self.dashboardAccount, what: "dashboard password")
        dashboardReady = true
        return nil
    }

    /// Saves a secret to Keychain, and says so when it cannot.
    ///
    /// The connection itself succeeded and stays usable; what fails is only
    /// remembering it. Left silent, the next launch asked for the key again
    /// and looked like a bug in connecting rather than in saving.
    private func keep(_ secret: String, account: String, what: String) {
        do {
            try KeyStore.save(secret, account: account)
        } catch {
            storageWarning = "Connected, but the \(what) could not be saved to Keychain (\(HermesErrors.describe(error, fallback: "\(type(of: error))"))). You will need to enter it again after relaunching."
        }
    }

    func restoreDashboard() async {
        guard !dashboardURL.isEmpty, !dashboardUser.isEmpty,
              let password = KeyStore.read(account: Self.dashboardAccount),
              let url = HermesAddress.normalize(dashboardURL)
        else {
            dashboardReady = false
            return
        }
        // Returning from suspension is a reachability check, not a connection
        // change. Keep the configured dashboard and its shared RPC socket when
        // the endpoint is unchanged: a bot turn may still own that socket, and
        // replacing it here used to fail an acknowledged submit or create a
        // thirty-second hole in its event stream.
        if Self.dashboardEndpointChanged(from: await dashboard.baseURL, to: url) {
            await resetDashboardRPC()
            await dashboard.use(
                .init(url: url, username: dashboardUser, password: password)
            )
        }
        // Saved credentials say only that this dashboard worked before. Probe
        // the authenticated surface before advertising it as live; otherwise a
        // stopped Mac looks connected forever after relaunch. Keep the saved
        // values on failure so a later foreground refresh can recover.
        do {
            _ = try await dashboard.memory()
            dashboardReady = true
        } catch {
            dashboardReady = false
            // A foreground probe is observational. It must not tear down the
            // RPC transport even when it fails: a bot turn, a settings save or
            // another dashboard request may already be in flight. The next
            // restore retries this configured client; an explicit repair or
            // Forget remains the operation that replaces it.
        }
    }

    nonisolated static func dashboardEndpointChanged(from current: URL?, to saved: URL) -> Bool {
        current != saved
    }

    func forgetDashboard() async {
        await resetDashboardRPC()
        await dashboard.use(nil)
        _ = KeyStore.clear(account: Self.dashboardAccount)
        dashboardURL = ""
        dashboardUser = ""
        dashboardReady = false
        // Another Hermes' notes are not this one's.
        notesSnapshot = nil
    }

    static let dashboardAccount = "dashboard-password"

    /// A JSON-RPC client is bound to the dashboard URL it was created with.
    /// Changing/forgetting that dashboard must therefore retire the socket;
    /// otherwise a later Bot Mode action can be routed to the previous host.
    private func resetDashboardRPC() async {
        if let rpcClient { await rpcClient.disconnect(finishingListeners: true) }
        rpcClient = nil
        liveBotSessions.removeAll()
        botLiveSessionIDs.removeAll()
        canonicalBotChats.removeAll()
        warmHomeSessions.removeAll()
        botMetadataIsRemote = false
    }

    /// Scans the most recent sessions for what the agent produced.
    ///
    /// Bounded on purpose: whole sessions run to hundreds of kilobytes, and
    /// the desktop client scans thirty. Fifteen is enough to fill a screen
    /// without making the phone read several megabytes to do it.
    func artifacts(limit: Int = 15) async throws -> [Artifact] {
        let recent = try await client.sessions().rows
            .filter { $0.messageCount > 1 }
            .prefix(limit)
        var found: [Artifact] = []
        var seen = Set<String>()
        for session in recent {
            let messages = (try? await client.messages(session.id)) ?? []
            for artifact in ArtifactScanner.scan(messages, session: session.title)
            where seen.insert(artifact.id).inserted {
                found.append(artifact)
            }
        }
        return found.sorted { ($0.when ?? .distantPast) > ($1.when ?? .distantPast) }
    }

    /// One live reading of the Mac this Hermes is running on.
    func hostLoad() async throws -> HostLoad {
        try await dashboard.hostLoad()
    }

    /// Ends one process on that Mac.
    func stopHostProcess(pid: Int, name: String) async throws {
        try await dashboard.stopHostProcess(pid: pid, name: name)
    }

    func botCurrentName(for name: String) -> String {
        if name == Self.todayProfile { return "Alice" }
        let shown: String
        if botMetadataIsRemote,
           let found = cachedBots.first(where: { $0.name == name }), !found.displayName.isEmpty {
            shown = found.displayName
        } else if let custom = botCustomNames[name], !custom.isEmpty {
            shown = custom
        } else if let found = cachedBots.first(where: { $0.name == name }), !found.displayName.isEmpty {
            shown = found.displayName
        } else {
            shown = name
        }
        return AgentMaker.displayIfNeeded(profile: name, shown: shown, role: cachedBots.first(where: { $0.name == name })?.aliceRole)
    }

    func botCurrentName(for bot: BotRow) -> String {
        if bot.name == Self.todayProfile { return "Alice" }
        let shown: String
        if botMetadataIsRemote {
            shown = bot.displayName.isEmpty ? bot.name : bot.displayName
        } else {
            shown = botCustomNames[bot.name] ?? (bot.displayName.isEmpty ? bot.name : bot.displayName)
        }
        return AgentMaker.displayIfNeeded(profile: bot.name, shown: shown, role: bot.aliceRole)
    }

    /// The bots, from Hermes' Bot Mode roster when the connected dashboard
    /// supports it.  `profiles.list` is the authoritative surface because it
    /// carries `ui_meta["hermes-bots"]` and its CAS revision; the older REST
    /// endpoint is retained only for backwards compatibility.
    func bots() async throws -> [BotRow] {
        var list: [BotRow]
        var remoteMetadata = false

        if let rpc = await dashboardRPC() {
            do {
                let result = try await rpc.call(
                    "profiles.list", JSONObject(["include_sessions": false])
                )
                list = Self.botRoster(
                    from: try DashboardClient.bots(from: result.fields, active: nil),
                    hiding: retiredBotSlugs
                )
                remoteMetadata = true
            } catch {
                // An older gateway may not implement profiles.list. The REST
                // list is still a real profile list, just without Bot Mode
                // presentation metadata. Preserve the last metadata snapshot
                // instead of making hidden/pinned bots jump around during a
                // transient WebSocket failure.
                list = Self.botRoster(from: try await dashboard.bots(), hiding: retiredBotSlugs)
                list = Self.carryCachedMetadata(list, from: cachedBots)
            }
        } else {
            list = Self.botRoster(from: try await dashboard.bots(), hiding: retiredBotSlugs)
            list = Self.carryCachedMetadata(list, from: cachedBots)
        }

        botMetadataIsRemote = remoteMetadata
        if remoteMetadata, await migrateLegacyBotPreferences(in: list) {
            // Migration writes the missing metadata to Hermes. Re-read once so
            // the rows on screen contain the exact server result + revisions.
            if let rpc = await dashboardRPC(),
               let refreshed = try? await rpc.call(
                    "profiles.list", JSONObject(["include_sessions": false])
               ),
               let parsed = try? DashboardClient.bots(from: refreshed.fields, active: nil) {
                list = Self.botRoster(from: parsed, hiding: retiredBotSlugs)
            }
        }

        if list != cachedBots { cachedBots = list }
        if remoteMetadata { applyBotPlacements(list) }
        return list
    }

    /// Files agents Hermes says belong in a channel there, once per placement.
    private func applyBotPlacements(_ bots: [BotRow]) {
        let result = BotChannel.applyingPlacements(
            bots, to: botChannels, applied: botPlacementsApplied
        )
        if result.channels != botChannels { botChannels = result.channels }
        if result.applied != botPlacementsApplied { botPlacementsApplied = result.applied }
    }

    /// Alice owns `default` as Home. Every named profile remains in Bots, even
    /// if it predates Bot Mode metadata: that is Hermes Desktop's legacy
    /// compatibility rule, made explicit rather than treating metadata as a
    /// type discriminator.
    nonisolated static func botRoster(
        from profiles: [BotRow], hiding retired: Set<String> = []
    ) -> [BotRow] {
        profiles.filter { !$0.isDefault && !retired.contains($0.name) }
    }

    nonisolated static func carryCachedMetadata(
        _ rows: [BotRow], from cache: [BotRow]
    ) -> [BotRow] {
        let old = Dictionary(uniqueKeysWithValues: cache.map { ($0.name, $0.metadata) })
        return rows.map { row in
            guard let metadata = old[row.name], metadata.present else { return row }
            var copy = row
            copy.metadata = metadata
            if let title = metadata.title, !title.isEmpty { copy.displayName = title }
            if let description = metadata.description, !description.isEmpty { copy.detail = description }
            return copy
        }
    }

    /// One authenticated JSON-RPC socket is shared by Bot Mode configuration
    /// and Bot Chat. It is a transport to the machine dashboard, not a
    /// conversation, so sharing it cannot mix bot sessions.
    private func dashboardRPC() async -> HermesRPCClient? {
        guard dashboardReady else { return nil }
        if rpcClient == nil {
            guard let base = await dashboard.baseURL else { return nil }
            let dashboard = dashboard
            rpcClient = HermesRPCClient(endpoint: base) {
                try await dashboard.webSocketTicket()
            }
        }
        return rpcClient
    }

    /// Merge ONE Bot Mode namespace without losing fields Alice does not know
    /// about. The current raw object is fetched immediately before the write,
    /// and Hermes' per-key compare-and-swap revision prevents Alice and Desktop
    /// from silently overwriting each other. One conflict is retried against a
    /// fresh snapshot.
    private func mutateBotMetadata(
        _ name: String,
        mutation: ([String: Any]) -> [String: Any]
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }

        for attempt in 0..<2 {
            let roster = try await rpc.call(
                "profiles.list", JSONObject(["include_sessions": false])
            )
            guard let rows = roster["profiles"] as? [[String: Any]],
                  let row = rows.first(where: { ($0["name"] as? String) == name })
            else {
                throw HermesRPCClient.Failure(reason: "Hermes no longer has the bot ‘\(name)’.")
            }

            let uiMeta = row["ui_meta"] as? [String: Any]
            let current = (uiMeta?["hermes-bots"] as? [String: Any]) ?? [:]
            let next = mutation(current)
            let revisions = row["ui_meta_revisions"] as? [String: Any]
            let revision: Int = {
                if let value = revisions?["hermes-bots"] as? Int { return value }
                if let value = revisions?["hermes-bots"] as? NSNumber { return value.intValue }
                return 0
            }()
            let namespace: Any = next.isEmpty ? NSNull() : next
            let response = try await rpc.call(
                "profiles.configure",
                JSONObject([
                    "name": name,
                    "ui_meta": ["hermes-bots": namespace],
                    "ui_meta_expected_revisions": ["hermes-bots": revision],
                ])
            )
            let applied = response["applied"] as? [String: Any]
            if applied?["ui_meta"] as? Bool == true { return }
            if attempt == 0, applied?["ui_meta_conflicts"] != nil { continue }
            throw HermesRPCClient.Failure(
                reason: "Hermes did not save this bot setting. Refresh Bots and try again."
            )
        }
    }

    /// Hermes' metadata decides once a row carries it — also a row from the
    /// saved roster, before `profiles.list` has answered this launch. Only
    /// the live read used to count, so every launch and reconnect showed the
    /// Agents page without its pinned shelf until Hermes answered.
    private func usesRemoteMetadata(_ bot: BotRow) -> Bool {
        botMetadataIsRemote || bot.metadata.present
    }

    func isBotPinned(_ bot: BotRow) -> Bool {
        usesRemoteMetadata(bot) ? (bot.metadata.pinned ?? false) : pinnedBots.contains(bot.name)
    }

    func isBotHidden(_ bot: BotRow) -> Bool {
        usesRemoteMetadata(bot) ? (bot.metadata.hidden ?? false) : hiddenBots.contains(bot.name)
    }

    func setBotPinned(_ bot: BotRow, pinned: Bool) async throws {
        if botMetadataIsRemote {
            try await mutateBotMetadata(bot.name) { meta in
                var meta = meta
                meta["pinned"] = pinned
                return meta
            }
        } else if pinned {
            pinnedBots.insert(bot.name)
        } else {
            pinnedBots.remove(bot.name)
        }
    }

    func setBotHidden(_ bot: BotRow, hidden: Bool) async throws {
        if botMetadataIsRemote {
            try await mutateBotMetadata(bot.name) { meta in
                var meta = meta
                meta["hidden"] = hidden
                return meta
            }
        } else if hidden {
            hiddenBots.insert(bot.name)
        } else {
            hiddenBots.remove(bot.name)
        }
    }

    func setBotTitle(_ bot: BotRow, title: String) async throws {
        try await renameBot(bot.name, to: title)
    }

    /// Whether a turn is in flight for this profile, so a rename would strand it.
    func isProfileBusy(_ name: String) -> Bool {
        conversations.contains { conversation in
            conversation.botName == name && sendingConversations.contains(conversation.id)
        }
    }

    /// Asks the plugin engine to rename. A Hermes directory identity change is
    /// refused until Hermes can coordinate it; a same-id title update still runs.
    func renameBot(_ name: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != botCurrentName(for: name) else { return }
        let newID = try AgentProfileID.parse(trimmed)
        if isProfileBusy(name) || isProfileBusy(newID) {
            throw AgentOperationError.active(
                "This agent is in the middle of a request. Wait for it to finish, then rename."
            )
        }

        if newID == name {
            try await applyDisplayTitle(name, title: trimmed)
            return
        }

        let blocked = Set(takenBotSlugs().map { $0.lowercased() })
        if blocked.contains(newID) {
            throw AgentOperationError.occupied(
                "`\(newID)` already exists. The original agent was left unchanged."
            )
        }

        do {
            let result = try await dashboard.renameAgent(
                from: name, to: trimmed, busy: isProfileBusy(name)
            )
            let renamed = try result.requireRenamed()
            if renamed.sameID {
                try await applyDisplayTitle(name, title: trimmed)
                return
            }
            rebindLocalProfile(from: renamed.from, to: renamed.to, title: trimmed)
            if result.status != .completed {
                throw AgentOperationError.remote(
                    result.error ?? "The rename finished only in part. Alice will keep both names visible until it can verify."
                )
            }
            return
        } catch let failure as DashboardClient.Failure {
            switch failure {
            case .http(404, _), .http(405, _), .notConfigured:
                break
            default:
                throw failure
            }
        }

        // Official dashboard PATCH, with the already-normalized id — never a
        // display-only rename presented as a profile migration.
        do {
            try await dashboard.rename(name, to: newID)
        } catch {
            throw AgentOperationError.remote(
                (error as? LocalizedError)?.errorDescription
                ?? "Hermes could not rename this agent. The original was left unchanged."
            )
        }
        rebindLocalProfile(from: name, to: newID, title: trimmed)
        try? await applyDisplayTitle(newID, title: trimmed)
    }

    private func applyDisplayTitle(_ name: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if botMetadataIsRemote {
            try await mutateBotMetadata(name) { meta in
                var meta = meta
                if trimmed.isEmpty { meta.removeValue(forKey: "title") }
                else { meta["title"] = trimmed }
                return meta
            }
            botCustomNames.removeValue(forKey: name)
        } else if trimmed.isEmpty {
            botCustomNames.removeValue(forKey: name)
        } else {
            botCustomNames[name] = trimmed
        }
    }

    /// Moves Alice's structured references after Hermes has already renamed
    /// the profile. Does not rewrite message text or chat history prose.
    func rebindLocalProfile(from old: String, to new: String, title: String? = nil) {
        guard old != new else { return }
        let previousTitle = botCurrentName(for: old)
        // The chat is looked up again under its new profile name.
        forgetCanonicalBotChat(old)
        forgetCanonicalBotChat(new)
        move(&botMarks, from: old, to: new)
        move(&botSections, from: old, to: new)
        move(&botModels, from: old, to: new)
        move(&recentBotModels, from: old, to: new)
        move(&botNotifications, from: old, to: new)
        move(&cachedBotFallbacks, from: old, to: new)
        if let index = botOrder.firstIndex(of: old) { botOrder[index] = new }
        botOrder.removeAll { $0 == old.lowercased() && $0 != new }
        for index in botChannels.indices { botChannels[index].rename(bot: old, to: new) }
        if let custom = botCustomNames.removeValue(forKey: old) {
            botCustomNames[new] = title ?? custom
        } else if let title {
            botCustomNames[new] = title
        }
        if let index = cachedBots.firstIndex(where: { $0.name == old }) {
            cachedBots[index] = cachedBots[index].withName(new, displayName: title ?? cachedBots[index].displayName)
        }
        for index in conversations.indices {
            if conversations[index].botName == old {
                conversations[index].botName = new
                if conversations[index].title == old || conversations[index].title == previousTitle {
                    conversations[index].title = title ?? new
                }
            }
            if conversations[index].legacyBotName == old {
                conversations[index].legacyBotName = new
            }
            if let bots = conversations[index].channelBots, bots.contains(old) {
                conversations[index].channelBots = bots.map { $0 == old ? new : $0 }
            }
            for messageIndex in conversations[index].messages.indices {
                if conversations[index].messages[messageIndex].botName == old {
                    conversations[index].messages[messageIndex].botName = new
                }
                if conversations[index].messages[messageIndex].fromAgent == old {
                    conversations[index].messages[messageIndex].fromAgent = new
                }
                if conversations[index].messages[messageIndex].mentionProfile == old {
                    conversations[index].messages[messageIndex].mentionProfile = new
                }
            }
        }
        for index in activity.indices {
            if activity[index].profile == old { activity[index].profile = new }
            if activity[index].reference.profile == old {
                activity[index].reference.profile = new
            }
            if let key = activity[index].reference.routineKey, key.hasPrefix("\(old)/") {
                activity[index].reference.routineKey = "\(new)/" + key.dropFirst(old.count + 1)
            }
        }
        mutedRoutines = Set(mutedRoutines.map { key in
            key.hasPrefix("\(old)/") ? "\(new)/" + key.dropFirst(old.count + 1) : key
        })
        persistConversations()
        persistActivity()
    }

    /// Carries one entry to a new key and leaves nothing behind at the old one.
    private func move<Value>(
        _ table: inout [String: Value], from old: String, to new: String
    ) {
        if let value = table.removeValue(forKey: old) {
            table[new] = value
        }
        table.removeValue(forKey: old.lowercased())
    }

    /// Move the old phone-only title/pin/hidden preferences into Hermes only
    /// when the corresponding server field is absent. Existing Desktop state
    /// always wins. Successful migrations delete the local mirror so another
    /// device becomes the same source of truth rather than a second opinion.
    private func migrateLegacyBotPreferences(in bots: [BotRow]) async -> Bool {
        var changed = false
        for bot in bots {
            let localTitle = botCustomNames[bot.name]
            let localPinned = pinnedBots.contains(bot.name)
            let localHidden = hiddenBots.contains(bot.name)
            let needsTitle = bot.metadata.title == nil && localTitle?.isEmpty == false
            let needsPinned = bot.metadata.pinned == nil && localPinned
            let needsHidden = bot.metadata.hidden == nil && localHidden

            if needsTitle || needsPinned || needsHidden {
                do {
                    try await mutateBotMetadata(bot.name) { meta in
                        var meta = meta
                        if needsTitle, meta["title"] == nil, let localTitle {
                            meta["title"] = localTitle
                        }
                        if needsPinned, meta["pinned"] == nil { meta["pinned"] = true }
                        if needsHidden, meta["hidden"] == nil { meta["hidden"] = true }
                        return meta
                    }
                    changed = true
                } catch {
                    continue
                }
            }

            // A remote value, including explicit false, is authoritative.
            if bot.metadata.title != nil || needsTitle { botCustomNames.removeValue(forKey: bot.name) }
            if bot.metadata.pinned != nil || needsPinned { pinnedBots.remove(bot.name) }
            if bot.metadata.hidden != nil || needsHidden { hiddenBots.remove(bot.name) }
        }
        return changed
    }

    /// The bot's routines, as the agent has them.
    ///
    /// There is deliberately no local copy merged in. There used to be, keyed
    /// by a UUID this app invented, and since the server assigns its own id
    /// the same routine came back twice for ever.
    func routines(for bot: String) async throws -> [JobRow] {
        try await routineCatalog.routines(for: bot)
    }

    /// Every routine grouped by its bot, in one request rather than one per
    /// bot — the search screen needs them all at once.
    func allRoutines() async throws -> [String: [JobRow]] {
        try await dashboard.allRoutines()
    }

    /// Creates a routine on the agent and reports whether it worked.
    ///
    /// No optimistic local row: the previous version wrote one with a
    /// client-side id and `lastStatus: "ok"`, so a routine that had never run
    /// — and, because the request was malformed, had never been created —
    /// showed a green tick.
    func addRoutine(
        for bot: String, name: String, prompt: String, schedule: String,
        deliver: String = "local"
    ) async throws {
        try await dashboard.createRoutine(
            for: bot, name: name, prompt: prompt, schedule: schedule, deliver: deliver
        )
    }

    func updateRoutine(
        _ routine: JobRow, name: String, prompt: String, schedule: String, deliver: String
    ) async throws {
        guard let profile = routine.profile, !profile.isEmpty else {
            throw DashboardClient.Failure.unreadable
        }
        try await dashboard.updateRoutine(
            routine.id, profile: profile, name: name, prompt: prompt,
            schedule: schedule, deliver: deliver
        )
    }

    func setRoutinePaused(_ routine: JobRow, paused: Bool) async throws {
        guard let profile = routine.profile, !profile.isEmpty else {
            throw DashboardClient.Failure.unreadable
        }
        if paused { try await dashboard.pauseRoutine(routine.id, profile: profile) }
        else { try await dashboard.resumeRoutine(routine.id, profile: profile) }
    }

    func triggerRoutine(_ routine: JobRow) async throws {
        guard let profile = routine.profile, !profile.isEmpty else {
            throw DashboardClient.Failure.unreadable
        }
        try await dashboard.triggerRoutine(routine.id, profile: profile)
    }

    func deleteRoutine(_ routine: JobRow) async throws {
        guard let profile = routine.profile, !profile.isEmpty else {
            throw DashboardClient.Failure.unreadable
        }
        try await dashboard.deleteRoutine(routine.id, profile: profile)
    }

    func routineRuns(_ routine: JobRow, limit: Int = 20) async throws -> [RoutineRun] {
        guard let profile = routine.profile, !profile.isEmpty else {
            throw DashboardClient.Failure.unreadable
        }
        return try await dashboard.routineRuns(routine.id, profile: profile, limit: limit)
    }

    func routineDeliveryTargets() async throws -> [RoutineDeliveryTarget] {
        try await dashboard.routineDeliveryTargets()
    }

    func routineTimezone(for profile: String) async throws -> String {
        try await dashboard.routineTimezone(for: profile)
    }

    /// Profiles available as routine owners. `default` is Alice/Home; named
    /// profiles are bots. Display names remain presentation only — mutations
    /// always route by the canonical profile slug.
    func routineProfiles() async throws -> [(id: String, label: String)] {
        let bots = try await bots()
        var rows: [(String, String)] = [("default", "Alice")]
        rows.append(contentsOf: bots.map { ($0.name, botCurrentName(for: $0)) })
        return rows
    }

    func exportBot(_ name: String) async throws -> String? {
        try await dashboard.exportBot(name)
    }

    func section(for bot: String) -> String? {
        botSections[bot] ?? botSections[bot.lowercased()]
    }

    func setBotSection(_ bot: String, section: String?) {
        if let section, !section.isEmpty {
            botSections[bot] = section
            botSections[bot.lowercased()] = section
        } else {
            botSections.removeValue(forKey: bot)
            botSections.removeValue(forKey: bot.lowercased())
        }
    }

    /// Applies Alice's saved presentation order without mutating state during
    /// a SwiftUI render. Unknown/new bots stay at the end in Hermes' order.
    func orderedBots(_ bots: [BotRow]) -> [BotRow] {
        Self.orderedBots(bots, using: botOrder)
    }

    nonisolated static func orderedBots(_ bots: [BotRow], using order: [String]) -> [BotRow] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return bots.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.name]
            let right = rank[rhs.element.name]
            switch (left, right) {
            case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Reorders only the peers visible in one section. Other sections keep
    /// their relative slots in the master order, so dragging inside Work can
    /// never reshuffle Personal. Moving down lands after the row crossed;
    /// moving up lands before it, matching native list reordering.
    func reorderBot(_ source: String, relativeTo target: String, within peers: [String]) {
        let moved = Self.movingBot(source, relativeTo: target, within: peers)
        guard moved != peers else { return }
        botOrder = Self.mergingBotOrder(
            botOrder, allNames: cachedBots.map(\.name), orderedPeers: moved
        )
    }

    nonisolated static func movingBot(
        _ source: String, relativeTo target: String, within peers: [String]
    ) -> [String] {
        guard let from = peers.firstIndex(of: source),
              let to = peers.firstIndex(of: target), from != to
        else { return peers }
        var result = peers
        let item = result.remove(at: from)
        result.insert(item, at: min(to, result.count))
        return result
    }

    nonisolated static func mergingBotOrder(
        _ master: [String], allNames: [String], orderedPeers: [String]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in master + allNames where seen.insert(name).inserted { result.append(name) }

        let peers = Set(orderedPeers)
        let slots = result.indices.filter { peers.contains(result[$0]) }
        guard slots.count == orderedPeers.count else { return result }
        for (slot, name) in zip(slots, orderedPeers) { result[slot] = name }
        return result
    }

    /// The order the sections are shown in, derived and never stored from
    /// here.
    ///
    /// This used to assign `botSectionOrder` when the derived order differed,
    /// and it is read from inside a `ForEach` — so a fresh install mutated
    /// observed state, and wrote UserDefaults, in the middle of a render
    /// pass. Normalising is now the job of the calls that actually change
    /// something.
    var sectionOrder: [String] {
        var order = botSectionOrder.filter {
            $0 == Self.unassignedSectionKey || botCustomSections.contains($0)
        }
        for section in botCustomSections where !order.contains(section) {
            order.append(section)
        }
        if !order.contains(Self.unassignedSectionKey) {
            order.append(Self.unassignedSectionKey)
        }
        return order
    }

    /// Writes the derived order back. Call it from an action, never from a
    /// view's body.
    private func normaliseSectionOrder() {
        let order = sectionOrder
        if order != botSectionOrder { botSectionOrder = order }
    }

    func addSection(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "unassigned",
              !botCustomSections.contains(trimmed)
        else { return }
        botCustomSections.append(trimmed)
        if !botSectionOrder.contains(trimmed) {
            if let unassigned = botSectionOrder.firstIndex(of: Self.unassignedSectionKey) {
                botSectionOrder.insert(trimmed, at: unassigned)
            } else {
                botSectionOrder.append(trimmed)
            }
        }
        normaliseSectionOrder()
    }

    func toggleSectionCollapsed(_ section: String) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    func moveSectionUp(_ section: String) {
        var list = sectionOrder
        let key = (section == "Unassigned" || section == Self.unassignedSectionKey) ? Self.unassignedSectionKey : section
        guard let index = list.firstIndex(of: key), index > 0 else { return }
        list.swapAt(index, index - 1)
        botSectionOrder = list
        botCustomSections = list.filter { $0 != Self.unassignedSectionKey }
    }

    func moveSectionDown(_ section: String) {
        var list = sectionOrder
        let key = (section == "Unassigned" || section == Self.unassignedSectionKey) ? Self.unassignedSectionKey : section
        guard let index = list.firstIndex(of: key), index < list.count - 1 else { return }
        list.swapAt(index, index + 1)
        botSectionOrder = list
        botCustomSections = list.filter { $0 != Self.unassignedSectionKey }
    }

    /// Moves a Home section to where `target` is, the way a drag lands: before
    /// it when moving up, after it when moving down. Unassigned moves too, as it
    /// does with Move Up and Move Down.
    func moveSection(_ source: String, to target: String) {
        func key(_ name: String) -> String {
            (name == "Unassigned" || name == Self.unassignedSectionKey) ? Self.unassignedSectionKey : name
        }
        var list = sectionOrder
        guard let from = list.firstIndex(of: key(source)),
              let to = list.firstIndex(of: key(target)), from != to
        else { return }
        let item = list.remove(at: from)
        list.insert(item, at: to)
        botSectionOrder = list
        botCustomSections = list.filter { $0 != Self.unassignedSectionKey }
    }

    func renameSection(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName,
              oldName != Self.unassignedSectionKey,
              oldName != "Unassigned",
              trimmed.lowercased() != "unassigned",
              botCustomSections.contains(oldName),
              !botCustomSections.contains(trimmed)
        else { return }
        if let index = botCustomSections.firstIndex(of: oldName) {
            botCustomSections[index] = trimmed
        }
        if let index = botSectionOrder.firstIndex(of: oldName) {
            botSectionOrder[index] = trimmed
        }
        for (bot, sec) in botSections where sec == oldName {
            botSections[bot] = trimmed
        }
        if collapsedSections.contains(oldName) {
            collapsedSections.remove(oldName)
            collapsedSections.insert(trimmed)
        }
    }

    func deleteSection(_ section: String) {
        botCustomSections.removeAll { $0 == section }
        botSectionOrder.removeAll { $0 == section }
        for (bot, sec) in botSections where sec == section {
            botSections.removeValue(forKey: bot)
        }
        collapsedSections.remove(section)
        normaliseSectionOrder()
    }

    func toggleBotPin(_ bot: String) {
        if pinnedBots.contains(bot) { pinnedBots.remove(bot) }
        else { pinnedBots.insert(bot) }
    }

    func toggleBotUnread(_ bot: String) {
        if isBotUnread(bot) { markBotRead(bot) }
        else { unreadBots.insert(bot) }
    }

    /// Whether this bot has said something since its conversation was last
    /// opened. The explicit set remains the user's "Mark Unread" override;
    /// ordinary chat replies and routine cards are derived from their dates.
    func isBotUnread(_ bot: String) -> Bool {
        if unreadBots.contains(bot) { return true }
        guard let conversation = conversations.first(where: { $0.routedBotName == bot }),
              let newest = botChatPreview(conversation, botName: bot).newestReplyAt
        else { return false }
        return newest > (conversation.openedAt ?? .distantPast)
    }

    /// A bot chat's last reply as its row shows it, read again only when the
    /// chat changed (`BotChatPreviews`). Agents asks for it for every bot on
    /// every redraw.
    @ObservationIgnored private let botChatPreviews = BotChatPreviews()

    func botChatPreview(_ conversation: Conversation, botName: String) -> BotChatPreview {
        botChatPreviews.preview(
            for: conversation, botName: botName, quietRuns: quietRoutineRuns[botName] ?? []
        )
    }

    /// Only what the chat shows counts: another agent asking this one, and its
    /// answer, happen out of the person's sight and are not news here.
    nonisolated static func hasUnreadBotContent(
        messages: [Message], quietRuns: [QuietRoutineRun],
        botName: String, openedAt: Date?, agentAnswers: Set<String> = []
    ) -> Bool {
        let readThrough = openedAt ?? .distantPast
        return RoutineDelivery.present(
            messages, botName: botName, quietRuns: quietRuns, agentAnswers: agentAnswers
        ).contains {
            $0.role == .assistant && !$0.pending
                && MessageTime.isKnown($0.createdAt) && $0.createdAt > readThrough
        }
    }

    /// A quiet run reconstructed after launch is only unread when it really
    /// happened after this conversation was last opened. Rediscovery is not
    /// a new event.
    nonisolated static func hasUnreadQuietRun(
        _ runs: [QuietRoutineRun], openedAt: Date?
    ) -> Bool {
        let readThrough = openedAt ?? .distantPast
        return runs.contains {
            MessageTime.isKnown($0.finishedAt) && $0.finishedAt > readThrough
        }
    }

    /// Opening the conversation reads both chat replies and routine cards.
    func markBotRead(_ bot: String, at date: Date = Date()) {
        unreadBots.remove(bot)
        guard let index = conversations.firstIndex(where: { $0.routedBotName == bot })
        else { return }
        conversations[index].openedAt = date
        persistConversations()
    }

    /// Replies from agents named with `@` in the chat being read are read:
    /// the same exchange sits in the agent's own chat, and marking that one
    /// unread asked for a second reading of something already seen.
    func markMentionRepliesSeen(in conversationID: String?) {
        guard isForeground, let conversationID, conversationID == activeID,
              let chat = conversations.first(where: { $0.id == conversationID })
        else { return }
        let agents = Set(chat.messages.compactMap { message -> String? in
            guard message.role == .assistant, !message.pending else { return nil }
            return message.mentionProfile
        })
        guard !agents.isEmpty else { return }
        let now = Date()
        var changed = false
        for index in conversations.indices {
            guard let bot = conversations[index].routedBotName, agents.contains(bot),
                  conversations[index].isCanonicalBotChat,
                  (conversations[index].openedAt ?? .distantPast) < now
            else { continue }
            conversations[index].openedAt = now
            changed = true
        }
        if changed { persistConversations() }
    }

    func markActiveBotRead() {
        guard let bot = activeConversation?.routedBotName else { return }
        markBotRead(bot)
    }

    func hideBot(_ bot: String) {
        hiddenBots.insert(bot)
    }

    func unhideBot(_ bot: String) {
        hiddenBots.remove(bot)
    }

    func botModel(for bot: String) -> String? {
        if botMetadataIsRemote,
           let model = cachedBots.first(where: { $0.name == bot })?.model, !model.isEmpty {
            return model
        }
        return botModels[bot] ?? botModels[bot.lowercased()]
    }

    /// The exact catalogue option backing a bot's real Hermes model pin.
    /// Provider participates in the identity because the same model id may be
    /// served by more than one provider.
    func botModelOption(for bot: BotRow) -> HermesClient.ModelOption? {
        guard let model = bot.model, !model.isEmpty else { return nil }
        if let provider = bot.provider, !provider.isEmpty,
           let exact = models.first(where: { $0.id == model && $0.provider == provider }) {
            return exact
        }
        return models.first(where: { $0.id == model })
    }

    /// Models actually used by this bot, newest first, resolved against the
    /// live catalogue so unavailable entries quietly fall away.
    func recentBotModelOptions(for bot: String) -> [HermesClient.ModelOption] {
        (recentBotModels[bot] ?? []).compactMap { recent in
            if let provider = recent.provider, !provider.isEmpty,
               let exact = models.first(where: {
                   $0.id == recent.id && $0.provider == provider
               }) {
                return exact
            }
            return models.first { $0.id == recent.id }
        }
    }

    private func rememberBotModel(
        id: String?, provider: String?, for bot: String
    ) {
        guard let id, !id.isEmpty else { return }
        let selection = RecentBotModel(id: id, provider: provider)
        var recent = recentBotModels[bot] ?? []
        recent.removeAll { $0.id == id && $0.provider == provider }
        recent.insert(selection, at: 0)
        recentBotModels[bot] = Array(recent.prefix(6))
    }

    enum BotModelUpdate: Sendable {
        case confirmation(String)
        /// The profile itself changed. A warning means its dependent routines
        /// or live chat still need the idempotent follow-up to be retried.
        case applied(warning: String?)
    }

    /// Persist a model selection on the Hermes profile. Bot Mode's RPC has the
    /// same expensive/data-policy confirmation handshake as the main model
    /// picker. A profile write and its dependent routine/chat updates are not
    /// one server transaction, so partial success is reported as applied with
    /// a warning rather than thrown as though the model never changed.
    func setBotModel(
        _ bot: BotRow,
        to option: HermesClient.ModelOption,
        confirm: Bool = false
    ) async throws -> BotModelUpdate {
        guard let provider = option.provider, !provider.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "Hermes did not identify the provider for this model."
            )
        }

        if let pending = pendingBotModelSyncs[bot.name],
           pending.model == option.id, pending.provider == provider {
            // The same choice again is a retry of its follow-up: this
            // one is waited on, so the person sees whether it landed.
            botModelSyncTasks[bot.name]?.cancel()
            botModelSyncTasks.removeValue(forKey: bot.name)
            let outcome = await completeBotModelSync(pending, botName: bot.name)
            if case let .applied(warning) = outcome, let warning {
                botModelSyncWarnings[bot.name] = warning
            } else {
                botModelSyncWarnings.removeValue(forKey: bot.name)
            }
            return outcome
        }
        // Another model was still being followed up. Drop that work: the
        // new choice is the target, and the cancelled carry must not pin
        // routines to the model that was just abandoned.
        botModelSyncTasks[bot.name]?.cancel()
        botModelSyncTasks.removeValue(forKey: bot.name)

        // A Bot detail page can stay open across several selections. Its input
        // row is then stale, while the cache is Hermes' latest accepted model.
        // Always record the latter as the transition's true starting point.
        let transition = Self.modelSyncTransition(
            for: bot,
            cachedBots: cachedBots,
            model: option.id,
            provider: provider
        )
        // Replace the pending target before the network call so a cancelled
        // carry of the previous model cannot pin routines to it.
        let previousPending = pendingBotModelSyncs[bot.name]
        pendingBotModelSyncs[bot.name] = transition
        do {
            if let rpc = await dashboardRPC() {
                var params: [String: Any] = [
                    "name": bot.name, "model": option.id, "provider": provider,
                ]
                if confirm { params["confirm_expensive_model"] = true }
                let response = try await rpc.call("profiles.configure", JSONObject(params))
                if response["confirm_required"] as? Bool == true {
                    pendingBotModelSyncs[bot.name] = previousPending
                    return .confirmation(
                        (response["confirm_message"] as? String)
                            ?? "Hermes wants confirmation before using this model."
                    )
                }
                let applied = response["applied"] as? [String: Any]
                guard applied?["model"] as? Bool == true else {
                    throw HermesRPCClient.Failure(reason: "Hermes did not save the bot model.")
                }
            } else {
                // Compatibility with dashboards from before profiles.configure.
                // This still changes the real profile; it is never a phone-only
                // model override.
                try await dashboard.setModel(bot.name, provider: provider, model: option.id)
            }
        } catch {
            pendingBotModelSyncs[bot.name] = previousPending
            throw error
        }

        botModels.removeValue(forKey: bot.name)
        botModels.removeValue(forKey: bot.name.lowercased())
        rememberBotModel(
            id: transition.previousModel,
            provider: transition.previousProvider,
            for: bot.name
        )
        rememberBotModel(id: option.id, provider: provider, for: bot.name)
        if let index = cachedBots.firstIndex(where: { $0.name == bot.name }) {
            cachedBots[index].model = option.id
            cachedBots[index].provider = provider
        }
        // The profile is not the only place a bot's model lives. Hermes records
        // for each routine that follows the bot the model it was following, and
        // a routine whose record no longer matches refuses to run; a chat already
        // open keeps the model its runtime was built with. Both move with the
        // bot, or the picker shows one model while the bot runs another.
        //
        // That follow-up is another half-dozen round trips — the routine list,
        // a pin and a release per routine, a resume and a config.set on the
        // chat — and the picker used to stay up through all of them. The
        // profile is saved, which is the change the person made; the picker
        // may close now. The follow-up runs behind it, its record is kept
        // until it lands, and the bot's page says so while it is still going
        // or if it stopped short.
        pendingBotModelSyncs[bot.name] = transition
        botModelSyncWarnings.removeValue(forKey: bot.name)
        botModelSyncTasks[bot.name]?.cancel()
        botModelSyncTasks[bot.name] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.completeBotModelSync(transition, botName: bot.name)
            guard !Task.isCancelled,
                  Self.shouldApplyModelCarry(
                    transition, stillPending: self.pendingBotModelSyncs[bot.name]
                  )
            else { return }
            if case let .applied(warning) = outcome, let warning {
                self.botModelSyncWarnings[bot.name] = warning
            }
            self.botModelSyncTasks.removeValue(forKey: bot.name)
        }
        return .applied(warning: nil)
    }

    /// Model follow-ups still running, by bot. Cancelled when a newer choice
    /// for the same bot replaces them; the record in `pendingBotModelSyncs`
    /// outlives the task so a cancelled follow-up is still retried.
    @ObservationIgnored private var botModelSyncTasks: [String: Task<Void, Never>] = [:]

    /// What the last model follow-up for a bot could not finish, in words for
    /// the bot's page. Cleared when a follow-up completes or a new one starts.
    private(set) var botModelSyncWarnings: [String: String] = [:]

    /// True while a bot's routines and chat are still being moved onto the
    /// model just chosen for it.
    func botModelSyncRunning(_ bot: String) -> Bool {
        botModelSyncTasks[bot] != nil
    }

    /// The catalogue option for a bot's first fallback hop, when Hermes has one.
    func botFallbackOption(for bot: BotRow) -> HermesClient.ModelOption? {
        guard let first = cachedBotFallbacks[bot.name]?.first else { return nil }
        if let exact = models.first(where: { $0.id == first.model && $0.provider == first.provider }) {
            return exact
        }
        return first.option
    }

    @discardableResult
    func refreshBotFallback(_ profile: String) async throws -> [BotFallbackEntry] {
        let chain = try await dashboard.fallbackProviders(profile: profile)
        cachedBotFallbacks[profile] = chain
        return chain
    }

    /// Persist the first fallback hop on the Hermes profile. Clearing sends
    /// an empty `fallback_providers` list so routines stop billing a leftover
    /// Codex (or similar) chain. Extra hops after the first stay when a new
    /// first hop is chosen.
    func setBotFallback(
        _ bot: BotRow, to option: HermesClient.ModelOption?
    ) async throws {
        if let option {
            guard option.provider?.isEmpty == false else {
                throw HermesRPCClient.Failure(
                    reason: "Hermes did not identify the provider for this model."
                )
            }
        }
        let current = try await {
            if let cached = cachedBotFallbacks[bot.name] { return cached }
            return try await dashboard.fallbackProviders(profile: bot.name)
        }()
        guard BotFallbackChain.isChange(option, from: current) else {
            cachedBotFallbacks[bot.name] = current
            return
        }
        let next = BotFallbackChain.replacingFirst(
            current, with: option.flatMap(BotFallbackEntry.from(option:))
        )
        try await dashboard.setFallbackProviders(next, profile: bot.name)
        cachedBotFallbacks[bot.name] = next
        if let option {
            rememberBotModel(id: option.id, provider: option.provider, for: bot.name)
        }
    }

    /// A cancelled carry must not write pins or clear a newer pending target.
    nonisolated static func shouldApplyModelCarry(
        _ intended: PendingBotModelSync, stillPending: PendingBotModelSync?
    ) -> Bool {
        stillPending == intended
    }

    private func completeBotModelSync(
        _ pending: PendingBotModelSync, botName: String
    ) async -> BotModelUpdate {
        do {
            try Task.checkCancellation()
            guard Self.shouldApplyModelCarry(
                pending, stillPending: pendingBotModelSyncs[botName]
            ) else {
                return .applied(warning: nil)
            }
            try await carryModelChange(
                to: botName,
                previousModel: pending.previousModel,
                previousProvider: pending.previousProvider,
                model: pending.model,
                provider: pending.provider
            )
            try Task.checkCancellation()
            if Self.shouldApplyModelCarry(
                pending, stillPending: pendingBotModelSyncs[botName]
            ) {
                pendingBotModelSyncs.removeValue(forKey: botName)
            }
            return .applied(warning: nil)
        } catch is CancellationError {
            return .applied(warning: nil)
        } catch {
            // Keep the recovery record: the operation is idempotent and can be
            // resumed from the picker now or after the app is relaunched.
            return .applied(warning: PlainWords.describe(error, doing: "finish the model change"))
        }
    }

    /// What a bot's routine needs when the bot's model changes.
    enum RoutineModelChange: Equatable, Sendable {
        /// Follows the bot, but Hermes recorded another model for it: refresh
        /// the record, or the routine fails closed on its next run.
        case follow(id: String, profile: String)
        /// Pinned to the bot's previous model: the pin moves with the bot.
        case repin(id: String, profile: String)
    }

    /// Which of a bot's routines have to change so they keep running on the
    /// model the bot now uses. A routine pinned to some other model was given
    /// that model on purpose, and keeps it.
    nonisolated static func routineModelChanges(
        _ jobs: [JobRow], previousModel: String?, previousProvider: String?,
        newModel: String, newProvider: String
    ) -> [RoutineModelChange] {
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            (lhs ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                == (rhs ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        return jobs.compactMap { job in
            guard let profile = job.profile, !profile.isEmpty else { return nil }
            let pinned = (job.model ?? "").trimmingCharacters(in: .whitespaces)
            if pinned.isEmpty {
                let recordsNewModel = same(job.modelSnapshot, newModel)
                    && same(job.providerSnapshot, newProvider)
                return recordsNewModel ? nil : .follow(id: job.id, profile: profile)
            }
            if same(pinned, newModel) && same(job.provider, newProvider) { return nil }
            guard same(pinned, previousModel) else { return nil }
            if let pinnedProvider = job.provider, !pinnedProvider.isEmpty,
               let previousProvider, !previousProvider.isEmpty,
               !same(pinnedProvider, previousProvider) {
                return nil
            }
            return .repin(id: job.id, profile: profile)
        }
    }

    private func carryModelChange(
        to botName: String, previousModel: String?, previousProvider: String?,
        model: String, provider: String
    ) async throws {
        func reason(_ error: Error) -> String {
            PlainWords.describe(error, doing: "carry the model change")
        }
        var problems: [String] = []
        do {
            let jobs = try await routines(for: botName)
            let changes = Self.routineModelChanges(
                jobs, previousModel: previousModel, previousProvider: previousProvider,
                newModel: model, newProvider: provider
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                for change in changes {
                    group.addTask {
                        try Task.checkCancellation()
                        switch change {
                        case let .follow(id, profile):
                            // Hermes re-records what an unpinned routine follows
                            // only when its pin changes: pin it, then release it.
                            try await self.dashboard.pinRoutineModel(
                                id, profile: profile, provider: provider, model: model
                            )
                            try await self.dashboard.followProfileModel(id, profile: profile)
                        case let .repin(id, profile):
                            try await self.dashboard.pinRoutineModel(
                                id, profile: profile, provider: provider, model: model
                            )
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            problems.append("its routines could not be moved to it (\(reason(error)))")
        }
        do {
            try await switchOpenBotChat(botName, model: model, provider: provider)
        } catch {
            problems.append("its chat could not be switched (\(reason(error)))")
        }
        guard !problems.isEmpty else { return }
        throw HermesRPCClient.Failure(
            reason: "\(botCurrentName(for: botName)) now uses \(HermesClient.prettify(model)), but \(problems.joined(separator: " and "))."
        )
    }

    /// Moves the bot's own chat onto the model just set on its profile.
    ///
    /// Scoped to that session with `--session`: the profile change is the
    /// persistent one, and a session switch must not write any other
    /// profile's configuration. The model was already accepted for this bot
    /// when the profile changed, so Hermes' confirmation is not asked twice.
    private func switchOpenBotChat(_ botName: String, model: String, provider: String) async throws {
        guard let conversation = conversations.first(where: {
            $0.isCanonicalBotChat && $0.routedBotName == botName
        }), let source = await botChatSource() else { return }
        let chat = try await resolveBotChat(botName, source: source)
        let resumed = try await source.resume(profile: botName, target: chat.resolvedID)
        guard let liveID = resumed["session_id"] as? String, !liveID.isEmpty else { return }
        track(liveSessionID: liveID, for: conversation.id)
        _ = try await source.rpc.call("config.set", JSONObject([
            "session_id": liveID,
            "key": "model",
            "value": "\(model) --provider \(provider) --session",
            "confirm_expensive_model": true,
        ]))
    }

    // MARK: - Events

    /// What Alice has observed, newest first.
    ///
    /// Only events Alice actually saw. Hermes keeps no durable event history —
    /// the replay ring is in memory and resets with the gateway — so there is
    /// nothing to backfill from, and inventing entries for work that happened
    /// before Alice was watching would be fabricating a record. It starts
    /// empty and fills as Alice runs, which is the truth about what it knows.
    private(set) var activity: [AliceEvent] = []

    /// What agents did with consequences, as the Alice plugin records it
    /// (`AgentAction`), newest first.
    private(set) var agentActions: [AgentAction] = []
    /// What this phone did at an agent's suggestion — a card, a 👍 — which
    /// the Mac never saw. Kept on the phone.
    private(set) var phoneActions: [AgentAction] = []
    /// Whether the plugin answered at all, so an empty list can say why.
    private(set) var agentActionsAvailable: Bool?
    /// A cited conversation open over whatever is on screen (`ReceiptSheet`).
    var openedReceipt: RichReceipt?
    /// What is known of each cited conversation, by Hermes session id, for
    /// the links and sources that cite it.
    private(set) var receiptSummaries: [String: ReceiptSummary] = [:]

    struct ReceiptSummary: Equatable, Sendable {
        var title: String
        var profile: String
        var started: Date?
    }

    /// Conversation names by Hermes session id.
    var receiptTitles: [String: String] { receiptSummaries.mapValues(\.title) }
    @ObservationIgnored private var receiptTitlesAsked: Set<String> = []
    /// A message to bring into view once its chat is on screen.
    var focusedMessage: FocusedMessage?

    struct FocusedMessage: Equatable {
        var conversationID: String
        /// Hermes' id for the turn.
        var remoteID: String
    }

    /// Routines whose successful runs are not worth a notice, by
    /// `EventDigest.key(for:)`. A failure is still said: that is news.
    private(set) var mutedRoutines: Set<String> = [] {
        didSet { defaults.set(Array(mutedRoutines), forKey: Keys.mutedRoutines) }
    }

    func isMuted(_ routine: JobRow) -> Bool {
        mutedRoutines.contains(EventDigest.key(for: routine))
    }

    /// Mutes or unmutes a routine's reports. Muting also clears the reports
    /// already in Activity.
    func setMuted(_ routine: JobRow, _ muted: Bool) {
        let key = EventDigest.key(for: routine)
        if muted { mutedRoutines.insert(key) } else { mutedRoutines.remove(key) }
        guard muted else { return }
        let before = activity.count
        activity.removeAll { Self.isMutedReport($0, muted: mutedRoutines) }
        if activity.count != before {
            persistActivity()
            refreshAttention()
        }
    }

    nonisolated static func isMutedReport(_ event: AliceEvent, muted: Set<String>) -> Bool {
        guard let key = event.reference.routineKey, muted.contains(key) else { return false }
        return event.kind == .automationSucceeded || event.kind == .finished
    }

    /// Bounded on purpose: this is a phone, and the useful window is recent.
    static let activityLimit = 200

    /// When the person last opened Activity, for the unread count.
    ///
    /// Stored, not read through from UserDefaults: a computed property is
    /// invisible to observation, so the drawer's badge kept its old number
    /// after Activity had been seen, until something else redrew the drawer.
    var activitySeen: Date = .distantPast {
        didSet { defaults.set(activitySeen, forKey: Keys.activitySeen) }
    }

    /// When the Agents row last absorbed its own notices.
    var agentsNoticesSeen: Date = .distantPast {
        didSet { defaults.set(agentsNoticesSeen, forKey: Keys.agentsNoticesSeen) }
    }

    /// When the Routines row last absorbed its own notices.
    var routinesNoticesSeen: Date = .distantPast {
        didSet { defaults.set(routinesNoticesSeen, forKey: Keys.routinesNoticesSeen) }
    }

    var unreadActivity: Int {
        activity.filter { $0.occurred > activitySeen }.count
    }

    /// Unread notices that belong on one drawer row.
    func unreadNotices(in place: AliceEvent.NoticePlace) -> Int {
        let seen = switch place {
        case .agents: agentsNoticesSeen
        case .routines: routinesNoticesSeen
        }
        return activity.filter { $0.noticePlace == place && $0.occurred > seen }.count
    }

    func markNoticesSeen(_ place: AliceEvent.NoticePlace) {
        switch place {
        case .agents: agentsNoticesSeen = Date()
        case .routines: routinesNoticesSeen = Date()
        }
    }

    /// Components and automations that want attention right now.
    ///
    /// Distinct from `activity`, which is a record of things that happened.
    /// This is current state: something is wrong *now* and can be acted on.
    private(set) var attention: [AliceEvent] = []
    /// A screen something outside the drawer wants opened — an alert's "Open
    /// messaging apps". The drawer owns presentation, so it is asked.
    var requestedDestination: AliceDestination.Target?

    /// Reachability and health are different questions, and one green dot
    /// cannot answer both.
    enum Wellbeing: Equatable, Sendable {
        /// No Hermes configured yet.
        case notConfigured
        /// Configured, but the last attempt to reach it failed.
        case unreachable
        /// Reachable, and nothing is asking for attention.
        case well
        /// Reachable, but something inside wants attention.
        case needsAttention(Int)
    }

    var wellbeing: Wellbeing {
        // The user-facing Hermes connection is the gateway connection. The
        // dashboard is an authenticated management surface layered on top; it
        // must never turn a disconnected gateway into “Hermes connected”.
        guard isConnected else {
            return gatewayURL.isEmpty ? .notConfigured : .unreachable
        }
        return attention.isEmpty ? .well : .needsAttention(attention.count)
    }

    /// A few words for the drawer's menu, which truncates anything longer —
    /// "Everything is working" was cut off. Says what is true, and when
    /// something is wrong says how much rather than only that.
    var wellbeingSummary: String {
        switch wellbeing {
        case .notConfigured: "Connect Hermes"
        case .unreachable: "Can’t reach Hermes"
        case .well: "Hermes connected"
        case let .needsAttention(count):
            count == 1 ? "1 alert to check" : "\(count) alerts to check"
        }
    }

    /// Connection, build and recent log lines — never a secret or a message.
    func diagnosticsSnapshot() -> AppDiagnosticsSnapshot {
        let build = AliceBuildInfo.current
        let state: String
        switch wellbeing {
        case .notConfigured: state = "notConfigured"
        case .unreachable: state = "unreachable"
        case .well: state = "well"
        case let .needsAttention(count): state = "needsAttention:\(count)"
        }
        return AppDiagnosticsSnapshot(
            deviceID: AppDiagnosticsSnapshot.vendorDeviceID,
            capturedAt: Date(),
            version: build.version,
            build: build.build,
            revision: build.revision,
            wellbeing: state,
            connected: isConnected,
            dashboardReady: dashboardReady,
            gatewayConfigured: !gatewayURL.isEmpty,
            unknownEvents: HermesUnknownEvents.shared.all.prefix(16).map { sighting in
                let keys = sighting.keys.joined(separator: ",")
                return keys.isEmpty
                    ? "\(sighting.type) ×\(sighting.count)"
                    : "\(sighting.type) ×\(sighting.count) \(keys)"
            },
            lines: DiagnosticsLog.recentLines(limit: 200)
        )
    }

    /// POST the dump to the Alice plugin. `force` is `/debug` and a failed
    /// turn; coming to the foreground waits 20 seconds between uploads.
    @discardableResult
    func pushDiagnostics(force: Bool = false) async -> Bool {
        guard dashboardReady else { return false }
        if !force, let last = lastDiagnosticsPush, Date().timeIntervalSince(last) < 20 {
            return true
        }
        do {
            try await dashboard.postAppDiagnostics(diagnosticsSnapshot())
            lastDiagnosticsPush = Date()
            return true
        } catch {
            return false
        }
    }

    /// What Alice last saw, so a fact already reported is not reported twice.
    private var eventWatermarks: EventWatermarks {
        get {
            guard let data = defaults.data(forKey: Keys.eventWatermarks),
                  let marks = try? JSONDecoder().decode(EventWatermarks.self, from: data)
            else { return EventWatermarks() }
            return marks
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.eventWatermarks)
        }
    }

    /// Reads the durable state Alice can compare — routine run records and
    /// component health — and returns what changed since it last looked.
    ///
    /// Durable is the operative word. Hermes' event ring is in memory, 512
    /// entries per session, and resets with the gateway, so it cannot answer
    /// "what happened while I was away". These two can: a cron run record and
    /// a component's status are both current server state, and comparing them
    /// against a stored watermark is a statement Alice can defend.
    ///
    /// Returns an empty list rather than throwing when the installation cannot
    /// be reached: not knowing is not an event.
    /// The single live observer of the dashboard socket.
    ///
    /// One, for the whole app. `sendToBotChat` opens its own short-lived
    /// listener for the turn it is drawing, and the client fans every frame out
    /// to all listeners, so the two coexist — but a second *long-lived* one
    /// would record every completion twice.
    private var liveObserver: Task<Void, Never>?
    /// Runtime ids minted by `session.resume` on this dashboard socket. Hermes
    /// emits pushed frames under these ids, while Alice persists the durable
    /// session row. Mapping the runtime id back to the conversation keeps Chat
    /// and Activity on the same canonical Bot Chat.
    private var liveBotSessions: [String: String] = [:]

    /// Which installation the stored activity and cursors belong to.
    ///
    /// Not the URL itself: that would put the address of a private machine into
    /// UserDefaults for no benefit. Only the question "is this still the same
    /// one" ever needs answering.
    nonisolated static func installationFingerprint(_ endpoint: String) -> String {
        // Swift's `hashValue` is deliberately randomised for every process. It
        // therefore cannot be persisted as installation identity: after a
        // relaunch the same Hermes looked like a different server and Alice
        // discarded its watermarks/activity. FNV-1a is not cryptographic — it
        // does not need to be — but is deterministic and stores no address.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in endpoint.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// One conservative installation identity for whichever transport an
    /// event used. Prefer the dashboard because socket events require it; a
    /// gateway-only install still gets a stable identity for durable runs.
    private var currentInstallationFingerprint: String? {
        let endpoint = dashboardURL.isEmpty ? gatewayURL : dashboardURL
        guard !endpoint.isEmpty else { return nil }
        return Self.installationFingerprint(endpoint)
    }

    private func tagged(_ event: AliceEvent) -> AliceEvent {
        var tagged = event
        if tagged.reference.installation == nil {
            tagged.reference.installation = currentInstallationFingerprint
        }
        return tagged
    }

    private func tagged(_ events: [AliceEvent]) -> [AliceEvent] {
        events.map(tagged)
    }

    private func observe(_ raw: AliceEvent) {
        let event = tagged(raw)
        let wasKnown = activity.contains { $0.id == event.id }
        record([event])
        if event.standing == .waiting { refreshAttention() }
        if !wasKnown {
            Task { [weak self] in await self?.deliver([event]) }
        }
    }

    /// Starts watching for work finishing and for anything that needs a person.
    ///
    /// Idempotent: called on launch and on every return to the foreground,
    /// because the socket does not survive suspension.
    func startWatchingLiveEvents() {
        guard dashboardReady, liveObserver == nil else { return }
        liveObserver = Task { [weak self] in
            guard let self, let rpc = await self.dashboardRPC() else { return }
            for await frame in rpc.events() {
                if Task.isCancelled { return }
                await self.absorb(frame)
            }
        }
    }

    func stopWatchingLiveEvents() {
        liveObserver?.cancel()
        liveObserver = nil
    }

    /// One pushed frame, if it is something a person should know about.
    private func absorb(_ frame: HermesRPCEvent) async {
        if let withdrawn = GatewayServerRequests.cancelledRequestID(frame) {
            withdrawServerRequest(withdrawn)
            return
        }
        guard let identity = sessionIdentity(for: frame.sessionID) else { return }
        // A turn nobody here follows is picked up when its chat is opened.
        // Reading it now replaced that transcript on the main thread and
        // rebuilt the chat and the drawer underneath whatever else was on
        // screen. The chat the person is looking at still updates.
        if LiveEvents.isTurnOutcome(frame), let conversationID = identity.conversationID,
           conversationID == activeID,
           activeBotTurns[conversationID] == nil,
           conversations.contains(where: { $0.id == conversationID && $0.isCanonicalBotChat }) {
            Task { [weak self] in await self?.refreshBotChat(conversationID) }
        }
        guard let raw = LiveEvents.event(from: frame, session: identity) else { return }
        let event = tagged(raw)
        let wasKnown = activity.contains { $0.id == event.id }
        record([event])
        if event.standing == .waiting { refreshAttention() }
        // The replay/snapshot path may show the same request immediately after
        // the live frame. Notification identifiers dedupe in iOS, but posting
        // twice can still alert twice; only a newly observed fact is delivered.
        if !wasKnown { await deliver([event]) }
    }

    /// Resolves a session id to who it belongs to.
    ///
    /// Only sessions Alice mirrors as a bot chat: a frame for a session this
    /// phone knows nothing about cannot be opened from a notification, and
    /// telling someone about work they cannot reach is worse than silence.
    private func sessionIdentity(for sessionID: String) -> LiveEvents.SessionIdentity? {
        guard !sessionID.isEmpty else { return nil }
        let mentions = pendingRequestSessions.filter(\.isMention)
        let liveMention = liveBotSessions[sessionID].flatMap { conversationID in
            guard let turn = activeBotTurns[conversationID],
                  let profile = turn.mentionProfile, let storedID = turn.storedSessionID
            else { return nil as PendingRequestSessions.Target? }
            return mentions.first {
                $0.conversationID == conversationID && $0.address.profile == profile
                    && $0.address.sessionID == storedID
            }
        }
        let mention = mentions.first { $0.address.sessionID == sessionID }
            ?? liveMention
        if let mention {
            return LiveEvents.SessionIdentity(
                profile: mention.address.profile, sessionID: mention.address.sessionID,
                sessionKey: mention.address.sessionID, conversationID: mention.conversationID,
                label: mention.address.profile.map { botCurrentName(for: $0) } ?? "Alice"
            )
        }
        let conversation: Conversation?
        // A bot's chat, or Alice's own chat held as a session: both can ask.
        let holdsSession = { (chat: Conversation) in
            chat.isCanonicalBotChat || chat.isHomeSessionChat
        }
        if let direct = conversations.first(where: {
            $0.hermesSessionID == sessionID && holdsSession($0)
        }) {
            conversation = direct
        } else if let conversationID = liveBotSessions[sessionID] {
            conversation = conversations.first(where: {
                $0.id == conversationID && holdsSession($0)
            })
        } else {
            conversation = nil
        }
        guard let conversation else { return nil }
        let profile = conversation.routedBotName
        let durableID = conversation.hermesSessionID ?? sessionID
        return LiveEvents.SessionIdentity(
            profile: profile,
            // Persist/action by durable identity. The runtime id is only a
            // transport address and dies with this websocket.
            sessionID: durableID,
            sessionKey: durableID,
            conversationID: conversation.id,
            label: profile.map { botCurrentName(for: $0) } ?? "Alice"
        )
    }

    /// Posts events that deserve a notification.
    ///
    /// Nothing is posted for a conversation the person is looking at: they can
    /// already see it happen, and a banner over the thing it describes is
    /// noise. Set by the caller, since only the interface knows what is on
    /// screen.
    private func deliver(_ events: [AliceEvent]) async {
        let worth = events.filter { event in
            if let profile = event.profile, !botNotificationsEnabled(for: profile) {
                return false
            }
            if event.kind == .finished,
               event.reference.conversationID == activeID,
               isForeground { return false }
            return true
        }
        guard !worth.isEmpty else { return }
        await notify?(worth)
    }

    /// Set by the app so the store can post without owning the notifier.
    var notify: (@MainActor ([AliceEvent]) async -> Void)?
    /// Whether the interface is on screen, for the "already watching" rule.
    var isForeground = true
    /// Foreground dumps skip if one went up in the last 20 seconds.
    private var lastDiagnosticsPush: Date?

    @discardableResult
    func syncEvents() async -> [AliceEvent] {
        guard dashboardReady else { return [] }
        let routines: [JobRow]
        do {
            routines = try await allRoutines().values.flatMap { $0 }
        } catch {
            return []
        }
        // The machine-wide reading, not the default profile's. Only that one
        // folds in assistants running their own gateway, and its channel map
        // names the channel — the roll-up says "platforms: degraded" and
        // nothing about which, which is how an alert called "Messaging apps"
        // came to be about WhatsApp without ever saying so.
        let status = try? await hermesSystemStatus(profile: nil)
        let components = status?.components ?? []
        let platforms = await channelProblems(status?.platforms)

        var marks = eventWatermarks
        // A different Hermes has different cursors. Carrying these across would
        // suppress the new server's real events as "already seen" and file its
        // activity under the old one's name.
        let fingerprint = currentInstallationFingerprint
            ?? Self.installationFingerprint(dashboardURL)
        if marks.installation != fingerprint {
            marks = EventWatermarks(installation: fingerprint)
            activity = []
            attention = []
            dismissedAttention = [:]
            persistActivity()
        }

        // Roll-up rows are no longer recorded; the ones already stored go too,
        // now rather than at the next launch.
        if activity.contains(where: Self.isChannelRollupRecord) {
            activity.removeAll(where: Self.isChannelRollupRecord)
            persistActivity()
        }

        let result = EventDigest.digest(
            routines: routines,
            components: EventDigest.digestComponents(components, channelsKnown: status?.platforms != nil),
            since: marks
        )
        eventWatermarks = result.watermarks
        // Requests still waiting are read from current server state, not from
        // the event history — which is why a first sync can stay silent about
        // finished runs and still surface an approval that is live right now.
        let pending = await pendingRequests()
        let knownWaiting = Set(activity.filter(\.isActionable).map(\.id))
        reconcilePending(against: pending)
        await reconcileRunApprovals()
        let changed = tagged(result.events).filter { !Self.isMutedReport($0, muted: mutedRoutines) }
        let currentPending = tagged(pending.events)
        let newlyPending = currentPending.filter { !knownWaiting.contains($0.id) }
        // Record every current snapshot so partially answered clarify batches
        // restore their locked qids, but notify only requests Alice had not
        // already seen live or on an earlier sync.
        record(changed + currentPending)
        refreshAttention(routines: routines, components: components, platforms: platforms)
        return (changed + newlyPending.filter { $0.standing == .waiting })
            .filter { event in
            // A bot's events follow that bot's switch. Everything else is
            // about the installation, which has no per-bot switch to consult.
            guard let profile = event.profile else { return true }
            return botNotificationsEnabled(for: profile)
        }
    }

    private var pendingRequestSessions: [PendingRequestSessions.Target] {
        let waiting = activity.filter {
            $0.isActionable && $0.reference.transport == .socket
                && $0.reference.belongs(to: currentInstallationFingerprint)
        }
        let sessions = Set(waiting.compactMap { event -> PendingRequestSessions.Address? in
            guard let sessionID = event.reference.sessionKey ?? event.reference.sessionID else { return nil }
            return PendingRequestSessions.Address(profile: event.profile, sessionID: sessionID)
        })
        return PendingRequestSessions.targets(
            in: conversations, waitingConversations: Set(waiting.compactMap(\.reference.conversationID)),
            waitingSessions: sessions
        )
    }

    /// What mirrored chats and outstanding mentions are currently waiting on.
    ///
    /// One `session.resume` per distinct profile/session, once per sync.
    /// Mentions retain the sending chat as their owner; idle home chats are
    /// not opened. The same snapshot recovers approvals and clarify requests.
    private func pendingRequests() async -> (events: [AliceEvent], checked: Set<String>) {
        guard let source = await botChatSource() else { return ([], []) }
        var events: [AliceEvent] = []
        var checked: Set<String> = []

        for target in pendingRequestSessions {
            let sessionID = target.address.sessionID
            let profile = target.address.profile
            guard let resumed = try? await source.resume(
                profile: profile, target: sessionID
            ) else { continue }
            checked.insert(sessionID)

            let identity = LiveEvents.SessionIdentity(
                profile: profile, sessionID: sessionID,
                sessionKey: (resumed["session_key"] as? String) ?? sessionID,
                conversationID: target.conversationID,
                label: profile.map { botCurrentName(for: $0) } ?? "Alice"
            )
            events += LiveEvents.pendingEvents(from: resumed, session: identity)
        }
        return (events, checked)
    }

    /// Marks anything Alice still shows as waiting that the server no longer
    /// has — answered on another device, timed out, or its session deleted.
    private func reconcilePending(against pending: (events: [AliceEvent], checked: Set<String>)) {
        let stillPending = Set(pending.events.compactMap(\.reference.requestID))
        activity = LiveEvents.reconcile(
            held: activity, stillPending: stillPending, checked: pending.checked
        )
        persistActivity()
    }

    /// Channels Hermes reports as broken that are still switched on.
    ///
    /// The gateway's record of a channel is what it last saw, and switching a
    /// channel off does not rewrite it until the gateway restarts — so a channel
    /// somebody had just turned off would keep its alert. Its own settings are
    /// asked, and one that is off is not a problem.
    private func channelProblems(
        _ platforms: [HermesPlatformHealth]?
    ) async -> [HermesPlatformHealth]? {
        guard let platforms else { return nil }
        var settings: [String: MessagingPlatformsSnapshot] = [:]
        var kept: [HermesPlatformHealth] = []
        for problem in platforms where EventDigest.isChannelProblem(problem) {
            if settings[problem.profile] == nil {
                settings[problem.profile] = try? await messagingPlatforms(profile: problem.profile)
            }
            let enabled = settings[problem.profile]?.platforms
                .first { $0.id == problem.platform }?.enabled
            if enabled != false { kept.append(problem) }
        }
        return kept
    }

    /// Carries out what an alert offered, then reads again so the alert
    /// reflects what happened.
    func apply(_ fix: AlertAdvice.Fix, for event: AliceEvent) async -> AlertAdvice.Outcome {
        var outcome = AlertAdvice.Outcome.done
        do {
            switch fix {
            case .open(let target, _):
                requestedDestination = target
                return .done
            case .runAgain:
                let routine = try await routine(for: event)
                let askedAt = Date()
                do {
                    try await triggerRoutine(routine)
                } catch DashboardClient.Failure.timedOut {
                    // Hermes replies to "run now" only when the run is over,
                    // minutes later. The wait running out is not a failure, and
                    // saying it was sent someone to press the button again for
                    // a run already under way. The automation says whether it
                    // started.
                    let latest = try? await self.routine(for: event)
                    guard AlertAdvice.runStarted(latest, askedAt: askedAt) else {
                        return .failed("Hermes didn't confirm it started. Pull down in a minute to check.")
                    }
                }
                outcome = .started
            case .useCurrentModel:
                let routine = try await routine(for: event)
                let profile = routine.profile ?? "default"
                // Read now: the default named in an old skip message may have
                // changed again since.
                let current = try await dashboard.profileModelInfo(profile: profile)
                guard !current.model.isEmpty else {
                    return .failed("Hermes didn't say which model is the default right now.")
                }
                try await dashboard.pinRoutineModel(
                    routine.id, profile: profile,
                    provider: current.provider, model: current.model
                )
            case .keepOriginalModel:
                let routine = try await routine(for: event)
                guard let drift = AlertAdvice.drift(in: EventDigest.failureDetail(routine) ?? "")
                else { return .failed("This automation isn't waiting on a model choice any more.") }
                // The stored snapshot, not the message: Hermes lower-cases the
                // names it writes into the message, and a model id is not
                // guaranteed to survive that.
                try await dashboard.pinRoutineModel(
                    routine.id, profile: routine.profile ?? "default",
                    provider: drift.provider.map { routine.providerSnapshot ?? $0.from },
                    model: drift.model.map { routine.modelSnapshot ?? $0.from }
                )
            case .turnOffChannel(let platform, let profile, _):
                try await setMessagingPlatformEnabled(platform, profile: profile, enabled: false)
                // Hermes has already confirmed the channel is off — the switch
                // reads it back — so the alert goes now, not after the full
                // re-read below, which took long enough to look like it had not
                // worked.
                attention.removeAll { $0.id == event.id }
            }
        } catch {
            return .failed(PlainWords.describe(error, doing: "send that answer"))
        }
        _ = await syncEvents()
        return outcome
    }

    /// The automation an event is about, read fresh so a fix acts on its
    /// current state.
    private func routine(for event: AliceEvent) async throws -> JobRow {
        guard let key = event.reference.routineKey,
              let row = try await allRoutines().values.flatMap({ $0 })
                .first(where: { EventDigest.key(for: $0) == key })
        else { throw DashboardClient.Failure.unreadable }
        return row
    }

    /// Current state, from whatever was last read plus anything still waiting.
    private func refreshAttention(
        routines: [JobRow]? = nil, components: [HermesSystemComponent]? = nil,
        platforms: [HermesPlatformHealth]? = nil
    ) {
        var items = activity.filter(\.isActionable)
        if let routines, let components {
            var assistants: [String: String] = [:]
            for profile in Set((platforms ?? []).map(\.profile)) {
                assistants[profile] = botCurrentName(for: profile)
            }
            items += EventDigest.attention(
                routines: routines, components: components,
                platforms: platforms, assistants: assistants
            )
        } else {
            items += attention.filter { $0.kind != .needsInput }
        }
        let visible = EventDigest.visible(
            items, dismissed: dismissedAttention,
            completeReading: routines != nil && components != nil
        )
        dismissedAttention = visible.dismissed
        attention = visible.shown.sorted { $0.severity > $1.severity }
    }

    /// Alert id → what it looked like when dismissed. See `EventDigest.fingerprint`.
    private var dismissedAttention: [String: String] {
        get { defaults.dictionary(forKey: Keys.dismissedAttention) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.dismissedAttention) }
    }

    /// Answers a request Hermes is holding, then makes the record agree.
    ///
    /// The decision goes over the same socket the request arrived on, keyed by
    /// the `request_id` Hermes resolves against rather than by anything a
    /// person can see or rename. Afterwards the row stops being actionable and
    /// the notification that announced it is withdrawn: leaving a banner for a
    /// question already answered is the same lie as the switch that promised
    /// notifications and sent none.
    /// Requests currently being answered, so a second tap on the same row —
    /// or a sync landing mid-flight — cannot send the decision twice.
    private var resolving: Set<String> = []

    /// Answers an approval Hermes is holding.
    ///
    /// Routed by the transport the request arrived on. A bot chat's approval is
    /// resolved by `approval.respond` over the dashboard socket keyed by
    /// `request_id`; a gateway run's is a POST to `/v1/runs/{id}/approval`
    /// keyed by the run. Sending one to the other resolves nothing while
    /// looking like it worked, so the reference decides.
    @discardableResult
    func resolvePendingRequest(
        _ event: AliceEvent, choice: Message.ApprovalChoice
    ) async -> Bool {
        guard event.standing == .waiting, !resolving.contains(event.id) else { return false }
        guard event.reference.belongs(to: currentInstallationFingerprint) else {
            settle(event.id, as: .gone,
                   summary: "This belongs to a different Hermes than the one Alice is connected to.")
            return false
        }
        resolving.insert(event.id)
        defer { resolving.remove(event.id) }

        switch event.reference.transport {
        case .gatewayRun:
            guard let runID = event.reference.runID else { return false }
            do {
                _ = try await client.respondToRunApproval(
                    runID: runID, requestID: event.reference.requestID,
                    choice: choice, profile: event.reference.profile
                )
                settle(event.id, as: .resolved, summary: "You answered this.")
                mirrorGatewayApprovalIntoChat(event, resolved: true)
                return true
            } catch let failure as HermesClient.Failure {
                // 404/409 are authoritative evidence that this exact run or
                // approval is no longer pending. Transport failures are not.
                if case let .http(status, _, _) = failure, [404, 409].contains(status) {
                    settle(event.id, as: .gone, summary: Self.noLongerWaiting)
                    mirrorGatewayApprovalIntoChat(event, resolved: false)
                } else {
                    markResolutionFailed(event.id, failure)
                }
                return false
            } catch {
                markResolutionFailed(event.id, error)
                return false
            }
        case .socket:
            guard let requestID = event.reference.requestID,
                  let sessionID = event.reference.sessionID,
                  let rpc = await dashboardRPC()
            else { return false }
            do {
                let result = try await WebSocketBotChatSource(rpc: rpc).respondToApproval(
                    sessionID: sessionID, requestID: requestID, choice: choice.rawValue
                )
                guard LiveEvents.didResolve(result) else {
                    settle(event.id, as: .gone, summary: Self.noLongerWaiting)
                    mirrorApprovalIntoChat(event, resolved: false)
                    return false
                }
                settle(event.id, as: .resolved, summary: "You answered this.")
                mirrorApprovalIntoChat(event, resolved: true)
                return true
            } catch {
                markResolutionFailed(event.id, error)
                return false
            }
        }
    }

    /// Questions Hermes is waiting on in this conversation. Matched by Alice's
    /// conversation id, and also by the bot's profile so a request that landed
    /// before the session was mirrored still appears in that bot's chat.
    /// The active chat's agent asked and is waiting on the answers. Its turn
    /// reads as delivered: nothing to stop, and what is sent next answers.
    var activeAwaitsAnswers: Bool {
        activeID.map { !pendingQuestions(in: $0).isEmpty } ?? false
    }

    /// A reply is under way that Stop applies to — not one held on questions.
    var canStop: Bool { isSending && !activeAwaitsAnswers }

    /// Hermes has taken the send but has not started it yet.
    var queuedSendNote: String? {
        guard let id = activeID, let turn = activeBotTurns[id],
              let note = Self.queuedSendNote(
                disposition: turn.disposition,
                label: queuedSendLabel(for: turn, conversationID: id)
              )
        else { return nil }
        return note
    }

    /// There is no per-prompt cancel in Hermes; Stop interrupts the whole queue.
    func cancelQueuedSend() {
        stop()
    }

    nonisolated static func queuedSendNote(
        disposition: BotChatSubmission.Disposition?, label: String
    ) -> String? {
        guard let disposition, disposition == .queued || disposition == .foldedIn else {
            return nil
        }
        return deliveryNote(for: disposition, label: label)
    }

    private func queuedSendLabel(for turn: ActiveBotTurn, conversationID: String) -> String {
        let profile = conversations.first(where: { $0.id == conversationID })?.routedBotName
            ?? turn.mentionProfile
        return profile.map { botCurrentName(for: $0) } ?? "Alice"
    }

    /// What is written in the composer while questions wait answers the one
    /// being asked, as "Something else" would.
    private func answerWaitingQuestion(with text: String) -> Bool {
        guard let activeID,
              let event = pendingQuestions(in: activeID).first,
              let question = event.questions.first(where: { $0.answer == nil })
        else { return false }
        var answer = text
        if question.allowsMultiple,
           let data = try? JSONSerialization.data(withJSONObject: [text]),
           let encoded = String(data: data, encoding: .utf8) {
            answer = encoded
        }
        draft = ""
        Task { [weak self] in
            guard let self else { return }
            if await !self.answerClarification(event, questionID: question.id, answer: answer),
               self.draft.isEmpty {
                self.draft = text
            }
        }
        return true
    }

    func pendingQuestions(in conversationID: String) -> [AliceEvent] {
        guard let chat = conversation(conversationID) else { return [] }
        // A mention is identified by both profile and durable Hermes session.
        // Matching only by profile lets an older unresolved question from the
        // same agent jump into a newer turn in another session.
        let awaited = Set(chat.messages.compactMap { message -> PendingRequestSessions.Address? in
            guard message.pending || message.awaitingRemote,
                  let profile = message.mentionProfile, !profile.isEmpty,
                  let sessionID = message.mentionSessionID, !sessionID.isEmpty
            else { return nil }
            return PendingRequestSessions.Address(profile: profile, sessionID: sessionID)
        })
        return activity.filter { event in
            Self.claimsQuestions(
                event, conversationID: conversationID,
                routedBot: chat.routedBotName, routedSessionID: chat.hermesSessionID,
                awaitedSessions: awaited
            )
        }
    }

    /// Whether a chat is where a question should be asked.
    ///
    /// A direct conversation id wins. Otherwise a bot chat or `@bot` mention
    /// must match the exact Hermes session whenever both sides know it. This
    /// keeps a previous turn's still-live clarify card from being presented as
    /// the answer to a newly submitted turn merely because both use Inbox (or
    /// any other same-profile agent).
    nonisolated static func claimsQuestions(
        _ event: AliceEvent, conversationID: String, routedBot: String?,
        routedSessionID: String?, awaitedSessions: Set<PendingRequestSessions.Address>
    ) -> Bool {
        guard event.isActionable, !event.questions.isEmpty else { return false }
        if event.reference.conversationID == conversationID { return true }
        guard let profile = event.profile else { return false }

        let eventSessionID = event.reference.sessionID ?? event.reference.sessionKey
        if profile == routedBot {
            guard let routedSessionID, let eventSessionID else { return true }
            if eventSessionID == routedSessionID { return true }
        }

        guard let eventSessionID else {
            // Legacy records may predate persisted session identity. Preserve
            // their old profile fallback only while this chat is actively
            // waiting on that profile.
            return awaitedSessions.contains { $0.profile == profile }
        }
        return awaitedSessions.contains(
            PendingRequestSessions.Address(profile: profile, sessionID: eventSessionID)
        )
    }

    /// Answers one clarify question Hermes is blocked on.
    ///
    /// A batch is not one answer: Hermes locks each member by `question_id`
    /// and reports the qids still remaining. Alice keeps the Activity row
    /// actionable until that list is empty. Sending a batch without a qid is
    /// refused locally because Hermes would treat it as a cancel/whole-request
    /// answer and the first question would falsely resolve the rest.
    ///
    /// `skip` sends an empty answer, which Hermes reads as a deliberate skip.
    @discardableResult
    func answerClarification(
        _ event: AliceEvent, questionID: String? = nil, answer: String, skip: Bool = false
    ) async -> Bool {
        let text = skip ? "" : answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.standing == .waiting, skip || !text.isEmpty,
              !resolving.contains(event.id),
              let requestID = event.reference.requestID
        else { return false }
        if event.questions.count > 1 && questionID == nil {
            markResolutionFailed(
                event.id, HermesRPCClient.Failure(
                    reason: "Hermes is waiting on several questions; choose which one this answer belongs to."
                )
            )
            return false
        }
        if let questionID, !event.questions.contains(where: { $0.id == questionID }) {
            return false
        }
        guard event.reference.belongs(to: currentInstallationFingerprint) else {
            settle(event.id, as: .gone,
                   summary: "This belongs to a different Hermes than the one Alice is connected to.")
            return false
        }
        guard let rpc = await dashboardRPC() else { return false }
        resolving.insert(event.id)
        defer { resolving.remove(event.id) }

        do {
            let result = try await WebSocketBotChatSource(rpc: rpc).answerClarify(
                sessionID: event.reference.sessionID, requestID: requestID,
                questionID: questionID, answer: text
            )

            switch LiveEvents.clarifyReply(result, questionID: questionID) {
            case .resolved:
                if let questionID {
                    lockClarificationAnswer(event.id, questionID: questionID, answer: text)
                    settle(event.id, as: .resolved, summary: "You answered all questions.")
                } else {
                    settle(event.id, as: .resolved,
                           summary: skip ? "You skipped the question." : "You answered: \(text)")
                }
                return true
            case .partial:
                guard let questionID else { return false }
                lockClarificationAnswer(event.id, questionID: questionID, answer: text)
                return true
            case .expired:
                settle(event.id, as: .gone, summary: Self.noLongerWaiting)
                return false
            case .invalid:
                markResolutionFailed(
                    event.id, HermesRPCClient.Failure(
                        reason: "Hermes accepted the call but did not prove which clarification questions remain."
                    )
                )
                return false
            }
        } catch {
            markResolutionFailed(event.id, error)
            return false
        }
    }

    private func lockClarificationAnswer(_ id: String, questionID: String, answer: String) {
        guard let eventIndex = activity.firstIndex(where: { $0.id == id }),
              let questionIndex = activity[eventIndex].questions.firstIndex(where: { $0.id == questionID })
        else { return }
        activity[eventIndex].questions[questionIndex].answer = answer
        let answered = activity[eventIndex].questions.filter { $0.answer != nil }.count
        let total = activity[eventIndex].questions.count
        activity[eventIndex].summary = "\(answered) of \(total) questions answered. \(total - answered) still waiting."
        persistActivity()
        refreshAttention()
    }

    /// Settles whatever Activity row corresponds to a request answered
    /// elsewhere in the app. Keyed by the request id, which both surfaces use.
    func settleRequest(matching requestID: String, summary: String) {
        guard let event = activity.first(where: {
            $0.reference.requestID == requestID && $0.standing == .waiting
        }) else { return }
        settle(event.id, as: .resolved, summary: summary)
    }

    private func settleGatewayRun(matching runID: String, summary: String) {
        guard let event = activity.first(where: {
            $0.reference.runID == runID && $0.standing == .waiting
        }) else { return }
        settle(event.id, as: .resolved, summary: summary)
    }

    private func markRequestGone(matching requestID: String) {
        guard let event = activity.first(where: {
            $0.reference.requestID == requestID && $0.standing == .waiting
        }) else { return }
        settle(event.id, as: .gone, summary: Self.noLongerWaiting)
    }

    /// A question Hermes withdrew with `request.cancel`: it timed out, the turn
    /// was interrupted, or somebody answered on another device. Its Activity
    /// row, its notification and its card in the chat go with it — a card left
    /// behind would offer an answer nothing is waiting for.
    func withdrawServerRequest(_ requestID: String) {
        if let event = activity.first(where: {
            $0.reference.requestID == requestID && $0.standing == .waiting
        }) {
            withdraw?(event.id)
        }
        markRequestGone(matching: requestID)
        var changed = false
        for chat in conversations.indices {
            for message in conversations[chat].messages.indices
            where conversations[chat].messages[message].approval?.requestID == requestID {
                conversations[chat].messages[message].approval = nil
                changed = true
            }
        }
        if changed { persistConversations() }
    }

    /// Run approvals Alice still shows as waiting, checked with Hermes.
    ///
    /// These were only ever settled by answering them. Hermes gives up on an
    /// approval after its timeout — five minutes unless configured — and
    /// refuses it, so a request from hours earlier sat in Activity asking for
    /// an OK long after there was anything to answer. Only Hermes' own word
    /// expires one; a check that cannot reach it changes nothing.
    private func reconcileRunApprovals() async {
        let waiting = activity.filter {
            $0.standing == .waiting && $0.reference.transport == .gatewayRun
        }
        for event in waiting {
            guard let runID = event.reference.runID,
                  let stillWaiting = try? await client.runIsWaitingForApproval(
                      runID: runID, profile: event.reference.profile
                  ),
                  !stillWaiting
            else { continue }
            settle(event.id, as: .gone, summary: Self.stoppedWaiting)
            mirrorGatewayApprovalIntoChat(event, resolved: false)
        }
    }

    static let stoppedWaiting =
        "Hermes stopped waiting for an answer, so this wasn't allowed. There's nothing left to do."

    /// Rows written before a failed reply was kept in `note` carry the network
    /// error where the command should be, so "Show exact command" read
    /// "Couldn't reach that address from this iPhone". The command is not
    /// recoverable; the error is at least no longer passed off as it.
    nonisolated static func withoutMisplacedError(_ event: AliceEvent) -> AliceEvent {
        guard event.kind == .needsInput, event.questions.isEmpty, let detail = event.detail
        else { return event }
        let errors: [String] = [
            HermesClient.Failure.unreachable, .timedOut, .offline, .badResponse, .blockedByPolicy,
        ].compactMap(\.errorDescription) + [
            DashboardClient.Failure.unreachable, .timedOut, .notConfigured,
        ].compactMap(\.errorDescription)
        guard errors.contains(detail) || detail.hasPrefix("That reply didn't reach Hermes")
        else { return event }
        var repaired = event
        repaired.detail = nil
        return repaired
    }

    /// A stored record of the channels' roll-up — "platforms" going degraded or
    /// coming back. Each channel has its own named alert now, and a row saying
    /// only that some messaging app had, or no longer has, a problem was read
    /// as an alert about nothing. Reworded, it still said nothing.
    nonisolated static func isChannelRollupRecord(_ event: AliceEvent) -> Bool {
        guard event.id.hasPrefix("component:") else { return false }
        let parts = event.id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 2 && EventDigest.isChannelRollup(String(parts[1]))
    }

    /// A component row written by an older build keeps that build's words:
    /// Hermes' raw name and a bare status, "Platforms needs attention". The id
    /// has kept its shape — `component:<name>:<status>` — so the wording is
    /// derived again from it, the same way a new row gets it.
    nonisolated static func withCurrentWording(_ event: AliceEvent) -> AliceEvent {
        guard event.id.hasPrefix("component:") else { return event }
        let parts = event.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, !parts[1].isEmpty else { return event }
        let name = parts[1]
        let status = parts[2...].joined(separator: ":")
        var repaired = event
        repaired.title = EventDigest.label(for: name)
        repaired.summary = EventDigest.healthy(status)
            ? EventDigest.recovery(for: name, label: repaired.title)
            : EventDigest.consequence(for: name)
        return repaired
    }

    static let noLongerWaiting =
        "This was already answered elsewhere, or it expired."

    /// The send did not reach Hermes. The request stays actionable, because it
    /// is probably still blocking the agent.
    private func markResolutionFailed(_ id: String, _ error: Error) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        // Recorded beside the request, not over it. Writing this into `detail`
        // replaced the command the card is asking about, so the buttons ended
        // up offering Once/Always over the text of a network error.
        let reason = PlainWords.describe(error, doing: "send the reply")
        let who = activity[index].profile.map(botCurrentName(for:)) ?? "the assistant"
        activity[index].note =
            "That reply didn't reach Hermes (\(reason)), so \(who) is still waiting. Try again."
        persistActivity()
    }

    /// Clears the matching approval card in the conversation, so answering in
    /// Activity does not leave the chat still asking.
    private func mirrorApprovalIntoChat(_ event: AliceEvent, resolved: Bool) {
        guard let requestID = event.reference.requestID,
              let conversationID = event.reference.conversationID,
              let chat = conversations.firstIndex(where: { $0.id == conversationID })
        else { return }
        for index in conversations[chat].messages.indices
        where conversations[chat].messages[index].approval?.runID == requestID {
            conversations[chat].messages[index].approval = nil
            if resolved {
                conversations[chat].messages[index].runStatus = .running
            }
        }
        persistConversations()
    }

    private func mirrorGatewayApprovalIntoChat(_ event: AliceEvent, resolved: Bool) {
        guard let runID = event.reference.runID,
              let conversationID = event.reference.conversationID,
              let chat = conversations.firstIndex(where: { $0.id == conversationID })
        else { return }
        for index in conversations[chat].messages.indices
        where conversations[chat].messages[index].approval?.runID == runID {
            conversations[chat].messages[index].approval = nil
            if resolved { conversations[chat].messages[index].runStatus = .running }
        }
        persistConversations()
    }

    private func settle(_ id: String, as standing: AliceEvent.Standing, summary: String) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        activity[index].standing = standing
        activity[index].severity = .informational
        activity[index].summary = summary
        persistActivity()
        refreshAttention()
        withdraw?(id)
    }

    /// The event a tap arrived for, so the destination can highlight it.
    private(set) var routedEvent: String?
    /// A notification tap that cannot safely navigate gets an explicit reason
    /// instead of silently doing nothing or acting on the wrong installation.
    var routeNotice: String?

    /// Retracts a delivered notification. Owned by the app, like `notify`.
    var withdraw: (@MainActor (String) -> Void)?

    /// Opens what a tapped notification was about.
    /// Opens the chat a notification from the Mac watcher points at.
    func open(_ link: NotificationLink) {
        showingBots = false
        showingNotes = false
        showingAgenda = false
        switch link {
        case let .bot(name) where name == Self.todayProfile:
            openToday()
        case let .bot(name):
            let bot = cachedBots.first(where: { $0.name == name }) ?? BotRow(
                name: name, displayName: botCurrentName(for: name), detail: "",
                model: nil, provider: nil, skills: 0, isDefault: false,
                gatewayRunning: false, active: true
            )
            openBotConversation(for: bot)
        case let .chat(id):
            if let id, conversations.contains(where: { $0.id == id }) {
                activeID = id
            } else if let latest = conversations.first(where: { !$0.isCanonicalBotChat && $0.botName == nil }) {
                activeID = latest.id
            }
        }
    }

    @discardableResult
    func open(_ route: Notifier.Route) -> Bool {
        if let installation = route.installation,
           installation != currentInstallationFingerprint {
            routeNotice = "This notification belongs to a different Hermes installation. Nothing was changed."
            return false
        }

        routedEvent = route.eventID
        if land(on: route) { return true }

        // Missing local navigation is not evidence that the server-side request
        // expired. Keep an actionable Activity row actionable; it may still be
        // answerable from its saved session/request identity.
        if let profile = route.profile,
           retiredBotSlugs.contains(where: { $0.caseInsensitiveCompare(profile) == .orderedSame }) {
            routeNotice = "That agent was deleted."
            return false
        }
        routeNotice = route.conversationID == nil && route.profile == nil
            ? "This notification has no conversation to open. You can review it in Activity."
            : "That conversation is no longer on this phone. You can review the event in Activity."
        return false
    }

    /// Conversation id first, then the live session, then the bot the event
    /// named. A stale local id used to stop the tap even when the profile was
    /// still on the phone.
    private func land(on route: Notifier.Route) -> Bool {
        func show(_ id: String) -> Bool {
            showingBots = false
            showingNotes = false
            showingAgenda = false
            activeID = id
            return true
        }

        if let id = route.conversationID,
           conversations.contains(where: { $0.id == id }) {
            return show(id)
        }
        if let session = route.sessionID, !session.isEmpty,
           let chat = conversations.first(where: { $0.hermesSessionID == session }) {
            return show(chat.id)
        }
        if let profile = route.profile, !profile.isEmpty {
            // A deleted agent is not opened again: a fresh chat under its name
            // looked like the agent had survived its deletion.
            let known = cachedBots.contains {
                $0.name.caseInsensitiveCompare(profile) == .orderedSame
            }
            if retiredBotSlugs.contains(where: { $0.caseInsensitiveCompare(profile) == .orderedSame })
                || (!known && !cachedBots.isEmpty) {
                return false
            }
            showingBots = false
            showingNotes = false
            showingAgenda = false
            let bot = cachedBots.first {
                $0.name.caseInsensitiveCompare(profile) == .orderedSame
            } ?? BotRow(
                name: profile, displayName: botCurrentName(for: profile), detail: "",
                model: nil, provider: nil, skills: 0, isDefault: false,
                gatewayRunning: false, active: true
            )
            openBotConversation(for: bot)
            return true
        }
        return false
    }

    /// Keeps the newest events and drops the rest. A current server snapshot
    /// replaces an older copy of the same id so batch answers/standing survive
    /// reconnects without creating duplicate rows. Preserve the original time
    /// so a refresh does not turn an old request into new unread activity.
    private func record(_ events: [AliceEvent]) {
        guard !events.isEmpty else { return }
        var merged = activity
        for raw in events {
            let event = tagged(raw)
            if let index = merged.firstIndex(where: { $0.id == event.id }) {
                var replacement = event
                replacement.occurred = merged[index].occurred
                merged[index] = replacement
            } else {
                merged.append(event)
            }
        }
        activity = Array(
            merged.sorted { $0.occurred > $1.occurred }.prefix(Self.activityLimit)
        )
        persistActivity()
    }

    func markActivitySeen() {
        let now = Date()
        activitySeen = now
        agentsNoticesSeen = now
        routinesNoticesSeen = now
    }

    /// Removes a row the person is done with.
    ///
    /// Refuses anything still waiting on them: Activity accumulating forever
    /// was a real complaint, but the fix cannot be a gesture that makes a live
    /// approval disappear without answering it. Attention items are current
    /// state, so they come back on the next sync if the thing is still wrong —
    /// dismissing one clears the notice, not the problem.
    func dismissActivity(_ event: AliceEvent) {
        guard !event.isActionable else { return }
        // A current problem is read again on the next sync; without this it
        // was back within seconds of being swiped away.
        if let current = attention.first(where: { $0.id == event.id }) {
            dismissedAttention[current.id] = EventDigest.fingerprint(current)
        }
        activity.removeAll { $0.id == event.id }
        attention.removeAll { $0.id == event.id }
        persistActivity()
        withdraw?(event.id)
    }

    /// Clears the record under Recent.
    ///
    /// Not `dismissHandledActivity`, which also hides what is wrong now: Needs
    /// attention lists the present, and clearing history is a different wish
    /// from dismissing a problem. Anything still waiting on an answer stays.
    func clearActivityHistory() {
        let cleared = activity.filter { !$0.isActionable }
        activity.removeAll { !$0.isActionable }
        persistActivity()
        for event in cleared { withdraw?(event.id) }
    }

    var hasActivityHistory: Bool { activity.contains { !$0.isActionable } }

    #if DEBUG
    /// UI tests only: puts one channel alert in Needs attention so the fix
    /// flow can be driven without a Hermes. Its fix goes to the real client,
    /// which, unconnected, fails and must say so.
    func seedChannelAlertForUITests() {
        guard ProcessInfo.processInfo.arguments.contains("-seedChannelAlert") else { return }
        attention = EventDigest.attention(
            routines: [], components: [],
            platforms: [HermesPlatformHealth(
                key: "whatsapp", profile: "default", platform: "whatsapp", state: "fatal",
                errorCode: "whatsapp_not_paired",
                errorMessage: "WhatsApp enabled but not paired"
            )]
        )
    }

    /// UI tests only: a long bot conversation, open, so the transcript's
    /// jump-to-latest control can be driven without a Hermes.
    func seedLongBotChatForUITests() {
        let arguments = ProcessInfo.processInfo.arguments
        // `-seedTallBotChat` gives every reply the length of a Radar IA report,
        // the kind of chat that opened blank on a phone.
        let tall = arguments.contains("-seedTallBotChat")
        guard tall || arguments.contains("-seedLongBotChat") else { return }
        // Headlines carry their reply's number, so the end of one reply can be
        // told from the end of another: replies are drawn block by block.
        let report = { (reply: Int) in
            (1...14).map { item in
                "**Titular de prueba \(reply).\(item)**\nUna frase con qué cambia y por qué importa en la práctica, lo bastante larga para ocupar dos líneas.\nhttps://example.com/noticia/\(item)"
            }.joined(separator: "\n\n")
        }
        let start = Date().addingTimeInterval(-3_600)
        var messages: [Message] = []
        for n in 1...30 {
            let at = start.addingTimeInterval(Double(n) * 60)
            messages.append(Message(
                id: "uitest-q-\(n)", role: .user,
                content: "Pregunta \(n): ¿qué ha cambiado desde la última vez?",
                createdAt: at
            ))
            messages.append(Message(
                id: "uitest-a-\(n)", role: .assistant,
                content: tall ? "Respuesta de prueba \(n).\n\n\(report(n))" : "Respuesta de prueba \(n).",
                createdAt: at.addingTimeInterval(20), botName: "uitest-bot"
            ))
        }
        let chat = Conversation(
            id: "uitest-long-bot-chat", title: "UI Test Bot",
            createdAt: start, updatedAt: Date(), messages: messages, botName: "uitest-bot"
        )
        if !cachedBots.contains(where: { $0.name == "uitest-bot" }) {
            cachedBots.insert(BotRow(
                name: "uitest-bot", displayName: "UI Test Bot", detail: "Test bot",
                model: nil, provider: nil, skills: 0, isDefault: false,
                gatewayRunning: false, active: true
            ), at: 0)
        }
        conversations.removeAll { $0.id == chat.id }
        conversations.insert(chat, at: 0)
        activeID = chat.id

        // `-growSeededChat` makes the last reply land whole a moment after
        // opening, the way a bot's report arrives once its turn ends.
        guard arguments.contains("-growSeededChat") else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  let chat = self.conversations.firstIndex(where: { $0.id == "uitest-long-bot-chat" }),
                  let last = self.conversations[chat].messages.indices.last
            else { return }
            self.conversations[chat].messages[last].content += "\n\n\(report(30))\n\nFin del informe."
        }
    }    #endif

    /// Clears everything that is over, leaving anything still waiting.
    func dismissHandledActivity() {
        var dismissed = dismissedAttention
        for current in attention where !current.isActionable {
            dismissed[current.id] = EventDigest.fingerprint(current)
        }
        dismissedAttention = dismissed
        activity.removeAll { !$0.isActionable }
        attention.removeAll { !$0.isActionable }
        persistActivity()
    }

    private func persistActivity() {
        guard let data = try? JSONEncoder().encode(activity.map(StoredEvent.init)) else { return }
        defaults.set(data, forKey: Keys.activity)
    }

    private func loadActivity() {
        guard let data = defaults.data(forKey: Keys.activity),
              let stored = try? JSONDecoder().decode([StoredEvent].self, from: data)
        else { return }
        activity = stored.map(\.event).filter { event in
            // Left behind by agents deleted before their Activity went with them.
            !retiredBotSlugs.contains { slug in
                [event.profile, event.reference.profile].contains {
                    $0?.caseInsensitiveCompare(slug) == .orderedSame
                }
            }
        }
            .filter { !Self.isChannelRollupRecord($0) }
            .map(Self.withoutMisplacedError)
            .map(Self.withCurrentWording)
    }

    /// `AliceEvent` is the app's vocabulary; this is only its disk shape, kept
    /// separate so a future field cannot silently change what is already
    /// stored on somebody's phone.
    struct StoredEvent: Codable {
        var id: String
        var kind: String
        var severity: Int
        var profile: String?
        var title: String
        var summary: String
        var detail: String?
        var occurred: Date
        // Optional on disk for compatibility with activity written before
        // actionable requests were persisted completely.
        var reference: AliceEvent.Reference?
        var standing: AliceEvent.Standing?
        var questions: [AliceEvent.Question]?
        var approvalChoices: [Message.ApprovalChoice]?
        var note: String?
        var approvalDescription: String?
        var smartDenied: Bool?

        init(_ event: AliceEvent) {
            id = event.id
            kind = event.kind.rawValue
            severity = event.severity.rawValue
            profile = event.profile
            title = event.title
            summary = event.summary
            detail = event.detail
            occurred = event.occurred
            reference = event.reference
            standing = event.standing
            questions = event.questions
            approvalChoices = event.approvalChoices
            note = event.note
            approvalDescription = event.approvalDescription
            smartDenied = event.smartDenied ? true : nil
        }

        var event: AliceEvent {
            var event = AliceEvent(
                id: id,
                kind: AliceEvent.Kind(rawValue: kind) ?? .finished,
                severity: AliceEvent.Severity(rawValue: severity) ?? .informational,
                profile: profile, title: title, summary: summary,
                detail: detail, occurred: occurred,
                reference: reference ?? .init(),
                standing: standing ?? .none,
                questions: questions ?? [],
                approvalChoices: approvalChoices ?? [], note: note
            )
            event.approvalDescription = approvalDescription
            event.smartDenied = smartDenied ?? false
            return event
        }
    }

    func botNotificationsEnabled(for bot: String) -> Bool {
        botNotifications[bot] ?? botNotifications[bot.lowercased()] ?? false
    }

    func setBotNotifications(_ bot: String, enabled: Bool) {
        botNotifications[bot] = enabled
        botNotifications[bot.lowercased()] = enabled
    }

    // MARK: - Channels

    // MARK: - Notes

    /// The notes an agent keeps on Hermes, as last read. Nil until read once,
    /// so Notes opens on what it had while it asks again.
    /// Kept on the phone between launches, so Notes opens on what was there
    /// last time and is brought up to date behind it, instead of opening on a
    /// spinner for as long as the round trip to Hermes takes.
    private(set) var notesSnapshot: NotesSnapshot? {
        didSet {
            guard notesSnapshot != oldValue else { return }
            guard let notesSnapshot else {
                defaults.removeObject(forKey: Keys.notesSnapshot)
                return
            }
            // Notes still on their way are not kept: Hermes has not got them.
            let settled = notesSnapshot.with(notes: notesSnapshot.notes.filter { !$0.sending })
            if let data = try? JSONEncoder().encode(settled) {
                defaults.set(data, forKey: Keys.notesSnapshot)
            }
        }
    }

    /// Why the last notes refresh failed, or that the store is ready. Kept
    /// beside the snapshot so a timeout does not look like "no notes agent".
    private(set) var notesAccess: NotesAccess = .unknown
    /// The plugin on Hermes did not take attachments. Photos stay on this
    /// phone until that plugin is updated; the banner is only this, never a
    /// cached snapshot that simply omitted the flag.
    var notesAttachmentsNeedPlugin = false

    func refreshNotes() async throws {
        do {
            let snap = try await dashboard.notes()
            notesSnapshot = NotesFeed.mergingAttachments(remote: snap, local: notesSnapshot)
            if snap.supportsAttachments == true { notesAttachmentsNeedPlugin = false }
            notesAccess = .from(snapshot: snap)
            await moveLegacyFoldersToStore()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            notesAccess = .from(error: error)
            if let failure = error as? DashboardClient.Failure, case .http(404, _) = failure {
                throw HermesRPCClient.Failure(
                    reason: "Notes need the latest Alice plugin on your Hermes."
                )
            }
            throw error
        }
    }

    /// Closes Notes and opens the new-agent form on the Inbox template.
    func requestInboxAgent() {
        requestedAgentTemplate = "inbox"
        showingNotes = false
        showingAgenda = false
        showingBots = true
        markNoticesSeen(.agents)
    }

    /// Deletes a note, gone from the list at once. One Hermes did not delete
    /// comes back where it was, and the error is thrown.
    func deleteNote(_ note: Note) async throws {
        guard let current = notesSnapshot,
              let index = current.notes.firstIndex(where: { $0.id == note.id })
        else { return }
        var remaining = current.notes
        remaining.remove(at: index)
        notesSnapshot = current.with(notes: remaining)
        do {
            try await dashboard.deleteNote(id: note.id)
            // Kept here to recover for a while; gone from the store already.
            recentlyDeleted.insert(
                DeletedNote(note: note, deletedAt: Date(), folderID: note.folder), at: 0
            )
            pinnedNotes.remove(note.id)
        } catch {
            if let now = notesSnapshot, !now.notes.contains(where: { $0.id == note.id }) {
                var restored = now.notes
                restored.insert(note, at: min(index, restored.count))
                notesSnapshot = now.with(notes: restored)
            }
            throw error
        }
    }

    /// Saves an edited note, shown at once. A save Hermes refuses puts the
    /// note back as it was and throws, so the editor can say so.
    func editNote(_ note: Note, text: String, rich: String?, attachments: [Attachment]? = nil) async throws {
        func put(_ replacement: Note) {
            guard let current = notesSnapshot else { return }
            notesSnapshot = current.with(notes: current.notes.map { $0.id == replacement.id ? replacement : $0 })
        }
        let wanted = attachments ?? note.attachments
        let optimistic = Note(
            id: note.id, createdAt: note.createdAt, text: text, urls: note.urls,
            types: note.types, topics: note.topics, actions: note.actions,
            openQuestions: note.openQuestions, summary: note.summary,
            processed: note.processed, rich: rich, editedAt: Date(),
            folder: note.folder, tags: note.tags, attachments: wanted
        )
        put(optimistic)
        do {
            var saved = try await dashboard.editNote(
                id: note.id, text: text, rich: rich, attachments: wanted
            )
            rememberNoteAttachmentsSync(saved, sent: wanted)
            if saved.attachments == nil { saved.attachments = wanted }
            put(saved)
        } catch {
            put(note)
            throw error
        }
    }

    /// Shows a note at once and saves it in the agent's store. One Hermes did
    /// not take is taken off the list again, and the error thrown so the words
    /// go back into the field.
    @discardableResult
    func addNote(_ text: String, attachments: [Attachment]? = nil) async throws -> Note {
        let placeholder = Note(
            id: "local-\(UUID().uuidString)", createdAt: Date(), text: text, sending: true,
            attachments: attachments
        )
        if let current = notesSnapshot {
            notesSnapshot = current.with(notes: [placeholder] + current.notes)
        }
        func replacing(_ note: Note?) {
            guard let current = notesSnapshot else { return }
            var notes = current.notes.filter { $0.id != placeholder.id }
            if let note { notes.insert(note, at: 0) }
            notesSnapshot = current.with(notes: notes)
        }
        do {
            var saved = try await dashboard.addNote(text, attachments: attachments)
            rememberNoteAttachmentsSync(saved, sent: attachments)
            if saved.attachments == nil { saved.attachments = attachments }
            replacing(saved)
            return saved
        } catch {
            replacing(nil)
            throw error
        }
    }

    private func rememberNoteAttachmentsSync(_ saved: Note, sent: [Attachment]?) {
        if saved.attachments != nil {
            notesAttachmentsNeedPlugin = false
        } else if let sent, !sent.isEmpty {
            notesAttachmentsNeedPlugin = true
        }
    }

    /// Whether a bot lives in a channel, and so not in the Bots page's
    /// general list.
    func isInAnyChannel(_ bot: String) -> Bool {
        botChannels.contains { $0.bots.contains(bot) }
    }

    func hasUnread(_ bots: [String]) -> Bool {
        bots.contains { isBotUnread($0) }
    }

    /// Whether an agent is at work: a reply under way in its chat, a turn
    /// Hermes is running there, or an answer another agent is waiting on.
    /// A clarify question is already on screen: the bot is waiting on the
    /// person, not working.
    func isBotWorking(_ bot: String) -> Bool {
        let chats = conversations.filter {
            $0.routedBotName == bot && $0.isCanonicalBotChat
        }
        let waitingOnPerson = chats.contains { !pendingQuestions(in: $0.id).isEmpty }
        let sending = chats.contains { sendingConversations.contains($0.id) }
        let backgroundEmpty = chats.allSatisfy { backgroundWork(for: $0.id).isEmpty }
        let awaitedByPeer = backgroundWorks.values.contains { work in
            work.waitingOn.contains { $0.handle == bot }
        }
        return Self.isWorking(
            sending: sending,
            backgroundEmpty: backgroundEmpty,
            waitingOnPerson: waitingOnPerson,
            awaitedByPeer: awaitedByPeer
        )
    }

    nonisolated static func isWorking(
        sending: Bool, backgroundEmpty: Bool,
        waitingOnPerson: Bool, awaitedByPeer: Bool
    ) -> Bool {
        if waitingOnPerson { return false }
        return sending || !backgroundEmpty || awaitedByPeer
    }

    func isWorking(_ bots: [String]) -> Bool {
        bots.contains { isBotWorking($0) }
    }

    /// Whether Hermes lets `sender` message `handle`, as the Alice plugin
    /// decides (`hermes-plugin/__init__.py`): the agent exists, and both are in
    /// Business or both are not. Alice's own chat is `nil` or `default`. An
    /// unknown roster decides nothing, so nothing is dropped before it loads.
    nonisolated static func canMessage(from sender: String?, to handle: String, roster: [BotRow]) -> Bool {
        guard !roster.isEmpty else { return true }
        let named = (AgentMessages.normalized(handle) ?? handle).lowercased()
        let target = named == "hermes" ? "default" : named
        let from = (sender?.isEmpty ?? true) ? "default" : sender!
        guard target == "default" || roster.contains(where: { $0.name == target }) else { return false }
        func inBusiness(_ name: String) -> Bool {
            guard let channel = roster.first(where: { $0.name == name })?.placement?.channel else { return false }
            return channel.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(Self.businessChannel) == .orderedSame
        }
        return inBusiness(from) == inBusiness(target)
    }

    nonisolated static let businessChannel = "Business (Beta)"
    /// Live Activity identity for Alice's own chat. Distinct from any bot profile.
    nonisolated static let homeActivityProfile = "default"

    /// Agent chats at work that the person set going (`AgentActivities`): a
    /// reply under way, or teammates' answers still to come. An agent another
    /// agent is waiting on is not the person's task, so it has no activity.
    ///
    /// Read by the app's root on every change to any conversation — each
    /// streamed token among them. Only a chat that is sending or has work
    /// recorded can be working, so those two cheap lookups come first: asking
    /// every chat for its pending questions scanned every message and every
    /// event, per chat, per token, and froze the phone while replies streamed.
    var agentWorks: [AgentActivities.Work] {
        conversations.compactMap { chat in
            guard sendingConversations.contains(chat.id) || backgroundWorks[chat.id] != nil
            else { return nil }
            if !pendingQuestions(in: chat.id).isEmpty { return nil }
            let work = backgroundWork(for: chat.id)
            guard sendingConversations.contains(chat.id) || !work.isEmpty else { return nil }
            if chat.isCanonicalBotChat, let bot = chat.routedBotName {
                return AgentActivities.Work(
                    conversationID: chat.id,
                    profile: bot, name: botCurrentName(for: bot), mark: mark(for: bot),
                    waitingOn: work.waitingOn.map { botCurrentName(for: $0.handle) },
                    headline: Self.activityHeadline(for: chat)
                )
            }
            guard chat.isHomeSessionChat || (!chat.isBotChat && chat.legacyBotName == nil) else { return nil }
            return AgentActivities.Work(
                conversationID: chat.id,
                profile: Self.homeActivityProfile,
                name: "Alice",
                mark: mark(for: "alice"),
                waitingOn: work.waitingOn.map { botCurrentName(for: $0.handle) },
                headline: Self.activityHeadline(for: chat)
            )
        }
    }

    /// How an agent's task ended, from its last reply.
    func agentEnding(_ conversationID: String) -> AgentActivities.Ending {
        let chat = conversations.first(where: { $0.id == conversationID })
            ?? (conversationID == Self.homeActivityProfile
                ? conversations.first(where: { $0.isHomeSessionChat || (!$0.isBotChat && $0.legacyBotName == nil) })
                : conversations.first(where: { $0.isCanonicalBotChat && $0.routedBotName == conversationID }))
        guard let chat, let reply = chat.messages.last(where: { $0.role == .assistant })
        else { return .finished }
        if reply.error != nil { return .failed }
        if reply.incomplete == true { return .stopped }
        return .finished
    }

    /// Same words the chat row shows while this reply is under way.
    nonisolated static func activityHeadline(for chat: Conversation, now: Date = Date()) -> String {
        let reply = chat.messages.last(where: { $0.role == .assistant })
        // With a plan, how far along it is: "Step 3 of 5". Never the step's
        // own words — the Lock Screen is not the place for them.
        if let plan = chat.messages.last(where: { $0.role == .assistant && $0.plan != nil })?.plan,
           plan.total > 1, !plan.isFinished {
            return String(localized: "Step \(min(plan.done + 1, plan.total)) of \(plan.total)")
        }
        return ToolCaption.headline(
            pending: true,
            note: reply?.deliveryNote,
            thoughtSeconds: reply?.thoughtSeconds,
            steps: reply?.tools ?? [],
            elapsed: reply.map { now.timeIntervalSince($0.createdAt) },
            seed: ToolCaption.seed(reply?.id ?? chat.id),
            status: reply?.lastStatus
        )
    }

    @discardableResult
    func createChannel(name: String, bots: [String]) -> BotChannel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let channel = BotChannel(name: trimmed, bots: bots)
        botChannels.append(channel)
        return channel
    }

    func renameChannel(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        changeChannel(id) { $0.name = trimmed }
    }

    func setChannelBots(_ id: String, bots: [String]) {
        changeChannel(id) { $0.setBots(bots) }
    }

    func addBot(_ bot: String, toChannel id: String) {
        changeChannel(id) { $0.add(bot) }
    }

    func removeBot(_ bot: String, fromChannel id: String) {
        changeChannel(id) { $0.remove(bot) }
    }

    func toggleChannelCollapsed(_ id: String) {
        changeChannel(id) { $0.collapsed.toggle() }
    }

    func addChannelSection(_ id: String, name: String, bot: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        changeChannel(id) { channel in
            channel.addSection(trimmed)
            if let bot { channel.setSection(trimmed, for: bot) }
        }
    }

    func renameChannelSection(_ id: String, from old: String, to new: String) {
        changeChannel(id) { $0.renameSection(from: old, to: new) }
    }

    func setChannelSection(_ id: String, bot: String, section: String?) {
        changeChannel(id) { $0.setSection(section, for: bot) }
    }

    func deleteChannelSection(_ id: String, name: String) {
        changeChannel(id) { $0.deleteSection(name) }
    }

    func toggleChannelSectionCollapsed(_ id: String, section: String) {
        changeChannel(id) { $0.toggleSection(section) }
    }

    func moveChannelSection(_ id: String, section: String, to target: String) {
        changeChannel(id) { $0.moveSection(section, to: target) }
    }

    func moveChannel(_ id: String, to target: String) {
        let moved = BotChannel.moving(botChannels, id, to: target)
        if moved != botChannels { botChannels = moved }
    }

    /// The channel goes, and its teams' chats with it. Its bots are untouched:
    /// those in no other channel are back in the general list.
    func deleteChannel(_ id: String) {
        for team in teams(in: id) { delete(team.id) }
        botChannels.removeAll { $0.id == id }
    }

    /// A channel's teams: shared chats with several of its bots.
    func teams(in channelID: String) -> [Conversation] {
        conversations.filter { $0.isChannel == true && $0.teamChannelID == channelID }
    }

    /// A team always has a bot. Without one it would be a chat with nobody —
    /// or, worse, with Alice — and a channel is neither.
    @discardableResult
    func createTeam(inChannel id: String, name: String, bots: [String]) -> Conversation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bots.isEmpty, botChannels.contains(where: { $0.id == id })
        else { return nil }
        let now = Date()
        let team = Conversation(
            id: UUID().uuidString, title: trimmed, createdAt: now, updatedAt: now,
            isChannel: true, channelBots: bots, teamChannelID: id
        )
        conversations.insert(team, at: 0)
        persistConversations()
        return team
    }

    private func changeChannel(_ id: String, _ change: (inout BotChannel) -> Void) {
        guard let index = botChannels.firstIndex(where: { $0.id == id }) else { return }
        var channel = botChannels[index]
        change(&channel)
        if channel != botChannels[index] { botChannels[index] = channel }
    }

    /// Channels an earlier build saved as conversations become folders
    /// (`BotChannel.migratingLegacyChannels`). Never over an archive this
    /// build could not read.
    private func migrateLegacyChannels() {
        guard conversationsUnreadable == nil else { return }
        let migrated = BotChannel.migratingLegacyChannels(conversations, into: botChannels)
        guard migrated.channels != botChannels else { return }
        conversations = migrated.conversations.isEmpty ? [.blank()] : migrated.conversations
        botChannels = migrated.channels
        persistConversations()
    }

    /// How each bot's mark looks. Hermes stores no such thing, so it lives on
    /// the phone: losing it costs a colour, not a bot.
    var botMarks: [String: BotMark] {
        didSet {
            if let data = try? JSONEncoder().encode(botMarks) {
                defaults.set(data, forKey: Keys.marks)
            }
        }
    }

    func mark(for name: String) -> BotMark {
        (botMarks[name] ?? BotMark.derived(from: name)).fillingPortrait(from: name)
    }
    func soul(_ name: String) async throws -> (text: String, exists: Bool) {
        try await dashboard.soul(name)
    }
    func setSoul(_ name: String, _ text: String) async throws {
        // A manual edit becomes user-owned before its content changes. Clearing
        // the marker first is intentionally fail-closed: if Hermes cannot save
        // the metadata, Alice must not leave a custom SOUL marked as safe for a
        // future automatic template migration.
        if botMetadataIsRemote {
            try await mutateBotMetadata(name) { meta in
                var meta = meta
                meta.removeValue(forKey: "managedTemplateId")
                meta.removeValue(forKey: "managedTemplateVersion")
                return meta
            }
        }
        try await dashboard.setSoul(name, text)
    }

    /// Writes an Alice-managed SOUL and records the template version in the
    /// profile's cross-device metadata. If the metadata write loses its race,
    /// the exact SOUL remains detectable and a retry can safely finish marking
    /// it; no user-authored text is inferred from a phrase match.
    func setManagedSoul(
        _ name: String, _ text: String, templateID: String, version: Int
    ) async throws {
        try await dashboard.setSoul(name, text)
        guard botMetadataIsRemote else { return }
        try await markManagedTemplate(name, id: templateID, version: version)
    }

    func markManagedTemplate(_ name: String, id: String, version: Int) async throws {
        guard botMetadataIsRemote else { return }
        try await mutateBotMetadata(name) { meta in
            var meta = meta
            meta["managedTemplateId"] = id
            meta["managedTemplateVersion"] = version
            return meta
        }
    }
    func setBotDescription(_ name: String, _ text: String) async throws {
        // The agent first: a swallowed failure left the row showing a
        // description the profile does not have.
        try await dashboard.setDescription(name, text)
        if let index = cachedBots.firstIndex(where: { $0.name == name }) {
            cachedBots[index].detail = text
        }
    }
    /// Kept for compatibility with code paths that already have a canonical
    /// profile id (duplicate/import). New UI creation should use the
    /// display-name overload below so a human name and the profile slug do not
    /// become the same concept again.
    func createBot(name: String, description: String) async throws {
        if let rpc = await dashboardRPC() {
            _ = try await rpc.call(
                "profiles.create",
                JSONObject([
                    "name": name,
                    "description": description,
                    "share_auth": true,
                    "mirror_credentials": true,
                ])
            )
        } else {
            try await dashboard.createBot(name: name, description: description)
        }
    }

    /// Create a Hermes agent through the shared engine. The visible name and
    /// the profile id correspond; a taken name fails instead of minting `-2`.
    @discardableResult
    func createBot(
        displayName: String,
        description: String,
        model: HermesClient.ModelOption? = nil,
        fallback: HermesClient.ModelOption? = nil,
        soul: String? = nil,
        reuseProfile: String? = nil
    ) async throws -> String {
        let spec = try AgentSpec.form(
            title: displayName,
            description: description,
            soul: soul,
            model: model,
            fallback: fallback,
            reuseProfile: reuseProfile
        )
        let blocked = Set(takenBotSlugs().map { $0.lowercased() })
        if blocked.contains(spec.profileID), reuseProfile != spec.profileID {
            if retiredBotSlugs.contains(where: { $0.caseInsensitiveCompare(spec.profileID) == .orderedSame }) {
                throw AgentOperationError.retired(
                    "`\(spec.profileID)` belonged to an agent this phone deleted. Choose another name."
                )
            }
            throw AgentOperationError.occupied(
                "`\(spec.profileID)` already exists. The original agent was left unchanged."
            )
        }

        do {
            let result = try await dashboard.createAgent(spec)
            if result.didCreateProfile, let slug = result.profileID, !slug.isEmpty {
                if let index = cachedBots.firstIndex(where: { $0.name == slug }) {
                    cachedBots[index].displayName = spec.title
                } else {
                    cachedBots.append(
                        BotRow(
                            name: slug, displayName: spec.title, detail: spec.description,
                            model: spec.model, provider: spec.provider,
                            skills: 0, isDefault: false, gatewayRunning: false, active: true
                        )
                    )
                }
                if let fallback = spec.fallback {
                    cachedBotFallbacks[slug] = fallback
                }
            }
            return try result.requireReady()
        } catch let failure as DashboardClient.Failure {
            switch failure {
            case .http(404, _), .http(405, _), .notConfigured:
                break
            default:
                throw failure
            }
        }

        if let rpc = await dashboardRPC() {
            var payload: [String: Any] = [
                "name": spec.profileID,
                "description": spec.description,
                "share_auth": true,
                "mirror_credentials": true,
            ]
            if let model = spec.model, let provider = spec.provider {
                payload["model"] = model
                payload["provider"] = provider
            }
            _ = try await rpc.call("profiles.create", JSONObject(payload))
            try await mutateBotMetadata(spec.profileID) { meta in
                var meta = meta
                meta["title"] = spec.title
                meta["created"] = Date().timeIntervalSince1970 * 1000
                return meta
            }
        } else {
            try await dashboard.createBot(name: spec.profileID, description: spec.description)
            if let model = spec.model, let provider = spec.provider {
                try await dashboard.setModel(spec.profileID, provider: provider, model: model)
            }
            botCustomNames[spec.profileID] = spec.title
        }
        if let fallback = spec.fallback {
            try await dashboard.setFallbackProviders(fallback, profile: spec.profileID)
            cachedBotFallbacks[spec.profileID] = fallback
        }
        if let soul = spec.soul, !soul.isEmpty {
            try await setSoul(spec.profileID, soul)
        }
        return spec.profileID
    }

    nonisolated static func botSlug(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9_-]+", with: "-", options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(64)
            .description
    }

    /// A new agent keeps the person's title, but never the profile id of one
    /// that already exists or that this phone has deleted.
    nonisolated static func uniqueBotSlug(_ value: String, taken: Set<String>) -> String {
        let base = botSlug(value)
        guard !base.isEmpty else { return base }
        let blocked = Set(taken.map { $0.lowercased() })
        if !blocked.contains(base) { return base }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(base.prefix(max(1, 64 - suffix.count))) + suffix
            if !blocked.contains(candidate) { return candidate }
            n += 1
        }
    }

    private func takenBotSlugs() -> Set<String> {
        var taken = retiredBotSlugs
        taken.formUnion(cachedBots.map(\.name))
        taken.formUnion(conversations.compactMap(\.botName))
        return taken
    }

    /// Duplicate the actual Hermes profile, not Alice's cached idea of it.
    /// Model, skills, SOUL and config therefore come across together. Bot Mode
    /// presentation metadata is copied separately with a fresh creation time.
    func duplicateBot(_ bot: BotRow, as newName: String) async throws {
        if let rpc = await dashboardRPC() {
            _ = try await rpc.call(
                "profiles.create",
                JSONObject([
                    "name": newName,
                    "clone_from": bot.name,
                    "description": bot.detail,
                    "share_auth": true,
                ])
            )

            let roster = try await rpc.call(
                "profiles.list", JSONObject(["include_sessions": false])
            )
            let source = (roster["profiles"] as? [[String: Any]])?
                .first(where: { ($0["name"] as? String) == bot.name })
            var meta = ((source?["ui_meta"] as? [String: Any])?["hermes-bots"]
                        as? [String: Any]) ?? [:]
            meta.removeValue(forKey: "created")
            meta.removeValue(forKey: "groups")
            meta.removeValue(forKey: "group")
            meta["created"] = Date().timeIntervalSince1970 * 1000
            let baseTitle = bot.displayName.isEmpty ? bot.name : bot.displayName
            meta["title"] = "\(baseTitle) (copy)"
            try await mutateBotMetadata(newName) { _ in meta }
        } else {
            // Older dashboard fallback: it cannot clone through Bot Mode RPC,
            // but the profile itself is still real. Copy the user-editable
            // pieces Alice can address through REST.
            try await dashboard.createBot(name: newName, description: bot.detail)
            if let option = botModelOption(for: bot), let provider = option.provider {
                try await dashboard.setModel(newName, provider: provider, model: option.id)
            }
            let chain = try await dashboard.fallbackProviders(profile: bot.name)
            try await dashboard.setFallbackProviders(chain, profile: newName)
            cachedBotFallbacks[newName] = chain
            let originalSoul = try await soul(bot.name).text
            if !originalSoul.isEmpty { try await setSoul(newName, originalSoul) }
            botCustomNames[newName] = "\(baseTitle(for: bot)) (copy)"
        }
    }

    private func baseTitle(for bot: BotRow) -> String {
        bot.displayName.isEmpty ? bot.name : bot.displayName
    }

    func deleteBot(_ name: String) async throws {
        let snapshot = cachedBots
        let order = botOrder
        let chats = conversations
        let active = activeID
        let retired = retiredBotSlugs
        forgetBotOnScreen(name)
        do {
            try await dashboard.deleteBot(name)
        } catch {
            cachedBots = snapshot
            botOrder = order
            conversations = chats
            activeID = active
            retiredBotSlugs = retired
            persistConversations()
            throw error
        }
        forgetBotLocalData(name)
        forgetBotActivity(name)
    }

    /// A deleted agent's Activity goes with it: its reports, questions and
    /// alerts point at an agent that no longer exists.
    private func forgetBotActivity(_ name: String) {
        func belongs(_ event: AliceEvent) -> Bool {
            [event.profile, event.reference.profile].contains {
                $0?.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        guard activity.contains(where: belongs) else { return }
        activity.removeAll(where: belongs)
        persistActivity()
        refreshAttention()
    }

    /// Drops the row and its local chat immediately so Delete does not wait
    /// on Hermes, and so a later agent cannot reopen that transcript.
    private func forgetBotOnScreen(_ name: String) {
        retiredBotSlugs.insert(name)
        cachedBots.removeAll { $0.name == name }
        botOrder.removeAll { $0 == name || $0 == name.lowercased() }
        let open = conversations.first { $0.id == activeID }?.botName == name
        conversations.removeAll {
            $0.botName?.caseInsensitiveCompare(name) == .orderedSame
        }
        persistConversations()
        if open { goHome() }
    }

    private func forgetBotLocalData(_ name: String) {
        forgetCanonicalBotChat(name)
        pendingBotModelSyncs.removeValue(forKey: name)
        botModelSyncTasks[name]?.cancel()
        botModelSyncTasks.removeValue(forKey: name)
        botModelSyncWarnings.removeValue(forKey: name)
        botMarks.removeValue(forKey: name)
        botSections.removeValue(forKey: name)
        botSections.removeValue(forKey: name.lowercased())
        botModels.removeValue(forKey: name)
        botModels.removeValue(forKey: name.lowercased())
        recentBotModels.removeValue(forKey: name)
        cachedBotFallbacks.removeValue(forKey: name)
        botNotifications.removeValue(forKey: name)
        botCustomNames.removeValue(forKey: name)
        hiddenBots.remove(name)
        for index in botChannels.indices { botChannels[index].remove(name) }
        let open = conversations.first { $0.id == activeID }?.botName == name
        conversations.removeAll {
            $0.botName?.caseInsensitiveCompare(name) == .orderedSame
        }
        persistConversations()
        if open { goHome() }
    }

    /// Profiles are the ownership boundary for Projects and Memory. Alice/Home
    /// is the default profile; every named profile is one of its bots.
    func hermesProfiles() async throws -> [(id: String, label: String)] {
        let bots = try await bots()
        return [("default", "Alice")]
            + bots.map { ($0.name, botCurrentName(for: $0)) }
    }

    /// The authoritative project tree for one profile. This is Hermes' own cwd
    /// grouping, including inferred workspaces and the synthetic Home bucket.
    func projects(profile: String = "default") async throws -> [ProjectRow] {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        let result = try await rpc.call(
            "projects.tree",
            JSONObject(["profile": profile, "preview_limit": 3, "session_limit": 2000])
        )
        return try DashboardClient.projectRows(from: result.fields, profile: profile)
    }

    /// First-class projects from this profile's projects.db. Archived projects
    /// stay in the response so the UI can restore them instead of losing them.
    func projectListing(
        profile: String = "default"
    ) async throws -> (projects: [NamedProject], activeID: String?) {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        let result = try await rpc.call(
            "projects.list", JSONObject(["profile": profile])
        )
        return (
            try DashboardClient.namedProjects(from: result.fields),
            result["active_id"] as? String
        )
    }

    func namedProjects(profile: String = "default") async throws -> [NamedProject] {
        try await projectListing(profile: profile).projects
    }

    func createProject(
        profile: String = "default", name: String, folder: String? = nil,
        description: String? = nil, colour: String? = nil
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        var params: [String: Any] = ["profile": profile, "name": name]
        if let folder = Self.nonEmptyPath(folder) {
            params["folders"] = [folder]
            params["primary_path"] = folder
        }
        if let description { params["description"] = description }
        if let colour { params["color"] = colour }
        _ = try await rpc.call("projects.create", JSONObject(params))
    }

    func updateProject(
        _ id: String, profile: String = "default", name: String? = nil,
        description: String? = nil, colour: String? = nil
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        var params: [String: Any] = ["profile": profile, "id": id]
        if let name { params["name"] = name }
        if let description { params["description"] = description }
        if let colour { params["color"] = colour }
        _ = try await rpc.call("projects.update", JSONObject(params))
    }

    func renameProject(
        _ id: String, to name: String, colour: String?, profile: String = "default"
    ) async throws {
        try await updateProject(id, profile: profile, name: name, colour: colour)
    }

    func addProjectFolder(
        _ id: String, path: String, profile: String = "default", primary: Bool = false
    ) async throws {
        guard let path = Self.nonEmptyPath(path) else {
            throw HermesRPCClient.Failure(reason: "Enter a workspace folder path.")
        }
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "projects.add_folder",
            JSONObject([
                "profile": profile, "id": id, "path": path, "is_primary": primary,
            ])
        )
    }

    func removeProjectFolder(
        _ id: String, path: String, profile: String = "default"
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "projects.remove_folder",
            JSONObject(["profile": profile, "id": id, "path": path])
        )
    }

    func setProjectPrimaryFolder(
        _ id: String, path: String, profile: String = "default"
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "projects.set_primary",
            JSONObject(["profile": profile, "id": id, "path": path])
        )
    }

    func setProjectArchived(
        _ id: String, archived: Bool, profile: String = "default"
    ) async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "projects.archive",
            JSONObject(["profile": profile, "id": id, "restore": !archived])
        )
    }

    func setActiveProject(_ id: String?, profile: String = "default") async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        var params: [String: Any] = ["profile": profile]
        if let id { params["id"] = id }
        _ = try await rpc.call("projects.set_active", JSONObject(params))
    }

    func deleteProject(_ id: String, profile: String = "default") async throws {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "projects.delete", JSONObject(["profile": profile, "id": id])
        )
    }

    /// Promote an inferred workspace into a named first-class project without
    /// changing the sessions: Hermes will immediately group their existing cwd
    /// under the new folder.
    func promoteProject(
        _ row: ProjectRow, name: String? = nil, profile: String = "default"
    ) async throws {
        guard row.isAuto, let path = Self.nonEmptyPath(row.path) else {
            throw HermesRPCClient.Failure(reason: "This workspace cannot be promoted.")
        }
        try await createProject(
            profile: profile, name: name ?? row.label, folder: path
        )
    }

    private nonisolated static func nonEmptyPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    /// Move a persisted Hermes session into a Project by changing its real cwd
    /// to that project's primary workspace. This is the same operation the
    /// Hermes desktop uses; `Conversation.project` is only the last resolved
    /// display label after a successful server mutation.
    func moveConversation(_ conversationID: String, to project: NamedProject) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let cwd = Self.nonEmptyPath(project.primaryPath) else {
            throw HermesRPCClient.Failure(
                reason: "Add a workspace folder to this project before moving a chat into it."
            )
        }
        let conversation = conversations[index]
        let profile = conversation.routedBotName ?? "default"
        let sessionKey = conversation.hermesSessionID
            ?? (conversation.isBotChat ? nil : conversation.id)
        guard let sessionKey, !sessionKey.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "This chat does not have a Hermes session yet."
            )
        }
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        _ = try await rpc.call(
            "session.workspace.move",
            JSONObject([
                "profile": profile, "session_key": sessionKey, "cwd": cwd,
            ])
        )
        if let current = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[current].project = project.name
            persistConversations()
        }
    }

    /// Real curated MEMORY.md / USER.md for one profile. Third-party semantic
    /// providers remain provider configuration; Alice never pretends they all
    /// expose the same editable-entry API.
    func memorySnapshot(profile: String = "default") async throws -> MemorySnapshot {
        // The Alice plugin serves memory on any Hermes, so updates never touch
        // it. A Hermes without the plugin answers 404 and may still carry the
        // older in-core RPC this used before.
        do {
            return try await dashboard.aliceMemory(profile: profile)
        } catch DashboardClient.Failure.http(404, _) {}
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        let result = try await rpc.call(
            "memory.list", JSONObject(["profile": profile])
        )
        return try DashboardClient.memorySnapshot(from: result.fields, profile: profile)
    }

    func mutateMemory(
        profile: String = "default", target: String, action: String,
        content: String = "", oldText: String = ""
    ) async throws -> MemorySnapshot {
        do {
            return try await dashboard.mutateAliceMemory(
                profile: profile, target: target, action: action,
                content: content, oldText: oldText
            )
        } catch DashboardClient.Failure.http(404, _) {}
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        let result = try await rpc.call(
            "memory.mutate",
            JSONObject([
                "profile": profile, "target": target, "action": action,
                "content": content, "old_text": oldText,
            ])
        )
        return try DashboardClient.memorySnapshot(from: result.fields, profile: profile)
    }

    func skillContent(_ name: String, profile: String? = nil) async throws -> String {
        try await dashboard.skillContent(name, profile: profile)
    }
    func saveSkill(
        name: String, content: String, isNew: Bool, profile: String? = nil
    ) async throws {
        try await dashboard.saveSkill(
            name: name, content: content, isNew: isNew, profile: profile
        )
    }
    func memoryProviders() async throws -> [MemoryProvider] { try await dashboard.memory() }

    func memoryProviderStatus() async throws -> MemoryProviderStatusSnapshot {
        try await dashboard.memoryProviderStatus()
    }

    func memoryProviderConfiguration(
        _ name: String, profile: String = "default"
    ) async throws -> MemoryProviderConfiguration {
        try await dashboard.memoryProviderConfiguration(name, profile: profile)
    }

    func saveMemoryProviderConfiguration(
        _ name: String, profile: String = "default", surface: String, values: [String: String]
    ) async throws {
        try await dashboard.saveMemoryProviderConfiguration(
            name, profile: profile, surface: surface, values: values
        )
    }

    func activateMemoryProvider(_ name: String, profile: String = "default") async throws {
        try await dashboard.activateMemoryProvider(name, profile: profile)
    }

    func useBuiltinMemoryProvider(profile: String = "default") async throws {
        try await dashboard.useBuiltinMemoryProvider(profile: profile)
    }

    func setupMemoryProvider(_ name: String) async throws -> MemoryProviderSetupResponse {
        try await dashboard.setupMemoryProvider(name)
    }

    func memoryProviderOAuthStatus(
        _ name: String, profile: String = "default"
    ) async throws -> MemoryProviderOAuthStatus? {
        try await dashboard.memoryProviderOAuthStatus(name, profile: profile)
    }

    func startMemoryProviderOAuth(
        _ name: String, profile: String = "default"
    ) async throws -> MemoryProviderOAuthStatus {
        try await dashboard.startMemoryProviderOAuth(name, profile: profile)
    }

    // MARK: - Hermes managed files

    func hermesFiles(path: String? = nil) async throws -> ManagedFilesListing {
        try await dashboard.managedFiles(path: path)
    }

    // Agent work lives behind the same authenticated dashboard as the rest of
    // Alice's controls. Keep the screen independent of connection credentials.
    func sharedBrowser() async throws -> SharedBrowserState { try await dashboard.sharedBrowser() }
    func setSharedBrowser(on: Bool) async throws -> SharedBrowserState {
        try await dashboard.setSharedBrowser(on: on)
    }
    func sharedBrowserFrame(after: Int, target: String?) async throws -> SharedBrowserFrame {
        try await dashboard.sharedBrowserFrame(after: after, target: target)
    }
    func sharedBrowserInput(_ action: SharedBrowserAction, target: String?) async throws {
        try await dashboard.sharedBrowserInput(action, target: target)
    }
    func pageWatches() async throws -> (service: PageWatchService, watches: [PageWatch]) {
        try await dashboard.pageWatches()
    }
    func setUpPageWatches() async throws -> PageWatchService { try await dashboard.setUpPageWatches() }
    func createPageWatch(url: String, kind: PageWatch.Kind, label: String, below: Double?, text: String) async throws {
        try await dashboard.createPageWatch(url: url, kind: kind, label: label, below: below, text: text)
    }
    func deletePageWatch(_ id: String) async throws { try await dashboard.deletePageWatch(id) }
    func uploadAgentDocument(name: String, data: Data) async throws -> String {
        try await dashboard.uploadDocument(name: name, data: data)
    }

    func hermesFile(path: String) async throws -> ManagedFileContents {
        try await dashboard.managedFile(path: path)
    }

    func createHermesDirectory(path: String) async throws {
        _ = try await dashboard.createManagedDirectory(path: path)
    }

    func uploadHermesFile(
        path: String, data: Data, mimeType: String = "application/octet-stream"
    ) async throws {
        _ = try await dashboard.uploadManagedFile(path: path, data: data, mimeType: mimeType)
    }

    func uploadHermesFileStream(
        path: String, fileURL: URL, mimeType: String = "application/octet-stream",
        overwrite: Bool = true
    ) async throws {
        _ = try await dashboard.uploadManagedFileStream(
            path: path, fileURL: fileURL, mimeType: mimeType, overwrite: overwrite
        )
    }

    func downloadHermesFile(path: String) async throws -> HermesDownloadedFile {
        try await dashboard.downloadManagedFile(path: path)
    }

    /// Saves remote media (HTTP/HTTPS) into a temp file and hands it to the
    /// share sheet. Used by chat media cards: streaming plays straight from
    /// the source URL, saving is the only thing that needs bytes on disk.
    func downloadRemoteMedia(url: URL, name: String) async throws -> HermesDownloadedFile {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DashboardClient.Failure.unreadable
        }
        return try persistRemoteDownload(temporaryURL, name: name, response: http)
    }

    private func persistRemoteDownload(
        _ temporaryURL: URL, name: String, response: HTTPURLResponse
    ) throws -> HermesDownloadedFile {
        let sanitized = name.split(separator: "/").last.map(String.init) ?? "media"
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "alice-remote-downloads", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: sanitized.isEmpty ? "media" : sanitized)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first.map(String.init)
            ?? "application/octet-stream"
        return .init(url: destination, name: sanitized, mimeType: mime, size: bytes)
    }

    func deleteHermesFile(path: String, recursive: Bool = false) async throws {
        try await dashboard.deleteManagedFile(path: path, recursive: recursive)
    }

    // MARK: - Hermes remote filesystem

    func hermesFilesystemDirectory(path: String) async throws -> HermesFSDirectoryListing {
        try await dashboard.filesystemDirectory(path: path)
    }

    func hermesFilesystemText(path: String) async throws -> HermesFSTextSnapshot {
        try await dashboard.filesystemText(path: path)
    }

    func writeHermesFilesystemText(path: String, content: String) async throws -> HermesFSWriteResult {
        try await dashboard.writeFilesystemText(path: path, content: content)
    }

    func hermesFilesystemData(path: String) async throws -> HermesFSBinaryPreview {
        try await dashboard.filesystemData(path: path)
    }

    func downloadHermesFilesystemFile(path: String) async throws -> HermesDownloadedFile {
        try await dashboard.downloadFilesystemFile(path: path)
    }

    func hermesFilesystemGitRoot(path: String) async throws -> String? {
        try await dashboard.filesystemGitRoot(path: path)
    }

    func hermesFilesystemDefaultLocation() async throws -> HermesFSDefaultLocation {
        try await dashboard.filesystemDefaultLocation()
    }

    // MARK: - Hermes parity extras

    func terminalBackends(profile: String = "default") async throws -> HermesTerminalBackends { try await dashboard.terminalBackends(profile: profile) }
    func setTerminalBackend(_ backend: String, profile: String = "default") async throws { try await dashboard.setTerminalBackend(backend, profile: profile) }
    func learningGraph(profile: String = "default") async throws -> HermesLearningGraph { try await dashboard.learningGraph(profile: profile) }
    func learningNode(_ id: String, profile: String = "default") async throws -> HermesLearningNodeDetail { try await dashboard.learningNode(id, profile: profile) }
    func saveLearningNode(_ id: String, content: String, profile: String = "default") async throws { try await dashboard.saveLearningNode(id, content: content, profile: profile) }
    func deleteLearningNode(_ id: String, profile: String = "default") async throws { try await dashboard.deleteLearningNode(id, profile: profile) }

    func pairing(profile: String = "default") async throws -> PairingSnapshot { try await dashboard.pairing(profile: profile) }
    func approvePairing(platform: String, requestID: String? = nil, code: String? = nil, profile: String = "default") async throws { try await dashboard.approvePairing(platform: platform, requestID: requestID, code: code, profile: profile) }
    func revokePairing(platform: String, userID: String, profile: String = "default") async throws { try await dashboard.revokePairing(platform: platform, userID: userID, profile: profile) }
    func clearPendingPairing(profile: String = "default") async throws -> Int { try await dashboard.clearPendingPairing(profile: profile) }

    func pluginHub() async throws -> HermesPluginHub { try await dashboard.pluginHub() }
    func rescanPlugins() async throws -> Int { try await dashboard.rescanPlugins() }
    func installAgentPlugin(identifier: String, force: Bool = false, enable: Bool = true) async throws -> [String] { try await dashboard.installAgentPlugin(identifier: identifier, force: force, enable: enable) }
    func setAgentPlugin(_ name: String, enabled: Bool) async throws { try await dashboard.setAgentPlugin(name, enabled: enabled) }
    func updateAgentPlugin(_ name: String) async throws -> String? { try await dashboard.updateAgentPlugin(name) }
    func removeAgentPlugin(_ name: String) async throws { try await dashboard.removeAgentPlugin(name) }
    func setPluginHidden(_ name: String, hidden: Bool) async throws { try await dashboard.setPluginHidden(name, hidden: hidden) }
    func setContextEngine(_ name: String) async throws { try await dashboard.setContextEngine(name) }

    func credentialPool() async throws -> [CredentialPoolProvider] { try await dashboard.credentialPool() }
    func addCredentialPool(provider: String, apiKey: String, label: String?) async throws { try await dashboard.addCredentialPool(provider: provider, apiKey: apiKey, label: label) }
    func removeCredentialPool(provider: String, index: Int) async throws { try await dashboard.removeCredentialPool(provider: provider, index: index) }
    func hooks() async throws -> HermesHooksSnapshot { try await dashboard.hooks() }
    func createHook(event: String, command: String, matcher: String?, timeout: Int?, approve: Bool) async throws { try await dashboard.createHook(event: event, command: command, matcher: matcher, timeout: timeout, approve: approve) }
    func deleteHook(event: String, command: String) async throws { try await dashboard.deleteHook(event: event, command: command) }

    func curatorStatus() async throws -> HermesCuratorStatus { try await dashboard.curatorStatus() }
    func setCuratorPaused(_ paused: Bool) async throws { try await dashboard.setCuratorPaused(paused) }
    func runCurator() async throws -> HermesActionStart { try await dashboard.runCurator() }
    func portalStatus() async throws -> HermesPortalStatus { try await dashboard.portalStatus() }
    func computerUseStatus(profile: String = "default") async throws -> HermesComputerUseStatus { try await dashboard.computerUseStatus(profile: profile) }
    func grantComputerUsePermissions(profile: String = "default") async throws -> HermesActionStart { try await dashboard.grantComputerUsePermissions(profile: profile) }

    func cronBlueprints() async throws -> [CronBlueprint] { try await dashboard.cronBlueprints() }
    func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String = "default") async throws { try await dashboard.instantiateCronBlueprint(key, values: values, profile: profile) }

    func savedCustomEndpoints(profile: String = "default") async throws -> SavedCustomEndpointsSnapshot { try await dashboard.savedCustomEndpoints(profile: profile) }
    func saveCustomEndpoint(id: String, name: String, baseURL: String, model: String, apiKey: String?, contextLength: Int?, discoverModels: Bool, makeDefault: Bool, profile: String = "default") async throws -> SavedCustomEndpointsSnapshot { try await dashboard.saveCustomEndpoint(id: id, name: name, baseURL: baseURL, model: model, apiKey: apiKey, contextLength: contextLength, discoverModels: discoverModels, makeDefault: makeDefault, profile: profile) }
    func validateCustomEndpoint(name: String, baseURL: String, model: String, apiKey: String?, contextLength: Int?, discoverModels: Bool) async throws -> CustomEndpointValidation { try await dashboard.validateCustomEndpoint(name: name, baseURL: baseURL, model: model, apiKey: apiKey, contextLength: contextLength, discoverModels: discoverModels) }
    func activateCustomEndpoint(_ id: String, profile: String = "default") async throws { try await dashboard.activateCustomEndpoint(id, profile: profile) }
    func deleteCustomEndpoint(_ id: String, profile: String = "default") async throws { try await dashboard.deleteCustomEndpoint(id, profile: profile) }

    func importProfileArchive(path: String, name: String? = nil) async throws -> String { try await dashboard.importProfileArchive(path: path, name: name) }
    func profileSetupCommand(_ name: String) async throws -> String { try await dashboard.profileSetupCommand(name) }
    func describeProfileAutomatically(_ name: String, overwrite: Bool = true) async throws -> ProfileAutoDescription { try await dashboard.describeProfileAutomatically(name, overwrite: overwrite) }
    func runConfigMigration() async throws -> HermesActionStart { try await dashboard.runConfigMigration() }
    func debugShare(lines: Int = 500, redact: Bool = true) async throws -> HermesDebugShare { try await dashboard.debugShare(lines: lines, redact: redact) }
    func resetBuiltinMemory(target: String) async throws -> [String] { try await dashboard.resetBuiltinMemory(target: target) }

    // MARK: - MCP administration

    func mcpServers(profile: String = "default") async throws -> [MCPServerConfiguration] {
        try await dashboard.mcpServers(profile: profile)
    }

    func mcpCatalog(profile: String = "default") async throws -> MCPCatalogSnapshot {
        try await dashboard.mcpCatalog(profile: profile)
    }

    func addMCPServer(
        name: String, profile: String = "default", url: String? = nil,
        command: String? = nil, args: [String] = [], env: [String: String] = [:],
        auth: String? = nil, bearerToken: String? = nil
    ) async throws -> MCPServerConfiguration {
        try await dashboard.addMCPServer(
            name: name, profile: profile, url: url, command: command,
            args: args, env: env, auth: auth, bearerToken: bearerToken
        )
    }

    func setMCPServerEnabled(
        _ name: String, enabled: Bool, profile: String = "default"
    ) async throws {
        try await dashboard.setMCPServerEnabled(name, enabled: enabled, profile: profile)
    }

    func deleteMCPServer(_ name: String, profile: String = "default") async throws {
        try await dashboard.deleteMCPServer(name, profile: profile)
    }

    func testMCPServer(
        _ name: String, profile: String = "default"
    ) async throws -> MCPServerTestResult {
        try await dashboard.testMCPServer(name, profile: profile)
    }

    func startMCPOAuth(
        _ name: String, profile: String = "default"
    ) async throws -> MCPOAuthFlow {
        try await dashboard.startMCPOAuth(name, profile: profile)
    }

    func mcpOAuthStatus(
        _ flowID: String, profile: String = "default"
    ) async throws -> MCPOAuthFlow {
        try await dashboard.mcpOAuthStatus(flowID, profile: profile)
    }

    func cancelMCPOAuth(_ flowID: String, profile: String = "default") async throws {
        try await dashboard.cancelMCPOAuth(flowID, profile: profile)
    }

    func installMCPCatalogEntry(
        _ name: String, env: [String: String], profile: String = "default", enable: Bool = true
    ) async throws -> MCPCatalogInstallResult {
        try await dashboard.installMCPCatalogEntry(name, env: env, profile: profile, enable: enable)
    }

    // MARK: - Webhooks

    func webhooks() async throws -> WebhooksSnapshot {
        try await dashboard.webhooks()
    }

    func enableWebhooks() async throws -> WebhookEnableResult {
        try await dashboard.enableWebhooks()
    }

    func createWebhook(
        name: String,
        description: String = "",
        events: [String] = [],
        prompt: String = "",
        script: String = "",
        skills: [String] = [],
        deliver: String = "log",
        deliverOnly: Bool = false,
        deliverChatID: String = "",
        secret: String? = nil
    ) async throws -> WebhookCreation {
        try await dashboard.createWebhook(
            name: name,
            description: description,
            events: events,
            prompt: prompt,
            script: script,
            skills: skills,
            deliver: deliver,
            deliverOnly: deliverOnly,
            deliverChatID: deliverChatID,
            secret: secret
        )
    }

    func setWebhookEnabled(_ name: String, enabled: Bool) async throws {
        try await dashboard.setWebhookEnabled(name, enabled: enabled)
    }

    func deleteWebhook(_ name: String) async throws {
        try await dashboard.deleteWebhook(name)
    }

    // MARK: - System / health / operations

    func hermesHealth() async throws -> HermesHealthStatus {
        try await dashboard.health()
    }

    func hermesSystemStatus(profile: String? = "default") async throws -> HermesSystemStatus {
        try await dashboard.systemStatus(profile: profile)
    }

    func hermesSystemStats() async throws -> HermesSystemStats {
        try await dashboard.systemStats()
    }

    func hermesGatewayAction(
        _ verb: String, profile: String = "default"
    ) async throws -> HermesActionStart {
        try await dashboard.gatewayAction(verb, profile: profile)
    }

    func runHermesDoctor() async throws -> HermesActionStart { try await dashboard.runDoctor() }
    func runHermesSecurityAudit() async throws -> HermesActionStart { try await dashboard.runSecurityAudit() }
    func runHermesPromptSize() async throws -> HermesActionStart { try await dashboard.runPromptSize() }
    func runHermesDump() async throws -> HermesActionStart { try await dashboard.runDump() }
    func runHermesBackup() async throws -> HermesActionStart { try await dashboard.runBackup() }

    func restoreHermesBackup(path: String) async throws -> HermesActionStart {
        try await dashboard.restoreBackup(path: path)
    }

    func restoreHermesBackup(data: Data, filename: String) async throws -> HermesActionStart {
        try await dashboard.restoreBackup(data: data, filename: filename)
    }

    func downloadHermesBackup(_ archive: String) async throws -> Data {
        try await dashboard.downloadBackup(archive)
    }

    func hermesActionStatus(_ name: String, lines: Int = 400) async throws -> HermesActionStatus {
        try await dashboard.actionStatus(name, lines: lines)
    }

    func hermesLogs(file: String, lines: Int = 200, search: String = "") async throws -> HermesLogSnapshot {
        try await dashboard.logs(file: file, lines: lines, search: search)
    }

    func hermesCheckpoints() async throws -> HermesCheckpoints { try await dashboard.checkpoints() }
    func pruneHermesCheckpoints() async throws -> HermesActionStart { try await dashboard.pruneCheckpoints() }

    // MARK: - Messaging channels

    func messagingPlatforms(profile: String = "default") async throws -> MessagingPlatformsSnapshot {
        try await dashboard.messagingPlatforms(profile: profile)
    }

    func updateMessagingPlatform(
        _ id: String, profile: String = "default", enabled: Bool? = nil,
        env: [String: String] = [:], clearEnv: [String] = []
    ) async throws {
        try await dashboard.updateMessagingPlatform(
            id, profile: profile, enabled: enabled, env: env, clearEnv: clearEnv
        )
    }

    /// Switches a channel on or off so that it stays that way.
    ///
    /// Hermes reads whether a channel is on from two places, and for WhatsApp
    /// the `.env` flag wins over config.yaml (`gateway/config_env.py`,
    /// `_whatsapp`). The switch only wrote the config, so with
    /// `WHATSAPP_ENABLED=true` in `.env` the channel came straight back on and
    /// the toggle slid back as if nothing had happened. A set flag is cleared
    /// through Hermes' own API — it is one of the channel's configurable keys —
    /// leaving the config alone to decide, in either direction.
    func setMessagingPlatformEnabled(_ id: String, profile: String, enabled: Bool) async throws {
        // Read first, and fail if the read fails. With `try?` a slow or failed
        // read sent the switch without the flag: Hermes wrote only the config,
        // `.env` switched WhatsApp straight back on, and "Turn off WhatsApp"
        // reported success — every request in Hermes' log arrived with
        // `cleared_keys=[]`.
        let before = try await messagingPlatforms(profile: profile).platforms.first { $0.id == id }
        try await updateMessagingPlatform(
            id, profile: profile, enabled: enabled,
            clearEnv: before.map(Self.enablementFlags(in:)) ?? []
        )
        // And check it took. Hermes answers ok for a config write that its
        // environment then overrides, which must not read as done.
        if let after = try? await messagingPlatforms(profile: profile).platforms.first(where: { $0.id == id }),
           after.enabled != enabled {
            throw ChannelSwitchError.stillOverridden(name: after.name, on: after.enabled)
        }
    }

    enum ChannelSwitchError: LocalizedError {
        case stillOverridden(name: String, on: Bool)

        var errorDescription: String? {
            switch self {
            case let .stillOverridden(name, on):
                "Hermes still has \(name) switched \(on ? "on" : "off"). "
                    + "A setting in its .env file is overriding this switch."
            }
        }
    }

    /// The flag-style keys that decide a channel's state ahead of its config.
    nonisolated static func enablementFlags(in platform: MessagingPlatform) -> [String] {
        platform.envVars.filter { $0.isSet && $0.key.hasSuffix("_ENABLED") }.map(\.key)
    }

    func testMessagingPlatform(
        _ id: String, profile: String = "default"
    ) async throws -> MessagingPlatformTestResult {
        try await dashboard.testMessagingPlatform(id, profile: profile)
    }

    func startTelegramOnboarding(botName: String = "Hermes Agent") async throws -> TelegramOnboardingStart {
        try await dashboard.startTelegramOnboarding(botName: botName)
    }

    func telegramOnboardingStatus(_ pairingID: String) async throws -> TelegramOnboardingStatus {
        try await dashboard.telegramOnboardingStatus(pairingID)
    }

    func applyTelegramOnboarding(
        _ pairingID: String, allowedUserIDs: [String], profile: String = "default"
    ) async throws -> ChannelApplyResult {
        try await dashboard.applyTelegramOnboarding(
            pairingID, allowedUserIDs: allowedUserIDs, profile: profile
        )
    }

    func cancelTelegramOnboarding(_ pairingID: String) async throws {
        try await dashboard.cancelTelegramOnboarding(pairingID)
    }

    func startWhatsAppOnboarding(
        mode: String, allowedUsers: String, profile: String = "default"
    ) async throws -> WhatsAppOnboardingSession {
        try await dashboard.startWhatsAppOnboarding(
            mode: mode, allowedUsers: allowedUsers, profile: profile
        )
    }

    func whatsAppOnboardingStatus(_ pairingID: String) async throws -> WhatsAppOnboardingSession {
        try await dashboard.whatsAppOnboardingStatus(pairingID)
    }

    func applyWhatsAppOnboarding(
        _ pairingID: String, mode: String, allowedUsers: String, profile: String = "default"
    ) async throws -> ChannelApplyResult {
        try await dashboard.applyWhatsAppOnboarding(
            pairingID, mode: mode, allowedUsers: allowedUsers, profile: profile
        )
    }

    func cancelWhatsAppOnboarding(_ pairingID: String) async throws {
        try await dashboard.cancelWhatsAppOnboarding(pairingID)
    }

    func restartHermesGateway(profile: String = "default") async throws -> GatewayActionResult {
        try await dashboard.restartGateway(profile: profile)
    }

    // MARK: - Models, providers, usage & configuration

    func profileModelInfo(profile: String = "default") async throws -> ProfileModelInfo {
        try await dashboard.profileModelInfo(profile: profile)
    }

    func inferenceProviders(
        profile: String = "default", refreshing: Bool = false
    ) async throws -> [InferenceProvider] {
        try await dashboard.inferenceProviders(profile: profile, refreshing: refreshing)
    }

    func oauthProviderStates(profile: String = "default") async throws -> [OAuthProviderState] {
        try await dashboard.oauthProviderStates(profile: profile)
    }

    func providerCredentials(profile: String = "default") async throws -> [ProviderCredential] {
        try await dashboard.providerCredentials(profile: profile)
    }

    func setProfileDefaultModel(
        profile: String = "default", provider: String, model: String,
        baseURL: String = "", apiKey: String = "", confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        try await dashboard.setMainModel(
            profile: profile, provider: provider, model: model,
            baseURL: baseURL, apiKey: apiKey, confirmExpensive: confirmExpensive
        )
    }

    func auxiliaryModels(profile: String = "default") async throws -> AuxiliaryModelsSnapshot {
        try await dashboard.auxiliaryModels(profile: profile)
    }

    func setAuxiliaryModel(
        profile: String = "default", task: String, provider: String, model: String,
        baseURL: String = "", apiKey: String = "", confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        try await dashboard.setAuxiliaryModel(
            profile: profile, task: task, provider: provider, model: model,
            baseURL: baseURL, apiKey: apiKey, confirmExpensive: confirmExpensive
        )
    }

    func resetAuxiliaryModels(profile: String = "default") async throws -> ModelAssignmentResult {
        try await dashboard.resetAuxiliaryModels(profile: profile)
    }

    func recommendedModelDefault(provider: String) async throws -> RecommendedModelDefault {
        try await dashboard.recommendedModelDefault(provider: provider)
    }

    func moaConfiguration(profile: String = "default") async throws -> MoAConfiguration {
        try await dashboard.moaConfiguration(profile: profile)
    }

    func saveMoAConfiguration(
        _ configuration: MoAConfiguration, profile: String = "default"
    ) async throws -> MoAConfiguration {
        try await dashboard.saveMoAConfiguration(configuration, profile: profile)
    }

    // MARK: - Local models

    func localModelsStatus() async throws -> LocalModelsStatus {
        try await dashboard.localModelsStatus()
    }

    func localModelHardware() async throws -> LocalModelHardware {
        try await dashboard.localModelHardware()
    }

    func localModelCatalog() async throws -> [LocalModelCatalogItem] {
        try await dashboard.localModelCatalog()
    }

    func localModelJobs() async throws -> [LocalModelJob] {
        try await dashboard.localModelJobs()
    }

    func localModelJob(_ id: String) async throws -> LocalModelJob {
        try await dashboard.localModelJob(id)
    }

    func installLocalRuntime(backend: String? = nil) async throws -> LocalRuntimeInstallStart {
        try await dashboard.installLocalRuntime(backend: backend)
    }

    func quickstartLocalModel(_ modelID: String? = nil) async throws -> LocalModelQuickstartStart {
        try await dashboard.quickstartLocalModel(modelID)
    }

    func downloadLocalModel(_ modelID: String) async throws -> LocalModelDownloadStart {
        try await dashboard.downloadLocalModel(modelID)
    }

    func deleteLocalModel(_ modelID: String) async throws {
        try await dashboard.deleteLocalModel(modelID)
    }

    func setLocalModelServer(_ action: String) async throws {
        try await dashboard.setLocalServer(action)
    }

    func ejectLocalModel(_ modelID: String) async throws {
        try await dashboard.ejectLocalModel(modelID)
    }

    func activateLocalModel(_ modelID: String) async throws -> LocalModelJob {
        try await dashboard.activateLocalModel(modelID)
    }

    func searchLocalModels(_ query: String, limit: Int = 20) async throws -> [LocalModelHFHit] {
        try await dashboard.searchLocalModels(query, limit: limit)
    }

    func localModelRepoFiles(_ repo: String) async throws -> [LocalModelHFFileGroup] {
        try await dashboard.localModelRepoFiles(repo)
    }

    func downloadBrowsedLocalModel(repo: String, paths: [String]) async throws -> LocalModelDownloadStart {
        try await dashboard.downloadBrowsedLocalModel(repo: repo, paths: paths)
    }

    func sideloadLocalModel(path: String) async throws -> LocalModelSideloadResult {
        try await dashboard.sideloadLocalModel(path: path)
    }

    // MARK: - Git / remote development

    func gitRepoStatus(path: String) async throws -> GitRepoStatus? {
        try await dashboard.gitRepoStatus(path: path)
    }

    func gitHubAuthStatus(refresh: Bool = false) async throws -> GitHubAuthStatus {
        try await dashboard.gitHubAuthStatus(refresh: refresh)
    }

    func gitWorktrees(path: String) async throws -> [GitWorktree] {
        try await dashboard.gitWorktrees(path: path)
    }

    func gitBranches(path: String) async throws -> [GitBranch] {
        try await dashboard.gitBranches(path: path)
    }

    func gitBaseBranches(path: String) async throws -> [GitBaseBranch] {
        try await dashboard.gitBaseBranches(path: path)
    }

    func gitReviewList(path: String, scope: String, base: String? = nil) async throws -> GitReviewListing {
        try await dashboard.gitReviewList(path: path, scope: scope, base: base)
    }

    func gitReviewDiff(
        path: String, file: String, scope: String, base: String? = nil, staged: Bool = false
    ) async throws -> String {
        try await dashboard.gitReviewDiff(path: path, file: file, scope: scope, base: base, staged: staged)
    }

    func gitFileDiff(path: String, file: String) async throws -> String {
        try await dashboard.gitFileDiff(path: path, file: file)
    }

    func gitCommitContext(path: String) async throws -> GitCommitContext {
        try await dashboard.gitCommitContext(path: path)
    }

    func gitRevParse(path: String, ref: String? = nil) async throws -> String? {
        try await dashboard.gitRevParse(path: path, ref: ref)
    }

    func gitShipInfo(path: String) async throws -> GitShipInfo {
        try await dashboard.gitShipInfo(path: path)
    }

    func gitPullRequests(path: String, branches: [String], numbers: [Int] = []) async throws -> GitPullRequests {
        try await dashboard.gitPullRequests(path: path, branches: branches, numbers: numbers)
    }

    func gitStage(path: String, file: String? = nil) async throws {
        try await dashboard.gitStage(path: path, file: file)
    }

    func gitUnstage(path: String, file: String? = nil) async throws {
        try await dashboard.gitUnstage(path: path, file: file)
    }

    func gitRevert(path: String, file: String? = nil) async throws {
        try await dashboard.gitRevert(path: path, file: file)
    }

    func gitCommit(path: String, message: String, push: Bool) async throws {
        try await dashboard.gitCommit(path: path, message: message, push: push)
    }

    func gitPush(path: String) async throws {
        try await dashboard.gitPush(path: path)
    }

    func gitCreatePullRequest(path: String) async throws -> String {
        try await dashboard.gitCreatePullRequest(path: path)
    }

    func gitAddWorktree(
        path: String, name: String? = nil, branch: String? = nil,
        base: String? = nil, existingBranch: String? = nil
    ) async throws -> GitWorktreeCreation {
        try await dashboard.gitAddWorktree(
            path: path, name: name, branch: branch, base: base, existingBranch: existingBranch
        )
    }

    func gitRemoveWorktree(path: String, worktreePath: String, force: Bool) async throws -> String {
        try await dashboard.gitRemoveWorktree(path: path, worktreePath: worktreePath, force: force)
    }

    func gitSwitchBranch(path: String, branch: String) async throws -> String {
        try await dashboard.gitSwitchBranch(path: path, branch: branch)
    }

    func validateProviderCredential(key: String, value: String) async throws -> CredentialValidation {
        try await dashboard.validateProviderCredential(key: key, value: value)
    }

    func saveProviderCredential(profile: String, key: String, value: String) async throws {
        try await dashboard.saveProviderCredential(profile: profile, key: key, value: value)
    }

    func removeProviderCredential(profile: String, key: String) async throws {
        try await dashboard.removeProviderCredential(profile: profile, key: key)
    }

    func startOAuthLogin(provider: String, profile: String) async throws -> OAuthLogin {
        try await dashboard.startOAuthLogin(provider: provider, profile: profile)
    }

    func pollOAuth(provider: String, sessionID: String, profile: String) async throws -> OAuthPoll {
        try await dashboard.pollOAuth(provider: provider, sessionID: sessionID, profile: profile)
    }

    func cancelOAuth(sessionID: String, profile: String) async throws {
        try await dashboard.cancelOAuth(sessionID: sessionID, profile: profile)
    }

    func disconnectOAuth(provider: String, profile: String) async throws {
        try await dashboard.disconnectOAuth(provider: provider, profile: profile)
    }

    func hermesConfiguration(profile: String = "default") async throws -> HermesConfiguration {
        try await dashboard.hermesConfiguration(profile: profile)
    }

    func saveHermesConfiguration(
        _ configuration: HermesConfiguration, profile: String = "default"
    ) async throws {
        try await dashboard.saveHermesConfiguration(configuration, profile: profile)
    }

    func usage(profile: String = "default", days: Int = 30) async throws -> UsageReport {
        try await dashboard.usage(profile: profile, days: days)
    }

    func billingUsage() async throws -> BillingUsage {
        guard let rpc = await dashboardRPC() else {
            throw HermesRPCClient.Failure(reason: "The Hermes dashboard is not connected.")
        }
        let result = try await rpc.call("usage.bars", JSONObject([:]))
        return DashboardClient.billingUsage(from: result.fields)
    }

    func supports(_ capability: String) -> Bool {
        manifest?.supports(capability) ?? false
    }

    // MARK: - Conversations

    /// Recovered threads filed under one bot, newest first.
    ///
    /// They have no routing identity, so `openBotConversation` — which looks a
    /// bot up by the profile it sends to — will never find them. Without a
    /// list like this they are filed correctly and reachable from nowhere.
    func recoveredHistory(for profile: String) -> [Conversation] {
        conversations
            .filter { $0.isRecoveredHistory && $0.legacyBotName == profile }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Opens a conversation that already exists, by id.
    func openConversation(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].openedAt = Date()
        activeID = id
        persistConversations()
    }

    /// The bot conversation most recently opened, if there is one.
    /// Deliberately the live one: coming back to "the bot you were talking
    /// to" means the chat you can talk in, never a recovered transcript.
    var lastBotConversation: Conversation? {
        conversations
            .filter { $0.isCanonicalBotChat || $0.isChannel == true }
            .max { ($0.openedAt ?? $0.updatedAt) < ($1.openedAt ?? $1.updatedAt) }
    }

    /// Back to Alice's own conversation.
    ///
    /// Leaving a bot behind means leaving its conversation too: backing out
    /// of the bots page onto the bot you had just been talking to is not
    /// backing out of anything.
    func goHome() {
        if let home = conversations.first(where: { !$0.isBotChat }) {
            activeID = home.id
        } else {
            newChat()
        }
    }

    func hasHomeShortcut(matching target: HomeShortcut.Target) -> Bool {
        homeShortcuts.contains { $0.target == target }
    }

    /// The pin's current name. Saved labels are a fallback for something gone.
    func homeShortcutLabel(_ shortcut: HomeShortcut) -> String {
        switch shortcut.target {
        case let .note(id):
            return shortcut.displayedLabel(note: notesSnapshot?.notes.first { $0.id == id })
        case let .noteFolder(id):
            return shortcut.displayedLabel(folderName: noteFolders.first { $0.id == id }?.name)
        case let .bot(name):
            let known = cachedBots.contains {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            } || conversations.contains {
                $0.botName?.caseInsensitiveCompare(name) == .orderedSame
            }
            return shortcut.displayedLabel(botName: known ? botCurrentName(for: name) : nil)
        case let .conversation(id):
            guard let chat = conversations.first(where: { $0.id == id }) else {
                return shortcut.displayedLabel()
            }
            return shortcut.displayedLabel(conversationTitle: displayTitle(for: chat))
        case .destination, .artifact:
            return shortcut.displayedLabel()
        }
    }

    /// The pin as the shelf should draw it: a chat keeps the invoked agent's
    /// colour, the way the drawer already does.
    func homeShortcutStyledLabel(_ shortcut: HomeShortcut) -> AttributedString {
        if case let .conversation(id) = shortcut.target,
           let chat = conversations.first(where: { $0.id == id }) {
            return titleStyled(for: chat)
        }
        return AttributedString(homeShortcutLabel(shortcut))
    }

    func addHomeShortcut(_ shortcut: HomeShortcut) {
        guard !hasHomeShortcut(matching: shortcut.target) else { return }
        homeShortcuts.append(shortcut)
    }

    func removeHomeShortcut(_ id: String) {
        homeShortcuts.removeAll { $0.id == id }
    }

    func removeHomeShortcut(matching target: HomeShortcut.Target) {
        homeShortcuts.removeAll { $0.target == target }
    }

    /// The dragged pin takes `target`'s place, the way the Agents shelf does.
    func moveHomeShortcut(_ source: String, to target: String) {
        guard source != target,
              let from = homeShortcuts.firstIndex(where: { $0.id == source }),
              let to = homeShortcuts.firstIndex(where: { $0.id == target })
        else { return }
        var next = homeShortcuts
        let item = next.remove(at: from)
        next.insert(item, at: to)
        homeShortcuts = next
    }

    /// Opens what a home pin points at. Missing chats stay missing: this does
    /// not fall through to another conversation or another agent.
    func openHomeShortcut(_ shortcut: HomeShortcut) {
        showingBots = false
        showingNotes = false
        showingAgenda = false
        switch shortcut.target {
        case let .destination(raw):
            guard let destination = AliceDestination.Target(rawValue: raw) else { return }
            switch destination {
            case .notes:
                showingNotes = true
            case .agenda:
                showingAgenda = true
            case .bots:
                botsFromLeading = false
                showingBots = true
                markNoticesSeen(.agents)
            default:
                requestedDestination = destination
            }
        case let .note(id):
            showingNotes = true
            requestedNote = id
        case let .noteFolder(id):
            showingNotes = true
            requestedNotesScope = .folder(id)
        case let .bot(name):
            if let bot = cachedBots.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                openBotConversation(for: bot)
            } else if let existing = conversations.first(where: {
                $0.botName?.caseInsensitiveCompare(name) == .orderedSame
            }) {
                openConversation(existing.id)
            }
        case let .artifact(kind, value):
            if kind == LibraryTool.shortcutKind, let tool = LibraryTool(rawValue: value) {
                presentedLibraryTool = tool
            } else if let artifactKind = Artifact.Kind(rawValue: kind) {
                requestedDestination = .library
                requestedArtifact = Artifact(kind: artifactKind, value: value, session: "")
            }
        case let .conversation(id):
            guard conversations.contains(where: { $0.id == id }) else { return }
            openConversation(id)
        }
    }

    /// Records a model as chosen, keeping the short list of recent ones.
    func chooseModel(_ id: String, provider: String?) {
        selectedModel = id
        selectedProvider = provider
        var recent = recentModels.filter { $0 != id }
        recent.insert(id, at: 0)
        recentModels = Array(recent.prefix(6))
        if let pending = pendingHomeModelConfirmation {
            pendingHomeModelConfirmation = nil
            retryHeldHomeSend(pending, confirmModel: false)
        }
    }

    /// The person agreed the current model may train on this chat. The original
    /// question is sent; it was never submitted while Hermes was waiting.
    func confirmHomeModel() {
        guard let pending = pendingHomeModelConfirmation else { return }
        pendingHomeModelConfirmation = nil
        retryHeldHomeSend(pending, confirmModel: true)
    }

    /// The person refused. The question stays; Alice did not answer it.
    func declineHomeModel() {
        guard let pending = pendingHomeModelConfirmation else { return }
        pendingHomeModelConfirmation = nil
        fail(
            pending.replyID, conversationID: pending.conversationID,
            message: "Alice did not send that. This model needs your OK first — it may train on what you write. Choose another model, then send again.",
            limit: nil
        )
        finish(pending.replyID, conversationID: pending.conversationID)
    }

    /// Sends a question that was held for a model policy. The placeholder
    /// stays the same reply, so the card is replaced by the real answer.
    private func retryHeldHomeSend(_ pending: ModelConfirmation.Pending, confirmModel: Bool) {
        sendingConversations.insert(pending.conversationID)
        if let location = messageLocation(pending.replyID, conversationID: pending.conversationID) {
            conversations[location.chat].messages[location.message].content = ""
            conversations[location.chat].messages[location.message].error = nil
            conversations[location.chat].messages[location.message].pending = true
            conversations[location.chat].messages[location.message].awaitingRemote = false
            conversations[location.chat].messages[location.message].deliveryNote = nil
            conversations[location.chat].messages[location.message].incomplete = false
        }
        persistConversations()
        streamTasks[pending.conversationID] = Task { [weak self] in
            await self?.sendToBotChat(
                profile: nil,
                conversationID: pending.conversationID,
                replyID: pending.replyID,
                text: pending.text,
                attachments: pending.attachments,
                earlier: pending.earlier,
                confirmModel: confirmModel
            )
        }
    }

    func newChat() {
        let chat = Conversation.blank()
        conversations.insert(chat, at: 0)
        activeID = chat.id
        draft = ""
        persistConversations()
    }

    func delete(_ id: String) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [.blank()] }
        if activeID == id { activeID = conversations.first(where: { !$0.isBotChat })?.id ?? conversations.first?.id }
        persistConversations()
    }

    /// A turn's content, with its attachments folded in: images as data URLs
    /// the way the OpenAI-compatible shape expects, and text files inlined
    /// into the prompt, since the agent cannot open a file this app is
    /// holding in memory.
    /// Which provider to name, or nil to let the agent choose.
    ///
    /// Thirty-seven of the ninety-nine models this agent offers are served by
    /// more than one, and taking the first of them is taking one at random —
    /// here it pinned every Anthropic model to `nous`, which has no token, so
    /// a spent quota came back as an authentication error instead. Where the
    /// choice is ambiguous the agent routes it, which is what its own
    /// fallback chain is for.
    static func provider(
        for model: String?,
        among options: [HermesClient.ModelOption],
        chosen: String? = nil
    ) -> String? {
        guard let model else { return nil }
        let serving = Set(options.filter { $0.id == model }.compactMap(\.provider))
        // What the reader picked, when it still serves this model. Only then
        // does the ambiguity below matter.
        if let chosen, serving.contains(chosen) { return chosen }
        return serving.count == 1 ? serving.first : nil
    }

    private static func content(
        of message: Message, includeAttachments: Bool
    ) -> HermesClient.Turn.Content {
        guard includeAttachments, !message.attachments.isEmpty else {
            return .text(message.content)
        }
        var text = [message.content]
        var images: [String] = []
        for attachment in message.attachments {
            if attachment.kind == .image {
                images.append(attachment.dataURL)
            } else if let contents = attachment.textContents {
                text.append("Attached file — \(attachment.name):\n\(contents)")
            } else {
                text.append("Attached file — \(attachment.name) (\(attachment.mime)), which I cannot read as text.")
            }
        }
        let combined = String(
            text.filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(60_000)
        )
        guard !images.isEmpty else { return .text(combined) }
        return .parts(text: combined, imageURLs: images)
    }

    /// Whether the bots page is up.
    ///
    /// A page rather than a sheet: it is arrived at sideways, from the drawer
    /// or by backing out of a bot's conversation, and a screen that rises
    /// from the bottom in answer to a swipe to the right reads as the wrong
    /// screen appearing.
    /// The model list shown and where it came from; see `ModelListPolicy`.
    @ObservationIgnored private var modelList = ModelListPolicy.State()
    /// The read in flight, joined by anyone who asks while it runs.
    @ObservationIgnored private var modelLoad: (
        token: UUID, refreshing: Bool, task: Task<Bool, Never>
    )?

    var showingBots = false
    /// Notes is a page as well, reached sideways from the drawer.
    var showingNotes = false
    /// The agenda, a page too (`AgendaScreen`).
    var showingAgenda = false
    /// "Tomorrow 11:30 · Hairdresser": the next commitment within a day and a
    /// half, read on this phone, for the home's suggestions.
    private(set) var nextCommitment: String?
    /// A home pin that wants a particular note open once Notes is up.
    var requestedNote: String?
    /// A home pin that wants a particular folder open once Notes is up.
    var requestedNotesScope: NotesScope?
    /// A home pin that wants a library item open once Library is up.
    var requestedArtifact: Artifact?
    /// A living artifact covering the screen: Mac, and whatever is added next.
    var presentedLibraryTool: LibraryTool?
    /// Opens the new-agent sheet on this template id, then is cleared.
    var requestedAgentTemplate: String?
    /// A note is open in its editor, on top of Notes. The Notes page's own
    /// swipe to close stands down so the swipe goes back to the list instead.
    var editingNote = false
    /// A note row is swiped open, so a rightward swipe closes it rather than Notes.
    var noteRowOpen = false
    /// When a finger last came down on a note row: a rightward swipe begun
    /// there pins the note, and must not also close Notes.
    var noteRowTouchedAt = Date.distantPast

    /// Notes kept at the top, by id. Kept on this phone.
    private(set) var pinnedNotes: Set<String> = [] {
        didSet { defaults.set(Array(pinnedNotes), forKey: Keys.pinnedNotes) }
    }

    func togglePinned(_ note: Note) {
        if pinnedNotes.contains(note.id) { pinnedNotes.remove(note.id) } else { pinnedNotes.insert(note.id) }
    }

    // MARK: - Locking

    /// Face ID (or the passcode) before Alice shows anything.
    var requireUnlock: Bool {
        get { lock.requireUnlock }
        set { lock.requireUnlock = newValue }
    }
    /// How long Alice may be away before it locks again, in seconds.
    var lockGrace: Int {
        get { lock.lockGrace }
        set { lock.lockGrace = newValue }
    }
    /// The app's content is covered until the owner unlocks it.
    var appLocked: Bool {
        get { lock.appLocked }
        set { lock.appLocked = newValue }
    }
    /// When Alice last left the foreground, for the grace period.
    var leftForegroundAt: Date? {
        get { lock.leftForegroundAt }
        set { lock.leftForegroundAt = newValue }
    }
    /// Locked notes were unlocked once; they stay open until Alice leaves the
    /// foreground, as in Notes.
    var lockedNotesOpen: Bool {
        get { lock.lockedNotesOpen }
        set { lock.lockedNotesOpen = newValue }
    }

    func isLocked(_ note: Note) -> Bool { lock.isLocked(note) }

    func setLocked(_ note: Note, _ locked: Bool) {
        lock.setLocked(note, locked)
    }

    /// Asks for Face ID when a locked note is to be opened, once per visit.
    func unlockNotes() async -> Bool {
        await lock.unlockNotes()
    }

    /// A copy of a note, styling and folder included.
    func duplicate(_ note: Note) async throws {
        var copy = try await addNote(note.text, attachments: note.attachments)
        if let rich = note.rich {
            try await editNote(copy, text: note.text, rich: rich, attachments: note.attachments)
            copy.rich = rich
        }
        if let folder = noteFolderOf[note.id] { await put(copy.id, in: .folder(folder)) }
        if lock.lockedNotes.contains(note.id) { lock.setLocked(copy, true) }
    }

    // MARK: - Note folders

    /// The folders in the notes store, in the order made — shared with the
    /// agent that keeps the notes, which files them there. Quick Notes and
    /// Recently Deleted are not among them: they are always there (the second
    /// only when it holds something).
    var noteFolders: [NoteFolder] { notesSnapshot?.folders ?? [] }

    /// The folders shown at the top level: the ones not put inside another.
    var rootNoteFolders: [NoteFolder] {
        orderedNoteFolders(NoteFolderTree.roots(noteFolders, parent: noteFolderParent))
    }

    /// The folders inside one, in the saved order.
    func subfolders(of id: String) -> [NoteFolder] {
        orderedNoteFolders(NoteFolderTree.children(of: id, in: noteFolders, parent: noteFolderParent))
    }

    private func orderedNoteFolders(_ folders: [NoteFolder]) -> [NoteFolder] {
        NoteFolderTree.ordered(
            folders, pinned: [], order: noteFolderOrder, sort: .manual
        )
    }

    /// Whether a folder is inside another, at any depth.
    func noteFolder(_ id: String, isInside ancestor: String) -> Bool {
        NoteFolderTree.isInside(id, ancestor, parent: noteFolderParent)
    }

    /// Puts a folder inside another, or back at the top level.
    func moveNoteFolder(_ id: String, into parent: String?) {
        noteFolderParent = NoteFolderTree.moving(id, into: parent, parent: noteFolderParent)
    }

    /// List edit-mode: the dragged folder takes the slot it was dropped on,
    /// and that neighbour takes the slot it left. A nested folder dragged
    /// out of its parent is un-nested.
    @discardableResult
    func reorderVisibleNoteFolders(from source: IndexSet, to destination: Int, displayed: [String]) -> Bool {
        guard let next = NoteFolderTree.movingDisplayed(
            from: source, to: destination, displayed: displayed,
            parent: noteFolderParent, order: noteFolderOrder
        ) else { return false }
        noteFolderParent = next.parent
        noteFolderOrder = next.order
        return true
    }

    /// The folder each note is filed in, by note id.
    var noteFolderOf: [String: String] {
        let known = Set(noteFolders.map(\.id))
        var map: [String: String] = [:]
        for note in notesSnapshot?.notes ?? [] {
            if let folder = note.folder, known.contains(folder) { map[note.id] = folder }
        }
        return map
    }

    /// Folders made on this phone before they lived in the store, moved there
    /// once and then forgotten.
    private var legacyFolders: [NoteFolder] = []
    private var legacyFolderOf: [String: String] = [:]

    private(set) var recentlyDeleted: [DeletedNote] = [] {
        didSet { save(recentlyDeleted, as: Keys.recentlyDeleted) }
    }
    /// A folder's page is open over the folders, so swiping right goes back to
    /// them rather than closing Notes.
    var notesFolderOpen = false
    /// Why the last change to a folder did not take, for the folders page.
    var noteFolderFailure: String?

    private func save<T: Encodable>(_ value: T, as key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func loadNoteFolders() {
        func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        legacyFolders = read([NoteFolder].self, Keys.noteFolders) ?? []
        legacyFolderOf = read([String: String].self, Keys.noteFolderOf) ?? [:]
        let cutoff = Date().addingTimeInterval(-DeletedNote.kept)
        recentlyDeleted = (read([DeletedNote].self, Keys.recentlyDeleted) ?? []).filter { $0.deletedAt > cutoff }
    }

    /// Folders made on this phone go to the store with their notes, once.
    private func moveLegacyFoldersToStore() async {
        guard !legacyFolders.isEmpty, notesSnapshot?.available == true else { return }
        for folder in legacyFolders {
            do {
                // Reuse a folder already created by an interrupted migration.
                let made: NoteFolder
                if let existing = noteFolders.first(where: { $0.id == folder.id || $0.name == folder.name }) {
                    made = existing
                } else {
                    made = try await dashboard.createNoteFolder(named: folder.name)
                    notesSnapshot = notesSnapshot?.with(folders: noteFolders + [made])
                }
                let pending = legacyFolderOf.filter { $0.value == folder.id }
                for note in pending.keys {
                    try await dashboard.fileNote(id: note, folder: made.id)
                    replaceNote(note) { $0.folder = made.id }
                    legacyFolderOf.removeValue(forKey: note)
                    save(legacyFolderOf, as: Keys.noteFolderOf)
                }
                legacyFolders.removeAll { $0.id == folder.id }
                save(legacyFolders, as: Keys.noteFolders)
            } catch {
                // Keep unfinished assignments for the next refresh; a failed
                // remote write must never discard the phone's migration data.
                noteFolderFailure = HermesErrors.describe(error)
                return
            }
        }
        defaults.removeObject(forKey: Keys.noteFolders)
        defaults.removeObject(forKey: Keys.noteFolderOf)
        if let fresh = try? await dashboard.notes() { notesSnapshot = fresh }
    }

    private func replaceNote(_ id: String, _ change: (inout Note) -> Void) {
        guard let current = notesSnapshot else { return }
        notesSnapshot = current.with(notes: current.notes.map { note in
            guard note.id == id else { return note }
            var changed = note
            change(&changed)
            return changed
        })
    }

    func notes(in scope: NotesScope) -> [Note] {
        let all = notesSnapshot?.notes ?? []
        switch scope {
        case .all:
            return all
        case .quick:
            let folders = Set(noteFolders.map(\.id))
            return all.filter { note in note.folder.map { !folders.contains($0) } ?? true }
        case let .folder(id):
            return all.filter { $0.folder == id }
        case .deleted:
            return recentlyDeleted.sorted { $0.deletedAt > $1.deletedAt }.map(\.note)
        }
    }

    func name(of scope: NotesScope) -> String {
        switch scope {
        case .all: "All Notes"
        case .quick: "Quick Notes"
        case let .folder(id): noteFolders.first { $0.id == id }?.name ?? "Folder"
        case .deleted: "Recently Deleted"
        }
    }

    /// Makes a folder in the notes store, shown at once. Hermes keeps folders
    /// flat and will hand back one of the same name; `inside` is this phone's
    /// nesting, so it is recorded on the placeholder and kept on whatever id
    /// the store returns — otherwise a nested create of a name already there
    /// stayed at the top and vanished from the parent.
    @discardableResult
    func createNoteFolder(named name: String, inside parent: String? = nil) async -> NoteFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = notesSnapshot else { return nil }
        let placeholder = NoteFolder(id: "local-\(UUID().uuidString)", name: trimmed)
        notesSnapshot = current.with(folders: noteFolders + [placeholder])
        if let parent {
            noteFolderParent[placeholder.id] = parent
        }
        do {
            let made = try await dashboard.createNoteFolder(named: trimmed)
            let others = noteFolders.filter { $0.id != placeholder.id && $0.id != made.id }
            notesSnapshot = notesSnapshot?.with(folders: others + [made])
            if let parent {
                var map = noteFolderParent
                map.removeValue(forKey: placeholder.id)
                map[made.id] = parent
                noteFolderParent = map
            }
            return made
        } catch {
            notesSnapshot = notesSnapshot?.with(folders: noteFolders.filter { $0.id != placeholder.id })
            if parent != nil {
                var map = noteFolderParent
                map.removeValue(forKey: placeholder.id)
                noteFolderParent = map
            }
            noteFolderFailure = HermesErrors.describe(error)
            return nil
        }
    }

    func renameNoteFolder(_ id: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let before = noteFolders
        notesSnapshot = notesSnapshot?.with(folders: before.map { $0.id == id ? NoteFolder(id: id, name: trimmed) : $0 })
        do {
            try await dashboard.renameNoteFolder(id: id, to: trimmed)
        } catch {
            notesSnapshot = notesSnapshot?.with(folders: before)
            noteFolderFailure = HermesErrors.describe(error)
        }
    }

    /// The folder goes; its notes go back to Quick Notes, not with it.
    func deleteNoteFolder(_ id: String) async {
        let before = noteFolders
        let parentsBefore = noteFolderParent
        let pinsBefore = pinnedNoteFolders
        let orderBefore = noteFolderOrder
        // Whatever was inside it comes back to the top level, with its notes.
        noteFolderParent = NoteFolderTree.removing(id, from: noteFolderParent)
        notesSnapshot = notesSnapshot?.with(folders: before.filter { $0.id != id })
        pinnedNoteFolders.remove(id)
        noteFolderOrder.removeAll { $0 == id }
        do {
            try await dashboard.deleteNoteFolder(id: id)
        } catch {
            noteFolderParent = parentsBefore
            notesSnapshot = notesSnapshot?.with(folders: before)
            pinnedNoteFolders = pinsBefore
            noteFolderOrder = orderBefore
            noteFolderFailure = HermesErrors.describe(error)
        }
    }

    /// Files a note in a folder of the store, or back in Quick Notes.
    func put(_ noteID: String, in scope: NotesScope) async {
        let folder: String? = if case let .folder(id) = scope { id } else { nil }
        let before = notesSnapshot?.notes.first { $0.id == noteID }?.folder
        guard before != folder else { return }
        replaceNote(noteID) { $0.folder = folder }
        do {
            try await dashboard.fileNote(id: noteID, folder: folder)
        } catch {
            replaceNote(noteID) { $0.folder = before }
            noteFolderFailure = HermesErrors.describe(error)
        }
    }

    /// A deleted note back in its store and its folder. The store gives it a
    /// new identity and today's date: it is written again, not undeleted.
    func recover(_ deleted: DeletedNote) async throws {
        var created = try await addNote(deleted.note.text, attachments: deleted.note.attachments)
        if let rich = deleted.note.rich {
            try await editNote(created, text: deleted.note.text, rich: rich, attachments: deleted.note.attachments)
            created.rich = rich
        }
        if let folder = deleted.folderID, noteFolders.contains(where: { $0.id == folder }) {
            await put(created.id, in: .folder(folder))
        }
        recentlyDeleted.removeAll { $0.id == deleted.id }
    }

    func deleteForever(_ deleted: DeletedNote) {
        recentlyDeleted.removeAll { $0.id == deleted.id }
    }

    func deleteAllForever() {
        recentlyDeleted.removeAll()
    }
    /// The launch logo has left, so home's own may come in.
    var launchRevealed = false

    /// Which side the bots page comes from and leaves by.
    ///
    /// Forward is leftward and back is rightward, so the page has to know
    /// which of the two is happening: arriving from the drawer it comes in
    /// off the right, and backing into it out of a bot's conversation it
    /// comes in off the left, the way the finger went.
    var botsFromLeading = false

    /// Which way the bots page leaves.
    ///
    /// Separate from the way it arrived, because the two are decided at
    /// different moments and by different gestures — and because a removal
    /// transition is read from the view as it last stood, so this has to be
    /// settled a frame before the page is dismissed.
    var botsExitLeading = false

    // MARK: - Time zone

    func hermesTimezones() async throws -> HermesTimezones {
        try await dashboard.hermesTimezones()
    }

    /// Sets one zone on Alice and on every agent, so none is left on the
    /// Mac's clock, and returns what Hermes then reports.
    func setHermesTimezone(_ identifier: String) async throws -> HermesTimezones {
        let current = try await dashboard.hermesTimezones()
        try await dashboard.setTimezone(identifier, profile: "default")
        for profile in current.profiles where profile.timezone != identifier {
            try await dashboard.setTimezone(identifier, profile: profile.name)
        }
        try? await dashboard.refreshTimezones()
        return try await dashboard.hermesTimezones()
    }

    // MARK: - Calendar

    /// Where the person's calendar stands with their Hermes. Read when the
    /// app comes back, and changed by the offer card and Settings.
    private(set) var calendarLink: CalendarLink = .unknown
    @ObservationIgnored private var calendarSyncedAt: Date?

    func refreshCalendarLink() async {
        guard dashboardReady, let link = try? await dashboard.calendarLink() else { return }
        if link != calendarLink { calendarLink = link }
    }

    /// Asks iOS for access and sends the first window. Nil when connected;
    /// otherwise what to tell the person.
    func connectCalendar() async -> String? {
        guard dashboardReady else { return "Connect to your Hermes first." }
        guard await CalendarSync.requestAccess() else {
            return CalendarSync.refused
                ? "Calendar access is off for Alice. Turn it on in iOS Settings › Alice › Calendars."
                : "Alice did not get access to your calendar."
        }
        do {
            try await uploadCalendar()
            return nil
        } catch {
            return PlainWords.describe(error, doing: "send your calendar to Hermes")
        }
    }

    /// "Not now": agents stop offering it until the person connects it.
    func declineCalendar() async {
        guard (try? await dashboard.declineCalendar()) != nil else { return }
        calendarLink = .declined
    }

    /// Takes every event off Hermes. iOS keeps its own permission; the switch
    /// for that is in iOS Settings.
    func disconnectCalendar() async -> String? {
        do {
            try await dashboard.disconnectCalendar()
            calendarLink = .notConnected
            calendarSyncedAt = nil
            return nil
        } catch {
            return PlainWords.describe(error, doing: "disconnect your calendar")
        }
    }

    /// Keeps Hermes' copy current while connected: on each return to the app
    /// and each background refresh, at most every ten minutes.
    func syncCalendarIfConnected() async {
        if calendarLink == .unknown { await refreshCalendarLink() }
        guard calendarLink.isConnected, CalendarSync.hasAccess else { return }
        if let last = calendarSyncedAt, Date().timeIntervalSince(last) < 10 * 60 { return }
        try? await uploadCalendar()
    }

    /// After the app itself wrote an event: Hermes' copy is updated now, not
    /// at the next ten-minute mark.
    func syncCalendarNow() async {
        guard CalendarSync.hasAccess else { return }
        try? await uploadCalendar()
    }

    private func uploadCalendar() async throws {
        let window = CalendarSync.window()
        let events = await CalendarSync.events(from: window.start, to: window.end)
        try await dashboard.uploadCalendar(events, from: window.start, to: window.end)
        calendarSyncedAt = Date()
        calendarLink = .connected(updatedAt: Date())
    }

    // MARK: - Agenda

    /// What the agenda page just read, so the home can say what is next
    /// without reading the calendar again.
    func noteCommitments(_ items: [AgendaItem], now: Date = Date()) {
        let line = Agenda.next(items, now: now).map { Agenda.glance($0, now: now) }
        if line != nextCommitment { nextCommitment = line }
    }

    /// On each return to the app and each change to the phone's calendar.
    func refreshCommitments() async {
        guard CalendarSync.hasAccess else {
            if nextCommitment != nil { nextCommitment = nil }
            return
        }
        var items = AgendaSource.events()
        items += await AgendaSource.reminders()
        noteCommitments(items)
    }

    // MARK: - Today

    /// Alice's own forever-chat: the main profile's canonical Bot Chat in
    /// Hermes. It is where she writes first — the morning briefing, what a
    /// watch found — the way Poke or Today.ai keep one thread that starts
    /// without you. Her other chats are conversations you start; this one is
    /// hers, and reads, replies and approvals work as in any agent's chat.
    nonisolated static let todayProfile = "default"
    nonisolated static let todayTitle = "Today"

    private static var todayBot: BotRow {
        BotRow(
            name: todayProfile, displayName: todayTitle, detail: "",
            model: nil, provider: nil, skills: 0, isDefault: true,
            gatewayRunning: false, active: true
        )
    }

    var todayConversationID: String? {
        conversations.first { $0.routedBotName == Self.todayProfile }?.id
    }

    /// Whether Alice has written something in Today since it was last opened.
    var todayUnread: Bool { isBotUnread(Self.todayProfile) }

    /// How many messages Alice wrote in Today since it was last opened.
    var todayNewCount: Int {
        guard let today = conversations.first(where: { $0.routedBotName == Self.todayProfile })
        else { return 0 }
        let since = today.openedAt ?? .distantPast
        return RoutineDelivery.present(
            today.messages, botName: Self.todayProfile,
            agentAnswers: Set(today.agentAnswerIDs ?? [])
        ).filter {
            $0.role == .assistant && !$0.pending && MessageTime.isKnown($0.createdAt) && $0.createdAt > since
        }.count
    }

    func openToday() {
        showingBots = false
        showingNotes = false
        showingAgenda = false
        openBotConversation(for: Self.todayBot)
    }

    /// Today is kept on the phone from the start, so a briefing that arrives
    /// while the app is closed has somewhere to be read into and counted as
    /// new. Added at the end: it is never the chat the app opens on.
    private func ensureTodayConversation() {
        guard conversationsUnreadable == nil, todayConversationID == nil else { return }
        let now = Date()
        var today = Conversation(
            id: UUID().uuidString, title: Self.todayTitle,
            createdAt: now, updatedAt: now, botName: Self.todayProfile
        )
        // Nothing in it has been read yet, and nothing old should count as new.
        today.openedAt = now
        conversations.append(today)
        persistConversations()
    }

    /// Agents with replies or reports since their chat was last opened, for
    /// the home's "while you were away".
    var agentsWithNews: [HomeAgentNews] {
        cachedBots
            .filter { !isBotHidden($0) && isBotUnread($0.name) }
            .map { HomeAgentNews(slug: $0.name, name: botCurrentName(for: $0)) }
    }

    /// Opens a bot's chat, then reconciles it with the agent's own.
    ///
    /// The local conversation is a cache, so it opens at once from what is
    /// already on the phone and the canonical transcript is folded in when it
    /// arrives. Hermes owns the contents: a cron report delivered to the bot's
    /// forever-chat while the app was closed shows up on this read, because
    /// this reads that chat rather than a private copy Alice kept.
    @discardableResult
    func openBotConversation(
        for bot: BotRow, replacingExisting: Bool = false, refresh: Bool = true
    ) -> String {
        if replacingExisting {
            conversations.removeAll {
                $0.botName?.caseInsensitiveCompare(bot.name) == .orderedSame
            }
        }
        let id: String
        if !replacingExisting,
           let existing = conversations.first(where: {
               $0.botName?.caseInsensitiveCompare(bot.name) == .orderedSame
           }) {
            activeID = existing.id
            id = existing.id
        } else {
            let now = Date()
            let chat = Conversation(
                id: UUID().uuidString,
                title: bot.displayName,
                createdAt: now,
                updatedAt: now,
                botName: bot.name
            )
            conversations.insert(chat, at: 0)
            activeID = chat.id
            persistConversations()
            id = chat.id
        }
        markBotRead(bot.name)
        // A brand-new agent has no remote transcript. Waiting on a refresh
        // left the chat empty for seconds before the first prompt appeared.
        if refresh {
            Task { [weak self] in await self?.refreshBotChat(id) }
        }
        return id
    }

    /// Folds the bot's canonical Hermes transcript into the local cache.
    ///
    /// Safe to call repeatedly and on every open: the merge is keyed on the
    /// agent's message ids, so a report already shown is not shown twice. A
    /// failure leaves the cache exactly as it was and reports itself — an
    /// unreachable agent is not a bot with nothing to say.
    func refreshBotChat(_ conversationID: String) async {
        // Only a canonical bot chat has a remote transcript to read. Recovered
        // history is local by definition and has no session to refresh from.
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let profile = conversations[index].routedBotName,
              conversations[index].isCanonicalBotChat
        else { return }
        // A chat being cleared is emptied here first and deleted in Hermes
        // after. Until that finishes, the old chat is still readable there, and
        // a read would put every message back on the screen it just left.
        guard !clearingBotChats.contains(profile) else { return }
        guard let source = await botChatSource() else {
            botChatFailure[conversationID] =
                "Connect the Hermes dashboard to see this bot's own chat."
            return
        }
        do {
            var chat = try await resolveBotChat(profile, source: source)
            // One read gives both the transcript and what is still going on in
            // it: tool calls and whether a turn is running are in the same
            // projection, and are what the transcript alone leaves out.
            let resumed: JSONObject
            do {
                resumed = try await source.resume(profile: profile, target: chat.resolvedID)
            } catch let error where WebSocketBotChatSource.isNotFound(error) {
                // The chat moved — cleared or compressed elsewhere — since it
                // was cached. One fresh lookup, then the read goes on.
                forgetCanonicalBotChat(profile)
                chat = try await resolveBotChat(profile, source: source, fresh: true)
                resumed = try await source.resume(profile: profile, target: chat.resolvedID)
            }
            guard let current = conversations.firstIndex(where: { $0.id == conversationID })
            else { return }
            if conversations[current].hermesSessionID != chat.resolvedID {
                conversations[current].hermesSessionID = chat.resolvedID
            }
            // A reply nobody is following any more — the app was suspended or
            // relaunched mid-reply — is settled against what just arrived.
            let merged = BotChatSync.settle(
                BotChatSync.merge(
                    WebSocketBotChatSource.turns(from: resumed.rows),
                    into: conversations[current].messages,
                    botName: profile
                ),
                watching: Set(activeBotTurns.values.map(\.replyID)),
                note: Self.lostTouchNote(label: botCurrentName(for: profile))
            )
            // Same transcript as last time: assigning it anyway rebuilt every
            // screen that can see a conversation, including ones the person
            // is not in.
            let transcriptChanged = conversations[current].messages != merged
            if transcriptChanged {
                conversations[current].messages = merged
            }
            if conversations[current].messages.last(where: { $0.role == .assistant })?.pending != true {
                closeAgentActivity(for: conversationID)
            }
            // A reply this phone lost the thread of, still being written in
            // Hermes: drawn in progress again rather than as cut off.
            let runningRemotely = activeBotTurns[conversationID] == nil
                && BotTurnState(resumed)?.running == true
            var resumedReply = false
            if let last = conversations[current].messages.last(where: { $0.role == .assistant }),
               last.awaitingRemote, !last.pending, last.remoteID == nil {
                setStillWorking(runningRemotely, replyID: last.id)
                resumedReply = runningRemotely
                let label = botCurrentName(for: profile)
                if runningRemotely, last.deliveryNote != Self.stillWorkingNote(label: label),
                   let at = conversations[current].messages.lastIndex(where: { $0.id == last.id }) {
                    conversations[current].messages[at].deliveryNote = Self.stillWorkingNote(label: label)
                    persistConversations()
                }
                if runningRemotely { startReplyRecovery() }
            }
            for message in conversations[current].messages where remoteWorkingReplies.contains(message.id)
                && !(message.awaitingRemote && runningRemotely) {
                setStillWorking(false, replyID: message.id)
            }
            // The answer landed while the watch had lost its socket: the
            // placeholder is gone, and so is anything left to follow.
            if let turn = activeBotTurns[conversationID], turn.disposition != nil,
               !conversations[current].messages.contains(where: { $0.id == turn.replyID }) {
                releaseBotWatcher(conversationID, expectedToken: turn.token)
            }
            _ = index
            let roster = cachedBots
            let delegations = AgentMessages.delegations(in: resumed.rows) { handle in
                Self.canMessage(from: profile, to: handle, roster: roster)
            }
            // Kept across reads: a compressed history can drop the call an
            // answer belonged to, and the answer must not turn into a request.
            let answers = Set(conversations[current].agentAnswerIDs ?? []).union(delegations.answers)
            if answers != Set(conversations[current].agentAnswerIDs ?? []) {
                conversations[current].agentAnswerIDs = answers.sorted()
            }
            setBackgroundWork(AgentMessages.BackgroundWork(
                waitingOn: delegations.pending,
                // Shown in the reply itself when there is one to show it in.
                running: runningRemotely && !resumedReply
            ), for: conversationID)
            if botChatFailure[conversationID] != nil { botChatFailure[conversationID] = nil }
            if transcriptChanged { persistConversations() }
            await refreshQuietRoutineRuns(profile: profile)
        } catch {
            // Keep what is on screen. The reason is recorded so the chat can
            // say the transcript may be behind, rather than pretending it is
            // complete or blanking it.
            botChatFailure[conversationID] = HermesErrors.describe(error)
            // Its routine runs are read on their own route, and still count.
            await refreshQuietRoutineRuns(profile: profile)
        }
    }

    private func persistQuietRuns() {
        guard quietRunsLoaded else { return }
        if let data = try? JSONEncoder().encode(quietRoutineRuns) {
            defaults.set(data, forKey: Keys.quietRuns)
        }
        defaults.set(judgedRoutineRuns.mapValues { Array($0.suffix(200)) }, forKey: Keys.judgedRuns)
    }

    private func loadQuietRuns() {
        if let data = defaults.data(forKey: Keys.quietRuns),
           let saved = try? JSONDecoder().decode([String: [QuietRoutineRun]].self, from: data) {
            let since = Date().addingTimeInterval(-QuietRoutineRun.window)
            quietRoutineRuns = saved.mapValues { $0.filter { $0.finishedAt >= since } }
        }
        if let saved = defaults.dictionary(forKey: Keys.judgedRuns) as? [String: [String]] {
            judgedRoutineRuns = saved.mapValues(Set.init)
        }
        quietRunsLoaded = true
    }

    /// Work each bot chat has going on out of sight, keyed by conversation.
    private(set) var backgroundWorks: [String: AgentMessages.BackgroundWork] = [:]
    private var backgroundFollowers: [String: Task<Void, Never>] = [:]

    func backgroundWork(for conversationID: String) -> AgentMessages.BackgroundWork {
        var work = backgroundWorks[conversationID] ?? AgentMessages.BackgroundWork()
        // A turn this phone follows shows itself in the reply being written.
        if activeBotTurns[conversationID] != nil { work.running = false }
        // Clarify is already on screen. Hermes still reports the turn as
        // running, which would keep "is working on it" up while nobody is.
        // Asked only when it could change the answer: it is not cheap.
        if work.running, !pendingQuestions(in: conversationID).isEmpty { work.running = false }
        return work
    }

    /// Records what a chat is waiting on, and keeps reading the chat until
    /// that is over. Nothing on this phone follows it: the other agent's
    /// answer wakes this one inside Hermes.
    /// When the person stopped waiting for each agent, by chat.
    private var stoppedWaits: [String: [String: Date]] = [:]

    /// The person stops waiting for an agent's answer: a request refused out of
    /// sight, or an answer that will never come, no longer holds the chat.
    func stopWaiting(for handle: String, in conversationID: String) {
        stoppedWaits[conversationID, default: [:]][handle] = Date()
        setBackgroundWork(backgroundWorks[conversationID] ?? AgentMessages.BackgroundWork(), for: conversationID)
    }

    private func setBackgroundWork(
        _ incoming: AgentMessages.BackgroundWork, for conversationID: String
    ) {
        let work = incoming.withoutStopped(stoppedWaits[conversationID] ?? [:])
        guard !work.isEmpty else {
            if backgroundWorks[conversationID] != nil { backgroundWorks[conversationID] = nil }
            backgroundFollowers[conversationID]?.cancel()
            backgroundFollowers[conversationID] = nil
            return
        }
        if backgroundWorks[conversationID] != work { backgroundWorks[conversationID] = work }
        guard backgroundFollowers[conversationID] == nil else { return }
        backgroundFollowers[conversationID] = Task { [weak self] in
            // Bounded, so a delivery Hermes gave up on stops being waited for
            // even when this phone cannot reach Hermes to find out.
            for _ in 0..<Int(AgentMessages.patience / 8) {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled else { return }
                if self.activeID == conversationID, self.activeBotTurns[conversationID] == nil {
                    await self.refreshBotChat(conversationID)
                }
                if self.backgroundWorks[conversationID] == nil { return }
            }
            self?.backgroundWorks[conversationID] = nil
            self?.backgroundFollowers[conversationID] = nil
        }
    }

    /// The agents whose chat is being cleared: emptied here, still being
    /// deleted in Hermes.
    private var clearingBotChats: Set<String> = []

    /// Empties an agent's chat, in Hermes and on this phone. Its instructions,
    /// memory, skills and routines are kept.
    func clearBotChat(_ profile: String) async throws {
        guard let source = await botChatSource() else {
            throw HermesRPCClient.Failure(reason: "Connect the Hermes dashboard to clear this agent's chat.")
        }
        // A reply still under way — or held up by a question — belongs to the
        // chat being thrown away. Refusing until it finished made Clear Chat do
        // nothing for an agent waiting on an answer, which can be forever.
        let cleared = Set(conversations.filter {
            $0.routedBotName == profile && $0.isCanonicalBotChat
        }.map(\.id))
        for conversationID in cleared {
            releaseBotTurn(conversationID, stopped: true)
            setBackgroundWork(AgentMessages.BackgroundWork(), for: conversationID)
        }
        // The screen empties now, not when Hermes is done. Deleting a chat
        // there is the better part of a dozen round trips — let go of the live
        // session, delete the row and its compressed tip, make a fresh chat —
        // and waiting for all of them left the conversation sitting on screen
        // for about ten seconds after the person had cleared it. Reads are held
        // off meanwhile so nothing puts the old chat back, and a refusal from
        // Hermes restores exactly what was there.
        let kept = conversations.filter { cleared.contains($0.id) }.map { ($0.id, $0.messages) }
        let clearedBefore = botChatClearedAt[profile]
        clearingBotChats.insert(profile)
        defer { clearingBotChats.remove(profile) }
        botChatClearedAt[profile] = Date()
        quietRoutineRuns[profile] = nil
        // Nothing may send into the chat being thrown away.
        forgetCanonicalBotChat(profile)
        for index in conversations.indices where cleared.contains(conversations[index].id) {
            conversations[index].messages = []
            conversations[index].updatedAt = Date()
        }
        persistConversations()

        let fresh: CanonicalBotChat
        do {
            fresh = try await source.clearCanonicalBotChat(profile: profile)
        } catch {
            botChatClearedAt[profile] = clearedBefore
            for (id, messages) in kept {
                guard let index = conversations.firstIndex(where: { $0.id == id }) else { continue }
                conversations[index].messages = messages
            }
            persistConversations()
            throw error
        }
        // Its questions and approvals went with it.
        for event in activity where event.isActionable
            && cleared.contains(event.reference.conversationID ?? "") {
            settle(event.id, as: .gone, summary: "The chat was cleared.")
        }
        canonicalBotChats[profile] = (fresh, Date())
        for index in conversations.indices where cleared.contains(conversations[index].id) {
            conversations[index].hermesSessionID = fresh.resolvedID
        }
        botChatFailure = botChatFailure.filter { entry in
            !conversations.contains { $0.id == entry.key && $0.routedBotName == profile }
        }
        persistConversations()
    }

    /// Finds this bot's routine runs that ended with nothing to say. Best
    /// effort, like the rest of a refresh: a failure keeps what was found.
    private func refreshQuietRoutineRuns(profile: String) async {
        do {
            let routines = try await routines(for: profile)
            let since = max(
                Date().addingTimeInterval(-QuietRoutineRun.window),
                botChatClearedAt[profile] ?? .distantPast
            )
            let found = try await dashboard.quietRoutineRuns(
                profile: profile, routines: routines, since: since,
                skipping: judgedRoutineRuns[profile] ?? []
            )
            judgedRoutineRuns[profile, default: []].formUnion(found.judged)
            let kept = (quietRoutineRuns[profile] ?? []).filter { $0.finishedAt >= since }
            let newQuiet = found.quiet.filter { run in !kept.contains { $0.id == run.id } }
            let merged = (kept + newQuiet)
                .sorted { $0.finishedAt < $1.finishedAt }
            // A refresh may finish after the reader has already left this
            // chat. Preserve the notification explicitly in that race; when
            // the chat is still visible, the new card has just been seen.
            let openedAt = conversations.first {
                $0.routedBotName == profile
            }?.openedAt
            if Self.hasUnreadQuietRun(newQuiet, openedAt: openedAt),
               showingBots || activeConversation?.routedBotName != profile {
                unreadBots.insert(profile)
            }
            if merged != (quietRoutineRuns[profile] ?? []) {
                quietRoutineRuns[profile] = merged
            }
        } catch {
            // No card is better than a wrong one.
        }
    }

    /// Opens a bot's canonical session as soon as its chat appears, so Send
    /// is not the first `BotChatSync.resolve`.
    func prepareBotChatIfNeeded(profile: String) async {
        let open = conversations.first(where: {
            $0.isCanonicalBotChat && $0.routedBotName == profile
        })
        if let sessionID = open?.hermesSessionID, !sessionID.isEmpty { return }
        guard let source = await botChatSource() else { return }
        do {
            let chat = try await resolveBotChat(profile, source: source)
            if let index = conversations.firstIndex(where: {
                $0.isCanonicalBotChat && $0.routedBotName == profile
            }) {
                conversations[index].hermesSessionID = chat.resolvedID
            }
        } catch {
            // Warm-up only. Send still opens the session and says if it fails.
        }
    }

    /// Re-reads every bot chat the app is showing, once, on returning to the
    /// foreground. Not a poll: a cron report lands while the phone is asleep,
    /// and this is the moment it becomes worth asking for.
    func refreshVisibleBotChats() async {
        // Replies first: they are what someone coming back from a notification
        // opened the app to read. Every other bot is read when its own chat
        // opens. Refreshing them all here took the better part of a minute
        // and rebuilt the screens underneath Notes and Agents the whole time.
        await recoverWaitingReplies()
        if let activeID,
           conversations.contains(where: { $0.id == activeID && $0.isCanonicalBotChat }),
           activeBotTurns[activeID] == nil {
            await refreshBotChat(activeID)
        }
        // Today is read even when it is not open: it is where Alice writes
        // first, and the home says so only if the phone has seen it.
        if let today = todayConversationID, today != activeID, activeBotTurns[today] == nil {
            await refreshBotChat(today)
        }
        markMentionRepliesSeen(in: activeID)
        startReplyRecovery()
    }

    /// Replies this phone lost the thread of — the socket dropped, the app
    /// was suspended — that Hermes, read back since, says it is still
    /// writing. Drawn as in progress again, so a reply that is only out of
    /// sight never looks like one that was cut off; recovery settles them.
    private(set) var remoteWorkingReplies: Set<String> = []

    func isStillWorking(_ replyID: String) -> Bool { remoteWorkingReplies.contains(replyID) }

    private func setStillWorking(_ working: Bool, replyID: String) {
        if working, !remoteWorkingReplies.contains(replyID) {
            remoteWorkingReplies.insert(replyID)
        } else if !working, remoteWorkingReplies.contains(replyID) {
            remoteWorkingReplies.remove(replyID)
        }
    }

    nonisolated static func stillWorkingNote(label: String) -> String {
        "Reconnected. \(label) is still working on it."
    }

    /// Replies still drawn as on their way — being written, or left waiting by
    /// a watch that lost its socket — that Hermes may already have finished.
    private var waitingReplyChats: [String] {
        conversations.compactMap { conversation in
            guard let reply = conversation.messages.last(where: { $0.role == .assistant }),
                  reply.pending || reply.awaitingRemote,
                  conversation.isHomeSessionChat || conversation.isCanonicalBotChat
                    || reply.mentionSessionID != nil
            else { return nil }
            let followed = activeBotTurns[conversation.id]
            // Not yet accepted by Hermes: there is nothing there to find.
            if followed == nil, sendingConversations.contains(conversation.id) { return nil }
            if let followed, followed.disposition == nil { return nil }
            // Waiting on the person, not on Hermes. Treating it as a lost
            // turn wrote "Lost touch" over the confirmation card, then
            // finish() turned the empty bubble into "Couldn't reply."
            if pendingHomeModelConfirmation?.conversationID == conversation.id { return nil }
            return conversation.id
        }
    }

    /// Reads each waiting reply's chat back from Hermes, the way the Bark
    /// notifier knows a reply is done: by what Hermes has stored.
    private func recoverWaitingReplies() async {
        let waiting = waitingReplyChats
        if !waiting.isEmpty { DiagnosticsLog.write("recover.start chats=\(waiting.count)") }
        for id in waiting {
            guard pendingHomeModelConfirmation?.conversationID != id else { continue }
            guard let conversation = conversations.first(where: { $0.id == id }) else { continue }
            if conversation.messages.last(where: { $0.role == .assistant })?.mentionSessionID != nil {
                await settleMentionReply(id)
            } else if conversation.isHomeSessionChat {
                await settleHomeReply(id)
            } else {
                await refreshBotChat(id)
            }
        }
    }

    private var replyRecovery: Task<Void, Never>?

    /// Keeps looking for waiting replies while the app is open, every twelve
    /// seconds for up to ten minutes, whatever became of the watch following
    /// them — ended by a suspension, stalled, or never started after a relaunch.
    func startReplyRecovery() {
        guard replyRecovery == nil, !waitingReplyChats.isEmpty else { return }
        replyRecovery = Task { [weak self] in
            defer { self?.replyRecovery = nil }
            for _ in 0..<80 {
                // Sooner while Hermes is known to be writing: its answer
                // should land about when it would have streamed.
                let working = self?.remoteWorkingReplies.isEmpty == false
                try? await Task.sleep(for: .seconds(working ? 5 : 12))
                guard let self, !Task.isCancelled else { return }
                guard self.isForeground else { continue }
                if self.waitingReplyChats.isEmpty { return }
                await self.recoverWaitingReplies()
            }
        }
    }

    /// Sends one turn into a bot's canonical Hermes chat and streams the reply.
    ///
    /// The session is resolved before anything is sent, so the turn lands in
    /// the same chat cron delivers to. Nothing here builds a persona: the
    /// agent on the other end *is* the bot, with its own SOUL, memory, skills
    /// and configuration.
    /// A turn in a Hermes session over the dashboard socket: a bot's canonical
    /// chat, or, with no profile, Alice's own chat.
    private func sendToBotChat(
        profile: String?, conversationID: String, replyID startingReplyID: String, text: String,
        attachments: [Attachment], earlier: [Message] = [], mention: Bool = false,
        confirmModel: Bool = false
    ) async {
        var replyID = startingReplyID
        guard let source = await botChatSource() else {
            if profile == nil {
                streamThroughGateway(
                    conversationID: conversationID, replyID: replyID, invokedBot: nil
                )
                return
            }
            fail(replyID, conversationID: conversationID,
                 message: "Connect the Hermes dashboard to talk to this bot.",
                 limit: nil)
            finish(replyID, conversationID: conversationID)
            return
        }
        let token = UUID()
        activeBotTurns[conversationID] = ActiveBotTurn(
            token: token, conversationID: conversationID, replyID: replyID
        )
        let label = profile.map { botCurrentName(for: $0) } ?? "Alice"
        var ending = BotTurnEnding.stopped
        do {
            var storedSessionID: String
            let events = source.rpc.events()
            let submission: BotChatSubmission
            if let profile {
                var chat = try await resolveBotChat(profile, source: source)
                storedSessionID = chat.resolvedID
                if mention {
                    // This chat keeps its own session; the reply remembers the agent's.
                    if let location = messageLocation(replyID, conversationID: conversationID) {
                        conversations[location.chat].messages[location.message].mentionSessionID = storedSessionID
                    }
                    activeBotTurns[conversationID]?.mentionProfile = profile
                    activeBotTurns[conversationID]?.storedSessionID = storedSessionID
                } else if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].hermesSessionID = storedSessionID
                }
                do {
                    submission = try await source.submit(
                        profile: profile, sessionID: storedSessionID, text: text,
                        attachments: attachments
                    )
                } catch let error where WebSocketBotChatSource.isNotFound(error)
                    && canonicalBotChats[profile] != nil {
                    // The cached chat was cleared or compressed away since it
                    // was looked up. Ask Hermes again once, then send there.
                    forgetCanonicalBotChat(profile)
                    chat = try await resolveBotChat(profile, source: source, fresh: true)
                    storedSessionID = chat.resolvedID
                    if mention {
                        activeBotTurns[conversationID]?.storedSessionID = storedSessionID
                    } else if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                        conversations[index].hermesSessionID = storedSessionID
                    }
                    submission = try await source.submit(
                        profile: profile, sessionID: storedSessionID, text: text,
                        attachments: attachments
                    )
                }
            } else {
                guard let session = try await openHomeSession(
                    source: source, conversationID: conversationID, earlier: earlier,
                    confirmModel: confirmModel
                ) else {
                    // Hermes could not open the chat and nothing was sent, so
                    // the gateway can still take the turn — unless it was
                    // stopped meanwhile.
                    guard activeBotTurns[conversationID]?.token == token, !Task.isCancelled
                    else { return }
                    activeBotTurns[conversationID] = nil
                    streamThroughGateway(
                        conversationID: conversationID, replyID: replyID, invokedBot: nil
                    )
                    return
                }
                storedSessionID = session.storedID
                submission = try await source.submit(
                    liveSessionID: session.liveID, text: text, attachments: attachments
                )
            }
            setRemoteMatchContent(
                submission.submittedText, forReply: replyID, conversationID: conversationID
            )
            if activeBotTurns[conversationID]?.token == token {
                activeBotTurns[conversationID]?.disposition = submission.disposition
            }
            DiagnosticsLog.write(
                "turn.submitted reply=\(replyID) profile=\(profile ?? "alice") mention=\(mention) "
                    + "live=\(submission.liveSessionID) disposition=\(submission.disposition)"
            )
            track(liveSessionID: submission.liveSessionID, for: conversationID)
            // Stop may have been tapped while prompt.submit itself was still
            // awaiting its ACK. In that window interrupting first would race
            // the yet-to-arrive prompt and let it run AFTER the stop. The stop
            // intent is latched and fulfilled here, once Hermes has accepted
            // this exact submit and its live runtime is known.
            if botStopsInFlight[conversationID] == token {
                let ended = await interruptBotTurn(
                    conversationID: conversationID,
                    token: token, profile: profile, storedSessionID: storedSessionID,
                    liveSessionID: submission.liveSessionID, source: source
                )
                if ended || activeBotTurns[conversationID]?.token != token { return }
            }
            var watch = BotTurnWatch(submission: submission, now: Date())
            let requestIdentity = LiveEvents.SessionIdentity(
                profile: profile, sessionID: storedSessionID, sessionKey: storedSessionID,
                conversationID: conversationID, label: label
            )
            // Said while it is true: a busy bot has not started on this yet.
            let waitingNote = Self.deliveryNote(for: submission.disposition, label: label)
            setDeliveryNote(waitingNote, on: replyID, conversationID: conversationID)

            // Frames end the reply only when they say the turn is over, and a
            // silence is asked about rather than waited on forever.
            var unansweredChecks = 0
            watching: for await signal in BotTurnWatch.signals(from: events, every: .seconds(15)) {
                // Let go meanwhile — settled from the transcript, stopped, or
                // superseded — so nothing here may touch the reply again.
                guard activeBotTurns[conversationID]?.token == token else { break watching }
                switch signal {
                case let .frame(event):
                    if let withdrawn = GatewayServerRequests.cancelledRequestID(event) {
                        withdrawServerRequest(withdrawn)
                        continue
                    }
                    let step = watch.receive(event, now: Date())
                    if let request = watch.request(from: event, session: requestIdentity) {
                        observe(request)
                    }
                    if step == .ignore { continue }
                    if step == .finish,
                       let failure = Self.botTerminalFailure(from: event) {
                        recordBotFailure(
                            failure, on: replyID, conversationID: conversationID
                        )
                    }
                    if step == .queuedTurnEnded, profile == nil {
                        // Only this chat sends into Alice's own session, so
                        // what follows the turn ahead of it is its own.
                        watch.confirmQueuedOrigin(now: Date())
                        setDeliveryNote(nil, on: replyID, conversationID: conversationID)
                        continue
                    }
                    if step == .queuedTurnEnded, mention, let profile {
                        // Asked from another chat, there is no transcript of
                        // the agent's here to find this message in: look in
                        // its session instead.
                        if await mentionOriginLanded(
                            source: source, profile: profile, storedID: storedSessionID,
                            submitted: submission.submittedText, replyID: replyID,
                            conversationID: conversationID
                        ) {
                            watch.confirmQueuedOrigin(now: Date())
                            setDeliveryNote(nil, on: replyID, conversationID: conversationID)
                        }
                        continue
                    }
                    if step == .queuedTurnEnded {
                        // A queued submission may have several turns ahead.
                        // Never claim the next stream blindly: the canonical
                        // transcript settles us only after our exact user row.
                        await refreshBotChat(conversationID)
                        if messageLocation(replyID, conversationID: conversationID) == nil {
                            ending = .outcome
                            break watching
                        }
                        if botReplyOriginIsRemote(replyID, conversationID: conversationID) {
                            watch.confirmQueuedOrigin(now: Date())
                            setDeliveryNote(nil, on: replyID, conversationID: conversationID)
                        }
                        continue
                    }
                    // Narration before a tool is its own bubble. Clearing it
                    // used to drop the words the model had already said.
                    if event.type == "tool.start" {
                        replyID = sealOpenNarration(
                            replyID: replyID, conversationID: conversationID
                        )
                    }
                    // Asking another agent: said at once, not only once the
                    // turn has ended and the transcript is read.
                    if event.type == "tool.start",
                       (event.payload["name"] as? String) == "message_agent",
                       let target = (event.payload["args"] as? [String: Any])?["target"] as? String,
                       let handle = AgentMessages.normalized(target),
                       Self.canMessage(
                           from: conversations.first(where: { $0.id == conversationID })?.routedBotName,
                           to: handle, roster: cachedBots
                       ) {
                        var work = backgroundWorks[conversationID] ?? AgentMessages.BackgroundWork()
                        work.waitingOn.append(.init(handle: handle, sentAt: Date()))
                        setBackgroundWork(work, for: conversationID)
                    }
                    // Refused on the spot all the same (Hermes says why in the
                    // result): nobody is going to answer, so nobody is waited for.
                    if event.type == "tool.complete",
                       (event.payload["name"] as? String) == "message_agent",
                       let result = event.payload["result"] as? [String: Any], result["error"] != nil,
                       let target = (event.payload["args"] as? [String: Any])?["target"] as? String,
                       let handle = AgentMessages.normalized(target),
                       var work = backgroundWorks[conversationID],
                       let index = work.waitingOn.lastIndex(where: { $0.handle == handle }) {
                        work.waitingOn.remove(at: index)
                        setBackgroundWork(work, for: conversationID)
                    }
                    if let chatEvent = Self.chatEvent(from: event) {
                        apply(
                            chatEvent, to: replyID, conversationID: conversationID,
                            approvalTransport: .socket,
                            approvalSessionID: watch.liveSessionID,
                            approvalSessionKey: storedSessionID
                        )
                    }
                    if event.type == "message.complete",
                       let usage = MessageUsage.parse(event.payload) {
                        attachUsage(usage, to: replyID, conversationID: conversationID)
                    }
                    if step == .finish {
                        ending = .outcome
                        break watching
                    }
                case .tick:
                    guard watch.shouldCheck(now: Date()) else { continue }
                    if watch.needsTranscriptCorrelation, mention, let profile {
                        if await mentionOriginLanded(
                            source: source, profile: profile, storedID: storedSessionID,
                            submitted: submission.submittedText, replyID: replyID,
                            conversationID: conversationID
                        ) {
                            watch.confirmQueuedOrigin(now: Date())
                            setDeliveryNote(nil, on: replyID, conversationID: conversationID)
                        }
                    } else if watch.needsTranscriptCorrelation {
                        await refreshBotChat(conversationID)
                        if messageLocation(replyID, conversationID: conversationID) == nil {
                            ending = .outcome
                            break watching
                        }
                        if botReplyOriginIsRemote(replyID, conversationID: conversationID) {
                            watch.confirmQueuedOrigin(now: Date())
                            setDeliveryNote(nil, on: replyID, conversationID: conversationID)
                        }
                    }
                    let state: Result<BotTurnState, Error>
                    let liveSessionID = watch.liveSessionID
                    let sessionID = storedSessionID
                    do {
                        let snapshot = try await BotTurnWatch.answer(
                            within: BotTurnWatch.checkDeadline
                        ) {
                            try await source.turnSnapshot(
                                profile: profile,
                                storedSessionID: sessionID,
                                liveSessionID: liveSessionID
                            )
                        }
                        guard let current = BotTurnState(snapshot) else {
                            throw HermesRPCClient.Failure(reason: "Hermes returned no live session id.")
                        }
                        for request in LiveEvents.pendingEvents(from: snapshot, session: requestIdentity) {
                            observe(request)
                        }
                        unansweredChecks = 0
                        state = .success(current)
                    } catch {
                        // A socket that died without saying so leaves the call
                        // hanging. One missed snapshot is not that: drop the
                        // socket only after a second unanswered check, so a
                        // slow dashboard does not look like a reconnect.
                        if error is BotTurnWatch.NoAnswer {
                            unansweredChecks += 1
                            if unansweredChecks >= 2 { await rpcClient?.disconnect() }
                        }
                        state = .failure(error)
                    }
                    switch watch.checked(state, now: Date()) {
                    case let .keepWaiting(liveSessionIDChanged):
                        DiagnosticsLog.write("watch.keepWaiting reply=\(replyID) changed=\(liveSessionIDChanged)")
                        if liveSessionIDChanged {
                            track(liveSessionID: watch.liveSessionID, for: conversationID)
                        }
                        setDeliveryNote(
                            watch.needsTranscriptCorrelation ? waitingNote : nil,
                            on: replyID, conversationID: conversationID
                        )
                    case .reconnecting:
                        DiagnosticsLog.write("watch.reconnecting reply=\(replyID)")
                        setDeliveryNote(
                            "Reconnecting to Hermes…", on: replyID, conversationID: conversationID
                        )
                        startReplyRecovery()
                    case let .endedUnseen(failure):
                        DiagnosticsLog.write("watch.endedUnseen reply=\(replyID) failure=\(failure != nil)")
                        ending = .endedUnseen(failure)
                        break watching
                    case .lostTouch:
                        DiagnosticsLog.write("watch.lostTouch reply=\(replyID)")
                        ending = .lostTouch
                        break watching
                    }
                }
            }
        } catch {
            DiagnosticsLog.write("turn.failed reply=\(replyID) error=\(error.localizedDescription)")
            Task { await self.pushDiagnostics(force: true) }
            if profile == nil, let needed = ModelConfirmation.needed(from: error) {
                holdHomeModelConfirmation(
                    conversationID: conversationID, replyID: replyID, text: text,
                    attachments: attachments, earlier: earlier, message: needed.message
                )
                activeBotTurns[conversationID] = nil
                sendingConversations.remove(conversationID)
                streamTasks[conversationID] = nil
                return
            }
            ending = .failed
            fail(replyID, conversationID: conversationID,
                 message: HermesErrors.describe(error),
                 limit: nil)
        }

        // Stopped, or superseded by a newer message: whoever let go of this
        // reply has already settled it, and may be watching another.
        DiagnosticsLog.write(
            "turn.end reply=\(replyID) profile=\(profile ?? "alice") mention=\(mention) ending=\(ending)"
        )
        guard activeBotTurns[conversationID]?.token == token else { return }
        activeBotTurns[conversationID] = nil
        switch ending {
        case .outcome:
            if profile == nil,
               holdHomeModelConfirmationIfBanner(
                   conversationID: conversationID, replyID: replyID,
                   text: text, attachments: attachments, earlier: earlier
               ) {
                sendingConversations.remove(conversationID)
                streamTasks[conversationID] = nil
                return
            }
            fallthrough
        case .failed, .stopped:
            if profile == nil,
               await adoptHomeTranscriptIfEmpty(
                   replyID: replyID, conversationID: conversationID,
                   text: text, attachments: attachments, earlier: earlier
               ) {
                return
            }
            setDeliveryNote(nil, on: replyID, conversationID: conversationID)
            finish(replyID, conversationID: conversationID)
            await refreshBotChat(conversationID)
            if mention, let profile {
                await refreshOwnChat(of: profile)
                markMentionRepliesSeen(in: conversationID)
            }
        case let .endedUnseen(retainedFailure):
            // Nothing is running and no ending was seen. A disconnected client
            // can miss Hermes' terminal frame; session.activate/resume retains
            // failed turns in `inflight`, so prefer that exact cause over a
            // guessed "finished without answering" message.
            awaitRemote(replyID, conversationID: conversationID, note: nil)
            await refreshBotChat(conversationID)
            if profile == nil,
               await settleHomeReply(conversationID, replyID: replyID) {
                return
            }
            if mention, await settleMentionReply(conversationID, replyID: replyID) {
                if let profile { await refreshOwnChat(of: profile) }
                return
            }
            // The socket this watch asked on was new, and missed the turn;
            // Hermes, read back by the chat, says it is still being written.
            if isStillWorking(replyID) {
                startReplyRecovery()
                return
            }
            if botChatFailure[conversationID] == nil,
               messageLocation(replyID, conversationID: conversationID) != nil {
                if let retainedFailure {
                    recordBotFailure(
                        retainedFailure, on: replyID, conversationID: conversationID
                    )
                } else {
                    if let location = messageLocation(
                        replyID, conversationID: conversationID
                    ) {
                        conversations[location.chat].messages[location.message].awaitingRemote = false
                        conversations[location.chat].messages[location.message].deliveryNote = nil
                    }
                    fail(
                        replyID, conversationID: conversationID,
                        message: "\(label) stopped before producing a final reply. Hermes no longer reports this turn as running.",
                        limit: nil
                    )
                    persistConversations()
                }
            } else if botChatFailure[conversationID] != nil {
                awaitRemote(
                    replyID, conversationID: conversationID,
                    note: Self.lostTouchNote(label: label)
                )
            }
        case .lostTouch:
            awaitRemote(
                replyID, conversationID: conversationID,
                note: Self.lostTouchNote(label: label)
            )
            await refreshBotChat(conversationID)
            if profile == nil {
                await settleHomeReply(conversationID, replyID: replyID)
            } else if mention {
                await settleMentionReply(conversationID, replyID: replyID)
            }
        }
    }

    /// The Hermes session Alice's own chat continues in, on the model her
    /// picker names. Nil when Hermes could not open it: nothing was sent then,
    /// and the gateway can still take the turn. A model Hermes will not switch
    /// to without confirmation is thrown as `ModelConfirmation.Needed`.
    func openHomeSession(
        source: WebSocketBotChatSource, conversationID: String, earlier: [Message],
        confirmModel: Bool = false
    ) async throws -> HomeChatSession? {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID })
        else { return nil }
        let model = selectedModel
        let provider = Self.provider(for: model, among: models, chosen: selectedProvider)
        let session: HomeChatSession
        if let warm = warmHomeSessions[conversationID],
           warm.session.storedID == conversations[index].hermesSessionID,
           Date().timeIntervalSince(warm.at) < Self.warmHomeSessionLifetime {
            // Resumed while the person was still typing.
            session = warm.session
        } else {
            guard let opened = try? await source.openHomeChat(
                storedID: conversations[index].hermesSessionID,
                model: model, provider: provider,
                history: WebSocketBotChatSource.openingHistory(earlier)
            ) else { return nil }
            session = opened
        }
        warmHomeSessions[conversationID] = nil
        if let current = conversations.firstIndex(where: { $0.id == conversationID }),
           conversations[current].hermesSessionID != session.storedID {
            conversations[current].hermesSessionID = session.storedID
            persistConversations()
        }
        guard let model, !model.isEmpty else { return session }
        let wanted = "\(model)|\(provider ?? "")"
        guard confirmModel || homeChatModels[session.liveID] != wanted else { return session }
        // Always set on a runtime this app has not set it on: what a resumed
        // session reports is not what it runs.
        let switched = try await source.useModel(
            model, provider: provider, in: session, force: true, confirm: confirmModel
        )
        homeChatModels[switched.liveID] = wanted
        return switched
    }

    /// Resumes Alice's chat as the person opens it, so the send that follows
    /// does not first wait on `session.resume`. Only a chat Hermes already
    /// has: creating one here would open an empty session for a chat the
    /// person may never write in, and the create path needs the opening
    /// history the send assembles.
    func prepareHomeChatIfNeeded(conversationID: String) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.routedBotName == nil, !conversation.isRecoveredHistory,
              let storedID = conversation.hermesSessionID, !storedID.isEmpty
        else { return }
        if let warm = warmHomeSessions[conversationID], warm.session.storedID == storedID,
           Date().timeIntervalSince(warm.at) < Self.warmHomeSessionLifetime {
            return
        }
        guard let source = await botChatSource() else { return }
        guard let session = try? await source.openHomeChat(
            storedID: storedID, model: nil, provider: nil, history: []
        ) else { return }
        // A chat deleted in Hermes came back as a fresh one; nothing was sent
        // to it, and the send finds it by the id kept here.
        warmHomeSessions[conversationID] = (session, Date())
        if let current = conversations.firstIndex(where: { $0.id == conversationID }),
           conversations[current].hermesSessionID != session.storedID {
            conversations[current].hermesSessionID = session.storedID
            persistConversations()
        }
    }

    /// Home sessions resumed ahead of a send, by conversation. Short-lived:
    /// Hermes reaps idle runtimes, and a send on one that is gone is answered
    /// "not found" and opened again the slow way.
    private var warmHomeSessions: [String: (session: HomeChatSession, at: Date)] = [:]
    private static let warmHomeSessionLifetime: TimeInterval = 120

    /// The model each of Alice's live session runtimes was last put on from
    /// this app.
    ///
    /// Keyed by the runtime, not the stored chat. When a provider fails, Hermes
    /// answers with a fallback and saves that model on the chat; once the
    /// runtime is reaped, resuming rebuilds it on the saved fallback. Keyed by
    /// the chat, Alice believed her pick was still applied and never asked
    /// again, so a chat on Union Alpha carried on as GPT-5.6 Terra. Nor can
    /// the model a resumed session reports be trusted — it names the configured
    /// one — so every new runtime is set explicitly.
    private var homeChatModels: [String: String] = [:]

    /// Home chat is waiting on the person to accept a model policy, not on Hermes.
    private(set) var pendingHomeModelConfirmation: ModelConfirmation.Pending?

    private func holdHomeModelConfirmation(
        conversationID: String, replyID: String, text: String,
        attachments: [Attachment], earlier: [Message], message: String
    ) {
        if let location = messageLocation(replyID, conversationID: conversationID) {
            conversations[location.chat].messages[location.message].content = ""
            conversations[location.chat].messages[location.message].error = nil
            conversations[location.chat].messages[location.message].pending = true
            conversations[location.chat].messages[location.message].deliveryNote = nil
        }
        pendingHomeModelConfirmation = ModelConfirmation.Pending(
            conversationID: conversationID, replyID: replyID, text: text,
            attachments: attachments, earlier: earlier, message: message
        )
        persistConversations()
    }

    /// An empty turn ending is not proof Hermes said nothing: some models
    /// only put the body on the complete frame, which we now read, and others
    /// only persist it. Finishing those as "Couldn't reply." hid both.
    private func adoptHomeTranscriptIfEmpty(
        replyID: String, conversationID: String,
        text: String, attachments: [Attachment], earlier: [Message]
    ) async -> Bool {
        guard let location = messageLocation(replyID, conversationID: conversationID)
        else { return false }
        let reply = conversations[location.chat].messages[location.message]
        guard reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reply.error == nil, reply.approval == nil
        else { return false }
        guard await settleHomeReply(conversationID, replyID: replyID) else { return false }
        if holdHomeModelConfirmationIfBanner(
            conversationID: conversationID, replyID: replyID,
            text: text, attachments: attachments, earlier: earlier
        ) {
            sendingConversations.remove(conversationID)
            streamTasks[conversationID] = nil
            return true
        }
        sendingConversations.remove(conversationID)
        streamTasks[conversationID] = nil
        return true
    }

    /// Hermes sometimes writes the policy notice as the completion itself.
    @discardableResult
    private func holdHomeModelConfirmationIfBanner(
        conversationID: String, replyID: String, text: String,
        attachments: [Attachment], earlier: [Message]
    ) -> Bool {
        guard let location = messageLocation(replyID, conversationID: conversationID)
        else { return false }
        let reply = conversations[location.chat].messages[location.message]
        guard let notice = ModelConfirmation.notice(in: reply.content)
            ?? ModelConfirmation.notice(in: reply.error ?? "")
        else { return false }
        holdHomeModelConfirmation(
            conversationID: conversationID, replyID: replyID, text: text,
            attachments: attachments, earlier: earlier, message: notice
        )
        return true
    }

    /// A reply in Alice's own chat that is still outstanding.
    nonisolated static func awaitsReply(_ conversation: Conversation) -> Bool {
        guard let reply = conversation.messages.last(where: { $0.role == .assistant })
        else { return false }
        return reply.pending || reply.awaitingRemote == true
    }

    /// Settles a reply in Alice's own chat that nobody saw finish — the app
    /// was suspended, or the socket dropped — with the answer Hermes kept.
    @discardableResult
    private func settleHomeReply(_ conversationID: String, replyID: String? = nil) async -> Bool {
        guard let chat = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[chat].isHomeSessionChat,
              let storedID = conversations[chat].hermesSessionID
        else { return false }
        let messages = conversations[chat].messages
        let candidate = replyID.flatMap { id in messages.first { $0.id == id } }
            ?? messages.last { $0.role == .assistant }
        // A reply from an agent named with `@` lives in that agent's session.
        guard let reply = candidate, reply.mentionProfile == nil else { return false }
        return await settleReply(reply, in: conversationID, profile: nil, storedID: storedID)
    }

    /// Settles a reply from an agent named with `@` in another chat from that
    /// agent's own session, the way `settleHomeReply` does Alice's.
    @discardableResult
    private func settleMentionReply(_ conversationID: String, replyID: String? = nil) async -> Bool {
        guard let chat = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let messages = conversations[chat].messages
        let candidate = replyID.flatMap { id in messages.first { $0.id == id } }
            ?? messages.last { $0.role == .assistant }
        guard let reply = candidate, let profile = reply.mentionProfile,
              let storedID = reply.mentionSessionID
        else { return false }
        let settled = await settleReply(reply, in: conversationID, profile: profile, storedID: storedID)
        if settled {
            await refreshOwnChat(of: profile)
            markMentionRepliesSeen(in: conversationID)
        }
        return settled
    }

    /// The agent's own chat on this phone, brought up to date with a turn that
    /// was sent to it from somewhere else.
    private func refreshOwnChat(of profile: String) async {
        guard let own = conversations.first(where: {
            $0.routedBotName?.caseInsensitiveCompare(profile) == .orderedSame && $0.isCanonicalBotChat
        }) else { return }
        await refreshBotChat(own.id)
    }

    /// Whether Hermes has written the message sent to a busy agent from
    /// another chat into that agent's session, so what streams next is its answer.
    private func mentionOriginLanded(
        source: WebSocketBotChatSource, profile: String, storedID: String,
        submitted: String, replyID: String, conversationID: String
    ) async -> Bool {
        guard let location = messageLocation(replyID, conversationID: conversationID),
              let state = try? await source.sessionState(profile: profile, storedID: storedID)
        else { return false }
        let sentAt = conversations[location.chat].messages[location.message].createdAt
        let wanted = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.turns.contains { turn in
            turn.role == .user
                && turn.createdAt >= sentAt.addingTimeInterval(-BotChatSync.copyClockSlack)
                && turn.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
    }

    /// Fills a reply nobody saw finish with the answer its session kept.
    private func settleReply(
        _ reply: Message, in conversationID: String, profile: String?, storedID: String
    ) async -> Bool {
        guard pendingHomeModelConfirmation?.replyID != reply.id else { return false }
        guard reply.pending || reply.awaitingRemote == true else { return false }
        guard let source = await botChatSource() else {
            DiagnosticsLog.write("settle.noSource reply=\(reply.id) dashboardReady=\(dashboardReady)")
            return false
        }
        let state: (turns: [BotChatTurn], running: Bool)
        do {
            let snapshot = try await source.resume(profile: profile, target: storedID)
            state = (WebSocketBotChatSource.turns(from: snapshot.rows), BotTurnState(snapshot)?.running == true)
            let identity = LiveEvents.SessionIdentity(
                profile: profile, sessionID: storedID, sessionKey: storedID,
                conversationID: conversationID,
                label: profile.map { botCurrentName(for: $0) } ?? "Alice"
            )
            for request in LiveEvents.pendingEvents(from: snapshot, session: identity) {
                observe(request)
            }
        } catch {
            DiagnosticsLog.write("settle.readFailed reply=\(reply.id) error=\(error.localizedDescription)")
            return false
        }
        let asking = reply.replyToMessageID.flatMap { origin in
            conversations.first(where: { $0.id == conversationID })?
                .messages.first(where: { $0.id == origin })
        }.map { $0.remoteMatchContent ?? $0.content }
        DiagnosticsLog.write(
            "settle.read reply=\(reply.id) profile=\(profile ?? "alice") running=\(state.running) "
                + "turns=\(state.turns.count) last=\(state.turns.last?.role.rawValue ?? "none") "
                + "asking=\(asking != nil)"
        )
        let followed = activeBotTurns[conversationID]?.replyID == reply.id
        setStillWorking(state.running && !followed, replyID: reply.id)
        guard !state.running,
              let answer = WebSocketBotChatSource.finishedReply(
                  in: state.turns, sentAt: reply.createdAt, asking: asking
              ),
              let location = messageLocation(reply.id, conversationID: conversationID)
        else {
            // Restored from a suspended or relaunched app, a reply nobody
            // follows any more would say "Thinking…" for ever. Say instead
            // that it will show here, and look again on the next return.
            if activeBotTurns[conversationID] == nil,
               !sendingConversations.contains(conversationID),
               let location = messageLocation(reply.id, conversationID: conversationID) {
                let label = profile.map { botCurrentName(for: $0) } ?? "Alice"
                let message = conversations[location.chat].messages[location.message]
                if state.running {
                    // Still being written: say so, and keep reading it back.
                    if message.pending || message.deliveryNote != Self.stillWorkingNote(label: label) {
                        awaitRemote(reply.id, conversationID: conversationID,
                                    note: Self.stillWorkingNote(label: label))
                    }
                    startReplyRecovery()
                } else if message.pending {
                    awaitRemote(reply.id, conversationID: conversationID,
                                note: Self.lostTouchNote(label: label))
                }
            }
            return false
        }
        setStillWorking(false, replyID: reply.id)
        var settled = conversations[location.chat].messages[location.message]
        settled.content = answer
        settled.settle()
        settled.awaitingRemote = false
        settled.deliveryNote = nil
        settled.error = nil
        settled.errorLimit = nil
        settled.incomplete = false
        conversations[location.chat].messages[location.message] = settled
        persistConversations()
        closeAgentActivity(for: conversationID)
        // A watch that lost its socket is still waiting on this reply.
        if let turn = activeBotTurns[conversationID], turn.replyID == reply.id {
            releaseBotWatcher(conversationID, expectedToken: turn.token)
        }
        return true
    }

    /// A terminal error carried by the live WebSocket frame. The same shape
    /// is also reconstructed from Hermes' retained `inflight` state after a
    /// reconnect, so both paths show the provider's real cause.
    nonisolated static func botTerminalFailure(
        from event: HermesRPCEvent
    ) -> BotTurnFailure? {
        guard event.type == "message.complete",
              (event.payload["status"] as? String) == "error"
        else { return nil }
        let raw = ((event.payload["error"] as? String)
            ?? (event.payload["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return BotTurnFailure(
            message: raw, partial: "",
            recoverable: (event.payload["recoverable"] as? Bool) == true
        )
    }

    private func recordBotFailure(
        _ failure: BotTurnFailure, on replyID: String, conversationID: String
    ) {
        guard let location = messageLocation(replyID, conversationID: conversationID) else { return }
        var reply = conversations[location.chat].messages[location.message]
        let cause = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let retained = failure.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = "Hermes stopped before finishing."
        var pieces: [String] = []
        if !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(reply.content)
        } else if !retained.isEmpty {
            pieces.append(retained)
        }
        let detail = cause.isEmpty ? heading : "\(heading)\n\n\(cause)"
        if !pieces.contains(where: { $0.contains(cause) && !cause.isEmpty }) {
            pieces.append(detail)
        }
        reply.content = pieces.joined(separator: "\n\n")
        reply.settle()
        reply.awaitingRemote = false
        reply.deliveryNote = nil
        reply.error = cause.isEmpty ? heading : cause
        reply.errorLimit = nil
        reply.incomplete = true
        reply.runStatus = .failed
        conversations[location.chat].messages[location.message] = reply
        persistConversations()
        closeAgentActivity(for: conversationID)
    }

    /// The body to keep when a turn ends. Hermes' parent `message.complete`
    /// often repeats only the last delta; replacing the streamed reply with
    /// that would drop what was said before a tool. An empty bubble with a
    /// complete-frame body is the other case: some models never stream deltas.
    nonisolated static func replyBody(current: String, completion: String?) -> String {
        guard let completion else { return current }
        let incoming = completion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return current }
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return completion
        }
        return completion.count > current.count ? completion : current
    }

    /// One pushed frame as the event this app already knows how to draw.
    ///
    /// An adapter rather than a second renderer: deltas, tools and approvals
    /// all reach `apply` the way the HTTP path's do.
    nonisolated static func chatEvent(from event: HermesRPCEvent) -> ChatEvent? {
        switch event.type {
        case "message.interim":
            // Already streamed as deltas: sealing it again doubled a free
            // model's "Required parameters (if any): query" as the reply.
            if event.payload["already_streamed"] as? Bool == true { return nil }
            guard let text = (event.payload["text"] as? String)
                ?? (event.payload["content"] as? String),
                  !TurnNarration.normalized(text).isEmpty
            else { return nil }
            return .interim(text)
        case "message.delta":
            guard let text = (event.payload["text"] as? String)
                ?? (event.payload["delta"] as? String), !text.isEmpty
            else { return nil }
            return .delta(text)
        case "message.complete":
            // Only when this is the turn ending. A child's completion is not
            // the parent's, and Hermes says which by carrying `status`.
            guard let raw = event.payload["status"] as? String else { return nil }
            let status: Message.RunStatus
            switch raw {
            case "complete": status = .completed
            case "error": status = .failed
            case "interrupted": status = .interrupted
            default: return nil
            }
            // Deltas usually already hold the body. Some models skip them and
            // only put the reply on this frame — finishing without it became
            // "Couldn't reply."
            let output = (event.payload["text"] as? String)
                ?? (event.payload["content"] as? String)
            let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .run(
                id: (event.payload["id"] as? String) ?? event.sessionID,
                status: status, output: (trimmed?.isEmpty == false) ? output : nil
            )
        case "tool.start":
            guard let name = event.payload["name"] as? String else { return nil }
            return .tool(
                id: (event.payload["id"] as? String)
                    ?? (event.payload["tool_id"] as? String)
                    ?? name,
                name: name, status: .start,
                detail: Self.toolDetail(from: event.payload)
            )
        case "tool.complete":
            guard let name = event.payload["name"] as? String else { return nil }
            return .tool(
                id: (event.payload["id"] as? String)
                    ?? (event.payload["tool_id"] as? String)
                    ?? name,
                name: name, status: .done,
                detail: Self.toolDetail(from: event.payload)
            )
        case "reasoning.delta":
            // Only the streamed reasoning is reasoning. Despite its name,
            // `reasoning.available` carries the start of the text the model
            // wrote in that step (`agent/turn_response_intake._relay_thinking`),
            // which showed the reply twice.
            guard let text = (event.payload["text"] as? String) ?? (event.payload["delta"] as? String),
                  !text.isEmpty
            else { return nil }
            return .reasoning(text, block: false)
        case "todo.updated":
            // The whole plan after every change; a bot chat's `todo` args
            // are not read, so the two never race.
            guard let plan = TaskPlan.snapshot(event.payload) else { return nil }
            return .plan(.snapshot(plan))
        case "status.update":
            if (event.payload["kind"] as? String) == "heartbeat" { return nil }
            let text = (event.payload["text"] as? String)
                ?? (event.payload["message"] as? String)
                ?? (event.payload["status"] as? String)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .status(text)
        case "approval.request":
            // Hermes' approval payload has no `title`: it carries `command`,
            // `description`, `pattern_key(s)`, `allow_session`,
            // `allow_permanent` and a computed `choices`. Requiring a title
            // meant this returned nil for every real approval, so the card
            // never appeared in a bot chat at all.
            guard let requestID = LiveEvents.requestID(event.payload) else { return nil }
            let description = (event.payload["description"] as? String) ?? ""
            return .approval(Message.Approval(
                runID: requestID, requestID: requestID,
                title: description.isEmpty ? "Approval needed" : description,
                detail: event.payload["detail"] as? String,
                command: event.payload["command"] as? String,
                // The options Hermes listed. Offering "always" on a
                // smart-denied request proposes a permanent grant the server
                // will refuse.
                choices: LiveEvents.choices(event.payload),
                smartDenied: (event.payload["smart_denied"] as? Bool) == true ? true : nil,
                viaSocket: true
            ))
        case "error":
            let message = (event.payload["message"] as? String) ?? "Hermes reported an error."
            return .failure(message: message, limit: nil)
        default:
            // Frames the turn watcher reads for itself (session.*, message.*
            // bookkeeping) are not unknown; only a kind nothing in Alice names.
            if !Self.knownSocketEventTypes.contains(event.type) {
                HermesUnknownEvents.shared.record(event.type, transport: .botSocket, payload: event.payload)
            }
            return nil
        }
    }

    /// A file, query or command Hermes sent with a tool, for the activity line.
    nonisolated static func toolDetail(from payload: [String: Any]) -> String? {
        let top = ["preview", "context", "path", "file", "query", "command", "target", "url", "args_text"]
        if let preview = string(in: payload, keys: top) { return preview }
        if let args = dictionary(payload["args"]) {
            return string(in: args, keys: ["path", "file", "query", "command", "target", "url", "preview"])
        }
        return nil
    }

    private nonisolated static func string(in bag: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = bag[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private nonisolated static func dictionary(_ value: Any?) -> [String: Any]? {
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

    /// Socket event kinds Alice either handles or knowingly lets pass.
    ///
    /// The first group is what `chatEvent`, `LiveEvents` and the turn watch
    /// act on. The second is the bookkeeping Hermes' `tui_gateway` pushes
    /// alongside a turn (read from its source at v2026.9.7: reasoning, interim
    /// text, notices, todo and usage updates, session status) that Alice
    /// deliberately ignores. Anything else is a kind this Hermes sends that
    /// Alice has not learnt, and is recorded in `HermesUnknownEvents`.
    nonisolated static let knownSocketEventTypes: Set<String> = [
        // Handled.
        "message.delta", "message.complete", "message.interim", "tool.start", "tool.complete",
        "todo.updated", "reasoning.delta",
        "approval.request", "clarify.request", "error", "request.cancel",
        "subagent.start", "subagent.complete", "status.update",
        // Known and let pass.
        "message.start", "message.user", "message.react",
        "reasoning.available", "notification.show", "notification.clear",
        "session.info", "session.status", "session.reclaimed", "session.redirect",
        "session.resume_progress", "usage.bars",
        "tool.generating", "tool.output_risk", "turn.start", "turn.end", "turn.error",
        "subagent.text", "subagent.thinking", "subagent.tool", "subagent.tail",
        "approval.pending", "approval.received", "model.context_length",
    ]

    /// The bot-chat transport, or nil when no dashboard is connected.
    ///
    /// The socket is authenticated by a single-use ticket the dashboard mints
    /// for its own signed-in session, so this reuses the login Alice already
    /// has: no second credential store, no second login screen, and the
    /// password never leaves `DashboardClient`.
    func botChatSource() async -> WebSocketBotChatSource? {
        // A send just after launch can arrive before the foreground probe.
        // Restore the saved dashboard instead of treating gateway access as
        // permission to run a named agent under the main profile.
        if !dashboardReady { await restoreDashboard() }
        guard let rpcClient = await dashboardRPC() else { return nil }
        return WebSocketBotChatSource(rpc: rpcClient)
    }

    /// The re-merge above works on messages, so a refreshed message goes back
    /// through the same door it came in by.
    private static func turn(from message: Message) -> BotChatTurn? {
        guard let remoteID = message.remoteID else { return nil }
        return BotChatTurn(
            id: remoteID, role: message.role,
            content: message.content, createdAt: message.createdAt
        )
    }

    /// True when the active conversation is recovered history: readable, not
    /// writable. Sending would resume a simulated default-profile session, or
    /// be redirected into the bot's real one — two agents' conversations
    /// spliced into one apparent history.
    var activeIsRecoveredHistory: Bool {
        activeChat.isRecoveredHistory
    }

    func setControlSending(_ value: Bool) {
        guard let activeID else { return }
        if value {
            sendingConversations.insert(activeID)
        } else {
            sendingConversations.remove(activeID)
        }
    }

    /// A reply button in a message (`alice://reply`): its text goes into the
    /// chat on screen as if typed. Whatever the person was writing stays in
    /// the composer, and is not sent along with it.
    func sendQuickReply(_ text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        let savedDraft = draft
        let savedAttachments = draftAttachments
        let keepsDraft = !savedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !savedAttachments.isEmpty
        // Offline, `send` reconnects and then sends whatever is in the
        // composer — which would be the person's own draft by then.
        guard isConnected || !keepsDraft else { return }
        // A button in the reply of an agent asked with `@` in Alice's chat
        // answers that agent, not Alice: approving Inbox's folder went to her.
        var addressed = reply
        if let chat = activeConversation, chat.routedBotName == nil,
           let agent = chat.messages.last(where: { $0.role == .assistant })?.mentionProfile,
           mentions(in: reply).isEmpty {
            addressed = "@\(agent) " + reply
        }
        draft = addressed
        draftAttachments = []
        send()
        if keepsDraft {
            draft = savedDraft
            draftAttachments = savedAttachments
        }
    }

    private func markLatency(_ conversationID: String, phase: String) {
        var logged = latencyLogged[conversationID] ?? []
        guard logged.insert(phase).inserted else { return }
        latencyLogged[conversationID] = logged
        let started = latencyStartedAt[conversationID] ?? Date()
        let ms = phase == "send" ? 0 : max(0, Int((Date().timeIntervalSince(started) * 1000).rounded()))
        DiagnosticsLog.write("latency \(conversationID) \(phase) \(ms)")
    }

    func send() {
        guard !activeIsRecoveredHistory else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingWhitespace = draft.prefix(while: { $0.isWhitespace }).utf16.count
        let messageMentions = draftMentions.compactMap { mention -> DraftMention? in
            var moved = mention
            moved.location -= leadingWhitespace
            return moved.range(in: text) == nil ? nil : moved
        }
        guard !text.isEmpty || !draftAttachments.isEmpty else { return }
        if let editing = editingMessageID {
            editingMessageID = nil
            if sendEdit(of: editing, text: text) { return }
        }
        if activeAwaitsAnswers, !text.isEmpty, answerWaitingQuestion(with: text) { return }
        // Hermes stop clears the active turn AND its server-side queue. Do not
        // accept another local send while that destructive RPC is unresolved.
        guard let activeID, botStopsInFlight[activeID] == nil else { return }
        if pendingHomeModelConfirmation?.conversationID == activeID { return }
        if isSending {
            // A busy bot still takes a message — Hermes folds it into the task
            // it is running or queues it — so the chat following that bot lets
            // go of the older reply and follows this one. Refusing it here
            // dropped the message without a word. Anywhere else a second send
            // would race the first.
            // Alice's own chat still waits its turn: a second prompt there would
            // queue behind the first with nobody following it.
            guard activeBotTurns[activeID] != nil,
                  activeConversation?.isCanonicalBotChat == true
            else { return }
            releaseBotTurn(activeID, stopped: false)
        }

        // Management commands stay on-device. Hermes slash commands (`/reasoning`,
        // `/status`, `/compress`…) run through `slash.exec` on this chat's
        // session. Everything else is a model turn.
        if handleChatControlIfNeeded(text) { return }
        if handleHermesSlashIfNeeded(text) { return }

        // Dropped since the last message? Pick it back up rather than making
        // somebody go to Connect and press a button for a connection that is
        // still perfectly good.
        // Alice's own chat and the agents' chats run over the dashboard's
        // socket; the gateway is only needed by the chats that stream through
        // it. Waiting on it for a dashboard chat held a message — the voice
        // mode's first one — until a reconnect that never came.
        let overDashboard = dashboardReady && conversations.contains {
            $0.id == activeID && ($0.isHomeSessionChat || $0.isCanonicalBotChat)
        }
        guard isConnected || overDashboard else {
            Task { [weak self] in
                await self?.restoreConnection()
                if self?.isConnected == true { self?.send() }
            }
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == activeID })
        else { return }
        let conversationID = conversations[index].id

        // Detect bot conversation, bot mention or channel bot
        var invokedBot: String?
        if let directBot = conversations[index].botName, !directBot.isEmpty {
            invokedBot = directBot
        } else {
            var candidates: [(slug: String, mention: String)] = []
            for bot in cachedBots {
                let current = botCurrentName(for: bot)
                candidates.append((bot.name, current))
                candidates.append((bot.name, bot.displayName))
                candidates.append((bot.name, bot.name))
            }
            for (key, custom) in botCustomNames {
                candidates.append((key, custom))
            }
            for name in knownBotNames {
                candidates.append((name, botCurrentName(for: name)))
                candidates.append((name, name))
            }
            var seen = Set<String>()
            let uniqueCandidates = candidates.filter { seen.insert("\($0.slug)|\($0.mention)").inserted }
                .sorted { $0.mention.count > $1.mention.count }

            for item in uniqueCandidates {
                let pattern = "@" + item.mention
                if let range = text.range(of: pattern, options: .caseInsensitive) {
                    let isStart = range.lowerBound == text.startIndex ||
                        text[text.index(before: range.lowerBound)].isWhitespace
                    if isStart {
                        invokedBot = item.slug
                        break
                    }
                }
            }

            if invokedBot == nil {
                for mention in messageMentions.sorted(by: { $0.display.count > $1.display.count }) {
                    if mention.range(in: text) != nil {
                        invokedBot = mention.slug
                        break
                    }
                }
            }

            if invokedBot == nil {
                let tokens = text.components(separatedBy: .whitespacesAndNewlines)
                if let mentionToken = tokens.first(where: { $0.hasPrefix("@") && $0.count > 1 }) {
                    let candidate = String(mentionToken.dropFirst()).trimmingCharacters(in: .punctuationCharacters)
                    if !candidate.isEmpty {
                        if let bot = cachedBots.first(where: {
                            $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame ||
                            $0.displayName.localizedCaseInsensitiveCompare(candidate) == .orderedSame ||
                            botCurrentName(for: $0).localizedCaseInsensitiveCompare(candidate) == .orderedSame
                        }) {
                            invokedBot = bot.name
                        } else if let custom = botCustomNames.first(where: { $0.value.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
                            invokedBot = custom.key
                        } else if knownBotNames.contains(where: { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
                            invokedBot = candidate.lowercased()
                        } else {
                            // An unknown mention still routes to an agent, but
                            // by its slug — "@My Bot" means profile `my-bot`,
                            // not the display text verbatim.
                            let slug = AgentProfileID.slugify(candidate)
                            if !slug.isEmpty { invokedBot = slug }
                        }
                    }
                } else if let channelBots = conversations[index].channelBots, !channelBots.isEmpty {
                    invokedBot = channelBots.first
                }
            }
        }

        // A team speaks to its bots. With none to route to there is nobody to
        // talk to, and it must never fall through to Alice.
        if conversations[index].isChannel == true, invokedBot == nil { return }

        guard let route = ChatTurnRoute.resolve(
            in: conversations[index], invokedBot: invokedBot,
            dashboardReady: dashboardReady, updatingHermes: HermesSelfUpdateIntent.matches(text)
        ) else { return }

        var mentionText: String?
        if case .agent(let profile, true) = route {
            let selected = messageMentions.first(where: { $0.slug == profile })
            mentionText = Self.withoutMention(
                text, of: profile, names: mentionNames(for: profile), selectedRange: selected?.utf16Range
            )
            guard mentionText?.isEmpty == false || !draftAttachments.isEmpty else { return }
        }

        let attachments = draftAttachments
        let selectedMentionRanges = messageMentions.map(\.utf16Range)
        draft = ""
        draftMentions = []
        draftAttachments = []
        sendingConversations.insert(conversationID)
        latencyStartedAt[conversationID] = Date()
        latencyLogged[conversationID] = []
        markLatency(conversationID, phase: "send")

        let user = Message(
            id: UUID().uuidString, role: .user, content: text, createdAt: Date(),
            attachments: attachments,
            mentionProfile: mentionText == nil ? nil : invokedBot,
            selectedMentionRanges: selectedMentionRanges
        )
        let replyID = UUID().uuidString
        conversations[index].messages.append(user)
        conversations[index].messages.append(
            Message(
                id: replyID, role: .assistant, content: "",
                createdAt: Date(), pending: true, botName: invokedBot,
                replyToMessageID: user.id,
                mentionProfile: mentionText == nil ? nil : invokedBot
            )
        )
        // Named by its subject, not its first forty keystrokes; a bare
        // greeting names nothing and the chat waits for the real question.
        if ConversationTitle.isPlaceholder(conversations[index].title),
           let title = ConversationTitle.from(text, attachmentName: attachments.first?.name) {
            conversations[index].title = title
        }
        conversations[index].updatedAt = Date()

        switch route {
        case .agent(let profile, let mention):
            streamTasks[conversationID] = Task { [weak self] in
                await self?.sendToBotChat(
                    profile: profile,
                    conversationID: conversationID,
                    replyID: replyID,
                    text: mentionText ?? text,
                    attachments: attachments,
                    mention: mention
                )
            }
        case .home:
            let earlier = conversations[index].messages.filter {
                $0.id != user.id && $0.id != replyID
            }
            streamTasks[conversationID] = Task { [weak self] in
                await self?.sendToBotChat(
                    profile: nil,
                    conversationID: conversationID,
                    replyID: replyID,
                    text: text,
                    attachments: attachments,
                    earlier: earlier
                )
            }
        case .gateway:
            streamThroughGateway(
                conversationID: conversationID, replyID: replyID, invokedBot: nil
            )
        }
    }

    /// A drawer title with each `@agent` invocation in that agent's colour.
    /// Titles saved before `@` was kept are restored from the first message.
    func titleStyled(for conversation: Conversation) -> AttributedString {
        let names = invokedTitleNames(in: conversation)
        return titleStyled(
            ConversationTitle.strippingAtMentions(in: conversation.title, invoked: names),
            names: names
        )
    }

    /// The title as the drawer should say it: the invoked agent's name, no `@`.
    func displayTitle(for conversation: Conversation) -> String {
        ConversationTitle.strippingAtMentions(
            in: conversation.title, invoked: invokedTitleNames(in: conversation)
        )
    }

    /// Agents the first ask actually invoked, so a title that merely contains
    /// a bot's name is not painted as a mention.
    private func invokedTitleNames(in conversation: Conversation) -> [(display: String, slug: String)] {
        let first = conversation.messages.first(where: { $0.role == .user })
        let fallback = conversation.messages.first(where: { $0.mentionProfile != nil })?.mentionProfile
        // The drawer asks for every row it draws, on every redraw. Read again
        // only when the first ask or the roster of names changed.
        var key = Hasher()
        key.combine(first?.id)
        key.combine(first?.content)
        key.combine(first?.mentionProfile)
        key.combine(fallback)
        key.combine(mentionNameList().key)
        let fingerprint = key.finalize()
        if let hit = invokedTitleNamesCache[conversation.id], hit.key == fingerprint { return hit.names }
        let names = computeInvokedTitleNames(first: first, fallback: fallback)
        invokedTitleNamesCache[conversation.id] = (fingerprint, names)
        return names
    }

    @ObservationIgnored private var invokedTitleNamesCache:
        [String: (key: Int, names: [(display: String, slug: String)])] = [:]

    private func computeInvokedTitleNames(
        first: Message?, fallback: String?
    ) -> [(display: String, slug: String)] {
        var slugs = Set<String>()
        if let content = first?.content {
            slugs.formUnion(mentions(in: content).compactMap { range, slug in
                content[range].hasPrefix("@") ? slug : nil
            })
        }
        if let profile = first?.mentionProfile { slugs.insert(profile) }
        if slugs.isEmpty, let profile = fallback {
            slugs.insert(profile)
        }
        return slugs.sorted().flatMap { slug in mentionNames(for: slug).map { ($0, slug) } }
    }

    /// A drawer title with each `@agent` invocation in that agent's colour.
    /// A bare name is not an invocation and is left alone.
    func titleStyled(_ title: String, names: [(display: String, slug: String)]) -> AttributedString {
        var styled = AttributedString(title)
        for (range, slug) in ConversationTitle.agentNameRanges(in: title, names: names) {
            guard let lower = AttributedString.Index(range.lowerBound, within: styled),
                  let upper = AttributedString.Index(range.upperBound, within: styled)
            else { continue }
            styled[lower..<upper].foregroundColor = mark(for: slug).color
            styled[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return styled
    }

    /// A named agent is bold in a sent message, with the same text colour as
    /// everything around it.
    func mentionStyled(
        _ text: String, bareSlugs: [String] = [], selectedRanges: [NSRange] = []
    ) -> AttributedString {
        var styled = AttributedString(text)
        styled.font = .body
        var ranges = mentions(in: text).map(\.0)
        for selected in selectedRanges {
            if let range = Range(selected, in: text),
               ConversationTitle.isWord(range, in: text),
               !ranges.contains(where: { $0.overlaps(range) }) {
                ranges.append(range)
            }
        }
        // Archives made before selected ranges were stored can only identify
        // the routed profile. Emphasize one bare occurrence, not every repeat.
        if selectedRanges.isEmpty, ranges.isEmpty, !bareSlugs.isEmpty {
            for slug in bareSlugs {
                if let range = mentions(in: text, bareSlugs: [slug]).first(where: {
                    !text[$0.0].hasPrefix("@") && $0.1 == slug
                })?.0 {
                    ranges.append(range)
                }
            }
        }
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: styled),
                  let upper = AttributedString.Index(range.upperBound, within: styled)
            else { continue }
            styled[lower..<upper].font = .body.weight(.bold)
        }
        return styled
    }

    /// A draft after one character was deleted from the end of an `@agent` in
    /// it: the whole name goes, as a mention is one thing, not letters.
    func draftDeletingMention(old: String, new: String) -> String? {
        guard old.count == new.count + 1 else { return nil }
        for range in draftMentionRanges(in: old) {
            var trimmed = old
            trimmed.remove(at: old.index(before: range.upperBound))
            if trimmed == new {
                var whole = old
                whole.removeSubrange(range)
                return whole
            }
        }
        return nil
    }

    /// Each `@agent` in a text. A bare name counts only when it was picked
    /// from the `@` menu (`bareSlugs`); typing the name by hand does not.
    func mentions(in text: String, bareSlugs: [String] = []) -> [(Range<String.Index>, String)] {
        // Without an `@` only a picked bare name could match.
        if bareSlugs.isEmpty, !text.contains("@") { return [] }
        let names = mentionNameList().names
        let allowedBare = Set(bareSlugs)
        var taken: [Range<String.Index>] = []
        var found: [(Range<String.Index>, String)] = []
        for (name, slug) in names {
            var needles = ["@" + name]
            if allowedBare.contains(slug) { needles.append(name) }
            for needle in needles {
                var from = text.startIndex
                while let range = text.range(of: needle, options: .caseInsensitive, range: from..<text.endIndex) {
                    from = range.upperBound
                    guard ConversationTitle.isWord(range, in: text),
                          !taken.contains(where: { $0.overlaps(range) })
                    else { continue }
                    taken.append(range)
                    found.append((range, slug))
                }
            }
        }
        return found
    }

    /// Explicit @mentions plus only the bare occurrences actually picked in
    /// this draft. Other uses of an agent's name stay ordinary text.
    func draftMentionRanges(in text: String) -> [Range<String.Index>] {
        var ranges = mentions(in: text).map(\.0)
        for mention in draftMentions {
            if let range = mention.range(in: text),
               !ranges.contains(where: { $0.overlaps(range) }) {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Every name an agent can be mentioned by, longest first, built once per
    /// roster rather than on every call: `mentions` ran for each drawer row
    /// on each redraw and rebuilt it every time.
    private func mentionNameList() -> (key: Int, names: [(String, String)]) {
        var slugs = Set(cachedBots.map(\.name))
        slugs.formUnion(knownBotNames)
        slugs.formUnion(botCustomNames.keys)
        var hasher = Hasher()
        for slug in slugs.sorted() { hasher.combine(slug) }
        for bot in cachedBots { hasher.combine(bot.name); hasher.combine(bot.displayName); hasher.combine(bot.aliceRole) }
        hasher.combine(botCustomNames)
        hasher.combine(botMetadataIsRemote)
        let key = hasher.finalize()
        if let cached = mentionNameListCache, cached.key == key { return cached }
        let names = slugs.flatMap { slug in mentionNames(for: slug).map { ($0, slug) } }
            .sorted { ($0.0.count, $0.0, $0.1) > ($1.0.count, $1.0, $1.1) }
        mentionNameListCache = (key, names)
        return (key, names)
    }

    @ObservationIgnored private var mentionNameListCache: (key: Int, names: [(String, String)])?

    func rememberDraftMention(display: String, slug: String, location: Int) {
        let mention = DraftMention(display: display, slug: slug, location: location)
        if mention.range(in: draft) != nil { draftMentions.append(mention) }
    }

    /// Every name an agent can be mentioned by.
    private func mentionNames(for slug: String) -> [String] {
        var names = [slug, botCurrentName(for: slug)]
        if let bot = cachedBots.first(where: { $0.name == slug }) { names.append(bot.displayName) }
        if let custom = botCustomNames[slug] { names.append(custom) }
        return names.filter { !$0.isEmpty }
    }

    /// The message as the agent would have been sent it in its own chat: the
    /// first `@name` or bare name for it taken out, and the space it leaves tidied.
    nonisolated static func withoutMention(
        _ text: String, of slug: String, names: [String], selectedRange: NSRange? = nil
    ) -> String {
        let orderedNames = Set(names + [slug]).sorted(by: { $0.count > $1.count })
        for name in orderedNames {
            if let range = ConversationTitle.firstWord(of: "@" + name, in: text) {
                return textRemovingMention(text, at: range)
            }
        }
        if let selectedRange, let range = Range(selectedRange, in: text),
           ConversationTitle.isWord(range, in: text),
           Set(names + [slug]).contains(where: {
               String(text[range]).caseInsensitiveCompare($0) == .orderedSame
           }) {
            return textRemovingMention(text, at: range)
        }
        for name in orderedNames {
            if let range = ConversationTitle.firstWord(of: name, in: text) {
                return textRemovingMention(text, at: range)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func textRemovingMention(
        _ text: String, at range: Range<String.Index>
    ) -> String {
        var rest = text
        rest.removeSubrange(range)
        if range.lowerBound < rest.endIndex,
           [",", ":"].contains(rest[range.lowerBound]) {
            rest.remove(at: range.lowerBound)
        }
        return rest
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A turn as a gateway run, with the conversation sent along with it.
    private func streamThroughGateway(
        conversationID: String, replyID: String, invokedBot: String?
    ) {
        // Also fence retries/edits using older call paths. A gateway request
        // cannot load a named profile by borrowing its visible name.
        guard invokedBot == nil else {
            fail(replyID, conversationID: conversationID,
                 message: "Connect the Hermes dashboard to talk to this agent.", limit: nil)
            finish(replyID, conversationID: conversationID)
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID })
        else { return }

        // Only the newest turn that has attachments sends them. Repeating
        // every image on every request is what turns a long conversation into
        // a payload the provider refuses, and the earlier ones have already
        // been read once.
        let history = conversations[index].messages
            .filter { !$0.pending && $0.error == nil }
        let newestWithAttachments = history.lastIndex { !$0.attachments.isEmpty }
        let turns = history.enumerated().map { offset, message in
            HermesClient.Turn(
                role: message.role.rawValue,
                content: Self.content(
                    of: message, includeAttachments: offset == newestWithAttachments
                )
            )
        }

        let model = selectedModel
        let provider = Self.provider(for: model, among: models, chosen: selectedProvider)

        let preferRuns = manifest?.supportsRuns ?? true
        let useRunIdempotency = manifest?.supportsRunIdempotency ?? false
        streamTasks[conversationID] = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.stream(
                messages: turns,
                model: model,
                provider: provider,
                profile: nil,
                conversationID: conversationID,
                preferRuns: preferRuns,
                runIdempotency: useRunIdempotency
            )
            do {
                for try await event in stream {
                    self.apply(event, to: replyID, conversationID: conversationID)
                }
            } catch {
                self.fail(
                    replyID,
                    conversationID: conversationID,
                    message: PlainWords.describe(error, doing: "get the reply"),
                    limit: nil
                )
            }
            self.finish(replyID, conversationID: conversationID)
        }
    }

    // MARK: - Editing a sent message

    /// The sent message the composer is rewriting. Sending replaces that
    /// exchange instead of adding a new one.
    var editingMessageID: String?

    /// Only the latest message can be rewritten: Hermes rewinds the last
    /// exchange, and nothing before it, so an earlier one could only be
    /// changed on this phone while the agent kept the original.
    ///
    /// Decided by the message alone, not by whether a reply is streaming or a
    /// refresh is under way: the menu re-reads this while it is open, and Edit
    /// vanished from under the finger when either changed a second later. A
    /// refresh also swaps a sent message for Hermes' copy under Hermes' id.
    func canEdit(_ message: Message) -> Bool {
        guard message.role == .user, !message.content.isEmpty, !activeIsRecoveredHistory,
              let chat = shownConversation,
              let last = chat.messages.last(where: { $0.role == .user })
        else { return false }
        return last.id == message.id
            || (message.remoteID != nil && last.remoteID == message.remoteID)
            || (last.content == message.content
                && abs(last.createdAt.timeIntervalSince(message.createdAt)) < 120)
    }

    func beginEditing(_ message: Message) {
        guard canEdit(message),
              let last = conversations.first(where: { $0.id == activeID })?
                .messages.last(where: { $0.role == .user })
        else { return }
        editingMessageID = last.id
        draft = message.content
    }

    func cancelEditing() {
        editingMessageID = nil
        draft = ""
    }

    /// Replaces the edited exchange: the reply goes the way Try Again takes it,
    /// with the new words. Returns false when there was nothing to replace, so
    /// the text is sent as it is.
    private func sendEdit(of messageID: String, text: String) -> Bool {
        // A reply still coming belongs to the exchange being replaced; it has
        // to end first. The edit is kept meanwhile.
        if isSending {
            editingMessageID = messageID
            return true
        }
        guard !text.isEmpty,
              let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == messageID }),
              conversations[chat].messages[index].role == .user,
              !conversations[chat].messages[(index + 1)...].contains(where: { $0.role == .user })
        else { return false }
        guard let reply = conversations[chat].messages[(index + 1)...]
            .first(where: { $0.role == .assistant })
        else {
            // Never answered: the old words go and the new ones are sent.
            conversations[chat].messages.remove(at: index)
            persistConversations()
            return false
        }
        draft = ""
        retry(reply.id, text: text)
        return true
    }

    /// Runs the last exchange again.
    ///
    /// Drops the reply and everything after it, then resends the user turn that
    /// prompted it — so a failed or unsatisfying answer is replaced rather than
    /// piled on top of, and the model sees the same history it saw the first
    /// time.
    func retry(_ messageID: String, text: String? = nil) {
        guard !isSending,
              let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == messageID }),
              conversations[chat].messages[index].role == .assistant
        else { return }

        let priorUser = conversations[chat].messages[..<index]
            .last { $0.role == .user }
        guard let priorUser else { return }

        // A bot chat's history lives in Hermes, which still holds the failed
        // exchange. Resending alone put the same message there twice, and the
        // next refresh showed it twice. Rewind it there first.
        if conversations[chat].isCanonicalBotChat,
           let profile = conversations[chat].routedBotName {
            guard !botRetryInFlight else { return }
            botRetryInFlight = true
            let conversationID = conversations[chat].id
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let source = await self.botChatSource() else {
                        throw HermesRPCClient.Failure(reason: "Hermes is not connected.")
                    }
                    let target = try await self.resolveBotChat(profile, source: source)
                    guard let current = self.conversations.first(where: { $0.id == conversationID })
                    else { throw HermesRPCClient.Failure(reason: "This chat is no longer open.") }
                    if let turnID = try await self.remoteTurnIDForRetry(
                        source: source,
                        profile: profile,
                        sessionID: target.resolvedID,
                        conversation: current,
                        replyID: messageID,
                        origin: priorUser
                    ) {
                        _ = try await source.rewindForRetry(
                            profile: profile,
                            sessionID: target.resolvedID,
                            turnID: turnID,
                            text: priorUser.remoteMatchContent ?? priorUser.content
                        )
                    }
                } catch {
                    self.botRetryInFlight = false
                    guard self.activeID == conversationID else { return }
                    // An edit that could not be applied keeps its new words.
                    if let text, self.draft.isEmpty { self.draft = text }
                    self.fail(
                        messageID,
                        conversationID: conversationID,
                        message: "Couldn’t retry safely without risking a duplicate. "
                            + PlainWords.describe(error, doing: "retry the message"),
                        limit: nil
                    )
                    return
                }
                self.botRetryInFlight = false
                guard self.activeID == conversationID, !self.isSending else { return }
                self.resend(priorUser, replacing: messageID, in: conversationID, text: text)
            }
            return
        }
        if conversations[chat].isHomeSessionChat {
            // Hermes still holds the exchange being replaced. A session that
            // opens with the conversation as it now stands does not.
            conversations[chat].hermesSessionID = nil
        }
        resend(priorUser, replacing: messageID, in: conversations[chat].id, text: text)
    }

    /// A bot chat's Retry is waiting on Hermes to rewind the exchange.
    private var botRetryInFlight = false

    /// Resolves the local user bubble to Hermes' durable row before `/retry`.
    /// The existing merge owns this correlation and accounts for timestamps,
    /// attachment refs and coalesced queued prompts; comparing text alone can
    /// erase an earlier, identical message when the latest send never arrived.
    private func remoteTurnIDForRetry(
        source: WebSocketBotChatSource,
        profile: String,
        sessionID: String,
        conversation: Conversation,
        replyID: String,
        origin: Message
    ) async throws -> String? {
        let remote = try await source.transcript(profile: profile, sessionID: sessionID)
        return try Self.retryTurnID(
            in: remote,
            conversation: conversation,
            replyID: replyID,
            origin: origin,
            profile: profile
        )
    }

    nonisolated static func retryTurnID(
        in remote: [BotChatTurn],
        conversation: Conversation,
        replyID: String,
        origin: Message,
        profile: String
    ) throws -> String? {
        let merged = BotChatSync.merge(remote, into: conversation.messages, botName: profile)
        guard let localReply = conversation.messages.first(where: { $0.id == replyID }) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes' chat changed before Alice could identify this turn."
            )
        }

        if let reply = merged.first(where: { $0.id == replyID }),
           let anchor = reply.replyToMessageID,
           let remoteOrigin = merged.first(where: {
               $0.role == .user && $0.remoteID == anchor
           }) {
            return remoteOrigin.remoteID
        }

        // A refresh can replace the local failed reply with Hermes' persisted
        // copy. In that case the local id is gone, but the matched assistant
        // row still identifies the user row directly before it.
        let remoteReplyID: String?
        if let exact = localReply.remoteID {
            remoteReplyID = exact
        } else {
            let represented = Set(conversation.messages.compactMap(\.remoteID))
            let earliest = localReply.createdAt.addingTimeInterval(-BotChatSync.copyClockSlack)
            let latest = localReply.createdAt.addingTimeInterval(BotChatSync.copyWindow)
            let text = localReply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates = remote.filter {
                $0.role == .assistant
                    && !represented.contains($0.id)
                    && $0.createdAt >= earliest
                    && $0.createdAt <= latest
                    && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }
            guard candidates.count < 2 else {
                throw HermesRPCClient.Failure(
                    reason: "Hermes has several identical replies that Alice cannot identify safely."
                )
            }
            remoteReplyID = candidates.first?.id
        }
        if let remoteReplyID,
           let replyIndex = remote.firstIndex(where: {
               $0.id == remoteReplyID && $0.role == .assistant
           }),
           let remoteOrigin = remote[..<replyIndex].last(where: { $0.role == .user }) {
            return remoteOrigin.id
        }

        guard merged.contains(where: { $0.id == replyID }) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes' chat changed before Alice could identify this turn."
            )
        }

        // No correlated row means Hermes did not persist this send, so there
        // is normally nothing to rewind. If an unclaimed identical row exists,
        // however, its identity is ambiguous and resending would be unsafe.
        let expected = (origin.remoteMatchContent ?? origin.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let matching = remote.last(where: {
            $0.role == .user
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }) {
            let alreadyRepresented = conversation.messages.contains {
                $0.role == .user && $0.remoteID == matching.id
            }
            if !alreadyRepresented {
                throw HermesRPCClient.Failure(
                    reason: "Hermes has an identical message that Alice cannot identify safely."
                )
            }
        }
        return nil
    }

    private func resend(
        _ priorUser: Message, replacing replyID: String, in conversationID: String,
        text: String? = nil
    ) {
        guard let chat = conversations.firstIndex(where: { $0.id == conversationID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == replyID })
        else { return }
        conversations[chat].messages.removeSubrange(index...)
        if let userIndex = conversations[chat].messages.firstIndex(where: { $0.id == priorUser.id }) {
            conversations[chat].messages.remove(at: userIndex)
        }
        draft = text ?? priorUser.content
        send()
    }

    func stop() {
        // A bot chat's run lives on the agent, not in this task. `interrupt`
        // also clears Hermes' queued_prompt(s), so stopping is transactional:
        // keep listening until the backend confirms it and reject a new local
        // send meanwhile. The old fire-and-forget path painted "Stopped." even
        // when the RPC failed, then a new send could be erased by the late stop.
        guard let activeID else { return }
        if let index = conversations.firstIndex(where: { $0.id == activeID }),
           let turn = activeBotTurns[activeID],
           let sessionID = turn.storedSessionID ?? conversations[index].hermesSessionID,
           turn.mentionProfile != nil
            || conversations[index].isCanonicalBotChat || conversations[index].isHomeSessionChat {
            // A turn sent to an agent named with `@` stops in that agent's session.
            let profile = turn.mentionProfile ?? conversations[index].routedBotName
            guard botStopsInFlight[activeID] == nil else { return }
            let token = turn.token
            botStopsInFlight[activeID] = token
            setDeliveryNote(
                "Stopping…", on: turn.replyID, conversationID: turn.conversationID
            )

            // A turn with no disposition has not received prompt.submit's ACK
            // yet. Latch the intent; sendToBotChat fulfils it immediately after
            // that ACK so stop can never overtake the submit it is meant to end.
            guard turn.disposition != nil else { return }
            let liveSessionID = botLiveSessionIDs[turn.conversationID]
            Task { [weak self] in
                guard let self else { return }
                _ = await self.interruptBotTurn(
                    conversationID: activeID,
                    token: token, profile: profile, storedSessionID: sessionID,
                    liveSessionID: liveSessionID, source: nil
                )
            }
            return
        }

        streamTasks[activeID]?.cancel()
        streamTasks[activeID] = nil
        sendingConversations.remove(activeID)
    }

    // MARK: - Following a bot's reply

    /// The bot reply this device is following. The token tells a watcher
    /// that has been let go — stopped, or superseded by a newer message — that
    /// the reply is no longer its to settle.
    private struct ActiveBotTurn {
        let token: UUID
        let conversationID: String
        var replyID: String
        var disposition: BotChatSubmission.Disposition? = nil
        /// The agent and stored session the turn went to, when that is not the
        /// chat's own — an agent named with `@` in another chat.
        var mentionProfile: String? = nil
        var storedSessionID: String? = nil
    }

    private enum BotTurnEnding {
        case outcome, failed, stopped, lostTouch
        case endedUnseen(BotTurnFailure?)
    }

    /// The reply each chat is following, keyed by conversation.
    private var activeBotTurns: [String: ActiveBotTurn] = [:]
    /// A confirmed stop is destructive to Hermes' whole server-side queue.
    /// While its RPC is in flight, another send in that chat must stay in the
    /// composer. Keyed by conversation.
    private var botStopsInFlight: [String: UUID] = [:]
    /// The runtime id each bot chat was last reached under, which is what
    /// `session.interrupt` needs. It dies with the socket; `interrupt` recovers.
    private var botLiveSessionIDs: [String: String] = [:]

    /// The canonical chat each bot resolved to, and when. Resolving is a
    /// `profiles.list` of every profile with its sessions, and it ran before
    /// every send, every refresh and every retry — one whole round trip the
    /// person waited through with nothing on screen. The answer barely
    /// changes: only a clear or a compression moves the chat, and a stale
    /// row answers "not found" on resume, which is when it is looked up again.
    private var canonicalBotChats: [String: (chat: CanonicalBotChat, at: Date)] = [:]
    private static let canonicalBotChatLifetime: TimeInterval = 45

    /// A bot's canonical chat, from the cache when it is fresh.
    func resolveBotChat(
        _ profile: String, source: WebSocketBotChatSource, fresh: Bool = false
    ) async throws -> CanonicalBotChat {
        if !fresh, let cached = canonicalBotChats[profile],
           Date().timeIntervalSince(cached.at) < Self.canonicalBotChatLifetime {
            return cached.chat
        }
        let chat = try await BotChatSync(source: source).resolve(profile: profile)
        canonicalBotChats[profile] = (chat, Date())
        return chat
    }

    private func forgetCanonicalBotChat(_ profile: String) {
        canonicalBotChats.removeValue(forKey: profile)
    }

    private func track(liveSessionID: String, for conversationID: String) {
        liveBotSessions[liveSessionID] = conversationID
        botLiveSessionIDs[conversationID] = liveSessionID
    }

    /// Completes one latched Stop against the exact Hermes runtime that
    /// accepted the turn. Returns true when there is no watcher left to run.
    @discardableResult
    private func interruptBotTurn(
        conversationID: String,
        token: UUID, profile: String?, storedSessionID: String,
        liveSessionID: String?, source existingSource: WebSocketBotChatSource?
    ) async -> Bool {
        guard botStopsInFlight[conversationID] == token,
              let turn = activeBotTurns[conversationID], turn.token == token
        else { return true }
        let replyID = turn.replyID

        do {
            let source: WebSocketBotChatSource
            if let existingSource {
                source = existingSource
            } else if let connected = await botChatSource() {
                source = connected
            } else {
                throw HermesRPCClient.Failure(reason: "Hermes is not connected.")
            }
            let interrupted = try await source.interrupt(
                profile: profile, storedSessionID: storedSessionID,
                liveSessionID: liveSessionID
            )
            guard botStopsInFlight[conversationID] == token,
                  activeBotTurns[conversationID]?.token == token
            else { return true }
            botStopsInFlight[conversationID] = nil

            if interrupted {
                releaseBotTurn(
                    conversationID, stopped: true, expectedToken: token,
                    stopMessage: "Stopped. Any queued messages were cleared too."
                )
                await refreshBotChat(conversationID)
                return true
            }

            // It may have finished in the race between the tap and the RPC.
            // Re-read canonical truth before deciding what to leave on screen.
            await refreshBotChat(conversationID)
            if messageLocation(replyID, conversationID: conversationID) == nil {
                releaseBotWatcher(conversationID, expectedToken: token)
                return true
            }
            setDeliveryNote(
                "Hermes had already stopped. Checking for its reply…",
                on: replyID, conversationID: conversationID
            )
            return false
        } catch {
            guard botStopsInFlight[conversationID] == token else {
                return activeBotTurns[conversationID]?.token != token
            }
            botStopsInFlight[conversationID] = nil
            guard activeBotTurns[conversationID]?.token == token else { return true }
            setDeliveryNote(
                "Couldn’t stop Hermes. It may still be working.",
                on: replyID, conversationID: conversationID
            )
            return false
        }
    }

    private func setRemoteMatchContent(
        _ content: String, forReply replyID: String, conversationID: String
    ) {
        guard let reply = messageLocation(replyID, conversationID: conversationID),
              let originID = conversations[reply.chat].messages[reply.message].replyToMessageID,
              let origin = conversations[reply.chat].messages.firstIndex(where: { $0.id == originID })
        else { return }
        conversations[reply.chat].messages[origin].remoteMatchContent = content
        persistConversations()
    }

    /// True once Hermes' canonical transcript contains the exact user row this
    /// local assistant placeholder belongs to. For queued sends this is the
    /// only safe point at which the live WebSocket stream becomes ours.
    private func botReplyOriginIsRemote(
        _ replyID: String, conversationID: String
    ) -> Bool {
        guard let reply = messageLocation(replyID, conversationID: conversationID),
              let anchor = conversations[reply.chat].messages[reply.message].replyToMessageID
        else { return false }
        return conversations[reply.chat].messages.contains { message in
            message.role == .user && message.remoteID == anchor
        }
    }

    /// Lets go of the reply being followed and settles it where it stands.
    ///
    /// Stopped, it says so. Superseded by a newer message to the same busy bot,
    /// an empty placeholder goes — Hermes folds that message in or queues it,
    /// and the answer arrives with the newer one — and a partial one is left
    /// for the transcript to complete.
    private func releaseBotTurn(
        _ conversationID: String,
        stopped: Bool, expectedToken: UUID? = nil, stopMessage: String = "Stopped."
    ) {
        guard let turn = activeBotTurns[conversationID],
              expectedToken == nil || turn.token == expectedToken
        else { return }
        activeBotTurns[conversationID] = nil
        if botStopsInFlight[conversationID] == turn.token { botStopsInFlight[conversationID] = nil }
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        sendingConversations.remove(conversationID)
        guard let location = messageLocation(turn.replyID, conversationID: turn.conversationID)
        else { return }
        var reply = conversations[location.chat].messages[location.message]
        reply.settle()
        reply.deliveryNote = nil
        if stopped {
            if reply.content.isEmpty && reply.approval == nil {
                reply.content = stopMessage
                reply.incomplete = true
            }
        } else if reply.content.isEmpty && reply.approval == nil {
            conversations[location.chat].messages.remove(at: location.message)
            persistConversations()
            closeAgentActivity(for: conversationID)
            return
        } else {
            reply.awaitingRemote = true
        }
        conversations[location.chat].messages[location.message] = reply
        persistConversations()
        if stopped || !reply.pending {
            closeAgentActivity(for: conversationID)
        }
    }

    private func releaseBotWatcher(_ conversationID: String, expectedToken: UUID) {
        guard activeBotTurns[conversationID]?.token == expectedToken else { return }
        activeBotTurns[conversationID] = nil
        if botStopsInFlight[conversationID] == expectedToken {
            botStopsInFlight[conversationID] = nil
        }
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        sendingConversations.remove(conversationID)
    }

    private func setDeliveryNote(_ note: String?, on replyID: String, conversationID: String) {
        guard let location = messageLocation(replyID, conversationID: conversationID),
              conversations[location.chat].messages[location.message].deliveryNote != note
        else { return }
        conversations[location.chat].messages[location.message].deliveryNote = note
        persistConversations()
    }

    /// Stops drawing a reply as in progress without calling it a failure.
    private func awaitRemote(_ replyID: String, conversationID: String, note: String?) {
        sendingConversations.remove(conversationID)
        streamTasks[conversationID] = nil
        guard let location = messageLocation(replyID, conversationID: conversationID) else { return }
        conversations[location.chat].messages[location.message].pending = false
        conversations[location.chat].messages[location.message].awaitingRemote = true
        conversations[location.chat].messages[location.message].deliveryNote = note
        persistConversations()
    }

    /// What a reply to a busy bot is waiting on, or nil when a turn began.
    nonisolated static func deliveryNote(
        for disposition: BotChatSubmission.Disposition, label: String
    ) -> String? {
        switch disposition {
        case .started:
            return nil
        case .foldedIn:
            return "\(label) is busy with something else. It will read this before it finishes."
        case .queued:
            return "\(label) is finishing something else. Your message is next."
        }
    }

    nonisolated static func lostTouchNote(label: String) -> String {
        "Lost touch with Hermes. If \(label) is still working, its reply will appear here."
    }

    /// Answers a real Hermes approval request and resumes the same durable run.
    /// The view never receives the gateway key or constructs a control URL.
    func resolveApproval(messageID: String, choice: Message.ApprovalChoice) async {
        guard let location = messageLocation(messageID),
              let approval = conversations[location.chat].messages[location.message].approval,
              approval.resolving != true
        else { return }

        conversations[location.chat].messages[location.message].approval?.resolving = true
        conversations[location.chat].messages[location.message].approval?.error = nil
        persistConversations()

        let conversationID = conversations[location.chat].id
        let profile = conversations[location.chat].messages[location.message].botName
            ?? conversations[location.chat].routedBotName

        // Canonical Bot Chats receive approvals over the dashboard socket, and
        // so does Alice's own chat when it runs there. Their `runID` field
        // holds the request id; do not send it to `/v1/runs`, which is a
        // different server and identity domain.
        if conversations[location.chat].isCanonicalBotChat || approval.viaSocket == true {
            let requestID = approval.requestID ?? approval.runID
            // The session the question came from: an agent asked with `@` in
            // Alice's chat asks from its own session, which this chat does not
            // hold — looking only at the chat's session reported the dashboard
            // as disconnected while it was not.
            let sessionID = botLiveSessionIDs[conversationID]
                ?? activeBotTurns[conversationID]?.storedSessionID
                ?? conversations[location.chat].hermesSessionID
                ?? ""
            guard let source = await botChatSource() else {
                setApprovalFailure(messageID, "The Hermes dashboard is not connected.")
                return
            }
            guard !sessionID.isEmpty || GatewayServerRequests.isServerRequestID(requestID) else {
                setApprovalFailure(messageID, "Hermes no longer holds the session that asked this.")
                return
            }
            do {
                let result = try await source.respondToApproval(
                    sessionID: sessionID,
                    requestID: requestID,
                    choice: choice.rawValue
                )
                guard LiveEvents.didResolve(result) else {
                    clearApproval(messageID, continueRunning: true)
                    markRequestGone(matching: requestID)
                    await refreshBotChat(conversationID)
                    return
                }
                clearApproval(messageID, continueRunning: true)
                settleRequest(matching: requestID, summary: "You answered this.")
                return
            } catch {
                setApprovalFailure(messageID, PlainWords.describe(error, doing: "send your answer"))
                return
            }
        }

        // Ordinary chat runs use the gateway HTTP run protocol. Hermes' 2xx
        // body must report a positive resolution count; the client validates
        // that before this branch is allowed to clear the card.
        do {
            _ = try await client.respondToRunApproval(
                runID: approval.runID,
                requestID: approval.requestID,
                choice: choice,
                profile: profile
            )
            clearApproval(messageID, continueRunning: true)
            settleGatewayRun(matching: approval.runID, summary: "You answered this.")

            // A normal live run already has a stream waiting for this response.
            // If the app was relaunched or SSE had died, reattach explicitly.
            if streamTasks[conversationID] == nil {
                resumeRun(
                    runID: approval.runID,
                    replyID: messageID,
                    conversationID: conversationID,
                    profile: profile
                )
            }
        } catch {
            setApprovalFailure(messageID, PlainWords.describe(error, doing: "send your answer"))
        }
    }

    private func clearApproval(_ messageID: String, continueRunning: Bool) {
        guard let refreshed = messageLocation(messageID) else { return }
        conversations[refreshed.chat].messages[refreshed.message].approval = nil
        if continueRunning {
            conversations[refreshed.chat].messages[refreshed.message].runStatus = .running
            conversations[refreshed.chat].messages[refreshed.message].pending = true
        }
        persistConversations()
    }

    private func setApprovalFailure(_ messageID: String, _ message: String) {
        guard let refreshed = messageLocation(messageID) else { return }
        conversations[refreshed.chat].messages[refreshed.message].approval?.resolving = false
        conversations[refreshed.chat].messages[refreshed.message].approval?.error = message
        persistConversations()
    }

    private func resumeRun(
        runID: String,
        replyID: String,
        conversationID: String,
        profile: String?
    ) {
        guard streamTasks[conversationID] == nil else { return }
        sendingConversations.insert(conversationID)
        streamTasks[conversationID] = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.resumeRun(
                runID: runID,
                profile: profile,
                conversationID: conversationID
            )
            do {
                for try await event in stream {
                    self.apply(event, to: replyID, conversationID: conversationID)
                }
            } catch {
                self.fail(
                    replyID,
                    conversationID: conversationID,
                    message: PlainWords.describe(error, doing: "get the reply"),
                    limit: nil
                )
            }
            self.finish(replyID, conversationID: conversationID)
        }
    }

    private struct PendingStreamText {
        var conversationID: String
        var text: String
    }

    private func scheduleStreamFlush() {
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            self.streamFlush = nil
            guard !self.pendingStreamText.isEmpty else { return }
            self.flushStreamedText()
            if !self.pendingStreamText.isEmpty { self.scheduleStreamFlush() }
        }
    }

    /// Writes every held token into its reply. Called when a turn ends and
    /// when the app leaves, so the last characters are not still in the buffer.
    private func flushStreamedText() {
        let batch = pendingStreamText
        pendingStreamText.removeAll(keepingCapacity: true)
        for (id, pending) in batch {
            write(pending, into: id)
        }
    }

    /// One reply's held tokens, before anything else touches that reply.
    ///
    /// A turn's final text arrived while the last tokens were still held:
    /// the final text was taken as the reply, and the held tokens were then
    /// added after it — the reply ended with its last sentence twice.
    private func flushStreamedText(for id: String) {
        guard let pending = pendingStreamText.removeValue(forKey: id) else { return }
        write(pending, into: id)
    }

    private func write(_ pending: PendingStreamText, into id: String) {
        guard let location = messageLocation(id, conversationID: pending.conversationID) else { return }
        // A reply that has already ended holds its final text: tokens still
        // waiting for it are already in there.
        guard conversations[location.chat].messages[location.message].pending else { return }
        conversations[location.chat].messages[location.message].content += pending.text
    }

    private func apply(
        _ event: ChatEvent,
        to id: String,
        conversationID: String,
        approvalTransport: AliceEvent.Transport = .gatewayRun,
        approvalSessionID: String? = nil,
        approvalSessionKey: String? = nil
    ) {
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        markLatency(conversationID, phase: "firstEvent")
        if case .delta = event {} else { flushStreamedText(for: id) }
        let chat = location.chat
        let index = location.message
        let eventProfile = conversations[chat].messages[index].botName
            ?? conversations[chat].routedBotName
        let eventLabel = eventProfile.map { botCurrentName(for: $0) } ?? "Alice"

        switch event {
        case let .status(text):
            conversations[chat].messages[index].lastStatus = text

        case let .delta(text):
            // Held and drawn together. One character at a time rebuilt the
            // whole transcript, and a long reply left the phone unable to
            // take a tap until the stream slowed down. The first token of a
            // quiet stretch is drawn at once; the rest of that stretch lands
            // together.
            var pending = pendingStreamText[id] ?? PendingStreamText(conversationID: conversationID, text: "")
            pending.text += text
            pendingStreamText[id] = pending
            if streamFlush == nil {
                flushStreamedText()
                scheduleStreamFlush()
            }

        case let .interim(text):
            if TurnNarration.isDuplicate(text, of: conversations[chat].messages[index].content) {
                return
            }
            let replyTo = conversations[chat].messages[index].replyToMessageID
            if conversations[chat].messages.contains(where: { other in
                other.id != id && other.interim && other.replyToMessageID == replyTo
                    && TurnNarration.isDuplicate(text, of: other.content)
            }) {
                return
            }
            if conversations[chat].messages[index].content
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conversations[chat].messages[index].content = text
            }
            let next = sealOpenNarration(replyID: id, conversationID: conversationID)
            if next != id, var turn = activeBotTurns[conversationID], turn.replyID == id {
                turn.replyID = next
                activeBotTurns[conversationID] = turn
            }

        case let .tool(toolID, name, status, detail):
            var tools = conversations[chat].messages[index].tools
            if let existing = tools.firstIndex(where: { $0.id == toolID }) {
                tools[existing].status = status
                if let detail { tools[existing].detail = detail }
            } else {
                tools.append(.init(id: toolID, name: name, status: status, detail: detail))
            }
            conversations[chat].messages[index].tools = tools

        case let .reasoning(text, block):
            var reasoning = conversations[chat].messages[index].reasoning ?? ""
            if block {
                // A whole block: once, even when its pieces already streamed.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !reasoning.contains(trimmed) {
                    reasoning += (reasoning.isEmpty ? "" : "\n\n") + trimmed
                }
            } else {
                reasoning += text
            }
            conversations[chat].messages[index].reasoning = reasoning

        case let .plan(change):
            // One plan per task, on its newest reply: narration sealed into
            // bubbles earlier in the task gives it up.
            let replyTo = conversations[chat].messages[index].replyToMessageID
            var current = conversations[chat].messages[index].plan ?? .empty
            for other in conversations[chat].messages.indices where other != index {
                let sameTask = conversations[chat].messages[other].replyToMessageID == replyTo
                    && conversations[chat].messages[other].role == .assistant
                if sameTask, let earlier = conversations[chat].messages[other].plan {
                    if earlier.revision > current.revision { current = earlier }
                    conversations[chat].messages[other].plan = nil
                }
            }
            if let next = current.applying(change) {
                conversations[chat].messages[index].plan = next
            }

        case let .run(runID, status, output):
            conversations[chat].messages[index].runID = runID
            conversations[chat].messages[index].runStatus = status
            if status != .waitingForApproval {
                conversations[chat].messages[index].approval = nil
            }
            conversations[chat].messages[index].content = Self.replyBody(
                current: conversations[chat].messages[index].content,
                completion: output
            )
            if status.isTerminal {
                conversations[chat].messages[index].settle()
                closeAgentActivity(for: conversationID)
            }
            if status == .waitingForApproval || status.isTerminal || output != nil {
                persistConversations()
            }
            if status == .completed {
                observe(AliceEvent(
                    id: "run:\(runID)", kind: .finished, severity: .informational,
                    profile: eventProfile, title: eventLabel,
                    summary: "This task finished.", occurred: Date(),
                    reference: AliceEvent.Reference(
                        transport: .gatewayRun, runID: runID,
                        profile: eventProfile, conversationID: conversationID
                    )
                ))
            }

        case let .approval(approval):
            conversations[chat].messages[index].runID = approval.runID
            conversations[chat].messages[index].runStatus = .waitingForApproval
            conversations[chat].messages[index].approval = approval
            conversations[chat].messages[index].pending = true
            persistConversations()
            observe(Self.approvalActivityEvent(
                approval,
                profile: eventProfile,
                label: eventLabel,
                conversationID: conversationID,
                transport: approvalTransport,
                sessionID: approvalSessionID,
                sessionKey: approvalSessionKey
            ))

        case let .failure(message, limit):
            let runID = conversations[chat].messages[index].runID
            fail(
                id,
                conversationID: conversationID,
                message: message,
                limit: limit
            )
            if let runID {
                observe(AliceEvent(
                    id: "run:\(runID)", kind: .finished, severity: .failure,
                    profile: eventProfile, title: eventLabel,
                    summary: "This task stopped before it finished.",
                    detail: message, occurred: Date(),
                    reference: AliceEvent.Reference(
                        transport: .gatewayRun, runID: runID,
                        profile: eventProfile, conversationID: conversationID
                    )
                ))
            }
        }
        if !conversations[chat].messages[index].content.isEmpty {
            markLatency(conversationID, phase: "firstRender")
        }
    }

    /// Builds the Activity representation of a Chat approval without
    /// changing its transport. Bot Chat approvals come from `/api/ws`; run
    /// approvals come from `/v1/runs`. Their visible card is the same, but the
    /// response route is not.
    nonisolated static func approvalActivityEvent(
        _ approval: Message.Approval,
        profile: String?,
        label: String,
        conversationID: String,
        transport: AliceEvent.Transport,
        sessionID: String? = nil,
        sessionKey: String? = nil,
        now: Date = Date()
    ) -> AliceEvent {
        let requestID = approval.requestID ?? approval.runID
        let reference: AliceEvent.Reference
        let activityID: String
        switch transport {
        case .socket:
            reference = AliceEvent.Reference(
                transport: .socket,
                profile: profile,
                sessionID: sessionID,
                sessionKey: sessionKey,
                requestID: requestID,
                conversationID: conversationID
            )
            activityID = "approval:\(requestID)"
        case .gatewayRun:
            reference = AliceEvent.Reference(
                transport: .gatewayRun,
                runID: approval.runID,
                profile: profile,
                requestID: approval.requestID,
                conversationID: conversationID
            )
            activityID = "run-approval:\(approval.runID):\(requestID)"
        }
        // Hermes' statement goes where the explanation reads it, and the
        // command stays the command. `command ?? detail` put the statement in
        // the command's place and dropped it as the reason.
        let explanation = ApprovalExplainer.explain(
            description: approval.hermesDescription, command: approval.command
        )
        var event = AliceEvent(
            id: activityID,
            kind: .needsInput, severity: .needsAttention,
            profile: profile, title: "\(label) needs your OK",
            summary: "Wants to \(explanation.action)",
            detail: approval.command, occurred: now,
            reference: reference,
            standing: .waiting,
            approvalChoices: approval.choices
        )
        event.approvalDescription = approval.hermesDescription
        event.smartDenied = approval.smartDenied == true
        return event
    }

    private func fail(
        _ id: String,
        conversationID: String,
        message: String,
        limit: ModelLimit?
    ) {
        flushStreamedText()
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        let chat = location.chat
        let index = location.message
        conversations[chat].messages[index].settle()
        conversations[chat].messages[index].error = message
        conversations[chat].messages[index].errorLimit = limit
        if conversations[chat].messages[index].content.isEmpty {
            conversations[chat].messages[index].content = message
        }
    }

    private func finish(_ id: String, conversationID: String) {
        flushStreamedText()
        sendingConversations.remove(conversationID)
        streamTasks[conversationID] = nil
        closeAgentActivity(for: conversationID)
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        let chat = location.chat
        let index = location.message
        conversations[chat].messages[index].settle()

        let text = conversations[chat].messages[index].content
        if text.isEmpty,
           conversations[chat].messages[index].error == nil,
           conversations[chat].messages[index].approval == nil {
            conversations[chat].messages[index].content = "Couldn’t reply."
            conversations[chat].messages[index].incomplete = true
        } else if conversations[chat].messages[index].error == nil,
                  let failure = Self.agentFailure(in: text) {
            conversations[chat].messages[index].error = failure
            // Deliberately unclassified. A failure wrapped in a 200 is what
            // the agent says after exhausting its own fallback chain, and the
            // message is the *last* provider's, not the chosen model's — a
            // model whose free period had ended was reported as "you have
            // used up your allowance for this model", naming a limit that
            // belonged to a different account entirely. Better a bare,
            // accurate sentence than a confident wrong explanation.
            conversations[chat].messages[index].errorLimit = nil
        }
        persistConversations()
    }

    private func attachUsage(
        _ usage: MessageUsage, to replyID: String, conversationID: String
    ) {
        guard let location = messageLocation(replyID, conversationID: conversationID)
        else { return }
        var recorded = usage
        if recorded.calls == 0 { recorded.calls = 1 }
        if recorded.seconds == nil, let started = latencyStartedAt[conversationID] {
            recorded.seconds = max(0, Int(Date().timeIntervalSince(started).rounded()))
        }
        conversations[location.chat].messages[location.message].usage = recorded
    }

    /// Keeps streamed narration as its own bubble and opens a fresh
    /// placeholder for whatever comes after the tool. Same conversation,
    /// same reply-to, same mention — never another chat.
    private func sealOpenNarration(replyID: String, conversationID: String) -> String {
        guard let location = messageLocation(replyID, conversationID: conversationID)
        else { return replyID }
        let current = conversations[location.chat].messages[location.message]
        guard current.role == .assistant,
              !TurnNarration.normalized(current.content).isEmpty
        else { return replyID }
        conversations[location.chat].messages[location.message].interim = true
        conversations[location.chat].messages[location.message].pending = false
        conversations[location.chat].messages[location.message].deliveryNote = nil
        let nextID = UUID().uuidString
        var next = Message(
            id: nextID, role: .assistant, content: "", createdAt: Date(),
            pending: true, botName: current.botName,
            replyToMessageID: current.replyToMessageID,
            mentionProfile: current.mentionProfile
        )
        next.mentionSessionID = current.mentionSessionID
        conversations[location.chat].messages.insert(next, at: location.message + 1)
        if var turn = activeBotTurns[conversationID], turn.replyID == replyID {
            turn.replyID = nextID
            activeBotTurns[conversationID] = turn
        }
        persistConversations()
        return nextID
    }

    private func messageLocation(
        _ messageID: String,
        conversationID: String? = nil
    ) -> (chat: Int, message: Int)? {
        if let conversationID,
           let chat = conversations.firstIndex(where: { $0.id == conversationID }),
           let message = conversations[chat].messages.firstIndex(where: { $0.id == messageID }) {
            return (chat, message)
        }
        for chat in conversations.indices {
            if let message = conversations[chat].messages.firstIndex(where: { $0.id == messageID }) {
                return (chat, message)
            }
        }
        return nil
    }

    /// A reply that is nothing but the provider's failure.
    ///
    /// Hermes answers 200 and puts the failure in the reply text, so the
    /// transport never sees a status to classify and the reader gets
    /// "API call failed after 3 retries: HTTP 429: The usage limit has been
    /// reached" as though the agent had said it. Recognised here, the same
    /// classifier that handles a real 429 can say what it means: the
    /// allowance is spent, and waiting will not help.
    ///
    /// Deliberately narrow — only a short reply that opens with one of these
    /// counts, so an answer that happens to discuss usage limits is left
    /// alone.
    static func agentFailure(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 400 else { return nil }
        let lowered = trimmed.lowercased()
        let openings = [
            "api call failed", "⚠️ provider", "provider authentication failed",
            "request failed", "all providers failed",
            "⚠️ no reply:", "no reply:",
        ]
        return openings.contains(where: lowered.hasPrefix) ? trimmed : nil
    }

    /// Hermes' own "the turn ended without an answer" notice, not a provider
    /// error string. `continue` retries that turn; another model does not.
    nonisolated static func isNoReply(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("⚠️ no reply:") || lowered.hasPrefix("no reply:")
    }

    // MARK: - Persistence

    /// Saves the conversations, unless the archive on disk could not be read.
    ///
    /// This is the guard that was missing. When a load fails, the app has no
    /// idea what the user actually had, and writing whatever is in memory —
    /// an empty list, or the shells the bots screen just recreated — destroys
    /// the real archive. Once a load has failed, nothing is written over it
    /// until the failure is understood.
    func persistConversations() {
        persistGeneration += 1
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            // A beat long enough that a streamed reply is saved a couple of
            // times a second, not at every batch of tokens: each save writes
            // the whole chat, attachments and all. Leaving for the background
            // saves at once (`persistConversationsImmediately`).
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            let generation = self.persistGeneration
            let snapshot = self.archiveSnapshot(self.conversations)
            await self.writeConversations(snapshot, generation: generation)
        }
    }

    /// Writes now: going to the background, or a test that must reopen the
    /// archive before the next line. Streaming uses `persistConversations()`,
    /// which waits a beat so many deltas become one encode.
    func persistConversationsImmediately() {
        flushStreamedText()
        persistTask?.cancel()
        persistGeneration += 1
        writeConversationsNow(conversations)
    }

    /// Conversations in files for the app itself, moved there from
    /// `UserDefaults` on the first launch that can (`ConversationArchive.adopt`).
    /// Another defaults suite — a test's — keeps them in that suite.
    private static func conversationStorage(for defaults: UserDefaults) -> ConversationStorage {
        guard defaults === UserDefaults.standard,
              let directory = FileConversationStorage.standardDirectory
        else { return defaults }
        let files = FileConversationStorage(directory: directory)
        return ConversationArchive.adopt(files, from: defaults) ? files : defaults
    }

    private func archiveSnapshot(_ conversations: [Conversation]) -> ConversationArchive.Snapshot {
        ConversationArchive.Snapshot(
            conversations: conversations,
            fingerprints: conversationFingerprints,
            persistedIDs: persistedConversationIDs,
            protectedIDs: protectedConversationIDs
        )
    }

    private func rememberWrite(_ prepared: ConversationArchive.PreparedWrite) {
        ConversationArchive.apply(prepared, to: conversationStorage)
        if let failure = (conversationStorage as? FileConversationStorage)?.takeFailure() {
            storageWarning = Self.saveFailedPrefix + HermesErrors.describe(failure, fallback: "\(type(of: failure))")
            return
        }
        conversationFingerprints = prepared.fingerprints
        persistedConversationIDs = prepared.persistedIDs
        if storageWarning?.hasPrefix(Self.saveFailedPrefix) == true { storageWarning = nil }
    }

    private func writeConversations(
        _ snapshot: ConversationArchive.Snapshot, generation: Int
    ) async {
        guard conversationsUnreadable == nil else { return }
        let encoded = await Task.detached(priority: .utility) {
            Result { try ConversationArchive.prepare(snapshot) }
        }.value
        guard generation == persistGeneration, conversationsUnreadable == nil else { return }
        switch encoded {
        case .success(let prepared):
            rememberWrite(prepared)
        case .failure(let error):
            storageWarning = Self.saveFailedPrefix + HermesErrors.describe(error, fallback: "\(type(of: error))")
        }
    }

    private func writeConversationsNow(_ snapshot: [Conversation]) {
        if conversationsUnreadable != nil { return }
        do {
            rememberWrite(try ConversationArchive.prepare(archiveSnapshot(snapshot)))
        } catch {
            // Nothing was written, and the last good archive is still there.
            // Said out loud: a phone that quietly stops saving loses today's
            // conversations at the next relaunch with no warning at all.
            storageWarning = Self.saveFailedPrefix + HermesErrors.describe(error, fallback: "\(type(of: error))")
        }
    }

    private nonisolated static let saveFailedPrefix = "Conversations could not be saved: "

    /// Something this phone could not keep — an archive it cannot read, a save
    /// that failed, a secret Keychain refused — said once where the person
    /// will see it (Settings), instead of surfacing as a silent gap later.
    private(set) var storageWarning: String?

    /// Why the last Live Activity could not start, if it could not. Shown in
    /// Settings; the chat itself is unaffected.
    var liveActivityWarning: String?
    /// Last chat whose reply just settled. AliceApp ends that Live Activity.
    var finishedActivityConversationID: String?

    private func closeAgentActivity(for conversationID: String) {
        finishedActivityConversationID = conversationID
    }

    /// Why the saved conversations could not be read, if they could not.
    ///
    /// Distinct from "there are none": an empty app and an unreadable archive
    /// look identical on screen, and only one of them is safe to write over.
    private(set) var conversationsUnreadable: String? {
        didSet {
            if let conversationsUnreadable {
                storageWarning = "Saved conversations could not be read (\(conversationsUnreadable)). They are kept aside untouched; nothing new is written over them until a build can read them again."
            } else if storageWarning?.hasPrefix("Saved conversations could not be read") == true {
                storageWarning = nil
            }
        }
    }

    /// Where the unreadable bytes were set aside, so they are recoverable.
    nonisolated static let salvageKey = ConversationArchive.salvageKey

    /// A description of a decode failure with nothing private in it.
    nonisolated static func describe(_ error: Error) -> String {
        ConversationArchive.describe(error)
    }

    /// Reads the saved conversations, and refuses to guess when it cannot.
    ///
    /// The previous version was one `try?` and a `guard … else { return }`, so
    /// an archive it could not decode looked exactly like a new install — and
    /// the next save wrote the empty result over it. That is how a build that
    /// merely added a field erased every conversation on the phone.
    private func loadConversations() {
        switch ConversationArchive.load(from: conversationStorage) {
        case .empty:
            return
        case .available(let loaded):
            rememberLoaded(loaded)
        case .unreadable(let reason, let bytes):
            if defaults.data(forKey: Self.salvageKey) == nil {
                defaults.set(bytes, forKey: Self.salvageKey)
            }
            conversationsUnreadable = reason
        }
    }

    private func rememberLoaded(_ loaded: ConversationArchive.Available) {
        conversationsUnreadable = nil
        if !loaded.conversations.isEmpty { conversations = loaded.conversations }
        if loaded.source == .split {
            conversationFingerprints = Dictionary(
                uniqueKeysWithValues: loaded.conversations.map {
                    ($0.id, ConversationArchive.fingerprint($0))
                }
            )
            persistedConversationIDs = Set(loaded.conversations.map(\.id))
        }
        for item in loaded.skipped {
            protectedConversationIDs.insert(item.id)
            persistedConversationIDs.insert(item.id)
            if defaults.data(forKey: Self.salvageKey) == nil {
                defaults.set(item.bytes, forKey: Self.salvageKey)
            }
        }
        if !loaded.skipped.isEmpty {
            let names = loaded.skipped.map(\.id).joined(separator: ", ")
            storageWarning = "Saved conversation \(names) could not be read (\(loaded.skipped[0].reason)). It is kept aside; the others were loaded."
        }
    }

    /// Puts a salvaged archive back once it can be read again.
    ///
    /// Called on launch: a build that fixes the decoder finds the bytes the
    /// broken one set aside and restores them, so recovery does not depend on
    /// anyone noticing.
    func restoreSalvagedConversationsIfPossible() {
        guard let salvaged = defaults.data(forKey: Self.salvageKey) else { return }
        let saved: [Conversation]
        if let many = try? JSONDecoder().decode([Conversation].self, from: salvaged),
           !many.isEmpty {
            saved = many
        } else if let one = try? JSONDecoder().decode(Conversation.self, from: salvaged) {
            saved = [one]
        } else {
            return
        }
        let live: [Conversation]
        if case let .available(loaded) = ConversationArchive.load(from: conversationStorage) {
            live = loaded.conversations
        } else {
            live = []
        }
        let liveMessages = live.reduce(0) { $0 + $1.messages.count }
        let salvagedMessages = saved.reduce(0) { $0 + $1.messages.count }
        // Only when the salvage actually holds more than what replaced it, so
        // a later legitimate history is never rolled back over.
        guard salvagedMessages > liveMessages else { return }
        conversations = saved
        conversationsUnreadable = nil
        persistConversations()
        defaults.removeObject(forKey: Self.salvageKey)
    }
}

/// Which model list the app keeps when several reads land.
///
/// Reads overlap and finish in whatever order the network returns them, so
/// arrival order cannot decide. On the morning this was written the read that
/// had timed out finished first, holding the one model `/v1/models` names; the
/// full list arrived two seconds later and was discarded, because the fallback
/// had already been taken as the answer.
///
/// A later answer replaces an earlier one only if it is at least as good:
/// a fallback never replaces a catalogue, and the cached catalogue never
/// replaces a refreshed one — that cache once declared every one of Nous's
/// thirty-eight models unavailable, and a refresh is how it gets corrected.
nonisolated enum ModelListPolicy {
    enum Source: Int, Comparable, Sendable {
        case none, fallback, cached, refreshed

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct State: Equatable, Sendable {
        var options: [HermesClient.ModelOption] = []
        var source: Source = .none
        /// One automatic refresh per connection, so a gateway that keeps
        /// failing is not polled in a loop.
        var refreshRequested = false
    }

    struct Outcome: Equatable, Sendable {
        var state: State
        var shouldRefresh: Bool
    }

    static func apply(
        _ list: HermesClient.ModelList, refreshing: Bool, to current: State
    ) -> Outcome {
        let source: Source = !list.isCatalogue ? .fallback : (refreshing ? .refreshed : .cached)
        var next = current
        if source >= current.source {
            next.options = list.options
            next.source = source
        }
        // Anything short of a refreshed catalogue earns one refresh — a
        // fallback most of all, which is what used to be left standing.
        let shouldRefresh = !refreshing
            && !current.refreshRequested
            && next.source != .refreshed
            && !list.options.isEmpty
        if shouldRefresh || refreshing { next.refreshRequested = true }
        return Outcome(state: next, shouldRefresh: shouldRefresh)
    }
}

// MARK: - Reactions, receipts and what agents did

extension AppStore {
    /// Whether a reply can be answered with a thumb: finished, in a chat this
    /// phone can still write to.
    func canReact(to message: Message) -> Bool {
        message.role == .assistant && !message.pending && !message.content.isEmpty
            && !message.interim && !activeIsRecoveredHistory && (isConnected || dashboardReady)
    }

    /// Answers a reply with a thumb.
    ///
    /// A 👍 to a reply that carries an unambiguous calendar card with a day and
    /// a time does what the card's button would — adds the event, or moves it —
    /// and says so under the thumb, so the agent confirms instead of trying
    /// again. Cancelling is never done this way: it keeps its own confirmation.
    func react(_ reaction: Reaction, to message: Message) async {
        guard canReact(to: message) else { return }
        let messages = activeConversation?.messages ?? []
        let language = ChatLanguage.of(message.content)
        // The newest reply needs no quote; an older one says which it was.
        let lastReply = messages.last { $0.role == .assistant && !$0.content.isEmpty }
        let isLatest = lastReply?.id == message.id && messages.last?.role != .user
        let note = reaction == .yes ? await applyCard(in: message, language: language) : nil
        let turn = ReactionTurn(
            reaction: reaction,
            quote: isLatest ? nil : ReactionTurn.snippet(of: message.content),
            note: note
        )
        sendQuickReply(turn.text)
    }

    private func applyCard(in message: Message, language: ChatLanguage) async -> String? {
        let blocks = RichMarkdown.blocks(message.content)
        var adds: [RichCalendarEvent] = []
        var moves: [RichCalendarChange] = []
        var others = 0
        for block in blocks {
            switch block {
            case let .addEvent(event): adds.append(event)
            case let .changeEvent(change) where change.kind == .move: moves.append(change)
            case .changeEvent: others += 1
            default: break
            }
        }
        // Two cards, or a cancel beside one: a thumb cannot say which.
        guard adds.count + moves.count == 1, others == 0 else { return nil }
        if !CalendarSync.hasAccess {
            guard await connectCalendar() == nil else { return nil }
        }
        if let event = adds.first {
            guard (try? AddEventCard.addFromReaction(event)) == true else { return nil }
            recordPhoneAction(kind: "phone.calendar.added", target: event.title)
            await syncCalendarNow()
            return language.pick("added to my calendar", "añadido a mi calendario")
        }
        if let change = moves.first, (try? ChangeEventCard.moveFromReaction(change)) == true {
            recordPhoneAction(kind: "phone.calendar.moved", target: change.title)
            await syncCalendarNow()
            return language.pick("moved in my calendar", "movido en mi calendario")
        }
        return nil
    }

    // MARK: Receipts

    /// Opens a cited conversation, from a link in a reply.
    func openReceipt(_ url: URL) {
        guard let receipt = RichReceipt(url: url) else { return }
        openedReceipt = receipt
    }

    /// The profile a receipt reads from: the one it names, or the chat's own.
    func receiptProfile(_ receipt: RichReceipt) -> String {
        receipt.profile ?? activeChat.routedBotName ?? Self.todayProfile
    }

    func receipt(_ receipt: RichReceipt, window: Int = 3) async throws -> ConversationReceipt {
        let found = try await dashboard.receipt(
            profile: receiptProfile(receipt), session: receipt.session,
            around: receipt.message, at: receipt.at, window: window
        )
        let agent = botCurrentName(for: found.profile)
        receiptSummaries[receipt.session] = ReceiptSummary(
            title: found.displayTitle(agent: agent), profile: found.profile, started: found.started
        )
        return found
    }

    /// Names the conversations a reply cites, once each, so their links read
    /// as titles rather than "that conversation".
    func loadReceiptTitles(_ receipts: [RichReceipt]) async {
        guard dashboardReady else { return }
        for receipt in receipts where receiptSummaries[receipt.session] == nil {
            guard receiptTitlesAsked.insert(receipt.session).inserted else { continue }
            _ = try? await self.receipt(receipt, window: 1)
        }
    }

    /// The conversation on this phone that is that Hermes session, if any.
    func conversation(forSession session: String) -> Conversation? {
        conversations.first { $0.hermesSessionID == session }
    }

    /// Opens the conversation a receipt came from, at the cited message.
    func openReceiptConversation(_ receipt: ConversationReceipt, anchor: String?) -> Bool {
        guard let chat = conversation(forSession: receipt.session) else { return false }
        showingBots = false
        showingNotes = false
        showingAgenda = false
        openConversation(chat.id)
        if let anchor { focusedMessage = FocusedMessage(conversationID: chat.id, remoteID: anchor) }
        return true
    }

    // MARK: What agents did

    /// Everything, newest first: the Mac's record and this phone's.
    var allAgentActions: [AgentAction] {
        let all = (agentActions + phoneActions).sorted { $0.at > $1.at }
        // A failed attempt the agent then made again successfully is not a
        // failure worth showing: an edit whose first try matched twice and
        // whose retry went through read as "Didn't go through".
        return all.filter { action in
            action.ok || !all.contains { other in
                other.ok && other.at >= action.at && other.kind == action.kind
                    && other.target == action.target && other.session == action.session
            }
        }
    }

    func refreshAgentActions() async {
        guard dashboardReady else { return }
        do {
            agentActions = try await dashboard.agentActions()
            agentActionsAvailable = true
        } catch {
            // An older plugin has no record to serve; that is not a failure
            // worth an alert, only a reason for the empty list.
            agentActionsAvailable = false
        }
    }

    /// Something done here, on an agent's suggestion.
    func recordPhoneAction(kind: String, target: String) {
        let chat = activeConversation
        let profile = chat?.routedBotName ?? Self.todayProfile
        var action = AgentAction(
            id: "phone-" + UUID().uuidString, at: Date(), profile: profile,
            session: chat?.hermesSessionID, kind: kind, target: target, ok: true,
            place: .phone, originTitle: chat?.title ?? "", routineKey: nil
        )
        action.conversationID = chat?.id
        phoneActions.insert(action, at: 0)
        if phoneActions.count > 200 { phoneActions.removeLast(phoneActions.count - 200) }
        if let data = try? JSONEncoder().encode(phoneActions) {
            defaults.set(data, forKey: Keys.phoneActions)
        }
    }

    private func loadPhoneActions() {
        guard let data = defaults.data(forKey: Keys.phoneActions),
              let stored = try? JSONDecoder().decode([AgentAction].self, from: data)
        else { return }
        phoneActions = stored
    }

    /// Where an action happened: a chat on this phone opens at once (true);
    /// anything else is the receipt of that moment, for Activity to show —
    /// Activity is itself a sheet, so the app's own cannot go over it.
    func openAction(_ action: AgentAction) -> (openedChat: Bool, receipt: RichReceipt?) {
        if action.place == .phone, let id = action.conversationID,
           conversations.contains(where: { $0.id == id }) {
            showingBots = false
            showingNotes = false
            showingAgenda = false
            openConversation(id)
            return (true, nil)
        }
        guard let session = action.session else { return (false, nil) }
        return (false, RichReceipt(profile: action.profile, session: session, at: action.at))
    }
}
