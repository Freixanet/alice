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
                            Text("A real Hermes bot with versioned instructions, chat, model, sessions and a verified routine.")
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
                    Text("Create & Configure makes the `radar-ia` Hermes profile, installs its standing editorial instructions, sets the profile time zone, and creates or updates one daily routine through Hermes' native management API. Alice reads everything back before reporting success.")
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
        let normalizedZone = zone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RadarIA.validSchedule(time: timeText, zone: normalizedZone) else { return }
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

                // Hermes seeds new profiles with its generic SOUL. That text is
                // bootstrap content, not a user customization, so Radar IA must
                // replace it with its real standing editorial instructions. A
                // genuinely custom non-empty SOUL is preserved.
                let soul = try await store.soul(RadarIA.botName)
                let emptySoul = !soul.exists
                    || soul.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let rowBeforeConfiguration = rows.first { $0.name == RadarIA.botName }
                let isManagedTemplate = rowBeforeConfiguration?.metadata.managedTemplateID
                    == RadarIA.botName
                let managedVersion = isManagedTemplate
                    ? (rowBeforeConfiguration?.metadata.managedTemplateVersion ?? 0) : nil
                let exactCurrentSoul = soul.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == RadarIA.editorialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !alreadyExists || emptySoul || RadarIA.isGenericHermesSoul(soul.text)
                    || (managedVersion.map { $0 < RadarIA.templateVersion } ?? false) {
                    try await store.setManagedSoul(
                        RadarIA.botName, RadarIA.editorialPrompt,
                        templateID: RadarIA.botName, version: RadarIA.templateVersion
                    )
                    let verified = try await store.soul(RadarIA.botName)
                    guard verified.exists, RadarIA.ownsSoul(verified.text) else {
                        throw RadarIAInstallError.soulDidNotPersist
                    }
                } else if exactCurrentSoul && managedVersion == nil {
                    // Safe adoption for installations created before template
                    // versioning: exact equality proves this is Alice's text.
                    try await store.markManagedTemplate(
                        RadarIA.botName, id: RadarIA.botName,
                        version: RadarIA.templateVersion
                    )
                }

                var configuration = try await store.hermesConfiguration(
                    profile: RadarIA.botName
                )
                if configuration.timezone != normalizedZone {
                    configuration.timezone = normalizedZone
                    try await store.saveHermesConfiguration(
                        configuration, profile: RadarIA.botName
                    )
                }
                guard try await store.routineTimezone(for: RadarIA.botName)
                    == normalizedZone else {
                    throw RadarIAInstallError.timezoneDidNotPersist
                }

                let schedule = RadarIA.schedule(at: timeText)
                let existingRoutines = try await store.routines(for: RadarIA.botName)
                let candidates = existingRoutines.filter(RadarIA.manages)
                guard candidates.count < 2 else {
                    throw RadarIAInstallError.ambiguousRoutines
                }
                if let routine = candidates.first {
                    // An exact name with unrelated instructions may be a user's
                    // routine. Never overwrite it just because the title fits.
                    guard RadarIA.matchesEditorialPrompt(routine.prompt) else {
                        throw RadarIAInstallError.customRoutineConflict
                    }
                    try await store.updateRoutine(
                        routine, name: RadarIA.routineName,
                        prompt: RadarIA.editorialPrompt, schedule: schedule,
                        deliver: routine.deliver ?? "local"
                    )
                    if routine.isPaused {
                        try await store.setRoutinePaused(routine, paused: false)
                    }
                } else {
                    try await store.addRoutine(
                        for: RadarIA.botName, name: RadarIA.routineName,
                        prompt: RadarIA.editorialPrompt, schedule: schedule,
                        deliver: "local"
                    )
                }

                let verifiedRoutines = try await store.routines(for: RadarIA.botName)
                    .filter(RadarIA.manages)
                guard verifiedRoutines.count == 1,
                      let verifiedRoutine = verifiedRoutines.first,
                      verifiedRoutine.name == RadarIA.routineName,
                      verifiedRoutine.schedule == schedule,
                      verifiedRoutine.enabled,
                      RadarIA.matchesEditorialPrompt(verifiedRoutine.prompt)
                else {
                    throw RadarIAInstallError.routineDidNotPersist
                }

                store.botCustomNames[RadarIA.botName] = RadarIA.displayName
                rows = try await store.bots()
                guard let bot = rows.first(where: { $0.name == RadarIA.botName }) else {
                    throw RadarIAInstallError.profileDidNotAppear
                }

                // From here onward Alice uses the exact same bot-conversation
                // path as every other Hermes profile. Configuration is already
                // complete and verified; opening chat does not ask a model to
                // mutate scheduler state on Alice's behalf.
                store.openBotConversation(for: bot)
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
    case soulDidNotPersist
    case timezoneDidNotPersist
    case ambiguousRoutines
    case customRoutineConflict
    case routineDidNotPersist

    var errorDescription: String? {
        switch self {
        case .profileDidNotAppear:
            "Hermes accepted the profile request but Radar IA did not appear when Alice read the bot list back. Nothing is being reported as configured until that read-back succeeds."
        case .soulDidNotPersist:
            "Hermes did not keep Radar IA's editorial instructions when Alice read the profile back. The setup was stopped rather than leaving the bot with generic Hermes instructions."
        case .timezoneDidNotPersist:
            "Hermes did not keep Radar IA's selected time zone. No routine was created with an unverified clock."
        case .ambiguousRoutines:
            "Hermes already has more than one Radar IA routine. Alice left them unchanged so you can remove or rename the duplicate first."
        case .customRoutineConflict:
            "A routine named “Radar IA — informe diario” already exists with different instructions. Alice left it unchanged rather than overwriting a customization."
        case .routineDidNotPersist:
            "Hermes did not return one active Radar IA routine with the requested schedule after saving it. Setup remains incomplete."
        }
    }
}
