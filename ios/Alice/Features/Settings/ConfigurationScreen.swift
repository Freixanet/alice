import SwiftUI

/// A small set of high-value Hermes settings. The dashboard owns the full
/// schema; Alice intentionally edits only options that materially change how
/// the agent behaves and deep-merges those keys server-side.
struct ConfigurationScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store

    @State private var profiles = [HermesProfileChoice(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var draft = HermesConfiguration()
    @State private var original = HermesConfiguration()
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?

    private var dirty: Bool { loaded && draft != original }

    var body: some View {
        Form {
            if profiles.count > 1 {
                Section {
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(profiles) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    Text("These settings belong to the selected Hermes profile.")
                }
            }

            if loaded {
                Section {
                    TextField("System timezone", text: $draft.timezone)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Time")
                } footer: {
                    Text("Use an IANA timezone such as Europe/Madrid. Leave blank to use the Mac's system timezone.")
                }

                Section {
                    Picker("Approval mode", selection: $draft.approvalsMode) {
                        Text("Smart").tag("smart")
                        Text("Manual").tag("manual")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Smart asks only when Hermes judges an action risky. Manual asks for dangerous actions explicitly. Off removes those approval prompts.")
                }

                Section {
                    Picker("Service tier", selection: $draft.serviceTier) {
                        Text("Default").tag("")
                        Text("Normal").tag("normal")
                        Text("Fast").tag("fast")
                        Text("Auto").tag("auto")
                        Text("Cold start").tag("cold")
                    }
                    Toggle("Verify completed work", isOn: $draft.verifyGuidance)
                    Toggle("Inspect environment at start", isOn: $draft.environmentProbe)
                } header: {
                    Text("Agent")
                } footer: {
                    Text("These are Hermes runtime policies, not Alice-only preferences. Changes take effect when Hermes builds or refreshes a session.")
                }

                Section {
                    Toggle("Long-term memory", isOn: $draft.memoryEnabled)
                    Toggle("User profile memory", isOn: $draft.userProfileEnabled)
                } header: {
                    Text("Memory")
                } footer: {
                    Text("This controls whether Hermes loads and writes MEMORY.md and USER.md for this profile. The Memory screen edits their actual contents.")
                }

                Section {
                    Toggle("Automatic context compression", isOn: $draft.compressionEnabled)
                    if draft.compressionEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Start compression")
                                Spacer()
                                Text(draft.compressionThreshold.formatted(.percent.precision(.fractionLength(0))))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $draft.compressionThreshold, in: 0.30...0.90, step: 0.05)
                        }
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Hermes compresses older conversation context once the configured fraction of the model window is used.")
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(Palette.danger(scheme)).font(.footnote) }
            }
        }
        .navigationTitle("Hermes Configuration")
        .aliceFormPaper(scheme)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && !loaded { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!dirty || saving)
            }
        }
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in Task { await load() } }
        .onChange(of: store.dashboardReady) { _, ready in
            guard ready else { return }
            Task { await loadProfiles(); await load() }
        }
        .refreshableWithFeedback { await load() }
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        if let choices = try? await store.hermesProfiles() {
            profiles = choices.map { HermesProfileChoice(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = "default" }
        }
    }

    private func load() async {
        guard store.dashboardReady else { failure = nil; loaded = false; return }
        loading = true
        defer { loading = false }
        do {
            let config = try await store.hermesConfiguration(profile: selectedProfile)
            draft = config
            original = config
            loaded = true
            failure = nil
        } catch {
            loaded = false
            failure = diagnosticMessage(error)
        }
    }

    private func save() {
        let timezone = draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timezone.isEmpty || TimeZone(identifier: timezone) != nil else {
            failure = "Use a valid IANA timezone, for example Europe/Madrid."
            return
        }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                let normalized = HermesConfiguration(
                    timezone: timezone,
                    approvalsMode: draft.approvalsMode,
                    serviceTier: draft.serviceTier,
                    memoryEnabled: draft.memoryEnabled,
                    userProfileEnabled: draft.userProfileEnabled,
                    compressionEnabled: draft.compressionEnabled,
                    compressionThreshold: draft.compressionThreshold,
                    verifyGuidance: draft.verifyGuidance,
                    environmentProbe: draft.environmentProbe
                )
                try await store.saveHermesConfiguration(normalized, profile: selectedProfile)
                draft = try await store.hermesConfiguration(profile: selectedProfile)
                original = draft
                failure = nil
            } catch { failure = diagnosticMessage(error) }
        }
    }
}
