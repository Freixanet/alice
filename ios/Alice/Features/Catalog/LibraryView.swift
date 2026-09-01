import SwiftUI

/// Skills, Tools, Add-ons, Projects, Artifacts and Memory all live on Hermes'
/// management surface. Each is listed here with the capability it needs, so an
/// empty section says *why* it is empty rather than just looking broken.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private struct Surface: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let capability: String
    }

    private let pending: [Surface] = [
        .init(id: "projects", title: "Projects", symbol: "folder", capability: "projects"),
        .init(id: "artifacts", title: "Artifacts", symbol: "paperclip", capability: "artifacts"),
        .init(id: "memory", title: "Memory", symbol: "brain", capability: "memory"),
    ]

    /// A built screen links through; the capability check happens inside it so
    /// the reason for an empty list is stated where the user is looking.
    @ViewBuilder
    private func row(_ source: CatalogScreen.Source, symbol: String) -> some View {
        NavigationLink {
            CatalogScreen(source: source)
        } label: {
            HStack {
                Label(source.title, systemImage: symbol)
                Spacer()
                if !store.supports(source.capability) {
                    Text("Not advertised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    List {
                Section {
                    row(.skills, symbol: "sparkles")
                    row(.toolsets, symbol: "wrench.adjustable")
                    row(.addons, symbol: "puzzlepiece.extension")
                }

                Section("Coming from the same surface") {
                    ForEach(pending) { surface in
                        let available = store.supports(surface.capability)
                        HStack {
                            Label(surface.title, systemImage: surface.symbol)
                            Spacer()
                            Text(available ? "Not built yet" : "Not advertised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(available ? .primary : .secondary)
                    }
                }
                    }
                } else {
                    ContentUnavailableView(
                        "Connect your Hermes",
                        systemImage: "link",
                        description: Text("These sections come from your agent.")
                    )
                }
            }
            .navigationTitle("Library")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))

        }
    }
}
