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

    var connectionError: String?
    var isConnecting = false
    /// Why the model list is empty, when it is. A picker that just says "no
    /// models" leaves you with nowhere to go.
    private(set) var modelsError: String?
    private(set) var isLoadingModels = false

    // Conversations
    var conversations: [Conversation] = [.blank()]
    var activeID: String? {
        didSet {
            guard activeID != oldValue,
                  let index = conversations.firstIndex(where: { $0.id == activeID })
            else { return }
            conversations[index].openedAt = Date()
        }
    }
    var draft: String = ""
    /// Waiting to go out with the next message.
    var draftAttachments: [Attachment] = []
    private(set) var isSending = false

    private let client = HermesClient()
    private let dashboard = DashboardClient()
    private let defaults = UserDefaults.standard
    private var streamTask: Task<Void, Never>?

    private enum Keys {
        static let theme = "alice.theme"
        static let accent = "alice.accent"
        static let gateway = "alice.gateway"
        static let model = "alice.model"
        static let conversations = "alice.conversations"
        static let dashboard = "alice.dashboard"
        static let dashboardUser = "alice.dashboard.user"
        static let marks = "alice.bot.marks"
        static let botSections = "alice.bot.sections"
        static let botCustomSections = "alice.bot.customSections"
        static let collapsedSections = "alice.bot.collapsedSections"
        static let pinnedBots = "alice.bot.pinned"
        static let unreadBots = "alice.bot.unread"
        static let hiddenBots = "alice.bot.hidden"
        static let botModels = "alice.bot.models"
        static let botNotifications = "alice.bot.notifications"
        static let botRoutines = "alice.bot.routines"
        static let botCustomNames = "alice.bot.customNames"
        static let botSectionOrder = "alice.bot.sectionOrder"
        static let cachedBots = "alice.cached.bots"
    }

    static let unassignedSectionKey = "__unassigned__"

    var botCustomNames: [String: String] = [:] {
        didSet { defaults.set(botCustomNames, forKey: Keys.botCustomNames) }
    }

    var botSectionOrder: [String] = [] {
        didSet { defaults.set(botSectionOrder, forKey: Keys.botSectionOrder) }
    }

    var botSections: [String: String] = [:] {
        didSet { defaults.set(botSections, forKey: Keys.botSections) }
    }
    var botCustomSections: [String] = [] {
        didSet { defaults.set(botCustomSections, forKey: Keys.botCustomSections) }
    }
    var collapsedSections: Set<String> = [] {
        didSet { defaults.set(Array(collapsedSections), forKey: Keys.collapsedSections) }
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
    var botModels: [String: String] = [:] {
        didSet { defaults.set(botModels, forKey: Keys.botModels) }
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

    var knownBotNames: [String] {
        var names = Set(cachedBots.map(\.name))
        names.formUnion(botMarks.keys)
        names.formUnion(botSections.keys)
        names.formUnion(botCustomNames.keys)
        names.formUnion(botModels.keys)
        for conv in conversations {
            if let b = conv.botName, !b.isEmpty { names.insert(b) }
            if let bots = conv.channelBots { names.formUnion(bots) }
        }
        return Array(names).sorted()
    }

    init() {
        botMarks = (defaults.data(forKey: Keys.marks))
            .flatMap { try? JSONDecoder().decode([String: BotMark].self, from: $0) } ?? [:]
        botCustomSections = defaults.stringArray(forKey: Keys.botCustomSections) ?? []
        botSectionOrder = defaults.stringArray(forKey: Keys.botSectionOrder) ?? []
        botSections = (defaults.dictionary(forKey: Keys.botSections) as? [String: String]) ?? [:]
        if let savedCollapsed = defaults.stringArray(forKey: Keys.collapsedSections) {
            collapsedSections = Set(savedCollapsed)
        }
        if let savedPinned = defaults.stringArray(forKey: Keys.pinnedBots) {
            pinnedBots = Set(savedPinned)
        }
        if let savedUnread = defaults.stringArray(forKey: Keys.unreadBots) {
            unreadBots = Set(savedUnread)
        }
        if let savedHidden = defaults.stringArray(forKey: Keys.hiddenBots) {
            hiddenBots = Set(savedHidden)
        }
        if let savedModels = defaults.dictionary(forKey: Keys.botModels) as? [String: String] {
            botModels = savedModels
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
        if let raw = defaults.string(forKey: Keys.theme),
           let value = ThemeChoice(rawValue: raw) { theme = value }
        dashboardURL = defaults.string(forKey: Keys.dashboard) ?? ""
        dashboardUser = defaults.string(forKey: Keys.dashboardUser) ?? ""
        if let raw = defaults.string(forKey: Keys.accent),
           let value = Accent(rawValue: raw) { accent = value }
        gatewayURL = defaults.string(forKey: Keys.gateway) ?? ""
        selectedModel = defaults.string(forKey: Keys.model)
        loadConversations()
        activeID = conversations.first(where: { !$0.isBotChat })?.id ?? conversations.first?.id
    }

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeID }
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
        guard let url = Self.normalize(trimmed) else {
            connectionError = "Check the address."
            return
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        await client.connect(to: .init(url: url, key: key))

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

        if await loadModels() { reachedSomething = true }

        if reachedSomething {
            isConnected = true
            connectionError = nil
            gatewayURL = url.absoluteString
            if persist { try? KeyStore.save(key) }
        } else {
            isConnected = false
            connectionError = HermesClient.describe(
                firstFailure ?? HermesClient.Failure.unreachable
            ).localizedDescription
            await client.disconnect()
        }
    }

    /// Reads the model list. Separate from connecting so it can be retried on
    /// its own: the agent is often reachable while this particular endpoint is
    /// not, and that should not cost you the connection.
    @discardableResult
    func loadModels() async -> Bool {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let found = try await client.models()
            models = found
            modelsError = found.isEmpty
                ? "This Hermes did not return a model list at that address."
                : nil
            if selectedModel == nil
                || !found.contains(where: { $0.id == selectedModel }) {
                selectedModel = found.first?.id
            }
            return !found.isEmpty
        } catch {
            models = []
            modelsError = HermesClient.describe(error).localizedDescription
            return false
        }
    }

    func disconnect() async {
        await client.disconnect()
        KeyStore.clear()
        isConnected = false
        manifest = nil
        models = []
        gatewayURL = ""
    }

    /// Accepts what someone actually types: a bare host, a host and port, or a
    /// full URL. Anything without a scheme is assumed to be plain HTTP, which
    /// is how a Hermes on the local network is reached.
    static func normalize(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        var value = text
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value),
              let host = components.host, !host.isEmpty
        else { return nil }
        if components.path.isEmpty { components.path = "/" }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Catalogs

    /// Reads one of the management collections. The screen owns the rows so a
    /// list the user is not looking at is never kept in memory or refreshed.
    func catalog(_ source: CatalogScreen.Source) async throws -> [CatalogRow] {
        switch source {
        case .skills: try await client.skills(manifest)
        case .toolsets: try await client.toolsets(manifest)
        case .addons: try await client.mcpServers(manifest)
        }
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        try await client.toggleSkill(name: name, enabled: enabled)
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].title = trimmed
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned.toggle()
    }

    func file(_ id: String, under project: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].project = project
    }

    func jobs() async throws -> [JobRow] {
        try await client.jobs(manifest)
    }

    func sessions() async throws -> (rows: [SessionRow], complete: Bool) {
        try await client.sessions()
    }

    // MARK: - Dashboard

    /// Remembers where the dashboard is and how to sign in to it. The password
    /// goes to the Keychain beside the gateway key, never to preferences.
    func connectDashboard(urlText: String, username: String, password: String) async -> String? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.normalize(trimmed) else { return "Check the address." }
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
        try? KeyStore.save(password, account: Self.dashboardAccount)
        dashboardReady = true
        return nil
    }

    func restoreDashboard() async {
        guard !dashboardURL.isEmpty, !dashboardUser.isEmpty,
              let password = KeyStore.read(account: Self.dashboardAccount),
              let url = Self.normalize(dashboardURL)
        else { return }
        await dashboard.use(
            .init(url: url, username: dashboardUser, password: password)
        )
        dashboardReady = true
    }

    func forgetDashboard() async {
        await dashboard.use(nil)
        _ = KeyStore.clear(account: Self.dashboardAccount)
        dashboardURL = ""
        dashboardUser = ""
        dashboardReady = false
    }

    static let dashboardAccount = "dashboard-password"

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

    func botCurrentName(for name: String) -> String {
        if let custom = botCustomNames[name], !custom.isEmpty {
            return custom
        }
        if let found = cachedBots.first(where: { $0.name == name }), !found.displayName.isEmpty {
            return found.displayName
        }
        return name
    }

    func botCurrentName(for bot: BotRow) -> String {
        botCustomNames[bot.name] ?? (bot.displayName.isEmpty ? bot.name : bot.displayName)
    }

    /// The bots, from the agent.
    ///
    /// Throws when the dashboard does not answer rather than quietly handing
    /// back the cache: a caller that cannot tell a live list from a stale one
    /// will show hours-old data as though it were current. `cachedBots` stays
    /// available for callers that would rather show something than nothing —
    /// but they have to choose that.
    func bots() async throws -> [BotRow] {
        var list = try await dashboard.bots()
        for index in list.indices {
            if let custom = botCustomNames[list[index].name] {
                list[index].displayName = custom
            }
        }
        // Only when it differs. Assigning unconditionally wrote UserDefaults
        // and invalidated every observer on every call, including the ones
        // that fire while somebody is typing a mention.
        if list != cachedBots { cachedBots = list }
        return list
    }
    /// The bot's routines, as the agent has them.
    ///
    /// There is deliberately no local copy merged in. There used to be, keyed
    /// by a UUID this app invented, and since the server assigns its own id
    /// the same routine came back twice for ever.
    func routines(for bot: String) async throws -> [JobRow] {
        try await dashboard.routines(for: bot)
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
    func addRoutine(for bot: String, name: String, prompt: String, schedule: String) async throws {
        try await dashboard.createRoutine(
            for: bot, name: name, prompt: prompt, schedule: schedule
        )
    }

    func exportBot(_ name: String) async throws -> String? {
        try await dashboard.exportBot(name)
    }
    /// Renames the bot on the agent, then moves everything this app keeps
    /// under the old slug to the new one.
    ///
    /// The agent goes first on purpose. Applying the change locally and
    /// firing the request with `try?` meant a rejected rename still showed
    /// the new name, and the aliases it left behind — including a key that
    /// mapped a name to itself — made a second rename resolve through the
    /// first one's stale value.
    func renameBot(_ name: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }

        try await dashboard.rename(name, to: trimmed)

        move(&botMarks, from: name, to: trimmed)
        move(&botSections, from: name, to: trimmed)
        move(&botModels, from: name, to: trimmed)
        move(&botNotifications, from: name, to: trimmed)
        botCustomNames.removeValue(forKey: name)

        if let index = cachedBots.firstIndex(where: { $0.name == name }) {
            cachedBots.remove(at: index)
        }
        for index in conversations.indices where conversations[index].botName == name {
            conversations[index].botName = trimmed
            conversations[index].title = trimmed
        }
        for index in conversations.indices {
            for messageIndex in conversations[index].messages.indices
            where conversations[index].messages[messageIndex].botName == name {
                conversations[index].messages[messageIndex].botName = trimmed
            }
        }
        persistConversations()
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

    func renameSection(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
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
        if unreadBots.contains(bot) { unreadBots.remove(bot) }
        else { unreadBots.insert(bot) }
    }

    func hideBot(_ bot: String) {
        hiddenBots.insert(bot)
    }

    func unhideBot(_ bot: String) {
        hiddenBots.remove(bot)
    }

    func botModel(for bot: String) -> String? {
        botModels[bot] ?? botModels[bot.lowercased()]
    }

    func setBotModel(_ bot: String, model: String?) {
        if let model {
            botModels[bot] = model
            botModels[bot.lowercased()] = model
        } else {
            botModels.removeValue(forKey: bot)
            botModels.removeValue(forKey: bot.lowercased())
        }
    }

    func botNotificationsEnabled(for bot: String) -> Bool {
        botNotifications[bot] ?? botNotifications[bot.lowercased()] ?? false
    }

    func setBotNotifications(_ bot: String, enabled: Bool) {
        botNotifications[bot] = enabled
        botNotifications[bot.lowercased()] = enabled
    }

    @discardableResult
    func createChannel(name: String, bots: [String], topic: String? = nil) -> Conversation {
        let now = Date()
        var conversation = Conversation(
            id: UUID().uuidString,
            title: "#" + name,
            createdAt: now,
            updatedAt: now,
            isChannel: true,
            channelBots: bots
        )
        if let topic, !topic.isEmpty {
            conversation.messages.append(
                Message(
                    id: UUID().uuidString,
                    role: .assistant,
                    content: "Channel **#\(name)** created with bots: \(bots.joined(separator: ", ")).\nTopic: \(topic)",
                    createdAt: now
                )
            )
        }
        conversations.insert(conversation, at: 0)
        activeID = conversation.id
        persistConversations()
        return conversation
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
        botMarks[name] ?? BotMark.derived(from: name)
    }
    func soul(_ name: String) async throws -> (text: String, exists: Bool) {
        try await dashboard.soul(name)
    }
    func setSoul(_ name: String, _ text: String) async throws {
        try await dashboard.setSoul(name, text)
    }
    func setBotDescription(_ name: String, _ text: String) async throws {
        // The agent first: a swallowed failure left the row showing a
        // description the profile does not have.
        try await dashboard.setDescription(name, text)
        if let index = cachedBots.firstIndex(where: { $0.name == name }) {
            cachedBots[index].detail = text
        }
    }
    func activateBot(_ name: String) async throws { try await dashboard.activate(name) }
    func createBot(name: String, description: String) async throws {
        try await dashboard.createBot(name: name, description: description)
    }
    func deleteBot(_ name: String) async throws { try await dashboard.deleteBot(name) }

    func projects() async throws -> [ProjectRow] { try await dashboard.projects() }

    func namedProjects() async throws -> [NamedProject] {
        try await dashboard.namedProjects()
    }
    func createProject(name: String, colour: String?) async throws {
        try await dashboard.createProject(name: name, colour: colour)
    }
    func renameProject(_ id: String, to name: String, colour: String?) async throws {
        try await dashboard.renameProject(id, to: name, colour: colour)
    }
    func deleteProject(_ id: String) async throws {
        try await dashboard.deleteProject(id)
    }

    func skillContent(_ name: String) async throws -> String {
        try await dashboard.skillContent(name)
    }
    func saveSkill(name: String, content: String) async throws {
        try await dashboard.saveSkill(name: name, content: content)
    }
    func deleteSkill(_ name: String) async throws {
        try await dashboard.deleteSkill(name)
    }
    func memoryProviders() async throws -> [MemoryProvider] { try await dashboard.memory() }
    func usage() async throws -> UsageReport { try await dashboard.usage() }

    func supports(_ capability: String) -> Bool {
        manifest?.supports(capability) ?? false
    }

    // MARK: - Conversations

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
        for model: String?, among options: [HermesClient.ModelOption]
    ) -> String? {
        guard let model else { return nil }
        let serving = Set(options.filter { $0.id == model }.compactMap(\.provider))
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
    var showingBots = false

    /// Which side the bots page comes from and leaves by.
    ///
    /// Forward is leftward and back is rightward, so the page has to know
    /// which of the two is happening: arriving from the drawer it comes in
    /// off the right, and backing into it out of a bot's conversation it
    /// comes in off the left, the way the finger went.
    var botsFromLeading = false

    @discardableResult
    func openBotConversation(for bot: BotRow) -> String {
        if let existing = conversations.first(where: { $0.botName == bot.name }) {
            activeID = existing.id
            return existing.id
        }
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
        return chat.id
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty, !isSending else { return }

        // Dropped since the last message? Pick it back up rather than making
        // somebody go to Connect and press a button for a connection that is
        // still perfectly good.
        guard isConnected else {
            Task { [weak self] in
                await self?.restoreConnection()
                if self?.isConnected == true { self?.send() }
            }
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == activeID })
        else { return }

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
                            invokedBot = candidate
                        }
                    }
                } else if let channelBots = conversations[index].channelBots, !channelBots.isEmpty {
                    invokedBot = channelBots.first
                }
            }
        }

        let attachments = draftAttachments
        draft = ""
        draftAttachments = []
        isSending = true

        let user = Message(
            id: UUID().uuidString, role: .user, content: text, createdAt: Date(),
            attachments: attachments
        )
        let replyID = UUID().uuidString
        conversations[index].messages.append(user)
        conversations[index].messages.append(
            Message(
                id: replyID, role: .assistant, content: "",
                createdAt: Date(), pending: true, botName: invokedBot
            )
        )
        if conversations[index].title == "New chat" {
            let name = text.isEmpty ? (attachments.first?.name ?? "New chat") : text
            conversations[index].title = String(name.prefix(40))
        }
        conversations[index].updatedAt = Date()

        // Only the newest turn that has attachments sends them. Repeating
        // every image on every request is what turns a long conversation into
        // a payload the provider refuses, and the earlier ones have already
        // been read once.
        let history = conversations[index].messages
            .filter { !$0.pending && $0.error == nil }
        let newestWithAttachments = history.lastIndex { !$0.attachments.isEmpty }
        var turns = history.enumerated().map { offset, message in
            HermesClient.Turn(
                role: message.role.rawValue,
                content: Self.content(
                    of: message, includeAttachments: offset == newestWithAttachments
                )
            )
        }

        var model = selectedModel
        if let invokedBot, let specificModel = botModel(for: invokedBot) {
            model = specificModel
        }
        let provider = Self.provider(for: model, among: models)

        if let invokedBot {
            let botInfo = cachedBots.first(where: { $0.name == invokedBot })
            let botTitle = botCurrentName(for: invokedBot)
            let botDesc = botInfo?.detail ?? ""
            var directive = "You are the bot '@\(botTitle)'. Respond in character as this bot with its personality and skills."
            if !botDesc.isEmpty {
                directive += " Profile description: \(botDesc)."
            }
            turns.insert(HermesClient.Turn(role: "system", content: .text(directive)), at: 0)
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.stream(
                messages: turns, model: model, provider: provider, profile: invokedBot
            )
            do {
                for try await event in stream {
                    self.apply(event, to: replyID)
                }
            } catch {
                self.fail(replyID, message: error.localizedDescription, limit: nil)
            }
            self.finish(replyID)
        }
    }

    /// Runs the last exchange again.
    ///
    /// Drops the reply and everything after it, then resends the user turn that
    /// prompted it — so a failed or unsatisfying answer is replaced rather than
    /// piled on top of, and the model sees the same history it saw the first
    /// time.
    func retry(_ messageID: String) {
        guard !isSending,
              let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == messageID }),
              conversations[chat].messages[index].role == .assistant
        else { return }

        let priorUser = conversations[chat].messages[..<index]
            .last { $0.role == .user }
        guard let priorUser else { return }

        conversations[chat].messages.removeSubrange(index...)
        if let userIndex = conversations[chat].messages.firstIndex(where: { $0.id == priorUser.id }) {
            conversations[chat].messages.remove(at: userIndex)
        }
        draft = priorUser.content
        send()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
    }

    private func apply(_ event: ChatEvent, to id: String) {
        guard let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == id })
        else { return }

        switch event {
        case let .delta(text):
            conversations[chat].messages[index].content += text
        case let .tool(toolID, name, status, detail):
            var tools = conversations[chat].messages[index].tools
            if let existing = tools.firstIndex(where: { $0.id == toolID }) {
                tools[existing].status = status
                if let detail { tools[existing].detail = detail }
            } else {
                tools.append(.init(id: toolID, name: name, status: status, detail: detail))
            }
            conversations[chat].messages[index].tools = tools
        case let .run(_, status, output):
            if let output { conversations[chat].messages[index].content = output }
            if ["completed", "failed", "cancelled"].contains(status) {
                conversations[chat].messages[index].pending = false
            }
        case let .failure(message, limit):
            fail(id, message: message, limit: limit)
        }
    }

    private func fail(_ id: String, message: String, limit: ModelLimit?) {
        guard let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[chat].messages[index].pending = false
        conversations[chat].messages[index].error = message
        conversations[chat].messages[index].errorLimit = limit
        if conversations[chat].messages[index].content.isEmpty {
            conversations[chat].messages[index].content = message
        }
    }

    private func finish(_ id: String) {
        isSending = false
        streamTask = nil
        guard let chat = conversations.firstIndex(where: { $0.id == activeID }),
              let index = conversations[chat].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[chat].messages[index].pending = false

        let text = conversations[chat].messages[index].content
        if text.isEmpty, conversations[chat].messages[index].error == nil {
            conversations[chat].messages[index].content = "Couldn’t reply."
            conversations[chat].messages[index].incomplete = true
        } else if conversations[chat].messages[index].error == nil,
                  let failure = Self.agentFailure(in: text) {
            conversations[chat].messages[index].error = failure
            conversations[chat].messages[index].errorLimit =
                ModelLimitClassifier.classify(status: nil, message: failure)
        }
        persistConversations()
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
        ]
        return openings.contains(where: lowered.hasPrefix) ? trimmed : nil
    }

    // MARK: - Persistence

    private func persistConversations() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        defaults.set(data, forKey: Keys.conversations)
    }

    private func loadConversations() {
        guard let data = defaults.data(forKey: Keys.conversations),
              let saved = try? JSONDecoder().decode([Conversation].self, from: data),
              !saved.isEmpty
        else { return }
        conversations = saved
    }
}
