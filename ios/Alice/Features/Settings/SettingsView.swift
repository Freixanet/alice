import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var tipsReset = false

    var body: some View {
        @Bindable var store = store

        Form {
            if let warning = store.storageWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning(scheme))
                }
            }
            if let warning = store.liveActivityWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning(scheme))
                }
            }

            // What everything else depends on, then what it connects to.
            Section {
                NavigationLink { ConnectView() } label: {
                    LabeledContent {
                        Text(store.isConnected ? "Connected" : "Not connected")
                    } label: {
                        Label("Hermes", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                if store.dashboardReady {
                    NavigationLink { ConnectionsScreen() } label: {
                        Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .accessibilityIdentifier("settings.connections")
                    NavigationLink { AgentWorkScreen() } label: {
                        Label("Agent work", systemImage: "square.stack.3d.up")
                    }
                }
            }

            Section {
                NavigationLink { ActivityScreen() } label: {
                    LabeledContent {
                        if store.unreadActivity > 0 {
                            Text("\(store.unreadActivity)")
                                .monospacedDigit()
                                .accessibilityLabel("\(store.unreadActivity) unread")
                        }
                    } label: {
                        Label("Activity", systemImage: "bell")
                    }
                }
                .accessibilityIdentifier("settings.activity")
                if store.dashboardReady {
                    NavigationLink { MemoryScreen() } label: {
                        Label("Memory", systemImage: "person.text.rectangle")
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.requireUnlock },
                    set: { on in
                        // Turned on only by someone who can unlock it, so the
                        // app is never locked against its own owner.
                        guard on else { store.requireUnlock = false; return }
                        Task {
                            if await Biometrics.authenticate(reason: "Turn on locking for Alice.") {
                                store.requireUnlock = true
                            }
                        }
                    }
                )) {
                    Label("Require \(Biometrics.name)", systemImage: Biometrics.symbol)
                }
                .disabled(!Biometrics.available && !store.requireUnlock)
                if store.requireUnlock {
                    Picker("Lock", selection: $store.lockGrace) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 15 minutes").tag(900)
                    }
                }
                Toggle(isOn: $store.barkRelays) {
                    Label("Notifications via Bark", systemImage: "bell.badge")
                }
            } footer: {
                if !Biometrics.available {
                    Text("Set a passcode for this iPhone to lock Alice.")
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    ForEach(Accent.allCases) { accent in
                        Button {
                            store.accent = accent
                        } label: {
                            Circle()
                                .fill(accent.swatch)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle().strokeBorder(Color.primary, lineWidth: store.accent == accent ? 2 : 0)
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.label)
                    }
                }
            }

            Section {
                if store.dashboardReady {
                    TimeZoneRow()
                }
                Button("Show Gesture Tips Again") {
                    GestureTips.showAgainNextLaunch()
                    tipsReset = true
                }
                .alert("Tips reset", isPresented: $tipsReset) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("They show again the next time Alice opens.")
                }
                NavigationLink { AdvancedSettingsView() } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                if store.developerMode {
                    NavigationLink { DeveloperScreen() } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
            }

            let build = AliceBuildInfo.current
            Section {
                LabeledContent("Alice", value: build.versionLabel)
                if store.dashboardReady {
                    HermesVersionRow()
                }
                if let revision = build.revision {
                    LabeledContent("Revision", value: revision)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            // A page, not a sheet: it goes back the way it came, with a chevron.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .aliceFormPaper(scheme)
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
        @Bindable var store = store
        Form {
            Section {
                Toggle("Developer mode", isOn: $store.developerMode)
            } footer: {
                Text("Adds Settings › Developer — checks that everything works, a live performance meter and tools — and shows the model, tokens and tool calls under each reply.")
            }
            if store.dashboardReady {
                Section("This Hermes") {
                    NavigationLink { ModelsProvidersScreen() } label: {
                        Label("Models & Providers", systemImage: "cpu")
                    }
                    NavigationLink { MemoryScreen() } label: {
                        Label("Memory", systemImage: "brain")
                    }
                    NavigationLink { ChannelsScreen() } label: {
                        Label("Channels", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            if store.isConnected {
                Section("Instructions") {
                    NavigationLink { CatalogScreen(source: .skills) } label: {
                        Label("Skills", systemImage: "sparkles")
                    }
                }
            }
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
        .aliceFormPaper(scheme)
    }
}

/// The Hermes this Alice talks to, beside Alice's own version: the two are
/// released apart, and knowing both is the first question when something
/// breaks after an update.
struct HermesVersionRow: View {
    @Environment(AppStore.self) private var store
    @State private var version: String?

    var body: some View {
        LabeledContent("Hermes", value: version ?? "…")
            .textSelection(.enabled)
            .task {
                guard version == nil, let status = try? await store.hermesSystemStatus(profile: nil) else { return }
                let released = status.releaseDate.isEmpty ? "" : " (\(status.releaseDate))"
                version = status.version + released
            }
    }
}
