import Foundation

enum ChatControlRequest: Equatable {
    case help
    case bots
    case botOpen(identifier: String)
    case botCreate(name: String)
    case botRename(identifier: String, title: String)
    case botDelete(identifier: String, confirm: Bool)
    case routines(profile: String?)
    case routineCreate(name: String, prompt: String, schedule: String, deliver: String, profile: String?)
    case projects(profile: String?)
    case memory(profile: String?)
    case model(profile: String?)
    case providers(profile: String?)
    case usage(profile: String?, days: Int)
    case config(profile: String?)
    case routine(action: String, identifier: String, profile: String?)
    case routineDelete(identifier: String, profile: String?, confirm: Bool)
    case projectUse(identifier: String?, profile: String?)
    case projectCreate(name: String, folder: String?, profile: String?)
    case projectArchive(identifier: String, archived: Bool, profile: String?)
    case projectDelete(identifier: String, profile: String?, confirm: Bool)
    case memoryAdd(target: String, text: String, profile: String?)
    case memoryRemove(target: String, text: String, profile: String?, confirm: Bool)
    case memoryReplace(target: String, oldText: String, newText: String, profile: String?)
    case modelSet(provider: String, model: String, profile: String?, confirm: Bool)
    case providerConnect(identifier: String, profile: String?)
    case providerDisconnect(identifier: String, profile: String?, confirm: Bool)
    case configSet(key: String, value: String, profile: String?)
}

enum ChatControlCenter {
    static func parse(_ raw: String) -> ChatControlRequest? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.hasPrefix("/") { return naturalRead(text) }

        var tokens = tokenize(text)
        guard let command = tokens.first?.lowercased() else { return nil }
        tokens.removeFirst()
        let profile = takeOption("--profile", from: &tokens)
        let confirm = takeFlag("--confirm", from: &tokens)

