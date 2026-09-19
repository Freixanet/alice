import SwiftUI

/// Picking a model deserves a screen, not a menu.
///
/// A Hermes can front a hundred models across half a dozen providers, which a
/// dropdown handles badly: no search, no grouping, and no room to say where a
/// model comes from. This lists them by provider with the current one checked.
struct ModelPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var applyingModel = false
    @State private var pendingBotModel: HermesClient.ModelOption?
    @State private var modelConfirmation: String?
    @State private var failure: String?
    /// Supplied by a bot's settings page. When absent, Alice's own model is
    /// being chosen (the chat composer never opens this sheet for a bot).
    var bot: BotRow?
    /// When true, this picker writes the profile's first `fallback_providers`
    /// hop rather than its primary model.
    var selectsFallback = false
    /// Set when a model is only being picked, not applied — for an agent that
    /// does not exist yet. The same list, recents and search as settings; the
    /// tap hands the choice back instead of writing it to a profile.
    var chosen: HermesClient.ModelOption?
    var onChoose: ((HermesClient.ModelOption) -> Void)?
    /// Create-agent fallback: "None" is a real choice, not a missing pick.
    var onClear: (() -> Void)?

    init(
        bot: BotRow? = nil, chosen: HermesClient.ModelOption? = nil,
        selectsFallback: Bool = false,
        onChoose: ((HermesClient.ModelOption) -> Void)? = nil,
        onClear: (() -> Void)? = nil
    ) {
        self.bot = bot
        self.chosen = chosen
        self.selectsFallback = selectsFallback
        self.onChoose = onChoose
        self.onClear = onClear
    }

    private var targetBot: BotRow? {
        guard let profile = targetProfile else { return nil }
        return store.cachedBots.first { $0.name == profile }
            ?? (bot?.name == profile ? bot : nil)
    }

    private var targetProfile: String? {
        guard onChoose == nil else { return nil }
        return bot?.name ?? store.activeBotProfileForModelSelection
    }

    private var currentModelLabel: String? {
        if onChoose != nil { return chosen?.label }
        guard let targetBot else { return store.currentChatModelLabel }
        if selectsFallback {
            return store.botFallbackOption(for: targetBot)?.label
                ?? store.cachedBotFallbacks[targetBot.name]?.first.map { HermesClient.prettify($0.model) }
        }
        return store.botModelOption(for: targetBot)?.label
            ?? targetBot.model.map(HermesClient.prettify)
    }

    private var allowsNone: Bool { selectsFallback }

    /// A typed id worth offering: it looks like a model name, and nothing in
    /// the catalogue already matches it exactly.
    private var customCandidate: String? {
        // Offered for agents as well as Alice: a model Hermes does not list —
        // OpenRouter's `stealth/union-alpha`, say — was out of every agent's
        // reach once it had been typed for Alice.
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 3, !typed.contains(" ") else { return nil }
        guard !store.models.contains(where: { $0.id == typed }) else { return nil }
        return typed
    }

    /// The providers models are listed under, in the order they first appear.
    private var typedProviders: [(slug: String, name: String)] {
        var seen = Set<String>()
        return store.models.compactMap { option in
            guard let slug = option.provider, !slug.isEmpty, seen.insert(slug).inserted
            else { return nil }
            return (slug, option.providerName ?? slug)
        }
    }

    private func typedOption(_ id: String, provider: String?, name: String?) -> HermesClient.ModelOption {
        HermesClient.ModelOption(
            id: id, label: HermesClient.prettify(id), provider: provider, providerName: name
        )
    }

    /// Alice's current model, for an agent's picker, when the list has not got it.
    private var aliceModelOption: HermesClient.ModelOption? {
        guard targetProfile != nil || onChoose != nil,
              query.isEmpty,
              let id = store.selectedModel, !id.isEmpty
        else { return nil }
        let provider = store.selectedProvider
        guard !store.models.contains(where: {
            $0.id == id && (provider == nil || $0.provider == provider)
        }) else { return nil }
        let name = typedProviders.first { $0.slug == provider }?.name
        return typedOption(id, provider: provider, name: name)
    }

    private func customRow(_ typed: String, via provider: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(typed).foregroundStyle(.primary)
                if let provider {
                    Text(provider).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "arrow.turn.down.left")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsNone {
                    Section {
                        Button {
                            chooseNone()
                        } label: {
                            HStack {
                                Text("None").foregroundStyle(.primary)
                                Spacer()
                                if usesNone {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(store.accent.primary(scheme))
                                }
                            }
                        }
                        .disabled(applyingModel)
                    } footer: {
                        Text("Used when the agent’s model is unavailable or at its limit.")
                    }
                }

                // Hermes does not always list everything it can serve. Its
                // catalogue for Nous, for one, holds only that provider's paid
                // models, so the free ones — which answer perfectly well —
                // appear nowhere and their provider vanishes from this screen
                // along with them. Typing an id is the way to reach anything
                // the catalogue has left out.
                if let typed = customCandidate {
                    Section("Use anyway") {
                        // One row per provider this Hermes has. Left to route
                        // it, Hermes keeps the current provider: Union Alpha
                        // typed as OpenRouter's `stealth/union-alpha` went on
                        // asking OpenCode Zen, which was failing, and the chat
                        // answered on a fallback model.
                        ForEach(typedProviders, id: \.slug) { provider in
                            Button {
                                choose(typedOption(typed, provider: provider.slug, name: provider.name))
                            } label: {
                                customRow(typed, via: provider.name)
                            }
                        }
                        if typedProviders.isEmpty {
                            Button {
                                choose(typedOption(typed, provider: nil, name: nil))
                            } label: {
                                customRow(typed, via: nil)
                            }
                        }
                    }
                }

                // Picking for an agent, Alice's own model is offered even when
                // Hermes' list leaves it out — typed by hand, it is in no list.
                if let alice = aliceModelOption {
                    Section("Alice’s model") {
                        row(alice)
                    }
                }

                // And once chosen, it has to be visible: a model this list has
                // never heard of would otherwise leave the screen looking as
                // though nothing were selected at all.
                if let current = currentModelLabel,
                   !store.models.contains(where: uses) {
                    Section("Current") {
                        HStack {
                            Text(current).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(store.accent.primary(scheme))
                        }
                    }
                }

                // Only the fallback answered: the one model the agent names to
                // OpenAI clients, not the list. A picker that quietly looks
                // complete is how one model passed for all of them.
                if store.modelListIsPartial, query.isEmpty, !store.isLoadingModels {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Only the default model loaded")
                                    .foregroundStyle(.primary)
                                Text("The full list took too long to arrive. Pull down to try again.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Recents first. Somebody who lives in one or two models
                // should not read past ninety-eight others to reach them.
                if !recents.isEmpty, query.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { model in
                            row(model)
                        }
                    }
                }

                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { model in
                            row(model)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle(selectsFallback ? "Fallback" : "Model")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.loadModels(refreshing: true) }
                    } label: {
                        if store.isLoadingModels {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!store.isConnected || store.isLoadingModels)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshableWithFeedback { await store.loadModels(refreshing: true) }
            .task {
                // A Bot Chat's model is profile state owned by Hermes. Refresh
                // it when this sheet opens so the checkmark reflects the
                // server rather than a stale phone-side roster snapshot.
                if let profile = targetProfile, store.dashboardReady {
                    if selectsFallback {
                        _ = try? await store.refreshBotFallback(profile)
                    } else {
                        _ = try? await store.bots()
                    }
                }
            }
            .alert(
                "Confirm model change",
                isPresented: Binding(
                    get: { modelConfirmation != nil },
                    set: { if !$0 { modelConfirmation = nil; pendingBotModel = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingBotModel = nil
                    modelConfirmation = nil
                }
                Button("Use Model") {
                    guard let pendingBotModel else { return }
                    modelConfirmation = nil
                    applyBotModel(pendingBotModel, confirm: true)
                    self.pendingBotModel = nil
                }
            } message: {
                Text(modelConfirmation ?? "Hermes requires confirmation.")
            }
            .alert(
                "Model change needs attention",
                isPresented: Binding(
                    get: { failure != nil },
                    set: { if !$0 { failure = nil } }
                )
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "Hermes did not finish changing the model.")
            }
            .overlay {
                if store.isLoadingModels && store.models.isEmpty {
                    ProgressView()
                } else if store.models.isEmpty {
                    ContentUnavailableView {
                        Label("No models", systemImage: "cpu")
                    } description: {
                        Text(
                            store.isConnected
                                ? (store.modelsError
                                    ?? "This Hermes returned no models.")
                                : "Connect your Hermes to choose a model."
                        )
                    } actions: {
                        if store.isConnected {
                            Button("Try again") {
                                Task { await store.loadModels(refreshing: true) }
                            }
                        }
                    }
                } else if groups.isEmpty, customCandidate == nil, query.count >= 3 {
                    // Small and out of the way: a full-screen "No results"
                    // covered the list with every letter typed, and the
                    // "Use anyway" rows with it.
                    Text("No models match “\(query)”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 24)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private struct Group {
        let name: String
        let models: [HermesClient.ModelOption]
    }

    /// The recently chosen models that the agent still offers, in the order
    /// they were last picked. Bot history is profile-specific; Alice keeps
    /// her existing global history.
    private var recents: [HermesClient.ModelOption] {
        if let profile = targetProfile {
            var result = store.recentBotModelOptions(for: profile)
            if selectsFallback {
                if let current = targetBot.flatMap({ store.botFallbackOption(for: $0) }),
                   !result.contains(where: { sameModel($0, current) }) {
                    result.insert(current, at: 0)
                }
            } else if let current = targetBot.flatMap({ store.botModelOption(for: $0) }),
               !result.contains(where: { sameModel($0, current) }) {
                result.insert(current, at: 0)
            }
            return result
        }
        return store.recentModels.compactMap { id in
            store.models.first { $0.id == id }
        }
    }

    private func sameModel(
        _ lhs: HermesClient.ModelOption, _ rhs: HermesClient.ModelOption
    ) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider
    }

    private func uses(_ model: HermesClient.ModelOption) -> Bool {
        if onChoose != nil { return chosen.map { sameModel($0, model) } ?? false }
        guard let targetBot else { return store.currentChatUses(model) }
        if selectsFallback {
            guard let first = store.cachedBotFallbacks[targetBot.name]?.first else { return false }
            guard first.model == model.id else { return false }
            return first.provider == model.provider || model.provider == nil
        }
        guard targetBot.model == model.id else { return false }
        guard let provider = targetBot.provider, !provider.isEmpty else { return true }
        return provider == model.provider
    }

    private var usesNone: Bool {
        if onChoose != nil { return chosen == nil }
        guard selectsFallback, let profile = targetProfile else { return false }
        return store.cachedBotFallbacks[profile]?.isEmpty == true
    }

    private func row(_ model: HermesClient.ModelOption) -> some View {
        Button {
            choose(model)
        } label: {
            HStack {
                Text(model.label).foregroundStyle(.primary)
                Spacer()
                if uses(model) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(store.accent.primary(scheme))
                } else if applyingModel, pendingBotModel == model {
                    ProgressView()
                }
            }
        }
        .disabled(applyingModel)
    }

    private func choose(_ model: HermesClient.ModelOption) {
        if let onChoose {
            onChoose(model)
            dismiss()
            return
        }
        guard let profile = targetProfile else {
            store.chooseModel(model.id, provider: model.provider)
            dismiss()
            return
        }
        if selectsFallback {
            if uses(model) {
                dismiss()
                return
            }
            applyBotFallback(model)
            return
        }
        // An already-selected model normally has nothing to write. A partial
        // routine/chat sync is the exception: tapping it resumes the saved,
        // idempotent follow-up instead of silently dismissing the picker.
        guard !uses(model)
                || store.botModelSyncPending(profile)
        else {
            dismiss()
            return
        }
        applyBotModel(model)
    }

    private func chooseNone() {
        if let onClear {
            onClear()
            dismiss()
            return
        }
        if usesNone {
            dismiss()
            return
        }
        applyBotFallback(nil)
    }

    private func applyBotFallback(_ model: HermesClient.ModelOption?) {
        guard !applyingModel else { return }
        guard let bot = targetBot else {
            failure = "Hermes did not return this bot’s current profile."
            return
        }
        applyingModel = true
        pendingBotModel = model
        Task {
            defer { applyingModel = false }
            do {
                try await store.setBotFallback(bot, to: model)
                pendingBotModel = nil
                dismiss()
            } catch {
                pendingBotModel = nil
                failure = PlainWords.describe(error, doing: "change the fallback model")
            }
        }
    }

    private func applyBotModel(
        _ model: HermesClient.ModelOption, confirm: Bool = false
    ) {
        guard !applyingModel else { return }
        guard let bot = targetBot else {
            failure = "Hermes did not return this bot’s current profile."
            return
        }
        applyingModel = true
        pendingBotModel = model
        Task {
            defer { applyingModel = false }
            do {
                switch try await store.setBotModel(bot, to: model, confirm: confirm) {
                case let .confirmation(message):
                    pendingBotModel = model
                    modelConfirmation = message
                case let .applied(warning):
                    pendingBotModel = nil
                    failure = warning
                    if warning == nil { dismiss() }
                }
            } catch {
                pendingBotModel = nil
                failure = PlainWords.describe(error, doing: "change the model")
            }
        }
    }

    private var groups: [Group] {
        let matching = store.models.filter {
            query.isEmpty
                || $0.label.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
        let keyed = Dictionary(grouping: matching) {
            $0.providerName ?? $0.provider ?? "Models"
        }
        return keyed.keys.sorted().map { Group(name: $0, models: keyed[$0] ?? []) }
    }
}
