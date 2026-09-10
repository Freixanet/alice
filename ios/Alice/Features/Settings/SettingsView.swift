import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var store = store

        Form {
            // First: whether Alice can reach Hermes is what everything
            // below depends on, and what people come here to check.
            Section("Connection") {
                NavigationLink { ConnectView() } label: {
                    HStack {
                        Label(
                            store.isConnected ? "Hermes connected" : "Connect your Hermes",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        Spacer()
                        Circle()
                            .fill(store.isConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
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
                                    .frame(width: 44, height: 44)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.label)
                        }
                    }
                }
            }

            if store.isConnected || store.dashboardReady {
                Section("Agent") {
                    if store.dashboardReady {
                        NavigationLink { ModelsProvidersScreen() } label: {
                            Label("Models & Providers", systemImage: "cpu")
                        }
                        NavigationLink { MemoryScreen() } label: {
                            Label("Memory", systemImage: "brain")
                        }
                    }
                    if store.isConnected {
                        NavigationLink { CatalogScreen(source: .skills) } label: {
                            Label("Skills", systemImage: "sparkles")
                        }
                    }
                    if store.dashboardReady {
                        NavigationLink { ChannelsScreen() } label: {
                            Label("Channels", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }

            Section {
                NavigationLink { AdvancedSettingsView() } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                }
            } footer: {
                Text("Technical and developer options are kept here so everyday settings stay simple.")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}

/// Less common Hermes administration lives one level deeper. Keeping this out
/// of the first Settings screen is progressive disclosure: nothing is removed,
/// but a person who only wants to change Alice's appearance or model never has
/// to understand MCP, webhooks, worktrees or host diagnostics first.
struct AdvancedSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section("Capabilities") {
                NavigationLink { CatalogScreen(source: .toolsets) } label: {
                    Label("Tools", systemImage: "wrench.adjustable")
                }
                NavigationLink { MCPScreen() } label: {
                    Label("Integrations (MCP)", systemImage: "shippingbox")
                }
                if store.dashboardReady {
                    NavigationLink { PluginsAdminScreen() } label: {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                    }
                }
            }

            Section("Automation & delivery") {
                NavigationLink { WebhooksScreen() } label: {
                    Label("Webhooks", systemImage: "link")
                }
            }

            Section("Hermes host") {
                NavigationLink { HermesFilesScreen() } label: {
                    Label("Hermes Files", systemImage: "folder.badge.gearshape")
                }
                NavigationLink { GitDevelopmentScreen() } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
                NavigationLink { SystemScreen() } label: {
                    Label("System", systemImage: "server.rack")
                }
            }

            if store.dashboardReady {
                Section("Configuration") {
                    NavigationLink { ConfigurationScreen() } label: {
                        Label("Hermes Configuration", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { PairingAdminScreen() } label: {
                        Label("Pairing", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}
