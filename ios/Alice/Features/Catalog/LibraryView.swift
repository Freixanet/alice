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

    private let surfaces: [Surface] = [
        .init(id: "skills", title: "Skills", symbol: "sparkles", capability: "skills"),
        .init(id: "toolsets", title: "Tools", symbol: "wrench.adjustable", capability: "toolsets"),
        .init(id: "mcp", title: "Add-ons", symbol: "puzzlepiece.extension", capability: "mcp"),
        .init(id: "projects", title: "Projects", symbol: "folder", capability: "projects"),
        .init(id: "artifacts", title: "Artifacts", symbol: "paperclip", capability: "artifacts"),
        .init(id: "memory", title: "Memory", symbol: "brain", capability: "memory"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(surfaces) { surface in
                    let available = store.supports(surface.capability)
                    HStack {
                        Label(surface.title, systemImage: surface.symbol)
                        Spacer()
                        if !available {
                            Text("Not advertised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(available ? .primary : .secondary)
                }
            } 
            .navigationTitle("Library")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .overlay {
                if !store.isConnected {
                    ContentUnavailableView(
                        "Connect your Hermes",
                        systemImage: "link",
                        description: Text("These sections come from your agent.")
                    )
                }
            }
        }
    }
}
