import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Hermes' messaging adapters, managed against the dashboard rather than
/// mirrored on-device. Channel credentials stay on Hermes; Alice only ever
/// receives the redacted values the dashboard intentionally exposes.
struct ChannelsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles: [ChannelProfile] = [.init(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var snapshot: MessagingPlatformsSnapshot?
    @State private var loading = false
    @State private var failure: String?
    @State private var busyPlatforms: Set<String> = []
    @State private var testResults: [String: MessagingPlatformTestResult] = [:]
    @State private var editing: MessagingPlatform?
    @State private var setup: SetupDestination?
    @State private var restartNeeded = false
    @State private var restarting = false
    @State private var restartConfirmation = false

    var body: some View {
        List {
            Section("Profile") {
                Picker("Channels for", selection: $selectedProfile) {
                    ForEach(profiles) { profile in
                        Text(profile.label).tag(profile.id)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }

            if let snapshot {
                Section {
                    channelSummary(snapshot)
                        .listRowBackground(Palette.card(scheme))
                }

                Section("Channels") {
                    if snapshot.platforms.isEmpty {
                        stateRow(
                            "No channels advertised",
                            detail: "This Hermes installation did not return any messaging adapters.",
                            systemImage: "bubble.left.and.exclamationmark.bubble.right"
                        )
                    } else {
                        ForEach(snapshot.platforms) { platform in
                            channelRow(platform)
                                .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            } else if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading channels…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } else if let failure {
                Section {
                    stateRow("Channels unavailable", detail: failure, systemImage: "antenna.radiowaves.left.and.right.slash")
                }
            }

            if let failure, snapshot != nil {
                Section {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in
            snapshot = nil
            testResults = [:]
            restartNeeded = false
            Task { await load() }
        }
        .refreshableWithFeedback { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    restartConfirmation = true
                } label: {
                    if restarting { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(!store.dashboardReady || restarting)
                .accessibilityLabel("Restart Hermes gateway")
            }
        }
        .confirmationDialog(
            "Restart Hermes gateway?",
            isPresented: $restartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart") { Task { await restartGateway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active channel connections for this profile will reconnect.")
        }
        .sheet(item: $editing) { platform in
            ChannelConfigurationSheet(
                platform: platform,
                profile: selectedProfile,
                onSaved: {
                    restartNeeded = true
                    Task { await load() }
                }
            )
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(item: $setup) { destination in
            switch destination {
            case let .telegram(platform):
                TelegramChannelSetup(
                    platform: platform,
                    profile: selectedProfile,
                    onFinished: finishOnboarding
                )
                .preferredColorScheme(store.theme.colorScheme)
            case let .whatsapp(platform):
                WhatsAppChannelSetup(
                    platform: platform,
                    profile: selectedProfile,
                    onFinished: finishOnboarding
                )
                .preferredColorScheme(store.theme.colorScheme)
            }
        }
    }

    @ViewBuilder
    private func channelSummary(_ snapshot: MessagingPlatformsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            let configured = snapshot.platforms.filter(\.configured).count
            HStack(spacing: 8) {
                Image(systemName: gatewayRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(gatewayRunning ? .green : .orange)
                Text(gatewayRunning ? "Gateway running" : "Gateway not running")
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(configured) of \(snapshot.platforms.count) channels configured.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if restartNeeded {
                Label("Changes are saved. Restart the gateway to apply them.", systemImage: "arrow.clockwise.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if !gatewayRunning, !snapshot.gatewayStartCommand.isEmpty {
                Text(snapshot.gatewayStartCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !snapshot.envPath.isEmpty {
                Text("Credentials: \(snapshot.envPath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func channelRow(_ platform: MessagingPlatform) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(for: platform))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(stateTint(platform.state))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(platform.name).font(.subheadline.weight(.semibold))
                        Text(stateLabel(platform.state))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stateTint(platform.state))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(stateTint(platform.state).opacity(0.12), in: Capsule())
                    }
                    if !platform.detail.isEmpty {
                        Text(platform.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = platform.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if busyPlatforms.contains(platform.id) {
                    ProgressView().frame(width: 51)
                } else {
                    Toggle(
                        platform.name,
                        isOn: Binding(
                            get: { currentPlatform(platform.id)?.enabled ?? platform.enabled },
                            set: { enabled in setEnabled(platform, enabled: enabled) }
                        )
                    )
                    .labelsHidden()
                }
            }

            HStack(spacing: 8) {
                Button {
                    test(platform)
                } label: {
                    Label("Test", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busyPlatforms.contains(platform.id))

                Button {
                    editing = platform
                } label: {
                    Label("Configure", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if platform.id == "telegram" {
                    Button {
                        setup = .telegram(platform)
                    } label: {
                        Label("Quick setup", systemImage: "paperplane")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if platform.id == "whatsapp" {
                    Button {
                        setup = .whatsapp(platform)
                    } label: {
                        Label("Pair QR", systemImage: "qrcode")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .labelStyle(.titleAndIcon)

            if let result = testResults[platform.id] {
                Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(result.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let home = platform.homeChannel, !home.chatID.isEmpty {
                Text("Home: \(home.name.isEmpty ? home.chatID : home.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var gatewayRunning: Bool {
        snapshot?.platforms.first?.gatewayRunning ?? false
    }

    private func currentPlatform(_ id: String) -> MessagingPlatform? {
        snapshot?.platforms.first { $0.id == id }
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        do {
            let found = try await store.routineProfiles()
            profiles = found.map { ChannelProfile(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) {
                selectedProfile = profiles.first?.id ?? "default"
            }
        } catch {
            profiles = [.init(id: "default", label: "Alice")]
        }
    }

    private func load() async {
        guard store.dashboardReady else {
            failure = "Connect the Hermes dashboard to manage channels."
            snapshot = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await store.messagingPlatforms(profile: selectedProfile)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func setEnabled(_ platform: MessagingPlatform, enabled: Bool) {
        guard !busyPlatforms.contains(platform.id) else { return }
        busyPlatforms.insert(platform.id)
        Task {
            defer { busyPlatforms.remove(platform.id) }
            do {
                try await store.updateMessagingPlatform(
                    platform.id, profile: selectedProfile, enabled: enabled,
                    clearEnv: AppStore.enablementFlags(in: platform)
                )
                restartNeeded = true
                await load()
                // Said, not left to the switch: sliding back on its own read as
                // the tap not registering.
                if let now = currentPlatform(platform.id), now.enabled != enabled {
                    failure = "Hermes still has \(platform.name) switched \(now.enabled ? "on" : "off"). "
                        + "Something in its settings is overriding this switch."
                }
            } catch {
                failure = reason(error)
            }
        }
    }

    private func test(_ platform: MessagingPlatform) {
        guard !busyPlatforms.contains(platform.id) else { return }
        busyPlatforms.insert(platform.id)
        Task {
            defer { busyPlatforms.remove(platform.id) }
            do {
                testResults[platform.id] = try await store.testMessagingPlatform(
                    platform.id, profile: selectedProfile
                )
            } catch {
                testResults[platform.id] = .init(
                    ok: false, state: platform.state, message: reason(error)
                )
            }
        }
    }

    private func restartGateway() async {
        restarting = true
        defer { restarting = false }
        do {
            _ = try await store.restartHermesGateway(profile: selectedProfile)
            restartNeeded = false
            try? await Task.sleep(for: .seconds(2))
            await load()
        } catch {
            failure = reason(error)
        }
    }

    private func finishOnboarding(_ result: ChannelApplyResult) {
        setup = nil
        restartNeeded = result.needsRestart && !result.restartStarted
        Task {
            if result.restartStarted { try? await Task.sleep(for: .seconds(2)) }
            await load()
        }
    }

    private func reason(_ error: Error) -> String {
        PlainWords.describe(error)
    }

    private func symbol(for platform: MessagingPlatform) -> String {
        switch platform.id {
        case "telegram": "paperplane.fill"
        case "whatsapp": "phone.bubble.left.fill"
        case "slack": "number.square.fill"
        case "signal": "bubble.left.and.bubble.right.fill"
        case "email": "envelope.fill"
        case "discord": "bubble.left.fill"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "connected": "Connected"
        case "pending_restart": "Restart to apply"
        case "gateway_stopped": "Gateway stopped"
        case "startup_failed": "Start failed"
        case "disconnected": "Disconnected"
        case "not_configured": "Not configured"
        case "disabled": "Disabled"
        case "fatal": "Error"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func stateTint(_ state: String) -> Color {
        switch state {
        case "connected": .green
        case "fatal", "startup_failed": .red
        case "pending_restart", "gateway_stopped", "disconnected": .orange
        default: .secondary
        }
    }

    private func stateRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }
}

private struct ChannelProfile: Identifiable, Hashable {
    let id: String
    let label: String
}

private enum SetupDestination: Identifiable {
    case telegram(MessagingPlatform)
    case whatsapp(MessagingPlatform)

    var id: String {
        switch self {
        case .telegram: "telegram"
        case .whatsapp: "whatsapp"
        }
    }
}

private struct ChannelConfigurationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let platform: MessagingPlatform
    let profile: String
    let onSaved: () -> Void

    @State private var values: [String: String] = [:]
    @State private var clears: Set<String> = []
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(platform.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let url = URL(string: platform.docsURL), !platform.docsURL.isEmpty {
                        Link(destination: url) {
                            Label("Setup guide", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                ForEach(platform.envVars) { field in
                    Section {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(field.prompt).font(.subheadline.weight(.medium))
                                if field.required { Text("Required").font(.caption2).foregroundStyle(.orange) }
                                Spacer()
                                if field.isSet && !clears.contains(field.key) {
                                    Label("Set", systemImage: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            if !field.detail.isEmpty {
                                Text(field.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            if clears.contains(field.key) {
                                Label("This saved value will be removed.", systemImage: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Button("Undo clear") { clears.remove(field.key) }
                            } else {
                                input(field)
                                if field.isSet, let redacted = field.redactedValue, !redacted.isEmpty {
                                    Text("Current: \(redacted)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if field.isSet {
                                    Button("Clear saved value", role: .destructive) {
                                        values[field.key] = ""
                                        clears.insert(field.key)
                                    }
                                    .font(.caption)
                                }
                            }
                            if !field.help.isEmpty {
                                Text(field.help).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let raw = field.docsURL, let url = URL(string: raw) {
                                Link("Open provider page", destination: url).font(.caption)
                            }
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Configure \(platform.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    @ViewBuilder
    private func input(_ field: MessagingEnvField) -> some View {
        let binding = Binding(
            get: { values[field.key] ?? "" },
            set: {
                values[field.key] = $0
                clears.remove(field.key)
            }
        )
        if field.isPassword {
            SecureField(field.isSet ? "Leave blank to keep current value" : field.key, text: binding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            TextField(field.isSet ? "Leave blank to keep current value" : field.key, text: binding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let env = values.reduce(into: [String: String]()) { result, item in
            let trimmed = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !clears.contains(item.key) { result[item.key] = trimmed }
        }
        guard !env.isEmpty || !clears.isEmpty else {
            dismiss()
            return
        }
        do {
            try await store.updateMessagingPlatform(
                platform.id, profile: profile, env: env, clearEnv: Array(clears).sorted()
            )
            onSaved()
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not save the channel."
        }
    }
}

private struct TelegramChannelSetup: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    let platform: MessagingPlatform
    let profile: String
    let onFinished: (ChannelApplyResult) -> Void

    @State private var botName = "Hermes Agent"
    @State private var start: TelegramOnboardingStart?
    @State private var status: TelegramOnboardingStatus?
    @State private var allowedUsers = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var applied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Hermes creates a Telegram setup session. Open it in Telegram, finish the bot flow, then Alice will detect when it is ready.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }

                if let start {
                    Section("Pairing") {
                        QRCodeView(payload: start.qrPayload)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Palette.card(scheme))

                        Button {
                            if let url = URL(string: start.deepLink) { openURL(url) }
                        } label: {
                            Label("Open in Telegram", systemImage: "paperplane.fill")
                        }
                        .listRowBackground(Palette.card(scheme))

                        if !start.suggestedUsername.isEmpty {
                            LabeledContent("Suggested username", value: start.suggestedUsername)
                                .listRowBackground(Palette.card(scheme))
                        }
                        LabeledContent("Expires", value: expiryText(start.expiresAt))
                            .listRowBackground(Palette.card(scheme))

                        if status?.status == "ready" {
                            Label(
                                status?.botUsername.map { "@\($0) is ready" } ?? "Telegram bot is ready",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                            .listRowBackground(Palette.card(scheme))
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Waiting for Telegram…").foregroundStyle(.secondary)
                            }
                            .listRowBackground(Palette.card(scheme))
                        }
                    }

                    if status?.status == "ready" {
                        Section("Allowed users") {
                            TextField("123456789, 987654321", text: $allowedUsers)
                                .keyboardType(.numbersAndPunctuation)
                                .listRowBackground(Palette.card(scheme))
                            Text("Use numeric Telegram user IDs. Hermes requires at least one for this quick setup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Palette.card(scheme))
                            Button {
                                Task { await apply() }
                            } label: {
                                if busy { ProgressView() } else { Label("Save and connect", systemImage: "checkmark.circle") }
                            }
                            .disabled(busy)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                } else {
                    Section("Bot") {
                        TextField("Bot name", text: $botName)
                            .listRowBackground(Palette.card(scheme))
                        Button {
                            Task { await begin() }
                        } label: {
                            if busy { ProgressView() } else { Label("Start Telegram setup", systemImage: "paperplane") }
                        }
                        .disabled(busy)
                        .listRowBackground(Palette.card(scheme))
                    }
                }

                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                            .listRowBackground(Palette.card(scheme))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Telegram setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: start?.pairingID) { await poll() }
            .onDisappear {
                guard !applied, let pairingID = start?.pairingID else { return }
                Task { try? await store.cancelTelegramOnboarding(pairingID) }
            }
        }
    }

    private func begin() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            start = try await store.startTelegramOnboarding(
                botName: botName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            status = .init(status: "waiting", expiresAt: start?.expiresAt ?? "", botUsername: nil, ownerUserID: nil)
        } catch {
            failure = reason(error)
        }
    }

    private func poll() async {
        guard let pairingID = start?.pairingID else { return }
        while !Task.isCancelled {
            if status?.status == "ready" { return }
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            do {
                let next = try await store.telegramOnboardingStatus(pairingID)
                status = next
                failure = nil
                if next.status == "ready" {
                    if allowedUsers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let owner = next.ownerUserID, !owner.isEmpty {
                        allowedUsers = owner
                    }
                    return
                }
            } catch {
                failure = reason(error)
                return
            }
        }
    }

    private func apply() async {
        guard let pairingID = start?.pairingID else { return }
        let ids = allowedUsers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty, ids.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            failure = "Add at least one numeric Telegram user ID."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await store.applyTelegramOnboarding(
                pairingID, allowedUserIDs: Array(Set(ids)).sorted(), profile: profile
            )
            applied = true
            onFinished(result)
            dismiss()
        } catch {
            failure = reason(error)
        }
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Telegram setup failed."
    }
}

private struct WhatsAppChannelSetup: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let platform: MessagingPlatform
    let profile: String
    let onFinished: (ChannelApplyResult) -> Void

    @State private var mode = "bot"
    @State private var allowedUsers = ""
    @State private var session: WhatsAppOnboardingSession?
    @State private var busy = false
    @State private var failure: String?
    @State private var applied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mode") {
                    Picker("WhatsApp mode", selection: $mode) {
                        Text("Bot").tag("bot")
                        Text("Self-chat").tag("self-chat")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Palette.card(scheme))
                    TextField("Allowed numbers, comma-separated", text: $allowedUsers)
                        .keyboardType(.phonePad)
                        .listRowBackground(Palette.card(scheme))
                    Text("Leave the allowlist blank to use Hermes pairing. In self-chat mode Hermes can allow the linked account automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }

                if let session {
                    Section("Pairing") {
                        statusRow(session)
                            .listRowBackground(Palette.card(scheme))
                        if let payload = session.qrPayload, !payload.isEmpty,
                           !["connected", "error", "expired", "cancelled"].contains(session.status) {
                            QRCodeView(payload: payload)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Palette.card(scheme))
                            Text("Scan this from WhatsApp → Linked Devices. If Alice is on the same phone as WhatsApp, use another screen to display the QR.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Palette.card(scheme))
                        }

                        if session.status == "connected" {
                            if let linked = linkedAccount(session) {
                                LabeledContent("Linked account", value: linked)
                                    .listRowBackground(Palette.card(scheme))
                            }
                            Button {
                                Task { await apply() }
                            } label: {
                                if busy { ProgressView() } else { Label("Save and restart", systemImage: "checkmark.circle") }
                            }
                            .disabled(busy)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task { await begin() }
                        } label: {
                            if busy { ProgressView() } else { Label("Pair with QR", systemImage: "qrcode") }
                        }
                        .disabled(busy)
                        .listRowBackground(Palette.card(scheme))
                    }
                }

                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                            .listRowBackground(Palette.card(scheme))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("WhatsApp setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: session?.pairingID) { await poll() }
            .onAppear {
                if let configured = platform.whatsappSetup?.mode,
                   ["bot", "self-chat"].contains(configured) {
                    mode = configured
                }
            }
            .onDisappear {
                guard !applied, let pairingID = session?.pairingID else { return }
                Task { try? await store.cancelWhatsAppOnboarding(pairingID) }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ session: WhatsAppOnboardingSession) -> some View {
        HStack(spacing: 10) {
            if session.status == "connected" {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if session.status == "error" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(whatsAppStatusLabel(session.status)).font(.subheadline.weight(.medium))
                Text("Expires \(expiryText(session.expiresAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func begin() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let result = try await store.startWhatsAppOnboarding(
                mode: mode, allowedUsers: allowedUsers, profile: profile
            )
            session = result
            if result.status == "error" { failure = result.error ?? "WhatsApp setup failed." }
        } catch {
            failure = reason(error)
        }
    }

    private func poll() async {
        guard let pairingID = session?.pairingID else { return }
        while !Task.isCancelled {
            guard let state = session?.status,
                  !["connected", "error", "expired", "cancelled"].contains(state) else { return }
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            do {
                let next = try await store.whatsAppOnboardingStatus(pairingID)
                session = next
                failure = next.status == "error" ? (next.error ?? "WhatsApp setup failed.") : nil
            } catch {
                failure = reason(error)
                return
            }
        }
    }

    private func apply() async {
        guard let pairingID = session?.pairingID else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await store.applyWhatsAppOnboarding(
                pairingID, mode: mode, allowedUsers: allowedUsers, profile: profile
            )
            applied = true
            onFinished(result)
            dismiss()
        } catch {
            failure = reason(error)
        }
    }

    private func linkedAccount(_ session: WhatsAppOnboardingSession) -> String? {
        if let phone = session.accountPhone, !phone.isEmpty { return "+\(phone)" }
        if let name = session.accountName, !name.isEmpty { return name }
        if let id = session.accountID, !id.isEmpty { return id }
        return nil
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "WhatsApp setup failed."
    }
}

private struct QRCodeView: View {
    let payload: String

    var body: some View {
        if let image = QRCodeRenderer.image(payload) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Pairing QR code")
        } else {
            ContentUnavailableView("QR unavailable", systemImage: "qrcode")
        }
    }
}

@MainActor
private enum QRCodeRenderer {
    static func image(_ payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private func expiryText(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: raw) else { return raw }
    if date <= Date() { return "expired" }
    let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
    return "in \(seconds / 60)m \(seconds % 60)s"
}

private func whatsAppStatusLabel(_ state: String) -> String {
    switch state {
    case "installing": "Preparing bridge…"
    case "starting": "Starting pairing…"
    case "waiting": "Waiting for QR scan"
    case "connected": "WhatsApp linked"
    case "error": "Pairing failed"
    case "expired": "Pairing expired"
    case "cancelled": "Pairing cancelled"
    default: state.capitalized
    }
}
