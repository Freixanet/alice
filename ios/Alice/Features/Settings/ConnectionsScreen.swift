import SwiftUI
import UIKit

/// Everything Alice can be connected to, each with its own logo: the iPhone's
/// calendar, then every connector Hermes offers (its approved catalog), the
/// ones already connected first. Connecting installs the connector on Hermes
/// and, when it needs an account, opens that service's own sign-in in Safari;
/// disconnecting removes it. "Add Connector" takes any other MCP address.
///
/// The logos are the products' own, read from their sites by the Alice plugin
/// on the Mac and kept there — never from an icon service.
struct ConnectionsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var catalog: [MCPCatalogEntry] = []
    @State private var servers: [MCPServerConfiguration] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var working: Set<String> = []
    @State private var problem: String?
    @State private var signingIn: SignIn?
    @State private var askingKeys: MCPCatalogEntry?
    @State private var disconnecting: String?
    @State private var adding = false

    fileprivate struct SignIn: Identifiable {
        let id: String
        let title: String
    }

    private var catalogNames: Set<String> { Set(catalog.map(\.name)) }

    /// The person's own connectors, added by address rather than from the catalog.
    private var custom: [MCPServerConfiguration] {
        servers.filter { !catalogNames.contains($0.name) }
    }

    private func isConnected(_ entry: MCPCatalogEntry) -> Bool { entry.installed && entry.enabled }

    private func matches(_ name: String, _ detail: String) -> Bool {
        query.isEmpty || ConnectorNames.title(name).localizedStandardContains(query) || detail.localizedStandardContains(query)
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    CalendarConnectionRow()
                    HealthConnectionRow()
                } footer: {
                    Text("Your agents see what you connect here. Nothing leaves your own Hermes, and nothing is added to your calendar unless you tap Add.")
                }
                .listRowBackground(Palette.card(scheme))
            }

            let connected = catalog.filter { isConnected($0) && matches($0.name, $0.detail) }
            let yours = custom.filter { matches($0.name, $0.url ?? "") }
            if !connected.isEmpty || !yours.isEmpty {
                Section("Connected") {
                    ForEach(connected) { entry in catalogRow(entry) }
                    ForEach(yours) { server in customRow(server) }
                }
                .listRowBackground(Palette.card(scheme))
            }

            let available = catalog.filter { !isConnected($0) && matches($0.name, $0.detail) }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { entry in catalogRow(entry) }
                }
                .listRowBackground(Palette.card(scheme))
            }

            if !loaded {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if query.isEmpty {
                Section {
                    Button { adding = true } label: {
                        Label("Add Connector", systemImage: "plus")
                    }
                } footer: {
                    Text("Any service with an MCP address. Connectors are added to Alice.")
                }
                .listRowBackground(Palette.card(scheme))
            } else if connected.isEmpty && available.isEmpty && yours.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
                    .listRowBackground(Color.clear)
            }
        }
        .aliceFormPaper(scheme)
        .searchable(text: $query, prompt: "Search connectors")
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $signingIn) { signIn in
            ConnectorSignInSheet(name: signIn.id, title: signIn.title) { _ in
                signingIn = nil
                Task { await load() }
            }
        }
        .sheet(item: $askingKeys) { entry in
            ConnectorKeysSheet(entry: entry) { env in
                askingKeys = nil
                if let env { Task { await install(entry, env: env) } }
            }
        }
        .sheet(isPresented: $adding) {
            AddConnectorSheet { name, oauth in
                adding = false
                Task {
                    await load()
                    if let name, oauth { signingIn = SignIn(id: name, title: ConnectorNames.title(name)) }
                }
            }
        }
        .confirmationDialog(
            disconnecting.map { String(localized: "Disconnect \(ConnectorNames.title($0))?") } ?? "",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let name = disconnecting { Task { await disconnect(name) } }
                disconnecting = nil
            }
        } message: {
            Text("Your agents stop using it. You can connect it again at any time.")
        }
    }

    // MARK: Rows

    private func catalogRow(_ entry: MCPCatalogEntry) -> some View {
        ConnectorRow(
            name: entry.name, detail: entry.detail, connected: isConnected(entry),
            working: working.contains(entry.name),
            onConnect: { Task { await connect(entry) } },
            onDisconnect: { disconnecting = entry.name },
            onSignIn: entry.authType == "oauth" ? { signingIn = SignIn(id: entry.name, title: ConnectorNames.title(entry.name)) } : nil
        )
    }

    private func customRow(_ server: MCPServerConfiguration) -> some View {
        ConnectorRow(
            name: server.name, detail: server.url ?? server.command ?? "", connected: server.enabled,
            working: working.contains(server.name),
            onConnect: { Task { await enable(server.name) } },
            onDisconnect: { disconnecting = server.name },
            onSignIn: server.auth == "oauth" ? { signingIn = SignIn(id: server.name, title: ConnectorNames.title(server.name)) } : nil
        )
    }

    // MARK: Actions

    private func load() async {
        async let catalogRead = try? store.mcpCatalog()
        async let serversRead = try? store.mcpServers()
        let (snapshot, configured) = await (catalogRead, serversRead)
        if let snapshot {
            catalog = snapshot.entries.sorted {
                ConnectorNames.title($0.name).localizedCaseInsensitiveCompare(ConnectorNames.title($1.name)) == .orderedAscending
            }
        }
        if let configured { servers = configured }
        loaded = true
    }

    private func connect(_ entry: MCPCatalogEntry) async {
        if entry.installed && !entry.enabled {
            await enable(entry.name)
            return
        }
        if entry.requiredEnv.contains(where: \.required) || entry.authType == "api_key" {
            askingKeys = entry
            return
        }
        await install(entry, env: [:])
    }

    private func install(_ entry: MCPCatalogEntry, env: [String: String]) async {
        working.insert(entry.name)
        defer { working.remove(entry.name) }
        do {
            let result = try await store.installMCPCatalogEntry(entry.name, env: env)
            if result.background {
                // Some connectors are built on the Mac first; wait for it.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    if let snapshot = try? await store.mcpCatalog(),
                       snapshot.entries.first(where: { $0.name == entry.name })?.installed == true { break }
                }
            }
            problem = nil
            await load()
            if entry.authType == "oauth" {
                signingIn = SignIn(id: entry.name, title: ConnectorNames.title(entry.name))
            }
        } catch {
            problem = PlainWords.describe(error, doing: "connect \(ConnectorNames.title(entry.name))")
        }
    }

    private func enable(_ name: String) async {
        working.insert(name)
        defer { working.remove(name) }
        do {
            try await store.setMCPServerEnabled(name, enabled: true)
            problem = nil
            await load()
        } catch {
            problem = PlainWords.describe(error, doing: "connect \(ConnectorNames.title(name))")
        }
    }

    private func disconnect(_ name: String) async {
        working.insert(name)
        defer { working.remove(name) }
        do {
            try await store.deleteMCPServer(name)
            problem = nil
            await load()
        } catch {
            problem = PlainWords.describe(error, doing: "disconnect \(ConnectorNames.title(name))")
        }
    }
}

