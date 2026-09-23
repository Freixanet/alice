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
                    Label("Something could not be kept on this phone", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning(scheme))
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let warning = store.liveActivityWarning {
                Section {
                    Label("Live Activity could not start", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning(scheme))
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Developer mode's own place: checks, the live meter and tools.
            if store.developerMode {
                Section {
                    NavigationLink { DeveloperScreen() } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
            }

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
                            .fill(store.isConnected ? Palette.success(scheme) : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
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
            } header: {
                Text("Privacy")
            } footer: {
                Text(Biometrics.available
                     ? "Alice asks for \(Biometrics.name) when it opens and when you come back to it, and hides its content in the app switcher. Notifications still arrive."
                     : "Set a passcode for this iPhone in the Settings app to lock Alice.")
            }

            Section {
                NavigationLink {
                    ActivityScreen()
                } label: {
                    HStack {
                        Label("Activity", systemImage: "bell")
                        Spacer(minLength: 8)
                        if store.unreadActivity > 0 {
                            Text("\(store.unreadActivity)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(store.accent.primary(scheme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(store.accent.primary(scheme).opacity(0.16), in: .capsule)
                                .accessibilityLabel("\(store.unreadActivity) unread")
                        }
                    }
                }
                .accessibilityIdentifier("settings.activity")
            } footer: {
                Text("What has happened, and what is waiting on you.")
            }

            // What Alice has learnt, where it can be read and corrected — the
            // same memory Hermes gives her in every conversation. Asking her
            // "what do you know about me?" or "forget …" works too.
            if store.dashboardReady {
                Section {
                    NavigationLink { MemoryScreen() } label: {
                        Label("What Alice knows about you", systemImage: "person.text.rectangle")
                    }
                } footer: {
                    Text("She remembers what matters from your conversations. Change or remove anything here, or tell her “forget …”.")
                }
            }

            // Where a connection an agent offered in a chat can be made — or
            // undone — whatever was said there.
            if store.dashboardReady {
                Section {
                    CalendarConnectionRow()
                } header: {
                    Text("Connections")
                } footer: {
                    Text("Your agents see what you connect here. Nothing leaves your own Hermes, and nothing is added to your calendar unless you tap Add.")
                }

                Section {
                    NavigationLink { AgentWorkScreen() } label: {
                        Label("Agent work", systemImage: "square.stack.3d.up")
                    }
                } footer: {
                    Text("Watch pages, share a browser with your agents and give them documents to work on.")
                }
            }

            Section {
                Toggle("Replies and routines come through Bark", isOn: $store.barkRelays)
            } header: {
                Text("Notifications")
            } footer: {
                Text(store.barkRelays
                     ? "Your Mac announces agent replies and routines through Bark, even while Alice is closed, so Alice does not announce them again. She still tells you about questions, approvals and problems with Hermes."
                     : "Alice announces replies and routines herself, but only when iOS lets her run. With Bark and the Mac notifier set up, they arrive every time — and this switch keeps them from arriving twice.")
            }

            Section("General") {
                if store.dashboardReady {
                    TimeZoneRow()
                }
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

                Button("Show Gesture Tips Again") {
                    GestureTips.showAgainNextLaunch()
                    tipsReset = true
                }
                .alert("Tips reset", isPresented: $tipsReset) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("They show again the next time Alice opens. Close Alice from the app switcher and open it.")
                }
            }

            if store.isConnected || store.dashboardReady {
                Section {
                    NavigationLink { AdvancedSettingsView() } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                } footer: {
                    Text("Models, memory, skills and Hermes administration live here. Everyday use stays in the chat.")
                }
            } else {
                Section {
                    NavigationLink { AdvancedSettingsView() } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                } footer: {
                    Text("Technical and developer options are kept here so everyday settings stay simple.")
                }
            }

            let build = AliceBuildInfo.current
            Section("About Alice") {
                LabeledContent("Version", value: build.versionLabel)
                if let revision = build.revision {
                    LabeledContent("Revision", value: revision)
                        .textSelection(.enabled)
                }
                if store.dashboardReady {
                    HermesVersionRow()
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
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
