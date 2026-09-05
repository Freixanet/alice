import SwiftUI

/// One-time migration from the old Jobs setup card to the thing Radar IA
/// actually is: a Hermes profile. Once the profile exists it is just another
/// bot and this sheet is no longer shown.
struct RadarIABotInstaller: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var time = RadarIA.dateForDefaultTime()
    @State private var zone = RadarIA.defaultZone
    @State private var busy = false
    @State private var failure: String?

    private var timeText: String { RadarIA.timeString(from: time) }
    private var valid: Bool { RadarIA.validSchedule(time: timeText, zone: zone) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Radar IA")
                                .font(.headline)
                            Text("A real Hermes bot with its own instructions, chat, model, sessions and routines.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title3)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                Section("Daily briefing") {
                    DatePicker(
                        "Start research",
                        selection: $time,
                        displayedComponents: .hourAndMinute
                    )

                    TextField("Europe/Madrid", text: $zone)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("The time zone must be a named IANA zone. Hermes will verify the effective scheduler time instead of assuming a fixed UTC offset.")
                        .font(.caption)
                        .foregroundStyle(valid || zone.isEmpty ? Color.secondary : Color.red)
                }
                .listRowBackground(Palette.card(scheme))

                Section {
                    Text("Create & Configure makes the `radar-ia` Hermes profile, installs its standing editorial instructions, opens its bot chat and sends one setup request so Hermes can verify the real scheduler, time zone and delivery path before creating or updating the daily routine.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Add Radar IA bot")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create & Configure") {
                            install()
                        }
                        .disabled(!valid)
                    }
                }
            }
        }
    }

    private func install() {
        guard let prompt = RadarIA.setupPrompt(time: timeText, zone: zone) else { return }
        busy = true
        failure = nil

        Task {
            defer { busy = false }
            do {
                var rows = try await store.bots()
                let alreadyExists = rows.contains { $0.name == RadarIA.botName }

                if !alreadyExists {
                    try await store.createBot(
                        name: RadarIA.botName,
                        description: RadarIA.description
                    )
                }

                // A retry after a partial create repairs an empty profile, but
                // an existing non-empty SOUL is treated as user-owned and kept.
                let soul = try await store.soul(RadarIA.botName)
                if !soul.exists || soul.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await store.setSoul(RadarIA.botName, RadarIA.editorialPrompt)
                }

                store.botCustomNames[RadarIA.botName] = RadarIA.displayName
                rows = try await store.bots()
                guard let bot = rows.first(where: { $0.name == RadarIA.botName }) else {
                    throw RadarIAInstallError.profileDidNotAppear
                }

                // From here onward Alice uses the exact same bot-conversation
                // path as every other Hermes profile. The setup request is sent
                // *inside Radar IA*, so the profile owns the resulting work.
                store.openBotConversation(for: bot)
                store.draft = prompt
                store.send()
                dismiss()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

private enum RadarIAInstallError: LocalizedError {
    case profileDidNotAppear

    var errorDescription: String? {
        switch self {
        case .profileDidNotAppear:
            "Hermes accepted the profile request but Radar IA did not appear when Alice read the bot list back. Nothing is being reported as configured until that read-back succeeds."
        }
    }
}
