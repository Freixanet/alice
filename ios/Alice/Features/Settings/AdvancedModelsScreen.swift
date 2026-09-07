import SwiftUI

/// Profile-scoped model routing that goes beyond the default-model picker:
/// auxiliary task pins, Hermes recommendations, MoA presets and custom/local
/// OpenAI-compatible endpoints. Provider secrets are write-only and never
/// persisted by Alice.
struct AdvancedModelsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    let profile: String

    @State private var aux: AuxiliaryModelsSnapshot?
    @State private var moa: MoAConfiguration?
    @State private var providers: [InferenceProvider] = []
    @State private var recommendationProvider = ""
    @State private var recommendation: RecommendedModelDefault?
    @State private var loading = false
    @State private var failure: String?
    @State private var pickerTarget: AdvancedAssignmentTarget?
    @State private var pendingConfirmation: AdvancedPendingAssignment?
    @State private var saving = false
    @State private var showCustomEndpoint = false
    @State private var showMoA = false
    @State private var confirmResetAll = false

    var body: some View {
        List {
            profileSection
            recommendationSection
            auxiliarySection
            customEndpointSection
            moaSection

            if let failure {
                Section("Last error") {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("Advanced Models")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .overlay { if loading && aux == nil { ProgressView() } }
        .task { await load(refreshing: false) }
        .refreshable { await load(refreshing: true) }
        .onChange(of: recommendationProvider) { _, _ in
            Task { await loadRecommendation() }
        }
        .sheet(item: $pickerTarget) { target in
            AdvancedProviderModelPicker(
                title: pickerTitle(target),
                providers: providers,
                currentProvider: currentProvider(target),
                currentModel: currentModel(target),
                excludeProviders: [],
                onSelect: { provider, model in
                    pickerTarget = nil
                    Task { await assign(target, provider: provider, model: model) }
                }
            )
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(isPresented: $showCustomEndpoint) {
            CustomModelEndpointSheet(profile: profile, tasks: aux?.tasks ?? []) {
                Task { await load(refreshing: true) }
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(isPresented: $showMoA) {
            if let moa {
                MoAConfigurationSheet(
                    profile: profile,
                    initial: moa,
                    providers: providers,
                    onSaved: { saved in
                        self.moa = saved
                        showMoA = false
                    }
                )
                .preferredColorScheme(store.theme.colorScheme)
            }
        }
        .confirmationDialog(
            "Reset every auxiliary task to Auto?",
            isPresented: $confirmResetAll,
            titleVisibility: .visible
        ) {
            Button("Reset all", role: .destructive) { Task { await resetAllAuxiliary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All per-task model overrides for this profile will be removed. Auxiliary work will follow the main model again.")
        }
        .confirmationDialog(
            "Expensive model warning",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use model anyway", role: .destructive) {
                guard let pending = pendingConfirmation else { return }
                pendingConfirmation = nil
                Task { await assignConfirmed(pending) }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(pendingConfirmation?.message ?? "Hermes reports unusually high known pricing for this model.")
        }
    }

    private var profileSection: some View {
        Section {
            LabeledContent("Profile", value: profile == "default" ? "Alice" : profile)
                .listRowBackground(Palette.card(scheme))
            if let aux {
                LabeledContent(
                    "Main model",
                    value: modelLabel(provider: aux.mainProvider, model: aux.mainModel)
                )
                .listRowBackground(Palette.card(scheme))
            }
        } footer: {
            Text("These settings affect new Hermes sessions in this profile. Existing chats keep their current session model unless switched inside the chat.")
        }
    }

    @ViewBuilder
    private var recommendationSection: some View {
        Section("Hermes recommendation") {
            Picker("Provider", selection: $recommendationProvider) {
                ForEach(recommendationProviders) { provider in
                    Text(provider.name).tag(provider.slug)
                }
            }
            .listRowBackground(Palette.card(scheme))

            if recommendationProvider.isEmpty {
                Text("No provider with models is available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            } else if let recommendation, !recommendation.model.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HermesClient.prettify(recommendation.model))
                        .font(.subheadline.weight(.semibold))
                    Text(recommendation.model)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let free = recommendation.freeTier {
                        Text(free ? "Nous free-tier recommendation" : "Nous paid-tier recommendation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                Button {
                    Task { await useRecommendation(recommendation) }
                } label: {
                    if saving { ProgressView() }
                    else { Label("Use recommended default", systemImage: "wand.and.stars") }
                }
                .disabled(saving)
                .listRowBackground(Palette.card(scheme))
            } else {
                Text("Hermes does not currently have a recommended default for this provider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    @ViewBuilder
    private var auxiliarySection: some View {
        Section {
            if let aux {
                ForEach(aux.tasks) { task in
                    auxiliaryRow(task)
                        .listRowBackground(Palette.card(scheme))
                }

                Menu {
                    Button("Choose one model for all tasks") {
                        pickerTarget = .allAuxiliary
                    }
                    Button("Reset all to Auto", role: .destructive) {
                        confirmResetAll = true
                    }
                } label: {
                    Label("Bulk auxiliary settings", systemImage: "slider.horizontal.3")
                }
                .listRowBackground(Palette.card(scheme))
            } else {
                Text("Auxiliary model assignments unavailable.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
        } header: {
            Text("Auxiliary tasks")
        } footer: {
            Text("Auto follows the main model. A pin is sticky when the main provider changes, so use it only where a cheaper, faster or specialized model is intentional.")
        }
    }

    private func auxiliaryRow(_ task: AuxiliaryModelAssignment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: auxiliarySymbol(task.task))
                    .foregroundStyle(task.isAutomatic ? .secondary : store.accent.primary(scheme))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auxiliaryLabel(task.task)).font(.subheadline.weight(.medium))
                    Text(auxiliaryHint(task.task)).font(.caption).foregroundStyle(.secondary)
                    Text(task.isAutomatic ? "Auto · use main model" : modelLabel(provider: task.provider, model: task.model))
                        .font(.caption2.monospaced())
                        .foregroundStyle(task.isAutomatic ? .secondary : .primary)
                        .lineLimit(2)
                    if !task.baseURL.isEmpty {
                        Text(task.baseURL)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if !task.isAutomatic {
                    Text("PINNED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(store.accent.primary(scheme))
                }
            }
            HStack(spacing: 8) {
                Button("Change") { pickerTarget = .auxiliary(task.task) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !task.isAutomatic {
                    Button("Auto") { Task { await resetAuxiliary(task.task) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var customEndpointSection: some View {
        Section {
            Button {
                showCustomEndpoint = true
            } label: {
                Label("Configure custom/local endpoint", systemImage: "network")
            }
            .listRowBackground(Palette.card(scheme))
        } header: {
            Text("OpenAI-compatible endpoints")
        } footer: {
            Text("The URL is resolved by the Hermes host, not by the iPhone. API keys are sent directly to Hermes and are never written to Alice preferences.")
        }
    }

    @ViewBuilder
    private var moaSection: some View {
        Section {
            if let moa {
                let preset = effectiveMoAPreset(moa)
                LabeledContent("Default preset", value: moa.defaultPreset)
                    .listRowBackground(Palette.card(scheme))
                if !moa.activePreset.isEmpty {
                    LabeledContent("Active override", value: moa.activePreset)
                        .listRowBackground(Palette.card(scheme))
                }
                if let preset {
                    LabeledContent("References", value: "\(preset.referenceModels.filter(\.enabled).count) enabled")
                        .listRowBackground(Palette.card(scheme))
                    LabeledContent(
                        "Aggregator",
                        value: modelLabel(provider: preset.aggregator.provider, model: preset.aggregator.model)
                    )
                    .listRowBackground(Palette.card(scheme))
                }
                Button {
                    showMoA = true
                } label: {
                    Label("Configure MoA presets", systemImage: "brain.head.profile")
                }
                .listRowBackground(Palette.card(scheme))
            } else {
                Text("MoA configuration unavailable.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
        } header: {
            Text("Mixture of Agents")
        } footer: {
            Text("Reference models produce parallel perspectives; the aggregator is the acting model that answers and calls tools. Recursive MoA is blocked.")
        }
    }

    private var recommendationProviders: [InferenceProvider] {
        providers.filter { !$0.models.isEmpty }.sorted { lhs, rhs in
            if lhs.slug == aux?.mainProvider { return true }
            if rhs.slug == aux?.mainProvider { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func load(refreshing: Bool) async {
        guard store.dashboardReady else {
            failure = "Connect the Hermes dashboard to manage advanced models."
            return
        }
        loading = true
        defer { loading = false }
        do {
            async let auxResult = store.auxiliaryModels(profile: profile)
            async let moaResult = store.moaConfiguration(profile: profile)
            async let providerResult = store.inferenceProviders(profile: profile, refreshing: refreshing)
            let result = try await (auxResult, moaResult, providerResult)
            aux = result.0
            moa = result.1
            providers = result.2
            if recommendationProvider.isEmpty || !providers.contains(where: { $0.slug == recommendationProvider && !$0.models.isEmpty }) {
                recommendationProvider = result.0.mainProvider
                if recommendationProvider.isEmpty || !providers.contains(where: { $0.slug == recommendationProvider && !$0.models.isEmpty }) {
                    recommendationProvider = recommendationProviders.first?.slug ?? ""
                }
            }
            failure = nil
            await loadRecommendation()
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func loadRecommendation() async {
        guard !recommendationProvider.isEmpty else {
            recommendation = nil
            return
        }
        do {
            recommendation = try await store.recommendedModelDefault(provider: recommendationProvider)
        } catch {
            recommendation = nil
        }
    }

    private func assign(_ target: AdvancedAssignmentTarget, provider: String, model: String) async {
        saving = true
        defer { saving = false }
        do {
            let result: ModelAssignmentResult
            switch target {
            case .mainRecommendation:
                result = try await store.setProfileDefaultModel(
                    profile: profile, provider: provider, model: model
                )
            case .allAuxiliary:
                result = try await store.setAuxiliaryModel(
                    profile: profile, task: "", provider: provider, model: model
                )
            case let .auxiliary(task):
                result = try await store.setAuxiliaryModel(
                    profile: profile, task: task, provider: provider, model: model
                )
            }
            if result.confirmRequired {
                pendingConfirmation = .init(
                    target: target, provider: provider, model: model,
                    message: result.confirmMessage
                )
                return
            }
            guard result.ok else {
                failure = "Hermes did not save that model assignment."
                return
            }
            await load(refreshing: false)
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func assignConfirmed(_ pending: AdvancedPendingAssignment) async {
        saving = true
        defer { saving = false }
        do {
            let result: ModelAssignmentResult
            switch pending.target {
            case .mainRecommendation:
                result = try await store.setProfileDefaultModel(
                    profile: profile, provider: pending.provider, model: pending.model,
                    confirmExpensive: true
                )
            case .allAuxiliary:
                result = try await store.setAuxiliaryModel(
                    profile: profile, task: "", provider: pending.provider,
                    model: pending.model, confirmExpensive: true
                )
            case let .auxiliary(task):
                result = try await store.setAuxiliaryModel(
                    profile: profile, task: task, provider: pending.provider,
                    model: pending.model, confirmExpensive: true
                )
            }
            guard result.ok else {
                failure = "Hermes did not save that model assignment."
                return
            }
            await load(refreshing: false)
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func useRecommendation(_ recommendation: RecommendedModelDefault) async {
        await assign(.mainRecommendation, provider: recommendation.provider, model: recommendation.model)
    }

    private func resetAuxiliary(_ task: String) async {
        do {
            let result = try await store.setAuxiliaryModel(
                profile: profile, task: task, provider: "auto", model: ""
            )
            guard result.ok else { throw DashboardClient.Failure.unreadable }
            await load(refreshing: false)
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func resetAllAuxiliary() async {
        do {
            let result = try await store.resetAuxiliaryModels(profile: profile)
            guard result.ok else { throw DashboardClient.Failure.unreadable }
            await load(refreshing: false)
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func pickerTitle(_ target: AdvancedAssignmentTarget) -> String {
        switch target {
        case .mainRecommendation: "Choose main model"
        case .allAuxiliary: "Set all auxiliary tasks"
        case let .auxiliary(task): "Set \(auxiliaryLabel(task))"
        }
    }

    private func currentProvider(_ target: AdvancedAssignmentTarget) -> String {
        switch target {
        case .mainRecommendation: aux?.mainProvider ?? ""
        case .allAuxiliary: ""
        case let .auxiliary(task): aux?.tasks.first(where: { $0.task == task })?.provider ?? ""
        }
    }

    private func currentModel(_ target: AdvancedAssignmentTarget) -> String {
        switch target {
        case .mainRecommendation: aux?.mainModel ?? ""
        case .allAuxiliary: ""
        case let .auxiliary(task): aux?.tasks.first(where: { $0.task == task })?.model ?? ""
        }
    }

    private func effectiveMoAPreset(_ config: MoAConfiguration) -> MoAPreset? {
        if !config.activePreset.isEmpty, let preset = config.presets[config.activePreset] { return preset }
        return config.presets[config.defaultPreset] ?? config.presets.values.first
    }
}

private enum AdvancedAssignmentTarget: Hashable, Identifiable {
    case mainRecommendation
    case allAuxiliary
    case auxiliary(String)

    var id: String {
        switch self {
        case .mainRecommendation: "main"
        case .allAuxiliary: "all-aux"
        case let .auxiliary(task): "aux-\(task)"
        }
    }
}

private struct AdvancedPendingAssignment {
    var target: AdvancedAssignmentTarget
    var provider: String
    var model: String
    var message: String
}

private struct AdvancedProviderModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let title: String
    let providers: [InferenceProvider]
    let currentProvider: String
    let currentModel: String
    let excludeProviders: Set<String>
    let onSelect: (String, String) -> Void

    @State private var search = ""

    private var visibleProviders: [InferenceProvider] {
        providers.compactMap { provider in
            guard !excludeProviders.contains(provider.slug.lowercased()) else { return nil }
            let models = provider.models.filter {
                search.isEmpty || $0.localizedCaseInsensitiveContains(search)
                    || provider.name.localizedCaseInsensitiveContains(search)
                    || provider.slug.localizedCaseInsensitiveContains(search)
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
                ForEach(visibleProviders) { provider in
                    Section {
                        if !provider.authenticated && !provider.isUserDefined {
                            Text("Connect this provider first in Models & Providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Palette.card(scheme))
                        }
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                onSelect(provider.slug, model)
                                dismiss()
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
                            .disabled(!provider.authenticated && !provider.isUserDefined)
                            .listRowBackground(Palette.card(scheme))
                        }
                    } header: {
                        Text(provider.name)
                    }
                }

                if visibleProviders.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No models available" : "No matches",
                        systemImage: "cpu"
                    )
                    .listRowBackground(Palette.card(scheme))
                }
            }
            .searchable(text: $search, prompt: "Model or provider")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct CustomModelEndpointSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let profile: String
    let tasks: [AuxiliaryModelAssignment]
    let onSaved: () -> Void

    @State private var provider = "custom"
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var scope = "main"
    @State private var task = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    Picker("Type", selection: $provider) {
                        Text("Custom").tag("custom")
                        Text("Local").tag("local")
                    }
                    .pickerStyle(.segmented)
                    TextField("http://127.0.0.1:11434/v1", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model ID", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    Text("Hermes resolves this URL on the Mac/server. `127.0.0.1` therefore means the Hermes host, not this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))

                Section("Assign to") {
                    Picker("Scope", selection: $scope) {
                        Text("Main model").tag("main")
                        Text("All auxiliary").tag("all")
                        Text("One auxiliary task").tag("task")
                    }
                    if scope == "task" {
                        Picker("Task", selection: $task) {
                            ForEach(tasks) { item in
                                Text(auxiliaryLabel(item.task)).tag(item.task)
                            }
                        }
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red) }
                        .listRowBackground(Palette.card(scheme))
                }
            }
            .navigationTitle("Custom Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .onAppear { if task.isEmpty { task = tasks.first?.task ?? "" } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(confirmed: false) } }.disabled(saving)
                }
            }
            .confirmationDialog(
                "Expensive model warning",
                isPresented: Binding(
                    get: { confirmMessage != nil },
                    set: { if !$0 { confirmMessage = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Use model anyway", role: .destructive) {
                    confirmMessage = nil
                    Task { await save(confirmed: true) }
                }
                Button("Cancel", role: .cancel) { confirmMessage = nil }
            } message: {
                Text(confirmMessage ?? "Hermes reports unusually high known pricing for this model.")
            }
        }
    }

    private func save(confirmed: Bool) async {
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            failure = "Enter a valid HTTP or HTTPS endpoint URL."
            return
        }
        guard !cleanModel.isEmpty else {
            failure = "Model ID is required."
            return
        }
        if scope == "task" && task.isEmpty {
            failure = "Choose an auxiliary task."
            return
        }

        saving = true
        defer { saving = false }
        failure = nil
        do {
            let result: ModelAssignmentResult
            if scope == "main" {
                result = try await store.setProfileDefaultModel(
                    profile: profile, provider: provider, model: cleanModel,
                    baseURL: cleanURL, apiKey: apiKey,
                    confirmExpensive: confirmed
                )
            } else {
                result = try await store.setAuxiliaryModel(
                    profile: profile, task: scope == "all" ? "" : task,
                    provider: provider, model: cleanModel,
                    baseURL: cleanURL, apiKey: apiKey,
                    confirmExpensive: confirmed
                )
            }
            if result.confirmRequired {
                confirmMessage = result.confirmMessage.isEmpty
                    ? "Hermes requires confirmation before using this model."
                    : result.confirmMessage
                return
            }
            guard result.ok else {
                failure = "Hermes did not save this endpoint assignment."
                return
            }
            apiKey = ""
            onSaved()
            dismiss()
        } catch {
            failure = diagnosticMessage(error)
        }
    }
}

private struct MoAConfigurationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let profile: String
    let providers: [InferenceProvider]
    let onSaved: (MoAConfiguration) -> Void

    @State private var draft: MoAConfiguration
    @State private var selectedPreset: String
    @State private var picker: MoAPickerTarget?
    @State private var saving = false
    @State private var failure: String?
    @State private var newPresetName = ""
    @State private var showNewPreset = false
    @State private var confirmDelete = false

    init(
        profile: String,
        initial: MoAConfiguration,
        providers: [InferenceProvider],
        onSaved: @escaping (MoAConfiguration) -> Void
    ) {
        self.profile = profile
        self.providers = providers
        self.onSaved = onSaved
        _draft = State(initialValue: initial)
        let first = initial.presets[initial.defaultPreset] != nil
            ? initial.defaultPreset
            : (initial.presets.keys.sorted().first ?? "")
        _selectedPreset = State(initialValue: first)
    }

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                referenceSection
                aggregatorSection
                tuningSection
                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                        .listRowBackground(Palette.card(scheme))
                }
            }
            .navigationTitle("Mixture of Agents")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || currentPreset == nil)
                }
            }
            .sheet(item: $picker) { target in
                AdvancedProviderModelPicker(
                    title: target.title,
                    providers: providers,
                    currentProvider: target.currentProvider(in: currentPreset),
                    currentModel: target.currentModel(in: currentPreset),
                    excludeProviders: ["moa"],
                    onSelect: { provider, model in
                        applyMoASelection(target, provider: provider, model: model)
                        picker = nil
                    }
                )
                .preferredColorScheme(store.theme.colorScheme)
            }
            .alert("New MoA preset", isPresented: $showNewPreset) {
                TextField("Preset name", text: $newPresetName)
                Button("Add") { addPreset() }
                Button("Cancel", role: .cancel) { newPresetName = "" }
            } message: {
                Text("The new preset starts as a copy of the currently selected preset.")
            }
            .confirmationDialog(
                "Delete preset “\(selectedPreset)” ?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deletePreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("At least one MoA preset must remain.")
            }
        }
    }

    private var presetSection: some View {
        Section("Presets") {
            Picker("Preset", selection: $selectedPreset) {
                ForEach(draft.presets.keys.sorted(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .listRowBackground(Palette.card(scheme))

            if let preset = currentPreset {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { preset.enabled },
                        set: { value in mutatePreset { $0.enabled = value } }
                    )
                )
                .listRowBackground(Palette.card(scheme))
            }

            LabeledContent("Default", value: draft.defaultPreset)
                .listRowBackground(Palette.card(scheme))
            if !draft.activePreset.isEmpty {
                LabeledContent("Active override", value: draft.activePreset)
                    .listRowBackground(Palette.card(scheme))
            }

            HStack {
                Button("Set default") { draft.defaultPreset = selectedPreset }
                    .disabled(selectedPreset.isEmpty || draft.defaultPreset == selectedPreset)
                Spacer()
                Menu {
                    Button("Add preset") {
                        newPresetName = ""
                        showNewPreset = true
                    }
                    Button("Delete preset", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(draft.presets.count <= 1)
                    if !draft.activePreset.isEmpty {
                        Button("Clear active override") { draft.activePreset = "" }
                    }
                } label: {
                    Label("Preset actions", systemImage: "ellipsis.circle")
                }
            }
            .listRowBackground(Palette.card(scheme))
        }
    }

    @ViewBuilder
    private var referenceSection: some View {
        Section("Reference models") {
            if let preset = currentPreset {
                ForEach(Array(preset.referenceModels.enumerated()), id: \.offset) { index, slot in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reference \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(modelLabel(provider: slot.provider, model: slot.model))
                                    .font(.caption.monospaced()).lineLimit(2)
                            }
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { currentPreset?.referenceModels[safe: index]?.enabled ?? slot.enabled },
                                    set: { value in mutateReference(index) { $0.enabled = value } }
                                )
                            )
                            .labelsHidden()
                        }
                        reasoningPicker(
                            value: slot.reasoningEffort,
                            set: { effort in mutateReference(index) { $0.reasoningEffort = effort } }
                        )
                        HStack(spacing: 8) {
                            Button("Change") { picker = .reference(index) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button("Remove", role: .destructive) {
                                mutatePreset { preset in
                                    guard preset.referenceModels.count > 1 else { return }
                                    preset.referenceModels.remove(at: index)
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(preset.referenceModels.count <= 1)
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Palette.card(scheme))
                }

                Button {
                    mutatePreset { preset in
                        var slot = preset.aggregator
                        slot.enabled = true
                        preset.referenceModels.append(slot)
                    }
                } label: {
                    Label("Add reference model", systemImage: "plus")
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    @ViewBuilder
    private var aggregatorSection: some View {
        Section("Aggregator") {
            if let preset = currentPreset {
                VStack(alignment: .leading, spacing: 7) {
                    Text(modelLabel(provider: preset.aggregator.provider, model: preset.aggregator.model))
                        .font(.caption.monospaced()).lineLimit(2)
                    reasoningPicker(
                        value: preset.aggregator.reasoningEffort,
                        set: { effort in mutatePreset { $0.aggregator.reasoningEffort = effort } }
                    )
                    Button("Change aggregator") { picker = .aggregator }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 3)
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    @ViewBuilder
    private var tuningSection: some View {
        if let preset = currentPreset {
            Section("Tuning") {
                optionalDoubleField(
                    "Reference temperature",
                    value: preset.referenceTemperature,
                    set: { value in mutatePreset { $0.referenceTemperature = value } }
                )
                optionalDoubleField(
                    "Aggregator temperature",
                    value: preset.aggregatorTemperature,
                    set: { value in mutatePreset { $0.aggregatorTemperature = value } }
                )
                optionalDoubleField(
                    "Reference timeout (s)",
                    value: preset.referenceTimeout,
                    positiveOnly: true,
                    set: { value in mutatePreset { $0.referenceTimeout = value } }
                )

                Picker(
                    "Degraded references",
                    selection: Binding(
                        get: { currentPreset?.degradedReferencePolicy ?? preset.degradedReferencePolicy },
                        set: { value in mutatePreset { $0.degradedReferencePolicy = value } }
                    )
                ) {
                    Text("Fail loudly").tag("loud")
                    Text("Continue silently").tag("silent")
                }

                integerField(
                    "Aggregator max tokens",
                    value: preset.maxTokens,
                    optional: false,
                    set: { value in if let value { mutatePreset { $0.maxTokens = value } } }
                )
                integerField(
                    "Reference max tokens",
                    value: preset.referenceMaxTokens,
                    optional: true,
                    set: { value in mutatePreset { $0.referenceMaxTokens = value } }
                )

                TextField(
                    "Fanout cadence",
                    text: Binding(
                        get: { currentPreset?.fanout ?? "" },
                        set: { raw in
                            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            mutatePreset { $0.fanout = clean.isEmpty ? nil : clean }
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Text("Fanout: user_turn (cheapest), per_iteration, or every_n:N where N ≥ 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Palette.card(scheme))
        }
    }

    private var currentPreset: MoAPreset? { draft.presets[selectedPreset] }

    private func mutatePreset(_ change: (inout MoAPreset) -> Void) {
        guard var preset = draft.presets[selectedPreset] else { return }
        change(&preset)
        draft.presets[selectedPreset] = preset
    }

    private func mutateReference(_ index: Int, _ change: (inout MoAModelSlot) -> Void) {
        mutatePreset { preset in
            guard preset.referenceModels.indices.contains(index) else { return }
            change(&preset.referenceModels[index])
        }
    }

    private func reasoningPicker(value: String?, set: @escaping (String?) -> Void) -> some View {
        let known = ["", "low", "medium", "high", "xhigh"]
        let current = value ?? ""
        let values = known.contains(current) ? known : known + [current]
        return Picker(
            "Reasoning effort",
            selection: Binding(
                get: { current },
                set: { set($0.isEmpty ? nil : $0) }
            )
        ) {
            ForEach(values, id: \.self) { effort in
                Text(effort.isEmpty ? "Provider default" : effort.capitalized).tag(effort)
            }
        }
        .pickerStyle(.menu)
    }

    private func optionalDoubleField(
        _ title: String, value: Double?, positiveOnly: Bool = false,
        set: @escaping (Double?) -> Void
    ) -> some View {
        TextField(
            title,
            text: Binding(
                get: { value.map { String($0) } ?? "" },
                set: { raw in
                    let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty { set(nil); return }
                    guard let parsed = Double(clean), parsed.isFinite, !positiveOnly || parsed > 0 else { return }
                    set(parsed)
                }
            )
        )
        .keyboardType(.decimalPad)
    }

    private func integerField(
        _ title: String, value: Int?, optional: Bool,
        set: @escaping (Int?) -> Void
    ) -> some View {
        TextField(
            title,
            text: Binding(
                get: { value.map(String.init) ?? "" },
                set: { raw in
                    let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty, optional { set(nil); return }
                    guard let parsed = Int(clean), parsed > 0 else { return }
                    set(parsed)
                }
            )
        )
        .keyboardType(.numberPad)
    }

    private func applyMoASelection(_ target: MoAPickerTarget, provider: String, model: String) {
        guard provider.lowercased() != "moa" else {
            failure = "MoA presets cannot reference or aggregate the MoA provider itself."
            return
        }
        switch target {
        case .aggregator:
            mutatePreset {
                $0.aggregator.provider = provider
                $0.aggregator.model = model
            }
        case let .reference(index):
            mutateReference(index) {
                $0.provider = provider
                $0.model = model
            }
        }
    }

    private func addPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { newPresetName = "" }
        guard !name.isEmpty, draft.presets[name] == nil, let seed = currentPreset else { return }
        draft.presets[name] = seed
        if draft.defaultPreset.isEmpty { draft.defaultPreset = name }
        selectedPreset = name
    }

    private func deletePreset() {
        guard draft.presets.count > 1 else { return }
        draft.presets.removeValue(forKey: selectedPreset)
        let next = draft.presets.keys.sorted().first ?? ""
        if draft.defaultPreset == selectedPreset { draft.defaultPreset = next }
        if draft.activePreset == selectedPreset { draft.activePreset = "" }
        selectedPreset = next
    }

    private func save() async {
        failure = validateDraft()
        guard failure == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let saved = try await store.saveMoAConfiguration(draft, profile: profile)
            onSaved(saved)
            dismiss()
        } catch {
            failure = diagnosticMessage(error)
        }
    }

    private func validateDraft() -> String? {
        guard !draft.presets.isEmpty else { return "At least one MoA preset is required." }
        guard draft.presets[draft.defaultPreset] != nil else { return "The default preset must exist." }
        for (name, preset) in draft.presets {
            guard !preset.referenceModels.isEmpty else { return "Preset \(name) needs at least one reference model." }
            if preset.referenceModels.contains(where: { $0.provider.isEmpty || $0.model.isEmpty }) {
                return "Every reference in preset \(name) needs a provider and model."
            }
            guard !preset.aggregator.provider.isEmpty, !preset.aggregator.model.isEmpty else {
                return "Preset \(name) needs an aggregator provider and model."
            }
            if preset.aggregator.provider.lowercased() == "moa"
                || preset.referenceModels.contains(where: { $0.provider.lowercased() == "moa" }) {
                return "MoA cannot recursively use the MoA provider."
            }
            guard preset.maxTokens > 0 else { return "Aggregator max tokens must be positive." }
            if let timeout = preset.referenceTimeout, timeout <= 0 { return "Reference timeout must be positive." }
            if let cap = preset.referenceMaxTokens, cap <= 0 { return "Reference max tokens must be positive." }
            if let fanout = preset.fanout, !validFanout(fanout) {
                return "Fanout must be user_turn, per_iteration, or every_n:N with N ≥ 2."
            }
        }
        return nil
    }

    private func validFanout(_ value: String) -> Bool {
        if ["user_turn", "per_iteration"].contains(value) { return true }
        guard value.hasPrefix("every_n:"), let n = Int(value.dropFirst("every_n:".count)) else { return false }
        return n >= 2
    }
}

private enum MoAPickerTarget: Identifiable {
    case reference(Int)
    case aggregator

    var id: String {
        switch self {
        case let .reference(index): "reference-\(index)"
        case .aggregator: "aggregator"
        }
    }

    var title: String {
        switch self {
        case let .reference(index): "Reference \(index + 1)"
        case .aggregator: "Aggregator"
        }
    }

    func currentProvider(in preset: MoAPreset?) -> String {
        switch self {
        case let .reference(index): preset?.referenceModels[safe: index]?.provider ?? ""
        case .aggregator: preset?.aggregator.provider ?? ""
        }
    }

    func currentModel(in preset: MoAPreset?) -> String {
        switch self {
        case let .reference(index): preset?.referenceModels[safe: index]?.model ?? ""
        case .aggregator: preset?.aggregator.model ?? ""
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func modelLabel(provider: String, model: String) -> String {
    if provider.isEmpty && model.isEmpty { return "Not set" }
    if provider.isEmpty { return model }
    if model.isEmpty { return provider }
    return "\(provider) · \(model)"
}

private func auxiliaryLabel(_ task: String) -> String {
    switch task {
    case "vision": "Vision"
    case "compression": "Compression"
    case "skills_hub": "Skills Hub"
    case "approval": "Approval"
    case "mcp": "MCP"
    case "title_generation": "Title Generation"
    case "review": "Review"
    case "triage_specifier": "Triage Specifier"
    case "kanban_decomposer": "Kanban Decomposer"
    case "profile_describer": "Profile Describer"
    case "curator": "Curator"
    default: task.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func auxiliaryHint(_ task: String) -> String {
    switch task {
    case "vision": "Image analysis"
    case "compression": "Context compaction"
    case "skills_hub": "Skill search"
    case "approval": "Smart auto-approve"
    case "mcp": "MCP tool routing"
    case "title_generation": "Session titles"
    case "review": "/review subagent"
    case "triage_specifier": "Kanban spec fleshing"
    case "kanban_decomposer": "Task decomposition"
    case "profile_describer": "Automatic profile descriptions"
    case "curator": "Skill-usage review"
    default: "Auxiliary Hermes task"
    }
}

private func auxiliarySymbol(_ task: String) -> String {
    switch task {
    case "vision": "eye"
    case "compression": "arrow.down.right.and.arrow.up.left"
    case "skills_hub": "sparkles"
    case "approval": "checkmark.shield"
    case "mcp": "shippingbox"
    case "title_generation": "textformat"
    case "review": "doc.text.magnifyingglass"
    case "triage_specifier": "list.bullet.clipboard"
    case "kanban_decomposer": "rectangle.3.group"
    case "profile_describer": "person.text.rectangle"
    case "curator": "books.vertical"
    default: "cpu"
    }
}
