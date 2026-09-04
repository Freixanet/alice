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

    /// A typed id worth offering: it looks like a model name, and nothing in
    /// the catalogue already matches it exactly.
    private var customCandidate: String? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 3, !typed.contains(" ") else { return nil }
        guard !store.models.contains(where: { $0.id == typed }) else { return nil }
        return typed
    }

    var body: some View {
        NavigationStack {
            List {
                // Hermes does not always list everything it can serve. Its
                // catalogue for Nous, for one, holds only that provider's paid
                // models, so the free ones — which answer perfectly well —
                // appear nowhere and their provider vanishes from this screen
                // along with them. Typing an id is the way to reach anything
                // the catalogue has left out.
                if let typed = customCandidate {
                    Section("Use anyway") {
                        Button {
                            store.selectedModel = typed
                            dismiss()
                        } label: {
                            HStack {
                                Text(typed).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.turn.down.left")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // And once chosen, it has to be visible: a model this list has
                // never heard of would otherwise leave the screen looking as
                // though nothing were selected at all.
                if let current = store.selectedModel,
                   !store.models.contains(where: { $0.id == current }) {
                    Section("Current") {
                        HStack {
                            Text(current).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(store.accent.primary(scheme))
                        }
                    }
                }

                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { model in
                            Button {
                                store.selectedModel = model.id
                                dismiss()
                            } label: {
                                HStack {
                                    Text(model.label).foregroundStyle(.primary)
                                    Spacer()
                                    if model.id == store.selectedModel {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(store.accent.primary(scheme))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
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
            .refreshable { await store.loadModels(refreshing: true) }
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
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private struct Group {
        let name: String
        let models: [HermesClient.ModelOption]
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
