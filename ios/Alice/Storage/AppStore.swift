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
    var activeID: String?
    var draft: String = ""
    private(set) var isSending = false

    private let client = HermesClient()
    private let defaults = UserDefaults.standard
    private var streamTask: Task<Void, Never>?

    private enum Keys {
        static let theme = "alice.theme"
        static let accent = "alice.accent"
        static let gateway = "alice.gateway"
        static let model = "alice.model"
        static let conversations = "alice.conversations"
    }

    init() {
        if let raw = defaults.string(forKey: Keys.theme),
           let value = ThemeChoice(rawValue: raw) { theme = value }
        if let raw = defaults.string(forKey: Keys.accent),
           let value = Accent(rawValue: raw) { accent = value }
        gatewayURL = defaults.string(forKey: Keys.gateway) ?? ""
        selectedModel = defaults.string(forKey: Keys.model)
        loadConversations()
        activeID = conversations.first?.id
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

        do {
            manifest = try await client.capabilities()
            reachedSomething = true
        } catch {
            manifest = nil
            firstFailure = error
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
        case .skills: try await client.skills()
        case .toolsets: try await client.toolsets()
        case .addons: try await client.mcpServers()
        }
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        try await client.toggleSkill(name: name, enabled: enabled)
    }

    func supports(_ capability: String) -> Bool {
        manifest?.supports(capability) ?? false
    }

    // MARK: - Conversations

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
        if activeID == id { activeID = conversations.first?.id }
        persistConversations()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, isConnected else { return }
        guard let index = conversations.firstIndex(where: { $0.id == activeID })
        else { return }

        draft = ""
        isSending = true

        let user = Message(
            id: UUID().uuidString, role: .user, content: text, createdAt: Date()
        )
        let replyID = UUID().uuidString
        conversations[index].messages.append(user)
        conversations[index].messages.append(
            Message(
                id: replyID, role: .assistant, content: "",
                createdAt: Date(), pending: true
            )
        )
        if conversations[index].title == "New chat" {
            conversations[index].title = String(text.prefix(40))
        }
        conversations[index].updatedAt = Date()

        let turns = conversations[index].messages
            .filter { !$0.pending && $0.error == nil }
            .map { HermesClient.Turn(role: $0.role.rawValue, content: $0.content) }
        let model = selectedModel
        let provider = models.first { $0.id == model }?.provider

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.stream(
                messages: turns, model: model, provider: provider
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
        if conversations[chat].messages[index].content.isEmpty,
           conversations[chat].messages[index].error == nil {
            conversations[chat].messages[index].content = "Couldn’t reply."
            conversations[chat].messages[index].incomplete = true
        }
        persistConversations()
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