// MARK: - Row

private struct ConnectorRow: View {
    let name: String
    let detail: String
    let connected: Bool
    let working: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onSignIn: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ConnectorLogo(name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectorNames.title(name))
                    .font(.body)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if working {
                ProgressView()
            } else if connected {
                Menu {
                    if let onSignIn {
                        Button(action: onSignIn) { Label("Sign In Again", systemImage: "person.badge.key") }
                    }
                    Button(role: .destructive, action: onDisconnect) {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("Connected", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.success(scheme))
                }
                .accessibilityIdentifier("connections.connected.\(name)")
            } else {
                Button("Connect", action: onConnect)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("connections.connect.\(name)")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A connector's logo on a white tile, like an app icon; its initial until
/// (or unless) the logo arrives.
struct ConnectorLogo: View {
    let name: String
    var size: CGFloat = 40

    @Environment(AppStore.self) private var store
    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Text(String(ConnectorNames.title(name).prefix(1)))
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: name) {
            if let cached = Self.cache.object(forKey: name as NSString) {
                image = cached
                return
            }
            guard let data = await store.connectorIcon(name), let loaded = UIImage(data: data) else { return }
            Self.cache.setObject(loaded, forKey: name as NSString)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Catalog names as their products write them.
enum ConnectorNames {
    static let known: [String: String] = [
        "aws-knowledge": "AWS Knowledge", "betterstack": "Better Stack", "circleci": "CircleCI",
        "clickup": "ClickUp", "comfy-cloud": "Comfy Cloud", "context7": "Context7", "deepwiki": "DeepWiki",
        "gitlab": "GitLab", "github": "GitHub", "globalping": "Globalping", "hugging_face": "Hugging Face",
        "microsoft-learn": "Microsoft Learn", "motherduck": "MotherDuck", "n8n": "n8n", "paypal": "PayPal",
        "prisma-postgres": "Prisma Postgres", "twelve-data": "Twelve Data", "alltrails": "AllTrails",
        "hubspot": "HubSpot", "youtube": "YouTube", "semgrep": "Semgrep", "posthog": "PostHog",
    ]

    static func title(_ name: String) -> String {
        if let known = known[name.lowercased()] { return known }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Sign in

/// The service's own sign-in, in Safari; Hermes keeps the account and Alice
/// waits here until it says so.
private struct ConnectorSignInSheet: View {
    let name: String
    let title: String
    let onDone: (Bool) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var flow: MCPOAuthFlow?
    @State private var opened = false
    @State private var done = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ConnectorLogo(name: name, size: 72)
                    .padding(.top, 28)
                Text(done ? String(localized: "\(title) is connected") : String(localized: "Sign in to \(title)"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if !done, failure == nil {
                    if let raw = flow?.authorizationURL, let url = URL(string: raw) {
                        Button("Open Sign-In Page") { openURL(url) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView()
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "Done" : "Cancel") { onDone(done) }
                }
            }
            .task { await run() }
            .onDisappear {
                guard !done, let flow else { return }
                Task { try? await store.cancelMCPOAuth(flow.flowID) }
            }
        }
        .presentationDetents([.medium])
    }

    private var detail: String {
        if let failure { return failure }
        if done { return String(localized: "Your agents can use it now.") }
        if flow?.authorizationURL != nil {
            return String(localized: "Finish signing in on the page that opened, then come back to Alice.")
        }
        return String(localized: "Getting the sign-in page ready…")
    }

    private func run() async {
        do {
            var current = try await store.startMCPOAuth(name)
            flow = current
            while !Task.isCancelled {
                switch current.status {
                case "approved":
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                case "error":
                    failure = current.error ?? String(localized: "The sign-in did not finish.")
                    return
                case "authorization_required":
                    if !opened, let raw = current.authorizationURL, let url = URL(string: raw) {
                        opened = true
                        openURL(url)
                    }
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(1200))
                current = try await store.mcpOAuthStatus(current.flowID)
                flow = current
            }
        } catch {
            failure = PlainWords.describe(error, doing: "sign in to \(title)")
        }
    }
}

// MARK: - Keys

/// A connector that works with a key, not an account: the key goes straight
/// into Hermes' own settings on the Mac, never shown again.
private struct ConnectorKeysSheet: View {
    let entry: MCPCatalogEntry
    let onDone: ([String: String]?) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var values: [String: String] = [:]

    private var ready: Bool {
        entry.requiredEnv.filter(\.required).allSatisfy { !(values[$0.name] ?? "").isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ConnectorLogo(name: entry.name, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ConnectorNames.title(entry.name)).font(.headline)
                            Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(entry.requiredEnv, id: \.name) { field in
                        SecureField(field.prompt.isEmpty ? field.name : field.prompt,
                                    text: Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Saved in Hermes on your Mac. Alice does not keep a copy.")
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { onDone(values.filter { !$0.value.isEmpty }) }.disabled(!ready)
                }
            }
        }
    }
}

// MARK: - Add

/// Any other connector, by its MCP address.
private struct AddConnectorSheet: View {
    let onDone: (_ name: String?, _ needsSignIn: Bool) -> Void

    enum Access: String, CaseIterable, Identifiable {
        case account, key, none
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .account: "Sign in with an account"
            case .key: "Access key"
            case .none: "No sign-in"
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var address = ""
    @State private var access = Access.account
    @State private var key = ""
    @State private var working = false
    @State private var problem: String?

    private var slug: String {
        name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var valid: Bool {
        !slug.isEmpty && (URL(string: address)?.scheme?.hasPrefix("http") ?? false) && (access != .key || !key.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("MCP address (https://…)", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("Access", selection: $access) {
                        ForEach(Access.allCases) { Text($0.title).tag($0) }
                    }
                    if access == .key {
                        SecureField("Key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("The service's own documentation gives its MCP address.")
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle("Add Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil, false) } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Add") { Task { await add() } }.disabled(!valid)
                    }
                }
            }
        }
    }

    private func add() async {
        working = true
        defer { working = false }
        do {
            _ = try await store.addMCPServer(
                name: slug, url: address.trimmingCharacters(in: .whitespaces),
                auth: access == .account ? "oauth" : nil,
                bearerToken: access == .key ? key : nil
            )
            onDone(slug, access == .account)
        } catch {
            problem = PlainWords.describe(error, doing: "add this connector")
        }
    }
}
