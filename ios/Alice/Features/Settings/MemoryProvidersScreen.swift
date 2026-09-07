import SwiftUI

struct MemoryProvidersScreen: View {
    @Environment(AppStore.self) private var store

    let profile: String
    let onChanged: () -> Void

    @State private var hostStatus: MemoryProviderStatusSnapshot?
    @State private var activeProvider = ""
    @State private var inspecting: MemoryProvider?
    @State private var failure: String?
    @State private var loading = false
    @State private var confirmingBuiltin = false

    init(profile: String, onChanged: @escaping () -> Void = {}) {
        self.profile = profile
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            Section("Active for this profile") {
                LabeledContent("Provider", value: activeProvider.isEmpty ? "Built-in" : activeProvider)
                Text("Availability and dependency checks are host-wide. Provider settings and activation are written to \(profile == "default" ? "Alice" : profile).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    if !activeProvider.isEmpty { confirmingBuiltin = true }
                } label: {
                    providerRow(
                        name: "Built-in",
                        detail: "Hermes MEMORY.md and USER.md",
                        status: "ready",
                        active: activeProvider.isEmpty
                    )
                }
                .buttonStyle(.plain)
                .disabled(activeProvider.isEmpty)

                if let hostStatus {
                    ForEach(hostStatus.providers) { provider in
                        Button { inspecting = provider } label: {
                            providerRow(
                                name: provider.name,
                                detail: provider.detail,
                                status: provider.status,
                                active: activeProvider == provider.name
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Secrets are write-only. Alice never reads a provider secret back from Hermes or stores it in app preferences.")
            }

            if let hostStatus {
                Section("Built-in storage on Hermes host") {
                    LabeledContent("MEMORY.md", value: formatBytes(hostStatus.builtinMemoryBytes))
                    LabeledContent("USER.md", value: formatBytes(hostStatus.builtinUserBytes))
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Memory Providers")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && hostStatus == nil { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $inspecting) { provider in
            MemoryProviderDetailSheet(
                profile: profile,
                provider: provider,
                setup: hostStatus?.setup[provider.name],
                active: activeProvider == provider.name
            ) {
                onChanged()
                Task { await load() }
            }
            .environment(store)
        }
        .confirmationDialog(
            "Use built-in memory?",
            isPresented: $confirmingBuiltin,
            titleVisibility: .visible
        ) {
            Button("Use Built-in") { Task { await useBuiltin() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the provider for new sessions in this Hermes profile. Existing memory files are not deleted.")
        }
    }

    @ViewBuilder
    private func providerRow(name: String, detail: String, status: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(name).foregroundStyle(.primary)
                    Text(status.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColour(status))
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if name != "Built-in" {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            hostStatus = try await store.memoryProviderStatus()
            activeProvider = try await store.memorySnapshot(profile: profile).provider
            failure = nil
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func useBuiltin() async {
        do {
            try await store.useBuiltinMemoryProvider(profile: profile)
            activeProvider = ""
            failure = nil
            onChanged()
        } catch { failure = diagnosticMessage(error) }
    }

    private func statusColour(_ status: String) -> Color {
        switch status {
        case "ready": .green
        case "needs_config": .orange
        case "unavailable", "missing": .red
        default: .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MemoryProviderDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: String
    let provider: MemoryProvider
    let setup: MemoryProviderSetupInfo?
    let active: Bool
    let onChanged: () -> Void

    @State private var config: MemoryProviderConfiguration?
    @State private var values: [String: String] = [:]
    @State private var oauth: MemoryProviderOAuthStatus?
    @State private var oauthTask: Task<Void, Never>?
    @State private var setupResults: [MemoryProviderSetupResult] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var saving = false
    @State private var settingUp = false
    @State private var connectingOAuth = false
    @State private var confirmingSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Provider", value: provider.name)
                    LabeledContent("Host status", value: provider.status.replacingOccurrences(of: "_", with: " "))
                    LabeledContent("Active", value: active ? "Yes" : "No")
                    if let setup {
                        LabeledContent("Dependencies", value: setup.dependenciesInstalled ? "Installed" : "Missing")
                    }
                    if !provider.detail.isEmpty {
                        Text(provider.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let setup, hasSetupWork(setup) {
                    Section {
                        if !setup.pipDependencies.isEmpty {
                            LabeledContent("Python") {
                                Text(setup.pipDependencies.joined(separator: ", "))
                                    .font(.caption.monospaced()).multilineTextAlignment(.trailing)
                            }
                        }
                        ForEach(setup.externalDependencies) { dependency in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dependency.name).font(.subheadline.weight(.medium))
                                if !dependency.install.isEmpty {
                                    Text(dependency.install).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        if !setup.requiredEnvironment.isEmpty {
                            Text("Required environment: \(setup.requiredEnvironment.joined(separator: ", "))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !setup.dependenciesInstalled {
                            Button {
                                confirmingSetup = true
                            } label: {
                                Label("Install dependencies on Hermes host", systemImage: "shippingbox.and.arrow.backward")
                            }
                            .disabled(settingUp)
                        }
                    } header: {
                        Text("Dependencies")
                    } footer: {
                        Text("Dependency setup runs on the Hermes host. Alice sends no provider secrets in this setup request.")
                    }
                }

                if let config {
                    if let url = URL(string: config.docsURL), !config.docsURL.isEmpty {
                        Section { Link("Provider documentation", destination: url) }
                    }

                    if !visibleFields.isEmpty {
                        Section {
                            ForEach(visibleFields) { field in
                                fieldEditor(field)
                            }
                        } header: {
                            Text("Configuration")
                        } footer: {
                            Text(active
                                 ? "Blank secret fields keep the existing secret unchanged."
                                 : "Saving these settings also asks Hermes to activate this provider for the selected profile. Blank secret fields keep existing secrets unchanged.")
                        }
                    } else if !loading {
                        Section {
                            Text("This provider exposes no editable dashboard settings.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let oauth {
                    Section {
                        LabeledContent("State", value: oauth.state)
                        if let auth = oauth.auth, !auth.isEmpty { LabeledContent("Auth", value: auth) }
                        if !oauth.detail.isEmpty { Text(oauth.detail).font(.footnote).foregroundStyle(.secondary) }
                        if !oauth.connected {
                            Button {
                                beginOAuth()
                            } label: {
                                Label("Connect on Hermes host", systemImage: "person.crop.circle.badge.plus")
                            }
                            .disabled(connectingOAuth)
                        }
                    } header: {
                        Text("OAuth")
                    } footer: {
                        Text("Hermes' memory OAuth endpoint opens the authorization browser on the machine running Hermes, not on this iPhone.")
                    }
                }

                if !setupResults.isEmpty {
                    Section("Setup results") {
                        ForEach(setupResults) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(result.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(result.status).font(.caption.monospaced())
                                }
                                if !result.command.isEmpty {
                                    Text(result.command).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                                if !result.stderr.isEmpty {
                                    Text(result.stderr).font(.caption2.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                                } else if !result.stdout.isEmpty {
                                    Text(result.stdout).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                Section {
                    if !active {
                        Button {
                            Task { await activate() }
                        } label: {
                            Label("Use for this profile", systemImage: "checkmark.circle")
                        }
                        .disabled(saving || setup?.dependenciesInstalled == false)
                    }
                } footer: {
                    if setup?.dependenciesInstalled == false {
                        Text("Install the declared dependencies first.")
                    } else if !active {
                        Text("Hermes validates this profile's required configuration before activation and returns the exact failure if it is not ready.")
                    }
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if loading && config == nil { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(active ? "Save" : "Save & Use") { Task { await save() } }
                        .disabled(saving || config == nil || visibleFields.isEmpty || setup?.dependenciesInstalled == false)
                }
            }
            .task { await load() }
            .onDisappear {
                oauthTask?.cancel()
                oauthTask = nil
            }
            .confirmationDialog(
                "Install provider dependencies?",
                isPresented: $confirmingSetup,
                titleVisibility: .visible
            ) {
                Button("Install") { Task { await runSetup() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(setupConfirmationText)
            }
        }
    }

    private var visibleFields: [MemoryProviderField] {
        guard let config else { return [] }
        return config.fields.filter(fieldVisible)
    }

    @ViewBuilder
    private func fieldEditor(_ field: MemoryProviderField) -> some View {
        switch field.kind {
        case "boolean":
            Toggle(field.label, isOn: boolBinding(field.key))
        case "select":
            Picker(field.label, selection: stringBinding(field.key)) {
                ForEach(field.options) { option in Text(option.label).tag(option.value) }
            }
        case "secret":
            VStack(alignment: .leading, spacing: 5) {
                SecureField(field.placeholder.isEmpty ? field.label : field.placeholder, text: stringBinding(field.key))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if field.isSet {
                    Label("A secret is already stored", systemImage: "checkmark.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                fieldHelp(field)
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                Text(field.label).font(.subheadline)
                TextField(field.placeholder, text: stringBinding(field.key), axis: field.kind == "json" ? .vertical : .horizontal)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(field.kind == "json" ? 2...8 : 1...1)
                    .keyboardType(field.kind == "integer" || field.kind == "number" ? .numbersAndPunctuation : .default)
                fieldHelp(field)
            }
        }
    }

    @ViewBuilder
    private func fieldHelp(_ field: MemoryProviderField) -> some View {
        if !field.detail.isEmpty { Text(field.detail).font(.caption).foregroundStyle(.secondary) }
        if !field.info.isEmpty { Text(field.info).font(.caption2).foregroundStyle(.secondary) }
        if field.required { Text("Required").font(.caption2.weight(.medium)).foregroundStyle(.orange) }
        if let url = URL(string: field.url), !field.url.isEmpty { Link("More information", destination: url).font(.caption) }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (values[key] ?? "").lowercased() == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }

    private func fieldVisible(_ field: MemoryProviderField) -> Bool {
        for (key, expected) in field.when {
            let actual = values[key] ?? config?.fields.first(where: { $0.key == key })?.value ?? ""
            if actual.lowercased() != expected.lowercased() { return false }
        }
        return true
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await store.memoryProviderConfiguration(provider.name, profile: profile)
            config = loaded
            values = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.key, $0.isSecret ? "" : $0.value) })
            oauth = try? await store.memoryProviderOAuthStatus(provider.name, profile: profile)
            failure = nil
        } catch { failure = diagnosticMessage(error) }
    }

    private func save() async {
        guard let config else { return }
        var payload: [String: String] = [:]
        for field in visibleFields {
            let value = values[field.key] ?? ""
            if field.isSecret && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if field.kind == "json", !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !validJSONObjectOrArray(value) {
                failure = "\(field.label) must be a valid JSON object or array."
                return
            }
            payload[field.key] = value
        }
        saving = true
        defer { saving = false }
        do {
            try await store.saveMemoryProviderConfiguration(
                provider.name, profile: profile, surface: config.surface, values: payload
            )
            failure = nil
            onChanged()
            await load()
        } catch { failure = diagnosticMessage(error) }
    }

    private func activate() async {
        saving = true
        defer { saving = false }
        do {
            try await store.activateMemoryProvider(provider.name, profile: profile)
            failure = nil
            onChanged()
            dismiss()
        } catch { failure = diagnosticMessage(error) }
    }

    private func runSetup() async {
        settingUp = true
        defer { settingUp = false }
        do {
            let result = try await store.setupMemoryProvider(provider.name)
            setupResults = result.results
            if !result.ok {
                failure = "Hermes reported that one or more dependency setup steps failed."
            } else {
                failure = nil
            }
            onChanged()
            await load()
        } catch { failure = diagnosticMessage(error) }
    }

    private func beginOAuth() {
        oauthTask?.cancel()
        connectingOAuth = true
        failure = nil
        oauthTask = Task {
            defer {
                connectingOAuth = false
                oauthTask = nil
            }
            do {
                oauth = try await store.startMemoryProviderOAuth(provider.name, profile: profile)
                for _ in 0..<300 {
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    guard let status = try await store.memoryProviderOAuthStatus(provider.name, profile: profile) else { return }
                    oauth = status
                    if status.connected || status.state == "error" {
                        if status.connected { onChanged() }
                        return
                    }
                }
                failure = "OAuth approval timed out."
            } catch {
                if !Task.isCancelled { failure = diagnosticMessage(error) }
            }
        }
    }

    private func hasSetupWork(_ setup: MemoryProviderSetupInfo) -> Bool {
        !setup.pipDependencies.isEmpty || !setup.externalDependencies.isEmpty || !setup.requiredEnvironment.isEmpty
    }

    private var setupConfirmationText: String {
        guard let setup else { return "Hermes will run the provider's declared setup steps on its host." }
        var lines: [String] = []
        if !setup.pipDependencies.isEmpty { lines.append("Python: " + setup.pipDependencies.joined(separator: ", ")) }
        lines.append(contentsOf: setup.externalDependencies.compactMap { $0.install.isEmpty ? nil : $0.install })
        return lines.isEmpty ? "Hermes will run the provider's declared setup steps on its host." : lines.joined(separator: "\n")
    }

    private func validJSONObjectOrArray(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any] || object is [Any]
    }
}
