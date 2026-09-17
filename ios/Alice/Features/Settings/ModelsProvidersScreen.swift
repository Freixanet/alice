import SwiftUI

private struct ProviderDestination: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Hermes' standing model/provider configuration. Chat's model picker remains
/// per-conversation; this screen changes the profile default used by new
/// sessions and therefore writes Hermes itself rather than an iPhone preference.
struct ModelsProvidersScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles = [HermesProfileChoice(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var info: ProfileModelInfo?
    @State private var providers: [InferenceProvider] = []
    @State private var oauth: [OAuthProviderState] = []
    @State private var credentials: [ProviderCredential] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var changingModel = false
    @State private var inspecting: ProviderDestination?

    private var allProviderDestinations: [ProviderDestination] {
        var labels: [String: String] = [:]
        for provider in providers { labels[provider.slug] = provider.name }
        for state in oauth where labels[state.id] == nil { labels[state.id] = state.name }
        for credential in credentials where labels[credential.provider] == nil {
            labels[credential.provider] = credential.providerLabel
        }
        return labels.map { ProviderDestination(id: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                if lhs.id == info?.provider { return true }
                if rhs.id == info?.provider { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            if profiles.count > 1 {
                Section {
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(profiles) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    Text("Each Hermes profile has its own default model and credentials.")
                }
            }

            if let info {
                Section("Default model") {
                    LabeledContent("Model", value: info.model.isEmpty ? "Not set" : info.model)
                    LabeledContent("Provider", value: info.provider.isEmpty ? "Auto" : info.provider)
                    if info.effectiveContextLength > 0 {
                        LabeledContent("Context", value: compactTokens(info.effectiveContextLength))
                    }
                    Button {
                        changingModel = true
                    } label: {
                        Label("Change default model", systemImage: "cpu")
                    }
                    .disabled(providers.allSatisfy { $0.models.isEmpty })
                }

                if hasCapabilities(info) {
                    Section("Capabilities") {
                        capability("Tools", info.capabilities.tools)
                        capability("Vision", info.capabilities.vision)
                        capability("Reasoning", info.capabilities.reasoning)
                        if !info.capabilities.family.isEmpty {
                            LabeledContent("Family", value: info.capabilities.family)
                        }
                        if info.capabilities.maxOutputTokens > 0 {
                            LabeledContent(
                                "Max output",
                                value: compactTokens(info.capabilities.maxOutputTokens)
                            )
                        }
                    }
                }
            }

            Section("Advanced models") {
                NavigationLink {
                    AdvancedModelsScreen(profile: selectedProfile)
                } label: {
                    Label("Auxiliary models, MoA & custom endpoints", systemImage: "brain.head.profile")
                }
                NavigationLink {
                    LocalModelsScreen()
                } label: {
                    Label("Local models on this Hermes host", systemImage: "desktopcomputer")
                }
                NavigationLink {
                    SavedEndpointsScreen(profile: selectedProfile)
                } label: {
                    Label("Saved custom endpoints", systemImage: "network.badge.shield.half.filled")
                }
            }

            Section {
                if allProviderDestinations.isEmpty, !loading {
                    Text("Hermes did not report any inference providers.")
                        .foregroundStyle(.secondary)
                }
                ForEach(allProviderDestinations) { destination in
                    Button {
                        inspecting = destination
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: providerConnected(destination.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(providerConnected(destination.id) ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(destination.name)
                                        .foregroundStyle(.primary)
                                    if destination.id == info?.provider {
                                        Text("Current")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(store.accent.primary(scheme))
                                    }
                                }
                                Text(providerSubtitle(destination.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Status comes from Hermes OAuth and provider-key stores. Alice never keeps provider secrets in app preferences.")
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Models & Providers")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading && info == nil { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load(refreshing: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading || !store.dashboardReady)
            }
        }
        .sheet(isPresented: $changingModel) {
            ModelPickerSheet(
                profile: selectedProfile,
                currentProvider: info?.provider ?? "",
                currentModel: info?.model ?? "",
                providers: providers,
                onChanged: { Task { await load() } }
            )
            .environment(store)
        }
        .sheet(item: $inspecting) { destination in
            ProviderDetailSheet(
                profile: selectedProfile,
                destination: destination,
                inventory: providers.first { $0.slug == destination.id },
                oauth: oauth.first { $0.id == destination.id },
                credentials: credentials.filter { $0.provider == destination.id },
                onChanged: { Task { await load() } }
            )
            .environment(store)
        }
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in Task { await load() } }
        .onChange(of: store.dashboardReady) { _, ready in
            guard ready else { return }
            Task { await loadProfiles(); await load() }
        }
        .refreshableWithFeedback { await load(refreshing: true) }
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        if let choices = try? await store.hermesProfiles() {
            profiles = choices.map { HermesProfileChoice(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = "default" }
        }
    }

    private func load(refreshing: Bool = false) async {
        guard store.dashboardReady else { failure = nil; return }
        loading = true
        defer { loading = false }
        do {
            info = try await store.profileModelInfo(profile: selectedProfile)
            providers = try await store.inferenceProviders(profile: selectedProfile, refreshing: refreshing)
            // Not `try?`: an empty list here is not "nothing is connected".
            // `providerConnected` reads both, so swallowing a failed load
            // showed a provider that has a stored key — or a completed OAuth —
            // as "Not configured", and offered to set up what was already set
            // up. A reload that did not happen has to say so.
            oauth = try await store.oauthProviderStates(profile: selectedProfile)
            credentials = try await store.providerCredentials(profile: selectedProfile)
            failure = nil
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func providerConnected(_ id: String) -> Bool {
        if providers.first(where: { $0.slug == id })?.authenticated == true { return true }
        if oauth.first(where: { $0.id == id })?.loggedIn == true { return true }
        return credentials.contains { $0.provider == id && $0.isSet }
    }

    private func providerSubtitle(_ id: String) -> String {
        if let warning = providers.first(where: { $0.slug == id })?.warning, !warning.isEmpty { return warning }
        if providerConnected(id) {
            let count = providers.first(where: { $0.slug == id })?.models.count ?? 0
            return count > 0 ? "Connected · \(count) models" : "Connected"
        }
        if let flow = oauth.first(where: { $0.id == id })?.flow {
            return flow == "external" ? "External sign-in required" : "Not connected"
        }
        return "Not configured"
    }

    private func capability(_ label: String, _ enabled: Bool) -> some View {
        LabeledContent(label) {
            Image(systemName: enabled ? "checkmark" : "minus")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
    }

    private func hasCapabilities(_ info: ProfileModelInfo) -> Bool {
        info.capabilities.tools || info.capabilities.vision || info.capabilities.reasoning
            || info.capabilities.contextWindow > 0 || info.capabilities.maxOutputTokens > 0
            || !info.capabilities.family.isEmpty
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct ModelPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: String
    let currentProvider: String
    let currentModel: String
    let providers: [InferenceProvider]
    let onChanged: () -> Void

    @State private var search = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var pendingProvider = ""
    @State private var pendingModel = ""
    @State private var confirmMessage: String?
    @State private var afterSaveMessage: String?

    private var visibleProviders: [InferenceProvider] {
        providers.compactMap { provider in
            let models = provider.models.filter {
                search.isEmpty || $0.localizedCaseInsensitiveContains(search)
                    || provider.name.localizedCaseInsensitiveContains(search)
            }
            guard !models.isEmpty else { return nil }
            var copy = provider
            copy.models = models
            return copy
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.footnote) }
                }
                ForEach(visibleProviders) { provider in
                    Section {
                        if !provider.authenticated && !provider.isUserDefined {
                            Text("Connect this provider first in Models & Providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                choose(provider.slug, model)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(HermesClient.prettify(model)).foregroundStyle(.primary)
                                        Text(model).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if provider.slug == currentProvider && model == currentModel {
                                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(saving || (!provider.authenticated && !provider.isUserDefined))
                        }
                    } header: {
                        Text(provider.name)
                    }
                }
            }
            .searchable(text: $search, prompt: "Model or provider")
            .navigationTitle("Default Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if saving { ProgressView() } }
            .confirmationDialog(
                "Confirm model", isPresented: Binding(
                    get: { confirmMessage != nil },
                    set: { if !$0 { confirmMessage = nil } }
                ), titleVisibility: .visible
            ) {
                Button("Use Model") { choose(pendingProvider, pendingModel, confirmed: true) }
                Button("Cancel", role: .cancel) { confirmMessage = nil }
            } message: {
                if let confirmMessage { Text(confirmMessage) }
            }
            .alert("Model changed", isPresented: Binding(
                get: { afterSaveMessage != nil },
                set: { if !$0 { afterSaveMessage = nil } }
            )) {
                Button("OK") { dismiss() }
            } message: {
                if let afterSaveMessage { Text(afterSaveMessage) }
            }
        }
    }

    private func choose(_ provider: String, _ model: String, confirmed: Bool = false) {
        guard !provider.isEmpty, !model.isEmpty else { return }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                let result = try await store.setProfileDefaultModel(
                    profile: profile, provider: provider, model: model,
                    confirmExpensive: confirmed
                )
                if result.confirmRequired {
                    pendingProvider = provider
                    pendingModel = model
                    confirmMessage = result.confirmMessage.isEmpty
                        ? "Hermes requires confirmation before using this model."
                        : result.confirmMessage
                    return
                }
                guard result.ok else {
                    failure = "Hermes did not save that model."
                    return
                }
                onChanged()
                if result.staleAux.isEmpty {
                    dismiss()
                } else {
                    let names = result.staleAux.map(\.task).joined(separator: ", ")
                    afterSaveMessage = "The default changed. Auxiliary tasks still pinned to another provider: \(names)."
                }
            } catch {
                failure = diagnosticMessage(error)
            }
        }
    }
}

private struct ProviderDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let profile: String
    let destination: ProviderDestination
    let inventory: InferenceProvider?
    let oauth: OAuthProviderState?
    let credentials: [ProviderCredential]
    let onChanged: () -> Void

    @State private var editingCredential: ProviderCredential?
    @State private var login: OAuthLogin?
    @State private var oauthTask: Task<Void, Never>?
    @State private var failure: String?
    @State private var working = false
    @State private var disconnecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Provider", value: destination.name)
                    LabeledContent("Models", value: "\(inventory?.models.count ?? 0)")
                    if let warning = inventory?.warning, !warning.isEmpty {
                        Text(warning).foregroundStyle(.orange).font(.footnote)
                    }
                    if let oauth, oauth.loggedIn {
                        LabeledContent("OAuth", value: oauth.source.isEmpty ? "Connected" : oauth.source)
                    }
                }

                if let oauth {
                    Section("Account") {
                        if oauth.loggedIn {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if !oauth.expiresAt.isEmpty {
                                LabeledContent("Expires", value: oauth.expiresAt)
                            }
                            if oauth.disconnectable {
                                Button("Disconnect OAuth", role: .destructive) { disconnecting = true }
                            } else if !oauth.disconnectHint.isEmpty {
                                Text(oauth.disconnectHint).font(.footnote).foregroundStyle(.secondary)
                            }
                        } else if oauth.flow == "device_code" {
                            Button {
                                beginOAuth(oauth)
                            } label: {
                                Label("Connect \(oauth.name)", systemImage: "person.crop.circle.badge.plus")
                            }
                            .disabled(working)
                        } else {
                            Text("Hermes requires this provider's external login flow.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !oauth.cliCommand.isEmpty {
                                Text(oauth.cliCommand)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            if let url = URL(string: oauth.docsURL), !oauth.docsURL.isEmpty {
                                Link("Open provider instructions", destination: url)
                            }
                        }
                        if !oauth.error.isEmpty {
                            Text(oauth.error).foregroundStyle(.red).font(.footnote)
                        }
                    }
                }

                if let login {
                    Section("Finish sign-in") {
                        if !login.userCode.isEmpty {
                            LabeledContent("Code") {
                                Text(login.userCode).font(.title3.monospaced().bold()).textSelection(.enabled)
                            }
                        }
                        if let url = URL(string: login.verificationURL) {
                            Button("Open verification page") { openURL(url) }
                        }
                        HStack { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
                    }
                }

                if !credentials.isEmpty {
                    Section {
                        ForEach(credentials.filter { !$0.advanced || $0.isSet }) { credential in
                            Button {
                                editingCredential = credential
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(credential.key).font(.subheadline.monospaced()).foregroundStyle(.primary)
                                        if !credential.detail.isEmpty {
                                            Text(credential.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(credential.isSet ? (credential.redactedValue.isEmpty ? "Set" : credential.redactedValue) : "Add")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("API keys")
                    } footer: {
                        Text("Keys are written to this Hermes profile's .env. Alice never stores their value locally.")
                    }
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(destination.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editingCredential) { credential in
                CredentialEditorSheet(profile: profile, credential: credential) {
                    onChanged()
                    dismiss()
                }
                .environment(store)
            }
            .confirmationDialog("Disconnect \(destination.name)?", isPresented: $disconnecting) {
                Button("Disconnect", role: .destructive) { disconnectOAuth() }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear { cancelPendingOAuth() }
        }
    }

    private func beginOAuth(_ state: OAuthProviderState) {
        oauthTask?.cancel()
        working = true
        failure = nil
        oauthTask = Task {
            defer {
                working = false
                oauthTask = nil
            }
            do {
                let started = try await store.startOAuthLogin(provider: state.id, profile: profile)
                login = started
                if let url = URL(string: started.verificationURL) { openURL(url) }
                let maxPolls = max(1, started.expiresIn / max(started.pollInterval, 1))
                for _ in 0..<maxPolls {
                    try await Task.sleep(for: .seconds(started.pollInterval))
                    let polled = try await store.pollOAuth(
                        provider: state.id, sessionID: started.sessionID, profile: profile
                    )
                    switch polled.status {
                    case "approved":
                        login = nil
                        onChanged()
                        dismiss()
                        return
                    case "denied", "expired", "error":
                        login = nil
                        failure = polled.error.isEmpty ? "Sign-in \(polled.status)." : polled.error
                        return
                    default: continue
                    }
                }
                login = nil
                failure = "Sign-in expired."
            } catch {
                login = nil
                if !Task.isCancelled { failure = diagnosticMessage(error) }
            }
        }
    }

    private func cancelPendingOAuth() {
        guard let pending = login else { return }
        login = nil
        oauthTask?.cancel()
        oauthTask = nil
        Task {
            try? await store.cancelOAuth(sessionID: pending.sessionID, profile: profile)
        }
    }

    private func disconnectOAuth() {
        guard let oauth else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await store.disconnectOAuth(provider: oauth.id, profile: profile)
                onChanged()
                dismiss()
            } catch { failure = diagnosticMessage(error) }
        }
    }
}

private struct CredentialEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: String
    let credential: ProviderCredential
    let onSaved: () -> Void

    @State private var value = ""
    @State private var failure: String?
    @State private var warning: String?
    @State private var saving = false
    @State private var removing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if credential.isPassword {
                        SecureField("Key", text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("Value", text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if !credential.detail.isEmpty {
                        Text(credential.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    if credential.isSet {
                        LabeledContent("Current", value: credential.redactedValue.isEmpty ? "Set" : credential.redactedValue)
                    }
                }
                if let warning { Section { Text(warning).foregroundStyle(.orange).font(.footnote) } }
                if let failure { Section { Text(failure).foregroundStyle(.red).font(.footnote) } }
                if credential.isSet {
                    Section { Button("Remove key", role: .destructive) { removing = true } }
                }
            }
            .navigationTitle(credential.key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .confirmationDialog("Remove this key?", isPresented: $removing) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        failure = nil
        warning = nil
        Task {
            defer { saving = false }
            do {
                let validation = try await store.validateProviderCredential(key: credential.key, value: trimmed)
                if !validation.ok && validation.reachable {
                    failure = validation.message.isEmpty ? "The provider rejected that credential." : validation.message
                    return
                }
                if !validation.reachable {
                    warning = validation.message.isEmpty
                        ? "Hermes could not verify this key live; it will still be saved."
                        : validation.message
                }
                try await store.saveProviderCredential(profile: profile, key: credential.key, value: trimmed)
                onSaved()
                dismiss()
            } catch { failure = diagnosticMessage(error) }
        }
    }

    private func remove() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.removeProviderCredential(profile: profile, key: credential.key)
                onSaved()
                dismiss()
            } catch { failure = diagnosticMessage(error) }
        }
    }
}
