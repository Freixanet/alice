import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var store = store

        Form {
            Section("What the agent has been doing") {
                NavigationLink { SessionsScreen() } label: {
                    Label("Sessions", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { InsightsScreen() } label: {
                    Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                }
                if store.dashboardReady {
                    NavigationLink { UsageScreen() } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }
                    NavigationLink { MemoryScreen() } label: {
                        Label("Memory", systemImage: "brain")
                    }
                }
                NavigationLink { CatalogScreen(source: .addons) } label: {
                    Label("Add-ons", systemImage: "puzzlepiece.extension")
                }
            }

            Section("General") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Colour")
                    HStack(spacing: 12) {
                        ForEach(Accent.allCases) { accent in
                            Button {
                                store.accent = accent
                            } label: {
                                Circle()
                                    .fill(accent.swatch)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Circle().strokeBorder(
                                            Color.primary,
                                            lineWidth: store.accent == accent ? 2 : 0
                                        )
                                    }
                                    // 44pt target around a 30pt swatch.
                                    .frame(width: 44, height: 44)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.label)
                        }
                    }
                }
            }

            Section("Model") {
                if store.models.isEmpty {
                    Text("Connect your Hermes to choose a model.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $store.selectedModel) {
                        ForEach(store.models) { model in
                            Text(model.label).tag(Optional(model.id))
                        }
                    }
                }
            }

            Section("Connection") {
                NavigationLink { ConnectView() } label: {
                    HStack {
                        Label(store.isConnected ? "Hermes connected" : "Connect your Hermes", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Circle()
                            .fill(store.isConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        // A sheet with nothing but a swipe to close it is a sheet the
        // reader has to guess at — the same gap Connect had.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}