        switch command {
        case "/control": return tokens.isEmpty ? .help : nil
        case "/bots": return tokens.isEmpty ? .bots : nil
        case "/bot":
            guard tokens.count >= 2 else { return nil }
            switch tokens[0].lowercased() {
            case "open": return .botOpen(identifier: tokens.dropFirst().joined(separator: " "))
            case "create": return .botCreate(name: tokens.dropFirst().joined(separator: " "))
            case "rename":
                guard let title = takeOption("--to", from: &tokens), tokens.count >= 2 else { return nil }
                return .botRename(identifier: tokens.dropFirst().joined(separator: " "), title: title)
            case "delete": return .botDelete(identifier: tokens.dropFirst().joined(separator: " "), confirm: confirm)
            default: return nil
            }
        case "/routines": return tokens.isEmpty ? .routines(profile: profile) : nil
        case "/projects": return tokens.isEmpty ? .projects(profile: profile) : nil
        case "/memory":
            if tokens.isEmpty { return .memory(profile: profile) }
            let action = tokens.first?.lowercased()
            if action == "replace" {
                guard tokens.count >= 2 else { return nil }
                let target = tokens[1].lowercased()
                guard target == "user" || target == "memory",
                      let old = takeOption("--old", from: &tokens),
                      let new = takeOption("--new", from: &tokens)
                else { return nil }
                return .memoryReplace(target: target, oldText: old, newText: new, profile: profile)
            }
            guard tokens.count >= 3 else { return nil }
            let target = tokens[1].lowercased()
            guard target == "user" || target == "memory" else { return nil }
            let body = tokens.dropFirst(2).joined(separator: " ")
            if action == "add" { return .memoryAdd(target: target, text: body, profile: profile) }
            if action == "remove" { return .memoryRemove(target: target, text: body, profile: profile, confirm: confirm) }
            return nil
        case "/model":
            if tokens.isEmpty { return .model(profile: profile) }
            guard tokens.first?.lowercased() == "set", tokens.count == 3 else { return nil }
            return .modelSet(provider: tokens[1], model: tokens[2], profile: profile, confirm: confirm)
        case "/providers": return tokens.isEmpty ? .providers(profile: profile) : nil
        case "/usage":
            let days = tokens.first.flatMap(Int.init) ?? 30
            guard tokens.count <= 1, (1...365).contains(days) else { return nil }
            return .usage(profile: profile, days: days)
        case "/config":
            if tokens.isEmpty { return .config(profile: profile) }
            guard tokens.first?.lowercased() == "set", tokens.count >= 3 else { return nil }
            return .configSet(key: tokens[1], value: tokens.dropFirst(2).joined(separator: " "), profile: profile)
        case "/routine":
            guard tokens.count >= 2 else { return nil }
            let action = tokens[0].lowercased()
            if action == "create" {
                guard let schedule = takeOption("--schedule", from: &tokens),
                      let prompt = takeOption("--prompt", from: &tokens),
                      tokens.count >= 2
                else { return nil }
                let deliver = takeOption("--deliver", from: &tokens) ?? "local"
                return .routineCreate(
                    name: tokens.dropFirst().joined(separator: " "),
                    prompt: prompt, schedule: schedule, deliver: deliver, profile: profile
                )
            }
            if action == "delete" {
                return .routineDelete(identifier: tokens.dropFirst().joined(separator: " "), profile: profile, confirm: confirm)
            }
            guard ["run", "pause", "resume"].contains(action) else { return nil }
            return .routine(action: action, identifier: tokens.dropFirst().joined(separator: " "), profile: profile)
        case "/project":
            guard let action = tokens.first?.lowercased() else { return nil }
            if action == "use" {
                guard tokens.count >= 2 else { return nil }
                let id = tokens.dropFirst().joined(separator: " ")
                return .projectUse(identifier: ["none", "off", "home"].contains(id.lowercased()) ? nil : id, profile: profile)
            }
            if action == "create" {
                guard tokens.count >= 2 else { return nil }
                let folder = takeOption("--folder", from: &tokens)
                return .projectCreate(name: tokens.dropFirst().joined(separator: " "), folder: folder, profile: profile)
            }
            if ["archive", "restore"].contains(action) {
                guard tokens.count >= 2 else { return nil }
                return .projectArchive(
                    identifier: tokens.dropFirst().joined(separator: " "),
                    archived: action == "archive", profile: profile
                )
            }
            if action == "delete" {
                guard tokens.count >= 2 else { return nil }
                return .projectDelete(
                    identifier: tokens.dropFirst().joined(separator: " "), profile: profile, confirm: confirm
                )
            }
            return nil
        case "/provider":
            guard tokens.count == 2 else { return nil }
            switch tokens[0].lowercased() {
            case "connect": return .providerConnect(identifier: tokens[1], profile: profile)
            case "disconnect": return .providerDisconnect(identifier: tokens[1], profile: profile, confirm: confirm)
            default: return nil
            }
        default: return nil
        }
    }

    static func naturalRead(_ raw: String) -> ChatControlRequest? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[?.!¡¿]+|[?.!¡¿]+$"#, with: "", options: .regularExpression)
        let text = folded(source)
        let phrases: [(String, ChatControlRequest)] = [
            ("show my bots", .bots), ("list my bots", .bots), ("what bots do i have", .bots),
            ("muestrame mis bots", .bots), ("lista mis bots", .bots), ("que bots tengo", .bots),
            ("show my routines", .routines(profile: nil)), ("list my routines", .routines(profile: nil)),
            ("muestrame mis rutinas", .routines(profile: nil)), ("lista mis rutinas", .routines(profile: nil)),
            ("show my projects", .projects(profile: nil)), ("list my projects", .projects(profile: nil)),
            ("muestrame mis proyectos", .projects(profile: nil)), ("lista mis proyectos", .projects(profile: nil)),
            ("show my memory", .memory(profile: nil)), ("muestrame mi memoria", .memory(profile: nil)),
            ("what model am i using", .model(profile: nil)), ("que modelo estoy usando", .model(profile: nil)),
            ("show my providers", .providers(profile: nil)), ("muestrame mis providers", .providers(profile: nil)),
            ("show my usage", .usage(profile: nil, days: 30)), ("muestrame mi uso", .usage(profile: nil, days: 30)),
            ("show my configuration", .config(profile: nil)), ("muestrame mi configuracion", .config(profile: nil)),
        ]
        if let read = phrases.first(where: { text == $0.0 })?.1 { return read }

        func tail(after prefixes: [String]) -> String? {
            for prefix in prefixes where text.hasPrefix(folded(prefix)) {
                guard source.count >= prefix.count else { continue }
                let cut = source.index(source.startIndex, offsetBy: prefix.count)
                let rest = String(source[cut...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
            return nil
        }

        if let name = tail(after: ["abre el bot ", "open bot "]) { return .botOpen(identifier: name) }
        if let name = tail(after: ["crea un bot llamado ", "create a bot called "]) { return .botCreate(name: name) }
        if let name = tail(after: ["ejecuta la rutina ", "run routine "]) {
            return .routine(action: "run", identifier: name, profile: nil)
        }
        if let name = tail(after: ["pausa la rutina ", "pause routine "]) {
            return .routine(action: "pause", identifier: name, profile: nil)
        }
        if let name = tail(after: ["reanuda la rutina ", "resume routine "]) {
            return .routine(action: "resume", identifier: name, profile: nil)
        }
        if let name = tail(after: ["activa el proyecto ", "use project "]) {
            return .projectUse(identifier: name, profile: nil)
        }
        if ["desactiva el proyecto", "quita el proyecto activo", "clear active project"].contains(text) {
            return .projectUse(identifier: nil, profile: nil)
        }
        if let fact = tail(after: ["recuerda que ", "remember that ", "anade a mi memoria "]) {
            return .memoryAdd(target: "memory", text: fact, profile: nil)
        }
        if let fact = tail(after: ["anade a mi perfil de usuario ", "add to my user profile "]) {
            return .memoryAdd(target: "user", text: fact, profile: nil)
        }
        if let rest = tail(after: ["cambia el modelo a ", "set model to "]) {
            let separators = [" con ", " via ", " with "]
            for separator in separators {
                if let range = rest.range(of: separator, options: .backwards) {
                    let model = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let provider = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !model.isEmpty, !provider.isEmpty {
                        return .modelSet(provider: provider, model: model, profile: nil, confirm: false)
                    }
                }
            }
        }
        return nil
    }

    static func tokenize(_ text: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?
        var escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func takeOption(_ name: String, from tokens: inout [String]) -> String? {
        guard let i = tokens.firstIndex(where: { $0.lowercased() == name }), i + 1 < tokens.count else { return nil }
        let value = tokens[i + 1]
        tokens.removeSubrange(i...i + 1)
        return value
    }

    private static func takeFlag(_ name: String, from tokens: inout [String]) -> Bool {
        guard let i = tokens.firstIndex(where: { $0.lowercased() == name }) else { return false }
        tokens.remove(at: i)
        return true
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[?.!¡¿]+|[?.!¡¿]+$"#, with: "", options: .regularExpression)
    }
}

@MainActor
extension AppStore {
    @discardableResult
    func handleChatControlIfNeeded(_ rawText: String) -> Bool {
        guard draftAttachments.isEmpty,
              let request = ChatControlCenter.parse(rawText),
              !activeIsRecoveredHistory, !isSending,
              let chatIndex = conversations.firstIndex(where: { $0.id == activeID })
        else { return false }

        let conversationID = conversations[chatIndex].id
        let replyID = UUID().uuidString
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        setControlSending(true)

        conversations[chatIndex].messages.append(
            Message(id: UUID().uuidString, role: .user, content: text, createdAt: Date())
        )
        conversations[chatIndex].messages.append(
            Message(id: replyID, role: .assistant, content: "", createdAt: Date(), pending: true)
        )
        if conversations[chatIndex].title == "New chat" {
            conversations[chatIndex].title = String(text.prefix(40))
        }
        conversations[chatIndex].updatedAt = Date()
        persistConversations()

        Task { [weak self] in
            guard let self else { return }
            if !self.dashboardReady { await self.restoreDashboard() }
            do {
                let result = try await self.executeChatControl(request, conversationID: conversationID)
                self.finishChatControl(replyID, conversationID: conversationID, content: result.text)
                if let bot = result.openBot { _ = self.openBotConversation(for: bot) }
            } catch {
                self.finishChatControl(
                    replyID, conversationID: conversationID,
                    content: "Could not complete that control action: \(diagnosticMessage(error))",
                    error: diagnosticMessage(error)
                )
            }
        }
        return true
    }

    private struct ControlResult {
        var text: String
        var openBot: BotRow? = nil
    }

    private func finishChatControl(
        _ replyID: String, conversationID: String, content: String, error: String? = nil
    ) {
        guard let chat = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[chat].messages.firstIndex(where: { $0.id == replyID })
        else { setControlSending(false); return }
        conversations[chat].messages[message].content = content
        conversations[chat].messages[message].pending = false
        conversations[chat].messages[message].error = error
        conversations[chat].updatedAt = Date()
        setControlSending(false)
        persistConversations()
    }

    private func executeChatControl(
        _ request: ChatControlRequest, conversationID: String
    ) async throws -> ControlResult {
        switch request {
        case .help:
            return ControlResult(text: Self.controlHelp)
        case .bots:
            let rows = orderedBots(try await bots())
            guard !rows.isEmpty else { return ControlResult(text: "You do not have any secondary Hermes bots.") }
            let body = rows.map { bot in
                let model = [bot.provider, bot.model].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " / ")
                return "- **\(botCurrentName(for: bot))** (`\(bot.name)`)" + (model.isEmpty ? "" : " — \(model)")
            }.joined(separator: "\n")
            return ControlResult(text: "**Bots**\n\n\(body)\n\nUse `/bot open <name>` or `/bot create <name>`.")
        case let .botOpen(identifier):
            let bot = try await resolveBot(identifier)
            return ControlResult(text: "Opening **\(botCurrentName(for: bot))**.", openBot: bot)
        case let .botCreate(name):
            let slug = try await createBot(displayName: name, description: "")
            _ = try await bots()
            return ControlResult(text: "Created bot **\(name)** (`\(slug)`).")
        case let .botRename(identifier, title):
            let bot = try await resolveBot(identifier)
            try await setBotTitle(bot, title: title)
            _ = try await bots()
            return ControlResult(text: "Renamed **\(botCurrentName(for: bot))** to **\(title)**.")
        case let .botDelete(identifier, confirm):
            let bot = try await resolveBot(identifier)
            guard confirm else {
                return ControlResult(text: "Deleting **\(botCurrentName(for: bot))** removes its Hermes profile. Run `/bot delete \(bot.name) --confirm` to confirm.")
            }
            try await deleteBot(bot.name)
            _ = try? await bots()
            return ControlResult(text: "Deleted bot **\(botCurrentName(for: bot))** (`\(bot.name)`).")
        case let .routines(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let rows = try await routines(for: profile)
            let label = try await controlProfileLabel(profile)
            guard !rows.isEmpty else { return ControlResult(text: "**Routines — \(label)**\n\nNo routines.") }
            let body = rows.map { row in
                "- **\(row.name)** (`\(row.id)`) — \(row.effectiveState), \(row.schedule)"
            }.joined(separator: "\n")
            return ControlResult(text: "**Routines — \(label)**\n\n\(body)\n\nUse `/routine run|pause|resume <name-or-id>`.")
        case let .projects(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let listing = try await projectListing(profile: profile)
            let label = try await controlProfileLabel(profile)
            let rows = listing.projects.filter { !$0.archived }
            guard !rows.isEmpty else { return ControlResult(text: "**Projects — \(label)**\n\nNo active projects.") }
            let body = rows.map { project in
                let active = project.id == listing.activeID ? " — **active**" : ""
                let folder = project.primaryPath.map { " — `\($0)`" } ?? ""
                return "- **\(project.name)** (`\(project.id)`)\(active)\(folder)"
            }.joined(separator: "\n")
            return ControlResult(text: "**Projects — \(label)**\n\n\(body)\n\nUse `/project use <name>`, `/project use none`, or `/project create <name>`.")
        case let .memory(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let snapshot = try await memorySnapshot(profile: profile)
            let label = try await controlProfileLabel(profile)
            var sections: [String] = []
            for target in snapshot.targets {
                let entries = target.entries.isEmpty ? "_No entries._" : target.entries.map { "- \($0)" }.joined(separator: "\n")
                sections.append("**\(target.label)** — \(target.used)/\(target.limit) chars\n\(entries)")
            }
            return ControlResult(text: "**Memory — \(label)**\n\n" + sections.joined(separator: "\n\n") + "\n\nAdd with `/memory add user <text>` or `/memory add memory <text>`.")
        case let .model(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let info = try await profileModelInfo(profile: profile)
            let label = try await controlProfileLabel(profile)
            var caps: [String] = []
            if info.capabilities.tools { caps.append("tools") }
            if info.capabilities.vision { caps.append("vision") }
            if info.capabilities.reasoning { caps.append("reasoning") }
            let context = info.effectiveContextLength > 0 ? "\nContext: \(Self.compactNumber(info.effectiveContextLength)) tokens" : ""
            let capText = caps.isEmpty ? "" : "\nCapabilities: \(caps.joined(separator: ", "))"
            return ControlResult(text: "**Model — \(label)**\n\nProvider: **\(info.provider)**\nModel: **\(info.model)**\(context)\(capText)\n\nSwitch with `/model set <provider> <model>`.")
        case let .providers(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let providers = try await inferenceProviders(profile: profile)
            let oauth = (try? await oauthProviderStates(profile: profile)) ?? []
            let oauthMap = Dictionary(uniqueKeysWithValues: oauth.map { ($0.id, $0) })
            let body = providers.map { provider in
                let connected = provider.authenticated || provider.isUserDefined || oauthMap[provider.slug]?.loggedIn == true
                return "- \(connected ? "✓" : "○") **\(provider.name)** (`\(provider.slug)`) — \(provider.totalModels) models"
            }.joined(separator: "\n")
            return ControlResult(text: "**Providers**\n\n\(body)\n\nOAuth providers can be started with `/provider connect <id>`. API keys stay in the secure Models & Providers editor and are never accepted in chat.")
        case let .usage(candidate, days):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let report = try await usage(profile: profile, days: days)
            let label = try await controlProfileLabel(profile)
            let cost = report.cost > 0 ? "\nCost: \(Self.money(report.cost))" : ""
            var text = "**Usage — \(label), last \(report.days) days**\n\nSessions: \(report.sessions)\nAPI calls: \(report.calls)\nInput: \(Self.compactNumber(report.inputTokens)) tokens\nOutput: \(Self.compactNumber(report.outputTokens)) tokens"
            if report.cacheReadTokens > 0 { text += "\nCache read: \(Self.compactNumber(report.cacheReadTokens))" }
            if report.reasoningTokens > 0 { text += "\nReasoning: \(Self.compactNumber(report.reasoningTokens))" }
            text += cost
            if !report.models.isEmpty {
                text += "\n\n**By model**\n" + report.models.prefix(6).map { row in
                    let provider = row.provider.map { " via \($0)" } ?? ""
                    return "- \(row.name)\(provider): \(Self.compactNumber(row.tokens)) tokens" + (row.cost > 0 ? ", \(Self.money(row.cost))" : "")
                }.joined(separator: "\n")
            }
            return ControlResult(text: text)
        case let .config(candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let config = try await hermesConfiguration(profile: profile)
            let label = try await controlProfileLabel(profile)
            return ControlResult(text: """
                **Hermes Configuration — \(label)**

                - Timezone: `\(config.timezone.isEmpty ? "system" : config.timezone)`
                - Approvals: `\(config.approvalsMode)`
                - Service tier: `\(config.serviceTier.isEmpty ? "default" : config.serviceTier)`
                - Long-term memory: \(config.memoryEnabled ? "on" : "off")
                - User profile memory: \(config.userProfileEnabled ? "on" : "off")
                - Context compression: \(config.compressionEnabled ? "on" : "off") at \(Int((config.compressionThreshold * 100).rounded()))%
                - Verify completed work: \(config.verifyGuidance ? "on" : "off")
                - Environment probe: \(config.environmentProbe ? "on" : "off")

                Change one with `/config set <key> <value>`.
                """)
        case let .routineCreate(name, prompt, schedule, deliver, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            try await addRoutine(for: profile, name: name, prompt: prompt, schedule: schedule, deliver: deliver)
            return ControlResult(text: "Created routine **\(name)** for **\(try await controlProfileLabel(profile))**.")
        case let .routine(action, identifier, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let row = try await resolveRoutine(identifier, profile: profile)
            switch action {
            case "run": try await triggerRoutine(row)
            case "pause": try await setRoutinePaused(row, paused: true)
            case "resume": try await setRoutinePaused(row, paused: false)
            default: break
            }
            return ControlResult(text: "Routine **\(row.name)**: \(action) accepted by Hermes.")
        case let .routineDelete(identifier, candidate, confirm):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let row = try await resolveRoutine(identifier, profile: profile)
            guard confirm else {
                return ControlResult(text: "Run `/routine delete \(row.id) --confirm` to delete **\(row.name)**.")
            }
            try await deleteRoutine(row)
            return ControlResult(text: "Deleted routine **\(row.name)**.")
        case let .projectUse(identifier, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            if let identifier {
                let project = try await resolveProject(identifier, profile: profile)
                try await setActiveProject(project.id, profile: profile)
                return ControlResult(text: "Active project is now **\(project.name)**.")
            }
            try await setActiveProject(nil, profile: profile)
            return ControlResult(text: "No Project is active for this profile.")
        case let .projectCreate(name, folder, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            try await createProject(profile: profile, name: name, folder: folder)
            return ControlResult(text: "Created Project **\(name)**" + (folder.map { " with `\($0)` as its workspace." } ?? "."))
        case let .projectArchive(identifier, archived, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let project = try await resolveProject(identifier, profile: profile)
            try await setProjectArchived(project.id, archived: archived, profile: profile)
            return ControlResult(text: "**\(project.name)** \(archived ? "archived" : "restored").")
        case let .projectDelete(identifier, candidate, confirm):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let project = try await resolveProject(identifier, profile: profile)
            guard confirm else {
                return ControlResult(text: "Run `/project delete \(project.id) --confirm` to permanently delete Project **\(project.name)**.")
            }
            try await deleteProject(project.id, profile: profile)
            return ControlResult(text: "Deleted Project **\(project.name)**.")
        case let .memoryAdd(target, text, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let snapshot = try await memorySnapshot(profile: profile)
            guard snapshot.targets.first(where: { $0.id == target })?.enabled == true else {
                throw HermesRPCClient.Failure(reason: "That memory target is disabled for this profile.")
            }
            _ = try await mutateMemory(profile: profile, target: target, action: "add", content: text)
            return ControlResult(text: "Added to **\(target == "user" ? "User profile" : "Memory")** for **\(try await controlProfileLabel(profile))**.")
        case let .memoryRemove(target, text, candidate, confirm):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            guard confirm else {
                return ControlResult(text: "Run `/memory remove \(target) \"\(text)\" --confirm` to remove the matching memory text.")
            }
            _ = try await mutateMemory(
                profile: profile, target: target, action: "remove", oldText: text
            )
            return ControlResult(text: "Removed the matching **\(target == "user" ? "User profile" : "Memory")** entry.")
        case let .memoryReplace(target, oldText, newText, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            _ = try await mutateMemory(
                profile: profile, target: target, action: "replace", content: newText, oldText: oldText
            )
            return ControlResult(text: "Updated the matching **\(target == "user" ? "User profile" : "Memory")** entry.")
        case let .modelSet(provider, model, candidate, confirm):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let providers = try await inferenceProviders(profile: profile)
            guard let found = providers.first(where: { $0.slug.caseInsensitiveCompare(provider) == .orderedSame }) else {
                throw HermesRPCClient.Failure(reason: "Hermes does not list provider ‘\(provider)’.")
            }
            guard found.authenticated || found.isUserDefined else {
                throw HermesRPCClient.Failure(reason: "Connect \(found.name) before selecting one of its models.")
            }
            guard found.models.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }) else {
                throw HermesRPCClient.Failure(reason: "\(found.name) does not currently advertise model ‘\(model)’.")
            }
            let resolvedModel = found.models.first { $0.caseInsensitiveCompare(model) == .orderedSame } ?? model
            let result = try await setProfileDefaultModel(
                profile: profile, provider: found.slug, model: resolvedModel, confirmExpensive: confirm
            )
            if result.confirmRequired && !confirm {
                let reason = result.confirmMessage.isEmpty ? "Hermes requires confirmation for this model." : result.confirmMessage
                return ControlResult(text: "\(reason)\n\nRun `\u{60}/model set \(found.slug) \(resolvedModel) --confirm\u{60}` to confirm.")
            }
            var text = "Default model changed to **\(resolvedModel)** via **\(found.name)**."
            if !result.staleAux.isEmpty {
                text += "\n\nAuxiliary assignments still pinned elsewhere: " + result.staleAux.map(\.task).joined(separator: ", ") + "."
            }
            return ControlResult(text: text)
        case let .providerConnect(identifier, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let states = try await oauthProviderStates(profile: profile)
            guard let provider = states.first(where: {
                $0.id.caseInsensitiveCompare(identifier) == .orderedSame || $0.name.caseInsensitiveCompare(identifier) == .orderedSame
            }) else {
                throw HermesRPCClient.Failure(reason: "That provider has no Hermes OAuth flow. API keys must be entered in the secure Models & Providers editor.")
            }
            if provider.loggedIn { return ControlResult(text: "**\(provider.name)** is already connected.") }
            guard provider.flow == "device_code" else {
                let command = provider.cliCommand.isEmpty ? "the provider's external login" : "`\(provider.cliCommand)`"
                return ControlResult(text: "**\(provider.name)** requires \(command); Hermes does not expose an in-app OAuth flow for it.")
            }
            let login = try await startOAuthLogin(provider: provider.id, profile: profile)
            return ControlResult(text: "**Connect \(provider.name)**\n\nCode: `\(login.userCode)`\n[Open verification page](\(login.verificationURL))\n\nHermes will finish the device-code flow on the Mac. Run `/providers` afterwards to verify the connected state.")
        case let .providerDisconnect(identifier, candidate, confirm):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            let states = try await oauthProviderStates(profile: profile)
            guard let provider = states.first(where: {
                $0.id.caseInsensitiveCompare(identifier) == .orderedSame || $0.name.caseInsensitiveCompare(identifier) == .orderedSame
            }) else { throw HermesRPCClient.Failure(reason: "Hermes does not list that OAuth provider.") }
            guard confirm else {
                return ControlResult(text: "Disconnecting **\(provider.name)** removes its Hermes OAuth session. Run `/provider disconnect \(provider.id) --confirm` to confirm.")
            }
            try await disconnectOAuth(provider: provider.id, profile: profile)
            return ControlResult(text: "Disconnected **\(provider.name)** from this Hermes profile.")
        case let .configSet(key, value, candidate):
            let profile = try await controlProfile(candidate, conversationID: conversationID)
            var config = try await hermesConfiguration(profile: profile)
            try Self.applyControlConfig(key: key, value: value, to: &config)
            try await saveHermesConfiguration(config, profile: profile)
            return ControlResult(text: "Updated `\(key)` for **\(try await controlProfileLabel(profile))**.")
        }
    }

    private func controlProfile(_ candidate: String?, conversationID: String) async throws -> String {
        if candidate == nil || candidate?.isEmpty == true {
            return conversations.first(where: { $0.id == conversationID })?.routedBotName ?? "default"
        }
        let choices = try await hermesProfiles()
        guard let match = choices.first(where: {
            $0.id.caseInsensitiveCompare(candidate!) == .orderedSame ||
            $0.label.caseInsensitiveCompare(candidate!) == .orderedSame
        }) else { throw HermesRPCClient.Failure(reason: "Hermes has no profile named ‘\(candidate!)’.") }
        return match.id
    }

    private func controlProfileLabel(_ profile: String) async throws -> String {
        if profile == "default" { return "Alice" }
        if let row = (try await hermesProfiles()).first(where: { $0.id == profile }) { return row.label }
        return profile
    }

    private func resolveBot(_ identifier: String) async throws -> BotRow {
        let rows = try await bots()
        let matches = rows.filter {
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.displayName.caseInsensitiveCompare(identifier) == .orderedSame ||
            botCurrentName(for: $0).caseInsensitiveCompare(identifier) == .orderedSame
        }
        guard matches.count == 1, let bot = matches.first else {
            throw HermesRPCClient.Failure(reason: matches.isEmpty ? "No bot matches ‘\(identifier)’." : "More than one bot matches ‘\(identifier)’.")
        }
        return bot
    }

    private func resolveRoutine(_ identifier: String, profile: String) async throws -> JobRow {
        let rows = try await routines(for: profile)
        let matches = rows.filter {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame || $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }
        guard matches.count == 1, let row = matches.first else {
            throw HermesRPCClient.Failure(reason: matches.isEmpty ? "No routine matches ‘\(identifier)’ in this profile." : "More than one routine has that name; use its id.")
        }
        return row
    }

    private func resolveProject(_ identifier: String, profile: String) async throws -> NamedProject {
        let rows = try await namedProjects(profile: profile)
        let matches = rows.filter {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.slug.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }
        guard matches.count == 1, let row = matches.first else {
            throw HermesRPCClient.Failure(reason: matches.isEmpty ? "No Project matches ‘\(identifier)’ in this profile." : "More than one Project matches that name; use its id.")
        }
        return row
    }

    private static func applyControlConfig(
        key rawKey: String, value rawValue: String, to config: inout HermesConfiguration
    ) throws {
        let key = rawKey.lowercased().replacingOccurrences(of: "_", with: "-")
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func bool(_ text: String) throws -> Bool {
            switch text.lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw HermesRPCClient.Failure(reason: "Use on/off for `\(rawKey)`.")
            }
        }
        switch key {
        case "timezone":
            guard value.isEmpty || TimeZone(identifier: value) != nil else {
                throw HermesRPCClient.Failure(reason: "Use a valid IANA timezone such as Europe/Madrid.")
            }
            config.timezone = value
        case "approvals", "approvals-mode":
            guard ["smart", "manual", "off"].contains(value.lowercased()) else {
                throw HermesRPCClient.Failure(reason: "Approvals must be smart, manual or off.")
            }
            config.approvalsMode = value.lowercased()
        case "service-tier":
            let normalized = value.lowercased() == "default" ? "" : value.lowercased()
            guard ["", "normal", "fast", "auto", "cold"].contains(normalized) else {
                throw HermesRPCClient.Failure(reason: "Service tier must be default, normal, fast, auto or cold.")
            }
            config.serviceTier = normalized
        case "memory", "memory-enabled": config.memoryEnabled = try bool(value)
        case "user-memory", "user-profile-enabled": config.userProfileEnabled = try bool(value)
        case "compression", "compression-enabled": config.compressionEnabled = try bool(value)
        case "compression-threshold":
            guard let number = Double(value.replacingOccurrences(of: "%", with: "")) else {
                throw HermesRPCClient.Failure(reason: "Compression threshold must be 30–90%.")
            }
            let fraction = number > 1 ? number / 100 : number
            guard (0.30...0.90).contains(fraction) else {
                throw HermesRPCClient.Failure(reason: "Compression threshold must be 30–90%.")
            }
            config.compressionThreshold = fraction
        case "verify", "verify-guidance": config.verifyGuidance = try bool(value)
        case "environment-probe": config.environmentProbe = try bool(value)
        default:
            throw HermesRPCClient.Failure(reason: "Alice intentionally exposes only the curated Hermes configuration keys shown by `/config`.")
        }
    }

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static func money(_ value: Double) -> String { String(format: "$%.2f", value) }

    private static let controlHelp = """
        **Alice control center**

        Read directly from Hermes:
        `/bots`, `/routines`, `/projects`, `/memory`, `/model`, `/providers`, `/usage 30`, `/config`

        Common actions:
        `/bot open <name>` · `/bot create <name>` · `/bot rename <name> --to <title>` · `/bot delete <name> --confirm`
        `/routine create <name> --schedule <expr> --prompt <text>` · `/routine run|pause|resume <name-or-id>` · `/routine delete <name-or-id> --confirm`
        `/project use <name|none>` · `/project create <name> [--folder <path>]` · `/project archive|restore <name>` · `/project delete <name> --confirm`
        `/memory add user|memory <text>` · `/memory remove user|memory <text> --confirm` · `/memory replace user|memory --old <text> --new <text>`
        `/model set <provider> <model> [--confirm]`
        `/provider connect <id>` · `/provider disconnect <id> --confirm`
        `/config set <key> <value>`

        Add `--profile <bot-or-profile>` to profile-scoped commands. In a bot's own chat, that bot is the default profile automatically.

        Simple questions such as “qué bots tengo”, “muéstrame mis proyectos” or “qué modelo estoy usando” are also handled locally without spending a model turn.
        """
}
