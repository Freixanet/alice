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

    var body: some View {
        NavigationStack {
            List {
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
                        Task { await store.loadModels() }
                    } label: {
                        if store.isLoadingModels {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!store.isConnected || store.isLoadingModels)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await store.loadModels() }
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
                                Task { await store.loadModels() }
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
