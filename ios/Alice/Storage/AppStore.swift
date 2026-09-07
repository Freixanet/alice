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

    /// Temporary. Keeps this build to loading state and importing recovered
    /// history: no bot-chat sync, no socket, no sends. It exists so a recovery
    /// on the phone cannot be confused by the unvalidated WebSocket path, and
    /// comes out once that path is proven.
    #if DEBUG
    nonisolated static let recoverySafeMode = true
    #else
    nonisolated static let recoverySafeMode = false
    #endif

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
        confirmExpensive: Bool = false
    ) async throws -> ModelAssignmentResult {
        try await dashboard.setMainModel(
            profile: profile, provider: provider, model: model,
            confirmExpensive: confirmExpensive
        )
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
        if !Self.recoverySafeMode {
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
        if Self.recoverySafeMode { return }
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
        if Self.recoverySafeMode { return }
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
            try await source.submit(
                profile: profile, sessionID: chat.resolvedID, text: text
            )
            for await event in events {
                guard event.sessionID.isEmpty || event.sessionID == chat.resolvedID
                else { continue }
                if let chatEvent = Self.chatEvent(from: event) {
                    apply(chatEvent, to: replyID, conversationID: conversationID)
                }
                if event.type == "message.complete" { break }
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
            // The stream already delivered the body as deltas; the completion
            // frame only says the turn is over.
            return .run(
                id: (event.payload["id"] as? String) ?? event.sessionID,
                status: .completed,
                output: nil
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
            guard let title = event.payload["title"] as? String else { return nil }
            return .approval(Message.Approval(
                runID: (event.payload["request_id"] as? String) ?? event.sessionID,
                title: title,
                detail: event.payload["detail"] as? String,
                command: event.payload["command"] as? String,
                choices: Message.ApprovalChoice.allCases
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
        // Recovery safe mode blocks bot-session mutation, not harmless Bot Mode
        // roster/config reads performed elsewhere through the same transport.
        guard !Self.recoverySafeMode, let rpcClient = await dashboardRPC() else { return nil }
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

    func send() {
        guard !activeIsRecoveredHistory else { return }
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
           conversations[index].isChannel != true, !Self.recoverySafeMode {
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

        let profile = conversations[location.chat].messages[location.message].botName
        do {
            try await client.respondToRunApproval(
                runID: approval.runID,
                choice: choice,
                profile: profile
            )
            guard let refreshed = messageLocation(messageID) else { return }
            conversations[refreshed.chat].messages[refreshed.message].approval = nil
            conversations[refreshed.chat].messages[refreshed.message].runStatus = .running
            conversations[refreshed.chat].messages[refreshed.message].pending = true
            persistConversations()

            // A normal live run already has a stream waiting for this response.
            // If the app was relaunched or SSE had died, reattach explicitly.
            if streamTask == nil {
                resumeRun(
                    runID: approval.runID,
                    replyID: messageID,
                    conversationID: conversations[refreshed.chat].id,
                    profile: profile
                )
            }
        } catch {
            guard let refreshed = messageLocation(messageID) else { return }
            conversations[refreshed.chat].messages[refreshed.message].approval?.resolving = false
            conversations[refreshed.chat].messages[refreshed.message].approval?.error =
                error.localizedDescription
            persistConversations()
        }
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

        case let .approval(approval):
            conversations[chat].messages[index].runID = approval.runID
            conversations[chat].messages[index].runStatus = .waitingForApproval
            conversations[chat].messages[index].approval = approval
            conversations[chat].messages[index].pending = true
            persistConversations()

        case let .failure(message, limit):
            fail(
                id,
                conversationID: conversationID,
                message: message,
                limit: limit
            )
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
    private func persistConversations() {
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
