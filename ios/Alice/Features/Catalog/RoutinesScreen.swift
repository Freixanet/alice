import SwiftUI

/// Every scheduled automation Hermes owns, across Alice and all named bots.
///
/// There is deliberately no second Jobs model in the app: this screen reads
/// and mutates the same profile-scoped cron stores that Hermes Desktop and the
/// agents' `cronjob_manage` tool use.
struct RoutinesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var routines: [JobRow] = []
    @State private var profiles: [(id: String, label: String)] = [("default", "Alice")]
    @State private var failure: String?
    @State private var partial = false
    @State private var loading = false
    @State private var selected: JobRow?
    @State private var creating = false

    var body: some View {
        List {
            Section("Scheduled") {
                if loading && routines.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading routines…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                } else if let failure {
                    stateRow(
                        title: "Routines unavailable", detail: failure,
                        systemImage: "clock.badge.exclamationmark"
                    )
                } else if routines.isEmpty {
                    stateRow(
                        title: partial ? "No routines on this gateway" : "No routines yet",
                        detail: partial
                            ? "Connect the dashboard to see and manage every profile's routines."
                            : "Create one here, or ask Alice or a bot in chat to schedule something.",
                        systemImage: "clock"
                    )
                } else {
                    ForEach(sorted, id: \.listIdentity) { routine in
                        Button { selected = routine } label: { routineRow(routine) }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.card(scheme))
                    }
                    if partial {
                        Text("This gateway's profile only. Connect the dashboard to manage all routines.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    }
                }
            }

            if !partial && failure == nil {
                Section("Templates") {
                    NavigationLink { CronBlueprintsScreen() } label: {
                        Label("Routine blueprints", systemImage: "square.grid.2x2")
                    }
                    Text("Hermes blueprints are server-defined templates with validated fields and live delivery targets.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Text("You can also schedule in chat: mention a bot, then ask naturally — for example, \(chatExample). The request runs as that bot, so Hermes creates the routine in the correct profile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .disabled(partial || failure != nil)
                    .accessibilityLabel("New routine")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { routine in
            RoutineDetailSheet(routine: routine) { await load() }
                .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(isPresented: $creating) {
            RoutineEditorSheet(profiles: profiles) { profile, name, prompt, schedule, deliver in
                try await store.addRoutine(
                    for: profile, name: name, prompt: prompt,
                    schedule: schedule, deliver: deliver
                )
                await load()
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
    }

    private var chatExample: String {
        if let bot = profiles.first(where: { $0.id != "default" }) {
            return "“@\(bot.label) hazme un resumen cada mañana a las 10”"
        }
        return "“Hazme un resumen cada mañana a las 10”"
    }

    private var sorted: [JobRow] {
        routines.sorted {
            switch ($0.nextRun, $1.nextRun) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private func routineRow(_ routine: JobRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(RoutinePresentation.colour(routine)).frame(width: 7, height: 7)
                Text(routine.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(profileLabel(routine.profile))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.secondary.opacity(0.10), in: .capsule)
            }
            if !routine.prompt.isEmpty {
                Text(routine.prompt).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 7) {
                if !routine.schedule.isEmpty {
                    Text(routine.schedule).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let next = routine.nextRun, routine.enabled {
                    Text("·").foregroundStyle(.tertiary)
                    Text("Next \(next.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = RoutinePresentation.failureText(routine) {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func profileLabel(_ profile: String?) -> String {
        guard let profile else { return "Hermes" }
        if profile == "default" { return "Alice" }
        return profiles.first(where: { $0.id == profile })?.label
            ?? store.botCurrentName(for: profile)
    }

    private func stateRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let listing = try await store.scheduledRoutines()
            routines = listing.rows
            partial = listing.scope == .oneGatewayProfile
            failure = nil
            if !partial, let found = try? await store.routineProfiles() { profiles = found }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not answer."
        }
    }
}

enum RoutinePresentation {
    static func colour(_ routine: JobRow) -> Color {
        if routine.isPaused || routine.isCompleted { return .secondary.opacity(0.5) }
        if routine.effectiveState == "error" { return .red }
        switch routine.lastStatus {
        case "error": return .red
        case "delivery_failed", "blocked_config": return .orange
        default: return .green
        }
    }

    static func failureText(_ routine: JobRow) -> String? {
        if let text = routine.lastDeliveryError, !text.isEmpty { return "Delivery failed — \(reason(text))" }
        if let text = routine.lastFireError, !text.isEmpty { return "Scheduled fire missed — \(reason(text))" }
        if let text = routine.lastError, !text.isEmpty { return "Failed — \(reason(text))" }
        if routine.lastStatus == "blocked_config" { return "Blocked by configuration" }
        return nil
    }

    static func reason(_ error: String) -> String {
        let lines = error.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.first else { return "no reason given" }
        if let last = lines.last, lines.count > 1,
           line.hasPrefix("Traceback") || line.hasPrefix("  File ") { line = last }
        for prefix in ["Error:", "Exception:", "error:", "ERROR:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return line.count > 110 ? String(line.prefix(109)) + "…" : line
    }
}

struct RoutineDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let routine: JobRow
    let onChanged: () async -> Void

    @State private var runs: [RoutineRun] = []
    @State private var runsFailure: String?
    @State private var loadingRuns = false
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var actionMessage: String?
    @State private var promptExpanded = false
    @State private var collapsedInstructionHeight: CGFloat = 0
    @State private var fullInstructionHeight: CGFloat = 0
    @State private var runsExpanded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: statusLabel)
                    LabeledContent("Profile", value: profileLabel)
                    if !routine.schedule.isEmpty { LabeledContent("Schedule", value: routine.schedule) }
                    LabeledContent("Delivery", value: deliveryLabel)
                    if let next = routine.nextRun { LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened)) }
                    if let last = routine.lastRun { LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened)) }
                    if let reason = routine.pausedReason, routine.isPaused {
                        LabeledContent("Paused because", value: reason)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                Section {
                    if !routine.isCompleted {
                        Button(routine.isPaused ? "Resume" : "Pause", systemImage: routine.isPaused ? "play" : "pause") {
                            mutate { try await store.setRoutinePaused(routine, paused: !routine.isPaused) }
                        }
                    }
                    Button("Run now", systemImage: "play.circle") {
                        runNow()
                    }
                    Button("Edit", systemImage: "slider.horizontal.3") { editing = true }
                    Button("Delete Routine", systemImage: "trash", role: .destructive) { deleting = true }
                }
                .disabled(busy)
                .listRowBackground(Palette.card(scheme))

                if !routine.prompt.isEmpty {
                    Section("Instructions") {
                        // A routine's prompt can run to paragraphs, and all of
                        // it sat between the top of the screen and the buttons.
                        Text(routine.prompt)
                            .textSelection(.enabled)
                            .lineLimit(promptExpanded ? nil : 4)
                            .background {
                                Text(routine.prompt)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        fullInstructionHeight = height
                                    }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                guard !promptExpanded else { return }
                                collapsedInstructionHeight = height
                            }
                            .listRowBackground(Palette.card(scheme))
                        if promptExpanded || instructionsAreTruncated {
                            Button(promptExpanded ? "Show less" : "Show all") {
                                withAnimation { promptExpanded.toggle() }
                            }
                            .font(.footnote)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }

                if let failure = RoutinePresentation.failureText(routine) {
                    Section("Last problem") {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                            .listRowBackground(Palette.card(scheme))
                        if let at = routine.lastFireAt {
                            Text(at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                                .listRowBackground(Palette.card(scheme))
                        }
                    }
                }

                Section("Recent runs") {
                    if loadingRuns && runs.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text("Loading history…") }
                            .foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    } else if let runsFailure {
                        Text(runsFailure).font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    } else if runs.isEmpty {
                        Text("No recorded runs yet").foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    } else {
                        ForEach(runsExpanded ? runs : Array(runs.prefix(3))) { run in
                            runRow(run).listRowBackground(Palette.card(scheme))
                        }
                        if runs.count > 3 {
                            Button(runsExpanded ? "Show less" : "Show all \(runs.count)") {
                                withAnimation { runsExpanded.toggle() }
                            }
                            .font(.footnote)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }

                if let actionMessage {
                    Section { Text(actionMessage).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { if busy { ProgressView() } }
            }
        }
        .task { await loadRuns() }
        .refreshable { await loadRuns() }
        .sheet(isPresented: $editing) {
            RoutineEditorSheet(profiles: [(routine.profile ?? "default", profileLabel)], routine: routine) {
                _, name, prompt, schedule, deliver in
                try await store.updateRoutine(
                    routine, name: name, prompt: prompt, schedule: schedule, deliver: deliver
                )
                await onChanged()
                dismiss()
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .confirmationDialog("Delete this routine?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Routine", role: .destructive) {
                mutate { try await store.deleteRoutine(routine) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will stop scheduling “\(routine.name)”. Its existing run history is not rewritten.")
        }
    }

    private var instructionsAreTruncated: Bool {
        fullInstructionHeight > collapsedInstructionHeight + 0.5
    }

    private var profileLabel: String {
        guard let profile = routine.profile else { return "Hermes" }
        return profile == "default" ? "Alice" : store.botCurrentName(for: profile)
    }

    private var deliveryLabel: String {
        switch routine.deliver {
        case nil, "", "local": return "Local (save only)"
        case let target?: return target
        }
    }

    private var statusLabel: String {
        switch routine.effectiveState {
        case "paused": return "Paused"
        case "completed": return "Completed"
        case "error": return "Error"
        default: return routine.enabled ? "Scheduled" : "Paused"
        }
    }

    private func runRow(_ run: RoutineRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(run.isActive ? Color.orange : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(run.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? run.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if run.tokens > 0 { Text("\(run.tokens) tok").font(.caption2).foregroundStyle(.secondary) }
            }
            if !run.preview.isEmpty { Text(run.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let reason = run.endReason, !reason.isEmpty {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadRuns() async {
        loadingRuns = true
        defer { loadingRuns = false }
        do { runs = try await store.routineRuns(routine); runsFailure = nil }
        catch { runsFailure = (error as? LocalizedError)?.errorDescription ?? "Run history unavailable." }
    }

    private func runNow() {
        busy = true
        actionMessage = nil
        Task {
            defer { busy = false }
            do {
                try await store.triggerRoutine(routine)
                actionMessage = "Triggered. Hermes owns the execution; pull to refresh the run history."
                await loadRuns()
                await onChanged()
            } catch {
                actionMessage = (error as? LocalizedError)?.errorDescription ?? "Hermes could not run it."
            }
        }
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        busy = true
        actionMessage = nil
        Task {
            do {
                try await action()
                await onChanged()
                dismiss()
            } catch {
                actionMessage = (error as? LocalizedError)?.errorDescription ?? "Hermes refused the change."
                busy = false
            }
        }
    }
}

/// One editor for creation and editing, used by both the global Routines screen
/// and a bot's profile sheet. The schedule presets compile to syntax Hermes'
/// real parser accepts; Custom is passed verbatim and validated by Hermes.
struct RoutineEditorSheet: View {
    enum ScheduleMode: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekdays = "Weekdays"
        case interval = "Interval"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let profiles: [(id: String, label: String)]
    let routine: JobRow?
    let onSave: (String, String, String, String, String) async throws -> Void

    @State private var profile: String
    @State private var name: String
    @State private var prompt: String
    @State private var deliver: String
    @State private var scheduleMode: ScheduleMode
    @State private var time = Date()
    @State private var intervalValue = 1
    @State private var intervalUnit = "h"
    @State private var customSchedule: String
    @State private var targets: [RoutineDeliveryTarget] = [
        RoutineDeliveryTarget(id: "local", name: "Local (save only)", homeTargetSet: true)
    ]
    @State private var hermesTimezone = ""
    @State private var busy = false
    @State private var failure: String?

    init(
        profiles: [(id: String, label: String)], routine: JobRow? = nil,
        onSave: @escaping (String, String, String, String, String) async throws -> Void
    ) {
        self.profiles = profiles
        self.routine = routine
        self.onSave = onSave
        _profile = State(initialValue: routine?.profile ?? profiles.first?.id ?? "default")
        _name = State(initialValue: routine?.name ?? "")
        _prompt = State(initialValue: routine?.prompt ?? "")
        _deliver = State(initialValue: routine?.deliver ?? "local")
        _scheduleMode = State(initialValue: routine == nil ? .daily : .custom)
        _customSchedule = State(initialValue: routine?.schedule ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if routine == nil, profiles.count > 1 {
                    Section("Runs as") {
                        Picker("Agent", selection: $profile) {
                            ForEach(profiles, id: \.id) { item in Text(item.label).tag(item.id) }
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                Section("Routine") {
                    TextField("Name", text: $name)
                    TextField("What should it do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                }
                .listRowBackground(Palette.card(scheme))

                Section("Schedule") {
                    Picker("Type", selection: $scheduleMode) {
                        ForEach(ScheduleMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch scheduleMode {
                    case .daily, .weekdays:
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    case .interval:
                        Stepper("Every \(intervalValue) \(unitLabel)", value: $intervalValue, in: 1...999)
                        Picker("Unit", selection: $intervalUnit) {
                            Text("Minutes").tag("m")
                            Text("Hours").tag("h")
                            Text("Days").tag("d")
                        }
                    case .custom:
                        TextField("e.g. every monday 9am or 0 9 * * *", text: $customSchedule)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text(hermesTimezone.isEmpty
                         ? "Hermes timezone: Mac local time. After saving, the exact next run is shown in your iPhone's local time."
                         : "Hermes timezone: \(hermesTimezone). After saving, the exact next run is shown in your iPhone's local time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))

                Section("Result") {
                    Picker("Deliver to", selection: $deliver) {
                        ForEach(targets) { target in
                            Text(target.homeTargetSet ? target.name : "\(target.name) — needs home channel")
                                .tag(target.id)
                        }
                    }
                    if let target = targets.first(where: { $0.id == deliver }), !target.homeTargetSet {
                        Text("Configure a home channel for \(target.name) in Hermes before using it for scheduled delivery.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                        .listRowBackground(Palette.card(scheme))
                }
            }
            .navigationTitle(routine == nil ? "New Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(routine == nil ? "Create" : "Save") { save() }.disabled(!canSave || busy)
                }
            }
        }
        .task {
            if let found = try? await store.routineDeliveryTargets(), !found.isEmpty {
                targets = found
                if !found.contains(where: { $0.id == deliver }), deliver != "local" {
                    // Never silently change an existing routine's destination.
                    // A target Hermes no longer advertises stays visible as a
                    // configuration problem until the user chooses a valid one.
                    targets.append(RoutineDeliveryTarget(
                        id: deliver, name: deliver.capitalized, homeTargetSet: false
                    ))
                }
            }
            await loadTimezone()
        }
        .onChange(of: profile) { _, _ in Task { await loadTimezone() } }
    }

    private func loadTimezone() async {
        hermesTimezone = (try? await store.routineTimezone(for: profile)) ?? ""
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !compiledSchedule.isEmpty
            && (targets.first(where: { $0.id == deliver })?.homeTargetSet ?? true)
    }

    private var unitLabel: String {
        switch intervalUnit {
        case "m": return intervalValue == 1 ? "minute" : "minutes"
        case "d": return intervalValue == 1 ? "day" : "days"
        default: return intervalValue == 1 ? "hour" : "hours"
        }
    }

    private var compiledSchedule: String {
        switch scheduleMode {
        case .daily:
            return "every day at \(clockString)"
        case .weekdays:
            return "weekdays at \(clockString)"
        case .interval:
            return "every \(intervalValue)\(intervalUnit)"
        case .custom:
            return customSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var clockString: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
    }

    private func save() {
        guard canSave else { return }
        busy = true
        failure = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = compiledSchedule
        Task {
            defer { busy = false }
            do {
                try await onSave(profile, name, prompt, schedule, deliver)
                dismiss()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Hermes refused the routine."
            }
        }
    }
}
