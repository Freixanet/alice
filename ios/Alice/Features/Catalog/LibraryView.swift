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

    /// Everything else the web client shows. None of it is reachable from a
    /// gateway-only install: these collections are served by the dashboard,
    /// which is a separate process, so the row says so rather than opening a
    /// screen that would only ever be empty.
    /// Artifacts and Agents have no route at all — not on the gateway and not
    /// on the dashboard, whose 281 published routes include neither. They are
    /// listed so their absence is stated rather than left as a gap.
    private let pending: [Surface] = [
        .init(id: "artifacts", title: "Artifacts", symbol: "paperclip", capability: "artifacts"),
        .init(id: "agents", title: "Agents", symbol: "person.2", capability: "agents"),
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
                    NavigationLink {
                        JobsScreen()
                    } label: {
                        Label("Jobs", systemImage: "clock")
                    }
                    NavigationLink {
                        SessionsScreen()
                    } label: {
                        Label("Sessions", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        InsightsScreen()
                    } label: {
                        Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }

                if store.dashboardReady {
                    Section("From the dashboard") {
                        NavigationLink { ProjectsScreen() } label: {
                            Label("Projects", systemImage: "folder")
                        }
                        NavigationLink { MemoryScreen() } label: {
                            Label("Memory", systemImage: "brain")
                        }
                        NavigationLink { UsageScreen() } label: {
                            Label("Usage", systemImage: "chart.bar")
                        }
                    }
                }

                Section(store.dashboardReady
                    ? "Not served by this Hermes"
                    : "Needs the Hermes dashboard") {
                    ForEach(pending) { surface in
                        let available = store.supports(surface.capability)
                        HStack {
                            Label(surface.title, systemImage: surface.symbol)
                            Spacer()
                            Text(available ? "Not built yet" : "Not served here")
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
