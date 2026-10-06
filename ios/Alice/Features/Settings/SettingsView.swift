import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
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

            Section("Connection") {
                NavigationLink { ConnectView(pushed: true) } label: {
                    SettingsMenuLabel(
                        "Hermes", systemImage: "antenna.radiowaves.left.and.right",
                        subtitle: "Your agent connection",
                        value: Text(store.isConnected ? "Connected" : "Not connected"),
                        valueTint: store.isConnected ? Palette.success(scheme) : .secondary
                    )
                }
                .accessibilityIdentifier("settings.hermes")
            }
            .listRowBackground(Palette.card(scheme))

            Section("Preferences") {
                NavigationLink { AppearanceSettingsView() } label: {
                    SettingsMenuLabel(
                        "Appearance", systemImage: "circle.lefthalf.filled",
                        value: Text(store.theme.label), swatch: store.accent.swatch
                    )
                }
                .accessibilityIdentifier("settings.appearance")
                NavigationLink { PrivacySettingsView() } label: {
                    SettingsMenuLabel(
                        "Privacy", systemImage: "hand.raised",
                        value: Text(store.requireUnlock ? Biometrics.name : String(localized: "Off"))
                    )
                }
                .accessibilityIdentifier("settings.privacy")
                NavigationLink { GeneralSettingsView() } label: {
                    SettingsMenuLabel("General", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.general")
            }
            .listRowBackground(Palette.card(scheme))

            Section("Alice") {
                NavigationLink { ActivityScreen() } label: {
                    SettingsMenuLabel(
                        "Activity", systemImage: "bell",
                        value: store.unreadActivity > 0 ? Text("\(store.unreadActivity)") : nil
                    )
                }
                .accessibilityIdentifier("settings.activity")
                .accessibilityValue(store.unreadActivity > 0 ? Text("\(store.unreadActivity) unread") : Text(""))
                // Beside Activity, where each routine's results arrive (it left the drawer).
                NavigationLink {
                    RoutinesScreen()
                        .onAppear { store.markNoticesSeen(.routines) }
                } label: {
                    SettingsMenuLabel(
                        "Routines", systemImage: "clock",
                        value: store.unreadNotices(in: .routines) > 0 ? Text("\(store.unreadNotices(in: .routines))") : nil
                    )
                }
                .accessibilityIdentifier("settings.routines")
                if store.dashboardReady {
                    NavigationLink { MemoryScreen() } label: {
                        SettingsMenuLabel("Memory", systemImage: "person.text.rectangle")
                    }
                    NavigationLink { ConnectionsScreen() } label: {
                        SettingsMenuLabel("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .accessibilityIdentifier("settings.connections")
                    NavigationLink { AgentWorkScreen() } label: {
                        SettingsMenuLabel("Agent work", systemImage: "square.stack.3d.up")
                    }
                }
            }
            .listRowBackground(Palette.card(scheme))
        }
        // Room between the bar's back button and the first section, «Connection».
        .contentMargins(.top, 20, for: .scrollContent)
        .navigationTitle("Settings")
        // The system's small centred title, not a large one over the list.
        .navigationBarTitleDisplayMode(.inline)
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

/// Settings › Privacy: locking the app, and how notifications arrive.
struct PrivacySettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { store.requireUnlock },
                    set: { on in
                        // Turned on only by someone who can unlock it, so the
                        // app is never locked against its own owner; turned off
                        // only by the owner too, not by whoever picked the phone up.
                        guard on else {
                            Task {
                                if await Biometrics.authenticate(reason: "Turn off locking for Alice.") {
                                    store.requireUnlock = false
                                }
                            }
                            return
                        }
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
            } footer: {
                if !Biometrics.available {
                    Text("Set a passcode for this iPhone to lock Alice.")
                }
            }
            Section {
                Toggle(isOn: $store.barkRelays) {
                    Label("Notifications via Bark", systemImage: "bell.badge")
                }
            } footer: {
                Text("On when your Mac already announces replies through Bark, so they don't arrive twice.")
            }
            Section {
                NavigationLink { CardsSettingsView() } label: {
                    Label("Cards", systemImage: "creditcard")
                }
                NavigationLink { DeliveryDetailsView() } label: {
                    Label("Delivery details", systemImage: "shippingbox")
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
    }
}

/// Settings › Appearance: theme and colour.
struct AppearanceSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var colourChoiceWidth: CGFloat = 84

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Theme") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Colour") {
                // Named choices reflow rather than squeezing six circles into
                // one row on small phones or with larger text.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: colourChoiceWidth), spacing: 12)], spacing: 16) {
                    ForEach(Accent.allCases) { accent in
                        colourChoice(accent)
                    }
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Palette.card(scheme))
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
    }

    private func colourChoice(_ accent: Accent) -> some View {
        let selected = store.accent == accent
        return Button {
            store.accent = accent
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(accent.swatch)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Circle().strokeBorder(Palette.border(scheme), lineWidth: 0.5)
                    }
                    .padding(4)
                    .overlay {
                        Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
                    }
                Text(accent.label)
                    .font(.footnote)
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.colour.\(accent.rawValue)")
    }
}

/// Settings › General: the rest, with the technical parts one level deeper.
struct GeneralSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var tipsReset = false

    var body: some View {
        Form {
            Section {
                if store.dashboardReady {
                    TimeZoneRow()
                }
                Button {
                    GestureTips.showAgainNextLaunch()
                    tipsReset = true
                } label: {
                    Label("Show Gesture Tips Again", systemImage: "hand.tap")
                }
                .foregroundStyle(.primary)
                .alert("Tips reset", isPresented: $tipsReset) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("They show again the next time Alice opens.")
                }
            }
            let build = AliceBuildInfo.current
            Section("Version") {
                LabeledContent("Alice", value: build.versionLabel)
                if store.dashboardReady {
                    HermesVersionRow()
                }
                if let revision = build.revision {
                    LabeledContent("Revision", value: revision)
                        .textSelection(.enabled)
                }
            }
            Section {
                NavigationLink { AdvancedSettingsView() } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                if store.developerMode {
                    NavigationLink { DeveloperScreen() } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
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

/// Shared alignment for the settings menu; navigation and disclosure remain
/// native, and large text puts the current value below its label.
private struct SettingsMenuLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: LocalizedStringKey
    let systemImage: String
    var subtitle: LocalizedStringKey?
    var value: Text?
    var valueTint: Color = .secondary
    var swatch: Color?

    init(_ title: LocalizedStringKey, systemImage: String,
         subtitle: LocalizedStringKey? = nil, value: Text? = nil,
         valueTint: Color = .secondary, swatch: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.value = value
        self.valueTint = valueTint
        self.swatch = swatch
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    labels
                    currentValue
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                labels
                Spacer(minLength: 8)
                currentValue
            }
        }
        .padding(.vertical, subtitle == nil ? 6 : 10)
        .frame(minHeight: 44)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var currentValue: some View {
        HStack(spacing: 6) {
            if let swatch {
                Circle().fill(swatch).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            if let value {
                value.font(.subheadline).foregroundStyle(valueTint)
                    .monospacedDigit()
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
    }
}
