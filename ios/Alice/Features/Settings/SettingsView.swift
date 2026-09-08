import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    #if DEBUG
    @State private var recoveryStatus: String?
    #endif

    var body: some View {
        @Bindable var store = store

        Form {
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
            Section("What the agent has been doing") {
                NavigationLink { SessionsScreen() } label: {
                    Label("Sessions", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { InsightsScreen() } label: {
                    Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                }
                if store.dashboardReady {
                    NavigationLink { ModelsProvidersScreen() } label: {
                        Label("Models & Providers", systemImage: "cpu")
                    }
                    NavigationLink { UsageScreen() } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }
                    NavigationLink { MemoryScreen() } label: {
                        Label("Memory", systemImage: "brain")
                    }
                    NavigationLink { ConfigurationScreen() } label: {
                        Label("Hermes Configuration", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { PairingAdminScreen() } label: {
                        Label("Pairing", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    NavigationLink { PluginsAdminScreen() } label: {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
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


            #if DEBUG
            // Recovery, debug-only and explicit.
            //
            // Reads a file placed at Documents/alice-recovery.json with
            // `devicectl device copy to`. Never runs on launch: history is
            // restored because someone asked for it, at a moment they chose.
            // Delete this section once the recovery is done.
            Section("Recovery (debug)") {
                Text(recoveryStatus ?? "Place alice-recovery.json in Documents, then dry-run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Dry run") { runRecovery(apply: false) }
                Button("Import") { runRecovery(apply: true) }
                    .disabled(recoveryStatus == nil)
                Button("Re-file under bots") { runMigration() }
                Button("User-turn patch → Dry run") { runPatch(apply: false) }
                Button("User-turn patch → Apply") { runPatch(apply: true) }
                    .disabled(recoveryStatus == nil)
            }
            #endif
        }
        .navigationTitle("Settings")
        // A sheet with nothing but a swipe to close it is a sheet the
        // reader has to guess at — the same gap Connect had.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }

    #if DEBUG
    private func runRecovery(apply: Bool) {
        let url = URL.documentsDirectory.appending(path: "alice-recovery.json")
        do {
            let data = try Data(contentsOf: url)
            let plan = apply
                ? try store.importRecovery(data)
                : try store.planRecovery(data)
            recoveryStatus = (apply ? "Imported: " : "Would import: ")
                + "\(plan.created.count) new, \(plan.merged.count) merged, "
                + "\(plan.messagesAdded) messages"
                + (plan.conflicts.isEmpty ? "" : ", \(plan.conflicts.count) conflicts")
                + (plan.alreadyApplied ? " (batch already applied)" : "")
        } catch {
            recoveryStatus = "Failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// The user-turn patch lives in its own file, so it can be dry-run and
    /// applied without going near the first archive again.
    private func runPatch(apply: Bool) {
        let url = URL.documentsDirectory.appending(path: "alice-userturns-patch.json")
        do {
            let data = try Data(contentsOf: url)
            let plan = apply
                ? try store.importRecovery(data)
                : try store.planRecovery(data)
            let total = store.conversations.reduce(0) { $0 + $1.messages.count }
            if let refusal = plan.refusal {
                recoveryStatus = "Refused: \(refusal)"
                return
            }
            recoveryStatus = (apply ? "Applied. " : "Dry run. ")
                + "conversations affected: \(plan.created.count + plan.merged.count), "
                + "messages to add: \(plan.messagesAdded), "
                + "historical inactive preserved: \(plan.preserved.count), "
                + "visible duplicates to remove: \(plan.removals.count), "
                + "conflicts: \(plan.conflicts.count), "
                + "final recovered messages: "
                + "\(apply ? total : total + plan.messagesAdded - plan.removals.count)"
                + (plan.alreadyApplied ? " (batch already applied)" : "")
        } catch {
            recoveryStatus = "Failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func runMigration() {
        let url = URL.documentsDirectory.appending(path: "alice-recovery.json")
        do {
            let data = try Data(contentsOf: url)
            let changed = try store.migrateRecoveryAssociations(data)
            let messages = store.conversations.reduce(0) { $0 + $1.messages.count }
            recoveryStatus = "Re-filed \(changed) conversation(s); \(messages) messages intact"
        } catch {
            recoveryStatus = "Failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
    #endif
}
