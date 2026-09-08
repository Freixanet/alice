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
    /// One socket for the whole app, built lazily once the dashboard is
    /// connected. The protocol addresses a session per call, so this is a
    /// transport, not a single global conversation — per-chat streaming can
    /// be layered on it without another transport rewrite.
    private var rpcClient: HermesRPCClient?
    /// Why a bot chat's transcript could not be re-read, keyed by conversation.
    /// Present means the list on screen may be behind the agent's.
    var botChatFailure: [String: String] = [:]
    private let dashboard = DashboardClient()
    private let defaults = UserDefaults.standard
    private var streamTask: Task<Void, Never>?

    private enum Keys {
        static let theme = "alice.theme"
        static let accent = "alice.accent"
        static let gateway = "alice.gateway"
        static let model = "alice.model"
        static let provider = "alice.model.provider"
        static let recentModels = "alice.models.recent"
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
        static let botOrder = "alice.bot.order"
        static let cachedBots = "alice.cached.bots"
        static let eventWatermarks = "alice.events.watermarks"
        static let activity = "alice.events.activity"
        static let activitySeen = "alice.events.activitySeen"
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
        botOrder = defaults.stringArray(forKey: Keys.botOrder) ?? []
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
        selectedProvider = defaults.string(forKey: Keys.provider)
        recentModels = defaults.stringArray(forKey: Keys.recentModels) ?? []
        loadConversations()
        loadActivity()
        restoreSalvagedConversationsIfPossible()
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
    func loadModels(refreshing: Bool = false) async -> Bool {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let found = try await client.models(refreshing: refreshing)

            // The cheap answer comes from a computed cache that is wrong in
            // one direction: it marks a provider's models unavailable and
            // then keeps saying so, which is how Nous — thirty-eight models,
            // all thirty-eight declared unavailable — vanished from the
            // picker. Recomputing fixes it but does not write the correction
            // back, so the cheap call keeps its wrong answer for ever.
            //
            // So the cheap answer is a first paint only, and once a real
            // refresh has landed it is not allowed to overwrite it. Several
            // things ask for the list — connecting, opening the picker — and
            // any one of them arriving after the refresh used to put the
            // truncated list back, which is why refreshing appeared to work
            // and then undo itself.
            if refreshing || !hasRefreshedModels {
                models = found
                modelsError = found.isEmpty
                    ? "This Hermes did not return a model list at that address."
                    : nil
            }
            if refreshing { hasRefreshedModels = true }
            if !refreshing, !hasRefreshedModels, !found.isEmpty {
                hasRefreshedModels = true
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
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned.toggle()
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
        guard let url = Self.normalize(trimmed) else { return "Check the address." }
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
        try? KeyStore.save(password, account: Self.dashboardAccount)
        dashboardReady = true
        return nil
    }

    func restoreDashboard() async {
        guard !dashboardURL.isEmpty, !dashboardUser.isEmpty,
              let password = KeyStore.read(account: Self.dashboardAccount),
              let url = Self.normalize(dashboardURL)
        else { return }
        await resetDashboardRPC()
        await dashboard.use(
            .init(url: url, username: dashboardUser, password: password)
        )
        dashboardReady = true
    }

    func forgetDashboard() async {
        await resetDashboardRPC()
        await dashboard.use(nil)
        _ = KeyStore.clear(account: Self.dashboardAccount)
        dashboardURL = ""
        dashboardUser = ""
        dashboardReady = false
    }

    static let dashboardAccount = "dashboard-password"

    /// A JSON-RPC client is bound to the dashboard URL it was created with.
    /// Changing/forgetting that dashboard must therefore retire the socket;
    /// otherwise a later Bot Mode action can be routed to the previous host.
    private func resetDashboardRPC() async {
        if let rpcClient { await rpcClient.disconnect() }
        rpcClient = nil
        liveBotSessions.removeAll()
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

    func botCurrentName(for name: String) -> String {
        if botMetadataIsRemote,
           let found = cachedBots.first(where: { $0.name == name }), !found.displayName.isEmpty {
            return found.displayName
        }
        if let custom = botCustomNames[name], !custom.isEmpty { return custom }
        if let found = cachedBots.first(where: { $0.name == name }), !found.displayName.isEmpty {
            return found.displayName
        }
        return name
    }

    func botCurrentName(for bot: BotRow) -> String {
        if botMetadataIsRemote { return bot.displayName.isEmpty ? bot.name : bot.displayName }
        return botCustomNames[bot.name] ?? (bot.displayName.isEmpty ? bot.name : bot.displayName)
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
                    from: try DashboardClient.bots(from: result.fields, active: nil)
                )
                remoteMetadata = true
            } catch {
                // An older gateway may not implement profiles.list. The REST
                // list is still a real profile list, just without Bot Mode
                // presentation metadata. Preserve the last metadata snapshot
                // instead of making hidden/pinned bots jump around during a
                // transient WebSocket failure.
                list = Self.botRoster(from: try await dashboard.bots())
                list = Self.carryCachedMetadata(list, from: cachedBots)
            }
        } else {
            list = Self.botRoster(from: try await dashboard.bots())
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
                list = Self.botRoster(from: parsed)
            }
        }

        if list != cachedBots { cachedBots = list }
        return list
    }

    /// Alice owns `default` as Home. Every named profile remains in Bots, even
    /// if it predates Bot Mode metadata: that is Hermes Desktop's legacy
    /// compatibility rule, made explicit rather than treating metadata as a
    /// type discriminator.
    nonisolated static func botRoster(from profiles: [BotRow]) -> [BotRow] {
        profiles.filter { !$0.isDefault }
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

    func isBotPinned(_ bot: BotRow) -> Bool {
        botMetadataIsRemote ? (bot.metadata.pinned ?? false) : pinnedBots.contains(bot.name)
    }

    func isBotHidden(_ bot: BotRow) -> Bool {
        botMetadataIsRemote ? (bot.metadata.hidden ?? false) : hiddenBots.contains(bot.name)
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if botMetadataIsRemote {
            try await mutateBotMetadata(bot.name) { meta in
                var meta = meta
                if trimmed.isEmpty { meta.removeValue(forKey: "title") }
                else { meta["title"] = trimmed }
                return meta
            }
            botCustomNames.removeValue(forKey: bot.name)
        } else if trimmed.isEmpty {
            botCustomNames.removeValue(forKey: bot.name)
        } else {
            botCustomNames[bot.name] = trimmed
        }
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

        // The name is changed here first, and kept whatever the agent says.
        // Renaming a profile is `PATCH /api/profiles/<name>`, and this Hermes
        // has no PATCH route for it at all — its patch handler knows only MCP
        // servers and kanban, and answers everything else with a 404. So the
        // rename was being sent, refused, and the new name thrown away: the
        // field simply snapped back with nothing said.
        //
        // A bot's shown name is already the app's to decide — `botCustomNames`
        // exists for exactly this — so it is set regardless, and the server is
        // still asked in case it is a build that can oblige. Only then are the
        // per-bot settings moved onto the new id.
        botCustomNames[name] = trimmed

        do {
            try await dashboard.rename(name, to: trimmed)
        } catch {
            return
        }

        move(&botMarks, from: name, to: trimmed)
        move(&botSections, from: name, to: trimmed)
        move(&botModels, from: name, to: trimmed)
        move(&botNotifications, from: name, to: trimmed)
        if let index = botOrder.firstIndex(of: name) { botOrder[index] = trimmed }
        botOrder.removeAll { $0 == name.lowercased() && $0 != trimmed }
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

    /// Persist a model selection on the Hermes profile. Bot Mode's RPC has the
    /// same expensive/data-policy confirmation handshake as the main model
    /// picker; the returned string is the confirmation message, or nil after
    /// a successful write.
    func setBotModel(
        _ bot: BotRow,
        to option: HermesClient.ModelOption,
        confirm: Bool = false
    ) async throws -> String? {
        guard let provider = option.provider, !provider.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "Hermes did not identify the provider for this model."
            )
        }

        if let rpc = await dashboardRPC() {
            var params: [String: Any] = [
                "name": bot.name, "model": option.id, "provider": provider,
            ]
            if confirm { params["confirm_expensive_model"] = true }
            let response = try await rpc.call("profiles.configure", JSONObject(params))
            if response["confirm_required"] as? Bool == true {
                return (response["confirm_message"] as? String)
                    ?? "Hermes wants confirmation before using this model."
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

        botModels.removeValue(forKey: bot.name)
        botModels.removeValue(forKey: bot.name.lowercased())
        if let index = cachedBots.firstIndex(where: { $0.name == bot.name }) {
            cachedBots[index].model = option.id
            cachedBots[index].provider = provider
        }
        return nil
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

    /// Bounded on purpose: this is a phone, and the useful window is recent.
    static let activityLimit = 200

    /// When the person last opened Activity, for the unread count.
    var activitySeen: Date {
        get { defaults.object(forKey: Keys.activitySeen) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Keys.activitySeen) }
    }

    var unreadActivity: Int {
        activity.filter { $0.occurred > activitySeen }.count
    }

    /// Components and automations that want attention right now.
    ///
    /// Distinct from `activity`, which is a record of things that happened.
    /// This is current state: something is wrong *now* and can be acted on.
    private(set) var attention: [AliceEvent] = []

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
        guard isConnected || dashboardReady else {
            return gatewayURL.isEmpty && dashboardURL.isEmpty ? .notConfigured : .unreachable
        }
        return attention.isEmpty ? .well : .needsAttention(attention.count)
    }

    /// One sentence for the connection row. Says what is true, and when
    /// something is wrong says how much rather than only that.
    var wellbeingSummary: String {
        switch wellbeing {
        case .notConfigured: "Connect your Hermes"
        case .unreachable: "Can’t reach Hermes"
        case .well: "Everything is working"
        case let .needsAttention(count):
            count == 1 ? "1 thing needs attention" : "\(count) things need attention"
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
        guard let identity = sessionIdentity(for: frame.sessionID) else { return }
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
        let conversation: Conversation?
        if let direct = conversations.first(where: {
            $0.hermesSessionID == sessionID && $0.isCanonicalBotChat
        }) {
            conversation = direct
        } else if let conversationID = liveBotSessions[sessionID] {
            conversation = conversations.first(where: {
                $0.id == conversationID && $0.isCanonicalBotChat
            })
        } else {
            conversation = nil
        }
        guard let conversation, let profile = conversation.routedBotName else { return nil }
        let durableID = conversation.hermesSessionID ?? sessionID
        return LiveEvents.SessionIdentity(
            profile: profile,
            // Persist/action by durable identity. The runtime id is only a
            // transport address and dies with this websocket.
            sessionID: durableID,
            sessionKey: durableID,
            conversationID: conversation.id,
            label: botCurrentName(for: profile)
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

    @discardableResult
    func syncEvents() async -> [AliceEvent] {
        guard dashboardReady else { return [] }
        let routines: [JobRow]
        do {
            routines = try await allRoutines().values.flatMap { $0 }
        } catch {
            return []
        }
        let components = (try? await hermesSystemStatus(profile: "default"))?.components ?? []

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
            persistActivity()
        }

        let result = EventDigest.digest(
            routines: routines, components: components, since: marks
        )
        eventWatermarks = result.watermarks
        // Requests still waiting are read from current server state, not from
        // the event history — which is why a first sync can stay silent about
        // finished runs and still surface an approval that is live right now.
        let pending = await pendingRequests()
        let knownWaiting = Set(activity.filter(\.isActionable).map(\.id))
        reconcilePending(against: pending)
        let changed = tagged(result.events)
        let currentPending = tagged(pending.events)
        let newlyPending = currentPending.filter { !knownWaiting.contains($0.id) }
        // Record every current snapshot so partially answered clarify batches
        // restore their locked qids, but notify only requests Alice had not
        // already seen live or on an earlier sync.
        record(changed + currentPending)
        refreshAttention(routines: routines, components: components)
        return (changed + newlyPending.filter { $0.standing == .waiting })
            .filter { event in
            // A bot's events follow that bot's switch. Everything else is
            // about the installation, which has no per-bot switch to consult.
            guard let profile = event.profile else { return true }
            return botNotificationsEnabled(for: profile)
        }
    }

    /// What every mirrored bot chat is currently waiting on.
    ///
    /// One `session.resume` per canonical bot chat, once per sync — not once
    /// per row drawn. `session.resume` is the call that returns
    /// `pending_approval` and `pending_clarify` alongside the transcript, so
    /// this costs nothing beyond what refreshing a chat already does.
    private func pendingRequests() async -> (events: [AliceEvent], checked: Set<String>) {
        guard let source = await botChatSource() else { return ([], []) }
        var events: [AliceEvent] = []
        var checked: Set<String> = []

        for conversation in conversations where conversation.isCanonicalBotChat {
            guard let profile = conversation.routedBotName,
                  let sessionID = conversation.hermesSessionID else { continue }
            guard let resumed = try? await source.resume(
                profile: profile, target: sessionID
            ) else { continue }
            checked.insert(sessionID)

            let identity = LiveEvents.SessionIdentity(
                profile: profile, sessionID: sessionID,
                sessionKey: (resumed["session_key"] as? String) ?? sessionID,
                conversationID: conversation.id,
                label: botCurrentName(for: profile)
            )
            if let approval = resumed["pending_approval"] as? [String: Any],
               let event = LiveEvents.pendingApproval(approval, session: identity) {
                events.append(event)
            }
            if let clarify = resumed["pending_clarify"] as? [String: Any],
               let event = LiveEvents.pendingClarify(clarify, session: identity) {
                events.append(event)
            }
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

    /// Current state, from whatever was last read plus anything still waiting.
    private func refreshAttention(
        routines: [JobRow]? = nil, components: [HermesSystemComponent]? = nil
    ) {
        var items = activity.filter(\.isActionable)
        if let routines, let components {
            items += EventDigest.attention(routines: routines, components: components)
        } else {
            items += attention.filter { $0.kind != .needsInput }
        }
        attention = items.sorted { $0.severity > $1.severity }
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
                let result = try await rpc.call("approval.respond", JSONObject([
                    "session_id": sessionID,
                    "request_id": requestID,
                    "choice": choice.rawValue,
                ]))
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

    /// Answers one clarify question Hermes is blocked on.
    ///
    /// A batch is not one answer: Hermes locks each member by `question_id`
    /// and reports the qids still remaining. Alice keeps the Activity row
    /// actionable until that list is empty. Sending a batch without a qid is
    /// refused locally because Hermes would treat it as a cancel/whole-request
    /// answer and the first question would falsely resolve the rest.
    @discardableResult
    func answerClarification(
        _ event: AliceEvent, questionID: String? = nil, answer: String
    ) async -> Bool {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.standing == .waiting, !text.isEmpty,
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
            var params: [String: Any] = ["request_id": requestID, "answer": text]
            if let sessionID = event.reference.sessionID { params["session_id"] = sessionID }
            if let questionID { params["question_id"] = questionID }
            let result = try await rpc.call("clarify.respond", JSONObject(params))

            switch LiveEvents.clarifyReply(result, questionID: questionID) {
            case .resolved:
                if let questionID {
                    lockClarificationAnswer(event.id, questionID: questionID, answer: text)
                    settle(event.id, as: .resolved, summary: "You answered all questions.")
                } else {
                    settle(event.id, as: .resolved, summary: "You answered: \(text)")
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

    static let noLongerWaiting =
        "This was already answered elsewhere, or it expired."

    /// The send did not reach Hermes. The request stays actionable, because it
    /// is probably still blocking the agent.
    private func markResolutionFailed(_ id: String, _ error: Error) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        activity[index].detail = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        activity[index].summary = "Alice could not send that answer. It is still waiting."
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
    @discardableResult
    func open(_ route: Notifier.Route) -> Bool {
        if let installation = route.installation,
           installation != currentInstallationFingerprint {
            routeNotice = "This notification belongs to a different Hermes installation. Nothing was changed."
            return false
        }

        routedEvent = route.eventID
        if let id = route.conversationID,
           conversations.contains(where: { $0.id == id }) {
            showingBots = false
            activeID = id
            return true
        }

        // Missing local navigation is not evidence that the server-side request
        // expired. Keep an actionable Activity row actionable; it may still be
        // answerable from its saved session/request identity.
        routeNotice = route.conversationID == nil
            ? "This notification has no conversation to open. You can review it in Activity."
            : "That conversation is no longer on this phone. You can review the event in Activity."
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

    func markActivitySeen() { activitySeen = Date() }

    private func persistActivity() {
        guard let data = try? JSONEncoder().encode(activity.map(StoredEvent.init)) else { return }
        defaults.set(data, forKey: Keys.activity)
    }

    private func loadActivity() {
        guard let data = defaults.data(forKey: Keys.activity),
              let stored = try? JSONDecoder().decode([StoredEvent].self, from: data)
        else { return }
        activity = stored.map(\.event)
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
        }

        var event: AliceEvent {
            AliceEvent(
                id: id,
                kind: AliceEvent.Kind(rawValue: kind) ?? .finished,
                severity: AliceEvent.Severity(rawValue: severity) ?? .informational,
                profile: profile, title: title, summary: summary,
                detail: detail, occurred: occurred,
                reference: reference ?? .init(),
                standing: standing ?? .none,
                questions: questions ?? [],
                approvalChoices: approvalChoices ?? []
            )
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

    /// Create a real Hermes bot with a stable canonical profile id and a
    /// separate presentation title, matching Hermes Desktop Bot Mode.
    @discardableResult
    func createBot(
        displayName: String,
        description: String,
        model: HermesClient.ModelOption? = nil
    ) async throws -> String {
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.botSlug(title)
        guard !slug.isEmpty else {
            throw HermesRPCClient.Failure(reason: "Give the bot a name with at least one letter or number.")
        }

        if let rpc = await dashboardRPC() {
            var payload: [String: Any] = [
                "name": slug,
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines),
                "share_auth": true,
                "mirror_credentials": true,
            ]
            if let model, let provider = model.provider, !provider.isEmpty {
                payload["model"] = model.id
                payload["provider"] = provider
            }
            _ = try await rpc.call("profiles.create", JSONObject(payload))

            // Title + created are Bot Mode presentation metadata, not profile
            // identity. Always write the title: `my-research-bot` and “My
            // Research Bot” should remain distinct concepts on every device.
            try await mutateBotMetadata(slug) { meta in
                var meta = meta
                meta["title"] = title
                meta["created"] = Date().timeIntervalSince1970 * 1000
                return meta
            }
        } else {
            try await dashboard.createBot(name: slug, description: description)
            if let model, let provider = model.provider, !provider.isEmpty {
                try await dashboard.setModel(slug, provider: provider, model: model.id)
            }
            // Old Hermes has nowhere to persist Bot Mode presentation fields.
            botCustomNames[slug] = title
        }
        return slug
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
            let originalSoul = try await soul(bot.name).text
            if !originalSoul.isEmpty { try await setSoul(newName, originalSoul) }
            botCustomNames[newName] = "\(baseTitle(for: bot)) (copy)"
        }
    }

    private func baseTitle(for bot: BotRow) -> String {
        bot.displayName.isEmpty ? bot.name : bot.displayName
    }

    func deleteBot(_ name: String) async throws {
        try await dashboard.deleteBot(name)
        botOrder.removeAll { $0 == name || $0 == name.lowercased() }
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

    func hermesSystemStatus(profile: String = "default") async throws -> HermesSystemStatus {
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

    /// Records a model as chosen, keeping the short list of recent ones.
    func chooseModel(_ id: String, provider: String?) {
        selectedModel = id
        selectedProvider = provider
        var recent = recentModels.filter { $0 != id }
        recent.insert(id, at: 0)
        recentModels = Array(recent.prefix(6))
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
    /// Whether the catalogue has been genuinely recomputed this launch.
    @ObservationIgnored private var hasRefreshedModels = false

    var showingBots = false

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

    /// Opens a bot's chat, then reconciles it with the agent's own.
    ///
    /// The local conversation is a cache, so it opens at once from what is
    /// already on the phone and the canonical transcript is folded in when it
    /// arrives. Hermes owns the contents: a cron report delivered to the bot's
    /// forever-chat while the app was closed shows up on this read, because
    /// this reads that chat rather than a private copy Alice kept.
    @discardableResult
    func openBotConversation(for bot: BotRow) -> String {
        let id: String
        if let existing = conversations.first(where: { $0.botName == bot.name }) {
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
        Task { [weak self] in await self?.refreshBotChat(id) }
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
        guard let source = await botChatSource() else {
            botChatFailure[conversationID] =
                "Connect the Hermes dashboard to see this bot's own chat."
            return
        }
        let sync = BotChatSync(source: source)
        do {
            let updated = try await sync.refresh(
                profile: profile, into: conversations[index]
            )
            guard let current = conversations.firstIndex(where: { $0.id == conversationID })
            else { return }
            conversations[current].hermesSessionID = updated.hermesSessionID
            conversations[current].messages = BotChatSync.merge(
                updated.messages.compactMap(Self.turn(from:)),
                into: conversations[current].messages
            )
            botChatFailure[conversationID] = nil
            persistConversations()
        } catch {
            // Keep what is on screen. The reason is recorded so the chat can
            // say the transcript may be behind, rather than pretending it is
            // complete or blanking it.
            botChatFailure[conversationID] =
                (error as? LocalizedError)?.errorDescription
                ?? "Hermes did not answer."
        }
    }

    /// Re-reads every bot chat the app is showing, once, on returning to the
    /// foreground. Not a poll: a cron report lands while the phone is asleep,
    /// and this is the moment it becomes worth asking for.
    func refreshVisibleBotChats() async {
        let ids = conversations.filter(\.isCanonicalBotChat).map(\.id)
        for id in ids { await refreshBotChat(id) }
    }

    /// Sends one turn into a bot's canonical Hermes chat and streams the reply.
    ///
    /// The session is resolved before anything is sent, so the turn lands in
    /// the same chat cron delivers to. Nothing here builds a persona: the
    /// agent on the other end *is* the bot, with its own SOUL, memory, skills
    /// and configuration.
    private func sendToBotChat(
        profile: String, conversationID: String, replyID: String, text: String
    ) async {
        guard let source = await botChatSource() else {
            fail(replyID, conversationID: conversationID,
                 message: "Connect the Hermes dashboard to talk to this bot.",
                 limit: nil)
            finish(replyID, conversationID: conversationID)
            return
        }
        do {
            let chat = try await BotChatSync(source: source).resolve(profile: profile)
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[index].hermesSessionID = chat.resolvedID
            }
            let events = source.rpc.events()
            let liveSessionID = try await source.submit(
                profile: profile, sessionID: chat.resolvedID, text: text
            )
            liveBotSessions[liveSessionID] = conversationID
            for await event in events {
                guard event.sessionID.isEmpty || event.sessionID == liveSessionID
                else { continue }
                if let chatEvent = Self.chatEvent(from: event) {
                    apply(chatEvent, to: replyID, conversationID: conversationID)
                }
                // Only a real turn outcome ends the stream. The subagent
                // mirror in `agent_callbacks` emits `message.complete` with no
                // `status`, on the PARENT's session id, when a child finishes
                // — breaking on that abandoned the parent mid-run and threw
                // away the reply it was still writing.
                if LiveEvents.isTurnOutcome(event) { break }
            }
        } catch {
            fail(replyID, conversationID: conversationID,
                 message: (error as? LocalizedError)?.errorDescription
                    ?? "Hermes did not answer.",
                 limit: nil)
        }
        finish(replyID, conversationID: conversationID)
        await refreshBotChat(conversationID)
    }

    /// One pushed frame as the event this app already knows how to draw.
    ///
    /// An adapter rather than a second renderer: deltas, tools and approvals
    /// all reach `apply` the way the HTTP path's do.
    nonisolated static func chatEvent(from event: HermesRPCEvent) -> ChatEvent? {
        switch event.type {
        case "message.delta", "message.interim":
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
            // The stream already delivered the body as deltas; the completion
            // frame only says how the turn ended.
            return .run(
                id: (event.payload["id"] as? String) ?? event.sessionID,
                status: status, output: nil
            )
        case "tool.start":
            guard let name = event.payload["name"] as? String else { return nil }
            return .tool(
                id: (event.payload["id"] as? String) ?? name,
                name: name, status: .start,
                detail: event.payload["context"] as? String
            )
        case "tool.complete":
            guard let name = event.payload["name"] as? String else { return nil }
            return .tool(
                id: (event.payload["id"] as? String) ?? name,
                name: name, status: .done,
                detail: event.payload["context"] as? String
            )
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
                choices: LiveEvents.choices(event.payload)
            ))
        case "error":
            let message = (event.payload["message"] as? String) ?? "Hermes reported an error."
            return .failure(message: message, limit: nil)
        default:
            return nil
        }
    }

    /// The bot-chat transport, or nil when no dashboard is connected.
    ///
    /// The socket is authenticated by a single-use ticket the dashboard mints
    /// for its own signed-in session, so this reuses the login Alice already
    /// has: no second credential store, no second login screen, and the
    /// password never leaves `DashboardClient`.
    private func botChatSource() async -> WebSocketBotChatSource? {
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
        conversations.first { $0.id == activeID }?.isRecoveredHistory == true
    }

    func setControlSending(_ value: Bool) {
        isSending = value
    }

    #if DEBUG
    /// Physical E2E only: Bot Chat is dashboard-routed and does not use the
    /// gateway after `send()` chooses the canonical bot path. This bypasses a
    /// presently slow model-catalogue read without replacing any Bot Chat code.
    func enableDashboardOnlyPhysicalE2E() { isConnected = true }
    #endif

    func send() {
        guard !activeIsRecoveredHistory else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty, !isSending else { return }

        // Management commands and a deliberately small set of natural control
        // intents stay on-device and use Hermes' authoritative management
        // APIs. Everything else continues into the actual agent unchanged.
        if handleChatControlIfNeeded(text) { return }

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

        // A direct bot chat is the bot's own canonical session, so the turn
        // goes into it as that bot — not to the default profile wearing a
        // "you are <bot>" directive, which is what made one assistant answer
        // in another's voice and kept cron's reports somewhere Alice never
        // looked. Mentions inside ordinary chats and channels are a different
        // thing and keep the path below.
        // `routedBotName`, never `botName` and never ownership: a recovered
        // legacy thread is filed under a bot but has no session to send into.
        if let directBot = conversations[index].routedBotName,
           conversations[index].isChannel != true {
            streamTask = Task { [weak self] in
                await self?.sendToBotChat(
                    profile: directBot,
                    conversationID: conversationID,
                    replyID: replyID,
                    text: text
                )
            }
            return
        }

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
        let invokedBotInfo = invokedBot.flatMap { name in
            cachedBots.first(where: { $0.name == name })
        }
        if let invokedBot, let specificModel = botModel(for: invokedBot) {
            model = specificModel
        }
        // The emergency direct-gateway bot fallback must use the bot profile's
        // provider with its model. Reusing Alice's selectedProvider can route a
        // perfectly valid bot model through the wrong account/provider.
        let provider: String?
        if botMetadataIsRemote, let botProvider = invokedBotInfo?.provider, !botProvider.isEmpty {
            provider = botProvider
        } else {
            provider = Self.provider(for: model, among: models, chosen: selectedProvider)
        }

        if let invokedBot {
            let botInfo = invokedBotInfo
            let botTitle = botCurrentName(for: invokedBot)
            let botDesc = botInfo?.detail ?? ""
            // Said this firmly because it is arguing with something. The
            // gateway answers every request as the default profile, so the
            // assistant's own standing prompt — its name, its warmth, the way
            // it addresses this particular reader — is already in force by the
            // time a bot's turn starts. "Respond in character" was too polite
            // to displace it, and a bot asked about deals answered in another
            // assistant's terms of endearment.
            var directive = """
                You are '\(botTitle)', a separate assistant with a voice of your own. \
                Any persona, name, personality or form of address established earlier \
                in this system prompt belongs to a different assistant and does not \
                apply to you: do not use its name for yourself, do not use terms of \
                endearment or a warm companion's register, and do not carry over its \
                habits of speech. Speak plainly as yourself unless your own \
                description below says otherwise.
                """
            if !botDesc.isEmpty {
                directive += "\n\nWhat you are for: \(botDesc)"
            }
            turns.insert(HermesClient.Turn(role: "system", content: .text(directive)), at: 0)
        }

        let preferRuns = manifest?.supportsRuns ?? true
        let useRunIdempotency = manifest?.supportsRunIdempotency ?? false
        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.stream(
                messages: turns,
                model: model,
                provider: provider,
                profile: invokedBot,
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
                    message: error.localizedDescription,
                    limit: nil
                )
            }
            self.finish(replyID, conversationID: conversationID)
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
        // A bot chat's run lives on the agent, not in this task: cancelling
        // here would only stop listening. Tell the session to stop.
        if let index = conversations.firstIndex(where: { $0.id == activeID }),
           let sessionID = conversations[index].hermesSessionID,
           conversations[index].isCanonicalBotChat {
            Task { [weak self] in
                guard let source = await self?.botChatSource() else { return }
                try? await source.interrupt(sessionID: sessionID)
            }
        }
        streamTask?.cancel()
        streamTask = nil
        isSending = false
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

        // Canonical Bot Chats receive approvals over the dashboard socket.
        // Their `runID` field historically held the request id; do not send it
        // to `/v1/runs`, which is a different server and identity domain.
        if conversations[location.chat].isCanonicalBotChat {
            let requestID = approval.requestID ?? approval.runID
            guard let sessionID = conversations[location.chat].hermesSessionID,
                  let source = await botChatSource()
            else {
                setApprovalFailure(messageID, "The Hermes dashboard is not connected.")
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
                setApprovalFailure(messageID, error.localizedDescription)
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
            if streamTask == nil {
                resumeRun(
                    runID: approval.runID,
                    replyID: messageID,
                    conversationID: conversationID,
                    profile: profile
                )
            }
        } catch {
            setApprovalFailure(messageID, error.localizedDescription)
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
        guard streamTask == nil else { return }
        isSending = true
        streamTask = Task { [weak self] in
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
                    message: error.localizedDescription,
                    limit: nil
                )
            }
            self.finish(replyID, conversationID: conversationID)
        }
    }

    private func apply(_ event: ChatEvent, to id: String, conversationID: String) {
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        let chat = location.chat
        let index = location.message
        let eventProfile = conversations[chat].messages[index].botName
            ?? conversations[chat].routedBotName
        let eventLabel = eventProfile.map { botCurrentName(for: $0) } ?? "Alice"

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

        case let .run(runID, status, output):
            conversations[chat].messages[index].runID = runID
            conversations[chat].messages[index].runStatus = status
            if status != .waitingForApproval {
                conversations[chat].messages[index].approval = nil
            }
            if let output { conversations[chat].messages[index].content = output }
            if status.isTerminal {
                conversations[chat].messages[index].pending = false
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
            let suffix = approval.requestID ?? approval.runID
            observe(AliceEvent(
                id: "run-approval:\(approval.runID):\(suffix)",
                kind: .needsInput, severity: .needsAttention,
                profile: eventProfile, title: "Needs your approval",
                summary: "\(eventLabel) is waiting for permission to continue.",
                detail: approval.command ?? approval.detail, occurred: Date(),
                reference: AliceEvent.Reference(
                    transport: .gatewayRun, runID: approval.runID,
                    profile: eventProfile, requestID: approval.requestID,
                    conversationID: conversationID
                ),
                standing: .waiting,
                approvalChoices: approval.choices
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
    }

    private func fail(
        _ id: String,
        conversationID: String,
        message: String,
        limit: ModelLimit?
    ) {
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        let chat = location.chat
        let index = location.message
        conversations[chat].messages[index].pending = false
        conversations[chat].messages[index].error = message
        conversations[chat].messages[index].errorLimit = limit
        if conversations[chat].messages[index].content.isEmpty {
            conversations[chat].messages[index].content = message
        }
    }

    private func finish(_ id: String, conversationID: String) {
        isSending = false
        streamTask = nil
        guard let location = messageLocation(id, conversationID: conversationID) else { return }
        let chat = location.chat
        let index = location.message
        conversations[chat].messages[index].pending = false

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
        ]
        return openings.contains(where: lowered.hasPrefix) ? trimmed : nil
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
        if conversationsUnreadable != nil { return }
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        defaults.set(data, forKey: Keys.conversations)
    }

    /// Why the saved conversations could not be read, if they could not.
    ///
    /// Distinct from "there are none": an empty app and an unreadable archive
    /// look identical on screen, and only one of them is safe to write over.
    private(set) var conversationsUnreadable: String?

    /// Where the unreadable bytes were set aside, so they are recoverable.
    nonisolated static let salvageKey = "alice.conversations.salvage"

    /// A description of a decode failure with nothing private in it.
    ///
    /// The coding path names fields and indexes, never contents, so this can
    /// go in a diagnostic without carrying anyone's messages with it.
    nonisolated static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(type(of: error))" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath
                .map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: " → ")
        }
        switch decoding {
        case let .keyNotFound(key, context):
            return "keyNotFound(\"\(key.stringValue)\") at [\(path(context))]"
        case let .typeMismatch(type, context):
            return "typeMismatch(\(type)) at [\(path(context))]"
        case let .valueNotFound(type, context):
            return "valueNotFound(\(type)) at [\(path(context))]"
        case let .dataCorrupted(context):
            return "dataCorrupted at [\(path(context))]"
        @unknown default:
            return "decodingError"
        }
    }

    /// Reads the saved conversations, and refuses to guess when it cannot.
    ///
    /// The previous version was one `try?` and a `guard … else { return }`, so
    /// an archive it could not decode looked exactly like a new install — and
    /// the next save wrote the empty result over it. That is how a build that
    /// merely added a field erased every conversation on the phone.
    private func loadConversations() {
        guard let data = defaults.data(forKey: Keys.conversations), !data.isEmpty
        else { return }  // Genuinely nothing saved. Writing is safe.
        do {
            let saved = try JSONDecoder().decode([Conversation].self, from: data)
            conversationsUnreadable = nil
            if !saved.isEmpty { conversations = saved }
        } catch {
            // Keep the bytes before anything else touches this key, and stop
            // writing. The user sees an app that cannot read its history —
            // which is true — rather than one that has none.
            if defaults.data(forKey: Self.salvageKey) == nil {
                defaults.set(data, forKey: Self.salvageKey)
            }
            conversationsUnreadable = Self.describe(error)
        }
    }

    /// Batches of recovered history already folded in, so a second import
    /// adds nothing.
    nonisolated static let appliedRecoveryKey = "alice.recovery.applied"

    var appliedRecoveryBatches: Set<String> {
        Set(defaults.stringArray(forKey: Self.appliedRecoveryKey) ?? [])
    }

    /// What importing a recovery archive would do. Changes nothing.
    func planRecovery(_ data: Data) throws -> RecoveryPlan {
        let archive = try RecoveryImporter.read(data)
        var plan = RecoveryImporter.plan(
            archive, into: conversations, appliedBatches: appliedRecoveryBatches
        )
        // A dry run that does not check the preconditions is a dry run of a
        // different operation than the one Apply would perform.
        let unmet = RecoveryImporter.unmetPreconditions(archive, against: conversations)
        if !unmet.isEmpty { plan.refusal = unmet.joined(separator: "; ") }
        return plan
    }

    /// Re-files already-imported history under the bot it belongs to.
    ///
    /// The first import set `botName` to nil to protect routing, which also
    /// dropped the history into Home. This puts `legacyBotName` on those same
    /// conversations — metadata only, the 67 recovered turns are not touched.
    @discardableResult
    func migrateRecoveryAssociations(_ data: Data) throws -> Int {
        let archive = try RecoveryImporter.read(data)
        let before = conversations.reduce(0) { $0 + $1.messages.count }
        let migrated = RecoveryImporter.migrateAssociations(conversations, using: archive)
        let after = migrated.reduce(0) { $0 + $1.messages.count }
        // A metadata migration that changed a message count has done something
        // it was not asked to.
        guard before == after else { return 0 }
        let changed = zip(conversations, migrated).filter {
            $0.legacyBotName != $1.legacyBotName || $0.botName != $1.botName
        }.count
        conversations = migrated
        persistConversations()
        return changed
    }

    /// Folds a recovery archive in. Explicit: nothing calls this on launch.
    @discardableResult
    func importRecovery(_ data: Data) throws -> RecoveryPlan {
        let archive = try RecoveryImporter.read(data)
        var plan = RecoveryImporter.plan(
            archive, into: conversations, appliedBatches: appliedRecoveryBatches
        )
        // Preconditions, checked before anything is written. A patch is built
        // against a known state; applying it to a different one would put
        // turns somewhere they do not belong.
        let unmet = RecoveryImporter.unmetPreconditions(archive, against: conversations)
        if !unmet.isEmpty {
            plan.refusal = unmet.joined(separator: "; ")
            return plan
        }
        let before = conversations.reduce(0) { $0 + $1.messages.count }
        let updated = RecoveryImporter.apply(archive, to: conversations)
        let after = updated.reduce(0) { $0 + $1.messages.count }
        let expected = before + plan.messagesAdded - plan.removals.count
        guard after == expected else {
            plan.refusal = "count would be \(after), expected \(expected) — nothing written"
            return plan
        }
        conversations = updated
        defaults.set(
            Array(appliedRecoveryBatches.union([archive.batchID])),
            forKey: Self.appliedRecoveryKey
        )
        persistConversations()
        return plan
    }

    /// Puts a salvaged archive back once it can be read again.
    ///
    /// Called on launch: a build that fixes the decoder finds the bytes the
    /// broken one set aside and restores them, so recovery does not depend on
    /// anyone noticing.
    func restoreSalvagedConversationsIfPossible() {
        guard let salvaged = defaults.data(forKey: Self.salvageKey),
              let saved = try? JSONDecoder().decode([Conversation].self, from: salvaged),
              !saved.isEmpty
        else { return }
        let live = (defaults.data(forKey: Keys.conversations))
            .flatMap { try? JSONDecoder().decode([Conversation].self, from: $0) } ?? []
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
