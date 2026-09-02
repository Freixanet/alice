import SwiftUI

/// Everything the agent can show that is not the conversation.
///
/// Split by where it comes from: the first section is served by the gateway
/// the app is already talking to, the second only by the dashboard, which is
/// a separate process and an optional connection. A section that is not there
/// is not a gap — it is an install without that half.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

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
                    NavigationLink {
                        ArtifactsScreen()
                    } label: {
                        Label("Artifacts", systemImage: "paperclip")
                    }
                }

                if store.dashboardReady {
                    Section("From the dashboard") {
                        NavigationLink { BotsScreen() } label: {
                            Label("Bots", systemImage: "person.2")
                        }
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
