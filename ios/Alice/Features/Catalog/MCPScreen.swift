import SwiftUI

/// Full native management surface for Hermes' profile-scoped MCP servers.
/// Secrets are write-only: server env values returned by Hermes are redacted,
/// and Alice never feeds those redactions back into config.
struct MCPScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles: [MCPProfile] = [.init(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var pane: MCPPane = .servers
    @State private var servers: [MCPServerConfiguration] = []
    @State private var catalog = MCPCatalogSnapshot(entries: [], diagnostics: [])
    @State private var loading = false
    @State private var failure: String?
    @State private var query = ""
    @State private var busyServers: Set<String> = []
    @State private var testing: Set<String> = []
    @State private var testResults: [String: MCPServerTestResult] = [:]
    @State private var restartNote = false
    @State private var showAdd = false
    @State private var installEntry: MCPCatalogEntry?
    @State private var oauthServer: MCPServerConfiguration?
    @State private var deleting: MCPServerConfiguration?
    @State private var installing: Set<String> = []
    @State private var installActions: [String: HermesActionStatus] = [:]
    /// Install polls, so leaving the screen stops them. An unstructured Task
    /// outlives the view that started it: the poll kept asking the agent for
    /// an action status every 1.2s, and wrote it back into state nobody was
    /// looking at, until the install happened to finish.
    @State private var installPolls: [String: Task<Void, Never>] = [:]

    var body: some View {
        List {
            Section("Profile") {
                Picker("MCP for", selection: $selectedProfile) {
                    ForEach(profiles) { profile in
                        Text(profile.label).tag(profile.id)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }

            Section {
                Picker("MCP view", selection: $pane) {
                    ForEach(MCPPane.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Palette.card(scheme))
            }

            if restartNote {
                Section {
                    Label(
                        "Enable/disable changes take effect on the next gateway or agent session.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .listRowBackground(Palette.card(scheme))
                }
            }

            if pane == .servers { serverSections } else { catalogSections }

            if let failure {
                Section {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("MCP")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .searchable(text: $query, prompt: pane == .servers ? "Search servers" : "Search catalog")
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in resetAndReload() }
        .onChange(of: pane) { _, _ in query = "" }
        .onDisappear { stopInstallPolls() }
        .refreshable { await load() }
        .toolbar {
            if pane == .servers {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("Add Server", systemImage: "plus") }
                        .disabled(!store.dashboardReady)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMCPServerSheet(profile: selectedProfile) {
                Task { await load() }
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(item: $installEntry) { entry in
            InstallMCPCatalogSheet(entry: entry, profile: selectedProfile) { result in
                installEntry = nil
                handleInstall(result)
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(item: $oauthServer) { server in
            MCPOAuthSheet(server: server, profile: selectedProfile) { tools in
                testResults[server.name] = MCPServerTestResult(
                    ok: true, error: nil, tools: tools, prompts: 0, resources: 0
                )
                oauthServer = nil
                Task { await load() }
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .confirmationDialog(
            "Remove MCP server?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let server = deleting else { return }
                deleting = nil
                Task { await remove(server) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "“\($0.name)” will be removed from \(profileLabel)." } ?? "")
        }
    }

    @ViewBuilder
    private var serverSections: some View {
        Section("Servers") {
            if loading && servers.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Loading MCP servers…").foregroundStyle(.secondary) }
                    .listRowBackground(Palette.card(scheme))
            } else if filteredServers.isEmpty {
                stateRow(
                    query.isEmpty ? "No MCP servers" : "No matches",
                    detail: query.isEmpty ? "Add a server manually or install one from the catalog." : "Try a different search.",
                    systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
                )
            } else {
                ForEach(filteredServers) { server in
                    serverRow(server).listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    @ViewBuilder
    private var catalogSections: some View {
        Section {
            Text("Nous-approved MCP integrations. Review endpoint or bootstrap details before installing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        }
        Section("Catalog · \(filteredCatalog.count)") {
            if loading && catalog.entries.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Loading catalog…").foregroundStyle(.secondary) }
                    .listRowBackground(Palette.card(scheme))
            } else if filteredCatalog.isEmpty {
                stateRow(
                    query.isEmpty ? "Catalog unavailable" : "No matches",
                    detail: query.isEmpty ? "Hermes returned no MCP catalog entries." : "Try a different search.",
                    systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
                )
            } else {
                ForEach(filteredCatalog) { entry in
                    catalogRow(entry).listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: server.transport == "http" ? "network" : "terminal")
                    .foregroundStyle(server.enabled ? .primary : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(server.name).font(.subheadline.weight(.semibold))
                        badge(server.transport.uppercased(), tint: server.transport == "http" ? .green : .orange)
                        if let auth = server.auth { badge(auth == "header" ? "BEARER" : auth.uppercased(), tint: .secondary) }
                        if !server.enabled { badge("OFF", tint: .secondary) }
                    }
                    Text(serverAddress(server))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if !server.env.isEmpty {
                        Text("\(server.env.count) stored env variable\(server.env.count == 1 ? "" : "s") · values hidden")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let tools = server.tools {
                        Text(tools.isEmpty ? "No tools selected" : "Tool filter: \(tools.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if busyServers.contains(server.name) {
                    ProgressView().frame(width: 51)
                } else {
                    Toggle(
                        server.name,
                        isOn: Binding(
                            get: { currentServer(server.name)?.enabled ?? server.enabled },
                            set: { toggle(server, enabled: $0) }
                        )
                    )
                    .labelsHidden()
                }
            }

            HStack(spacing: 8) {
                Button { test(server) } label: {
                    Group {
                        if testing.contains(server.name) { ProgressView() }
                        else { Label("Test", systemImage: "bolt.horizontal.circle") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(testing.contains(server.name))
                .frame(maxWidth: .infinity)

                if server.auth == "oauth" {
                    Button { oauthServer = server } label: {
                        Label("Authenticate", systemImage: "key")
                            .frame(maxWidth: .infinity, minHeight: 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }

                Button(role: .destructive) { deleting = server } label: {
                    Label("Remove", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            if let result = testResults[server.name] {
                testResultView(result)
            }
        }
        .padding(.vertical, 4)
        .opacity(server.enabled ? 1 : 0.62)
    }

    @ViewBuilder
    private func testResultView(_ result: MCPServerTestResult) -> some View {
        if result.ok {
            VStack(alignment: .leading, spacing: 3) {
                Label("Connected · \(result.tools.count) tool\(result.tools.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                if !result.tools.isEmpty {
                    Text(result.tools.prefix(8).map(\.name).joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if result.prompts > 0 || result.resources > 0 {
                    Text("\(result.prompts) prompts · \(result.resources) resources")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label(result.error ?? "Connection failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: MCPCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.subheadline.weight(.semibold))
                        badge(entry.transport.uppercased(), tint: entry.transport == "http" ? .green : .orange)
                        badge(entry.authType.uppercased(), tint: .secondary)
                        if entry.installed { badge("INSTALLED", tint: .green) }
                        if entry.installed && !entry.enabled { badge("OFF", tint: .secondary) }
                    }
                    if !entry.detail.isEmpty {
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let connection = catalogConnection(entry) {
                        Text(connection)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
            }

            let diagnostics = diagnostics(for: entry.name)
            ForEach(diagnostics) { item in
                Label(item.message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if entry.installURL != nil || !entry.bootstrap.isEmpty || !entry.postInstall.isEmpty {
                DisclosureGroup("Installation details") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let installURL = entry.installURL {
                            Text("Source: \(installURL)\(entry.installRef.map { " @ \($0)" } ?? "")")
                                .textSelection(.enabled)
                        }
                        ForEach(Array(entry.bootstrap.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !entry.postInstall.isEmpty {
                            Text(entry.postInstall).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 5)
                }
                .font(.caption)
            }

            if let action = installActions[entry.name] {
                installStatusView(action)
            }

            if entry.installed {
                Button("Show installed server") {
                    pane = .servers
                    query = entry.name
                }
                .font(.caption)
            } else {
                Button {
                    installEntry = entry
                } label: {
                    if installing.contains(entry.name) { ProgressView() }
                    else { Label("Install", systemImage: "square.and.arrow.down") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(installing.contains(entry.name))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func installStatusView(_ status: HermesActionStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                status.running ? "Installing…" : (status.exitCode == 0 ? "Installation complete" : "Installation failed"),
                systemImage: status.running ? "clock" : (status.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(status.running ? .orange : (status.exitCode == 0 ? .green : .red))
            if let last = status.lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Text(last).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private var filteredServers: [MCPServerConfiguration] {
        guard !query.isEmpty else { return servers }
        let needle = query.lowercased()
        return servers.filter {
            "\($0.name) \($0.transport) \($0.url ?? "") \($0.command ?? "") \($0.auth ?? "")"
                .lowercased().contains(needle)
        }
    }

    private var filteredCatalog: [MCPCatalogEntry] {
        guard !query.isEmpty else { return catalog.entries }
        let needle = query.lowercased()
        return catalog.entries.filter {
            "\($0.name) \($0.detail) \($0.source) \($0.transport) \($0.authType)"
                .lowercased().contains(needle)
        }
    }

    private var profileLabel: String {
        profiles.first(where: { $0.id == selectedProfile })?.label ?? selectedProfile
    }

    private func currentServer(_ name: String) -> MCPServerConfiguration? {
        servers.first { $0.name == name }
    }

    private func diagnostics(for name: String) -> [MCPCatalogDiagnostic] {
        catalog.diagnostics.filter { $0.name == name }
    }

    private func serverAddress(_ server: MCPServerConfiguration) -> String {
        if server.transport == "http" { return server.url ?? "HTTP endpoint unavailable" }
        return ([server.command].compactMap { $0 } + server.args).joined(separator: " ")
    }

    private func catalogConnection(_ entry: MCPCatalogEntry) -> String? {
        if entry.transport == "http" { return entry.url }
        guard let command = entry.command else { return nil }
        return ([command] + entry.args).joined(separator: " ")
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        do {
            profiles = try await store.routineProfiles().map { MCPProfile(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) {
                selectedProfile = profiles.first?.id ?? "default"
            }
        } catch {
            profiles = [.init(id: "default", label: "Alice")]
        }
    }

    private func load() async {
        guard store.dashboardReady else {
            failure = "Connect the Hermes dashboard to manage MCP servers."
            return
        }
        loading = true
        defer { loading = false }
        do {
            servers = try await store.mcpServers(profile: selectedProfile)
            catalog = try await store.mcpCatalog(profile: selectedProfile)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func resetAndReload() {
        servers = []
        catalog = .init(entries: [], diagnostics: [])
        testResults = [:]
        installActions = [:]
        restartNote = false
        query = ""
        Task { await load() }
    }

    private func toggle(_ server: MCPServerConfiguration, enabled: Bool) {
        guard !busyServers.contains(server.name) else { return }
        busyServers.insert(server.name)
        Task {
            defer { busyServers.remove(server.name) }
            do {
                try await store.setMCPServerEnabled(server.name, enabled: enabled, profile: selectedProfile)
                if let index = servers.firstIndex(where: { $0.name == server.name }) {
                    servers[index].enabled = enabled
                }
                restartNote = true
                catalog = try await store.mcpCatalog(profile: selectedProfile)
            } catch { failure = reason(error) }
        }
    }

    private func test(_ server: MCPServerConfiguration) {
        guard !testing.contains(server.name) else { return }
        testing.insert(server.name)
        Task {
            defer { testing.remove(server.name) }
            do { testResults[server.name] = try await store.testMCPServer(server.name, profile: selectedProfile) }
            catch {
                testResults[server.name] = MCPServerTestResult(
                    ok: false, error: reason(error), tools: [], prompts: 0, resources: 0
                )
            }
        }
    }

    private func remove(_ server: MCPServerConfiguration) async {
        busyServers.insert(server.name)
        defer { busyServers.remove(server.name) }
        do {
            try await store.deleteMCPServer(server.name, profile: selectedProfile)
            testResults.removeValue(forKey: server.name)
            await load()
        } catch { failure = reason(error) }
    }

    private func handleInstall(_ result: MCPCatalogInstallResult) {
        installing.insert(result.name)
        guard result.background, let action = result.action else {
            installing.remove(result.name)
            Task { await load() }
            return
        }
        installPolls[result.name]?.cancel()
        installPolls[result.name] = Task {
            await trackInstall(name: result.name, action: action)
        }
    }

    private func stopInstallPolls() {
        for (_, poll) in installPolls { poll.cancel() }
        installPolls = [:]
    }

    private func trackInstall(name: String, action: String) async {
        defer {
            installing.remove(name)
            installPolls[name] = nil
        }
        while !Task.isCancelled {
            do {
                let status = try await store.hermesActionStatus(action, lines: 80)
                installActions[name] = status
                if !status.running {
                    await load()
                    return
                }
            } catch {
                failure = reason(error)
                return
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.11), in: Capsule())
    }

    private func stateRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }
}

private enum MCPPane: String, CaseIterable, Identifiable {
    case servers = "Servers"
    case catalog = "Catalog"
    var id: String { rawValue }
}

private struct MCPProfile: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct AddMCPServerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let profile: String
    let onAdded: () -> Void

    @State private var name = ""
    @State private var transport = "http"
    @State private var url = ""
    @State private var auth = "none"
    @State private var bearerToken = ""
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Transport", selection: $transport) {
                        Text("HTTP / SSE").tag("http")
                        Text("stdio").tag("stdio")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Palette.card(scheme))

                if transport == "http" {
                    Section("HTTP") {
                        TextField("https://example.com/mcp", text: $url)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        Picker("Authentication", selection: $auth) {
                            Text("None").tag("none")
                            Text("Bearer").tag("header")
                            Text("OAuth").tag("oauth")
                        }
                        if auth == "header" {
                            SecureField("Bearer token", text: $bearerToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Hermes stores the token in this profile’s .env; config keeps only a reference.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if auth == "oauth" {
                            Text("After adding the server, use Authenticate to complete OAuth in Safari.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                } else {
                    Section("stdio") {
                        TextField("Command, e.g. npx", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Args separated by spaces or commas", text: $args)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Environment").font(.subheadline)
                            TextEditor(text: $env)
                                .font(.caption.monospaced())
                                .frame(minHeight: 90)
                            Text("One KEY=VALUE per line. These values are secrets and are not shown again unredacted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red) }
                        .listRowBackground(Palette.card(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(saving)
                }
            }
        }
    }

    private func add() async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { failure = "Name required."; return }
        saving = true
        defer { saving = false }
        do {
            if transport == "http" {
                let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = URL(string: cleanURL), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                    failure = "Enter a valid HTTP or HTTPS MCP URL."
                    return
                }
                if auth == "header" && bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failure = "Bearer token required."
                    return
                }
                _ = try await store.addMCPServer(
                    name: cleanName, profile: profile, url: cleanURL,
                    auth: auth, bearerToken: auth == "header" ? bearerToken : nil
                )
            } else {
                let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanCommand.isEmpty else { failure = "Command required."; return }
                _ = try await store.addMCPServer(
                    name: cleanName, profile: profile, command: cleanCommand,
                    args: parseArgs(args), env: parseEnv(env)
                )
            }
            onAdded()
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func parseArgs(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseEnv(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

private struct InstallMCPCatalogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let entry: MCPCatalogEntry
    let profile: String
    let onStarted: (MCPCatalogInstallResult) -> Void

    @State private var env: [String: String] = [:]
    @State private var installing = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.detail.isEmpty ? "Install this MCP integration into the selected Hermes profile." : entry.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let url = entry.url { LabeledContent("Endpoint", value: url) }
                    if let command = entry.command {
                        LabeledContent("Runs", value: ([command] + entry.args).joined(separator: " "))
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if !entry.requiredEnv.isEmpty {
                    Section("Required values") {
                        ForEach(entry.requiredEnv) { field in
                            SecureField(
                                field.required ? "\(field.prompt) *" : field.prompt,
                                text: Binding(
                                    get: { env[field.name] ?? "" },
                                    set: { env[field.name] = $0 }
                                )
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                        Text("Credentials are written directly to the selected Hermes profile and are not retained by Alice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if let installURL = entry.installURL {
                    Section("Bootstrap") {
                        Text("Source: \(installURL)\(entry.installRef.map { " @ \($0)" } ?? "")")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        ForEach(Array(entry.bootstrap.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text("Hermes runs these commands on the host. Review them before installing.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if !entry.postInstall.isEmpty {
                    Section("Setup notes") { Text(entry.postInstall).font(.footnote) }
                        .listRowBackground(Palette.card(scheme))
                }

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red) }
                        .listRowBackground(Palette.card(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Install \(entry.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") { Task { await install() } }.disabled(installing)
                }
            }
        }
    }

    private func install() async {
        let missing = entry.requiredEnv.first {
            $0.required && (env[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let missing { failure = "\(missing.prompt) is required."; return }
        let values = env.reduce(into: [String: String]()) { result, item in
            let clean = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { result[item.key] = clean }
        }
        installing = true
        defer { installing = false }
        do {
            let result = try await store.installMCPCatalogEntry(entry.name, env: values, profile: profile)
            onStarted(result)
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct MCPOAuthSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    let server: MCPServerConfiguration
    let profile: String
    let onFinished: ([MCPToolInfo]) -> Void

    @State private var flow: MCPOAuthFlow?
    @State private var openedAuthorization = false
    @State private var failure: String?
    @State private var approved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(statusLabel, systemImage: statusSymbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusTint)
                        Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Palette.card(scheme))
                }

                if let raw = flow?.authorizationURL, let url = URL(string: raw) {
                    Section("Authorization") {
                        Button { openURL(url) } label: {
                            Label("Open authorization page", systemImage: "safari")
                        }
                        .listRowBackground(Palette.card(scheme))
                        Text(raw).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .listRowBackground(Palette.card(scheme))
                    }
                }

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red) }
                        .listRowBackground(Palette.card(scheme))
                }

                if approved, let tools = flow?.tools, !tools.isEmpty {
                    Section("Tools · \(tools.count)") {
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.subheadline.weight(.medium))
                                if !tool.detail.isEmpty { Text(tool.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Authenticate \(server.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(approved ? "Done" : "Cancel") {
                        Task { await cancelIfNeeded() }
                        dismiss()
                    }
                }
            }
            .task { await beginAndPoll() }
            .onDisappear {
                guard !approved, let flow else { return }
                Task { try? await store.cancelMCPOAuth(flow.flowID, profile: profile) }
            }
        }
    }

    private var statusLabel: String {
        if approved { return "Authenticated" }
        switch flow?.status {
        case "authorization_required": return "Waiting for authorization"
        case "error": return "OAuth failed"
        case "starting": return "Starting OAuth"
        default: return "Preparing OAuth"
        }
    }

    private var statusDetail: String {
        if approved { return "Hermes saved the OAuth token and connected to the MCP server." }
        if let error = flow?.error, !error.isEmpty { return error }
        if flow?.status == "authorization_required" { return "Complete the provider flow in Safari, then return to Alice." }
        return "Hermes is discovering the provider’s OAuth configuration."
    }

    private var statusSymbol: String {
        approved ? "checkmark.circle.fill" : (flow?.status == "error" ? "xmark.circle.fill" : "key")
    }

    private var statusTint: Color {
        approved ? .green : (flow?.status == "error" ? .red : .orange)
    }

    private func beginAndPoll() async {
        do {
            var current = try await store.startMCPOAuth(server.name, profile: profile)
            flow = current
            while !Task.isCancelled {
                if current.status == "approved" {
                    approved = true
                    onFinished(current.tools)
                    return
                }
                if current.status == "error" {
                    failure = current.error ?? "OAuth failed."
                    return
                }
                if current.status == "authorization_required",
                   let raw = current.authorizationURL,
                   let url = URL(string: raw), !openedAuthorization {
                    openedAuthorization = true
                    openURL(url)
                }
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                current = try await store.mcpOAuthStatus(current.flowID, profile: profile)
                flow = current
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func cancelIfNeeded() async {
        guard !approved, let flow else { return }
        try? await store.cancelMCPOAuth(flow.flowID, profile: profile)
    }
}
