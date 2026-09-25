import Foundation
import SwiftUI


enum ActivityPresentation {
    /// Keeps current problems in "Needs attention" without repeating the same
    /// server state in history. Presentation copy is deliberately ignored: an
    /// app update that rewords an alert must not make the old wording appear as
    /// a second problem. Older genuinely different states remain in the record.
    static func partition(
        attention: [AliceEvent], activity: [AliceEvent]
    ) -> (needsAttention: [AliceEvent], history: [AliceEvent]) {
        var seen: Set<String> = []
        let current = (attention + activity.filter(\.isActionable))
            .filter { event in
                let key = event.isActionable ? "request:\(event.id)" : "state:\(event.subject)"
                return seen.insert(key).inserted
            }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.occurred > $1.occurred
            }

        let history = activity.filter { historical in
            guard !historical.isActionable else { return false }
            return !current.contains { now in
                !now.isActionable
                    && now.subject == historical.subject
                    && now.kind == historical.kind
                    && now.severity == historical.severity
                    && now.profile == historical.profile
                    && now.detail == historical.detail
            }
        }
        return (current, history)
    }
}

/// What has been happening, and what is waiting on you.
///
/// Two lists, because they answer different questions. "Needs attention" is
/// current state — something is wrong now and can be acted on. "Recent" is a
/// record of things that happened and are over.
///
/// The record only contains what Alice itself observed. Hermes keeps no
/// durable event history — its replay ring lives in memory and resets with the
/// gateway — so there is nothing to backfill, and an empty list on a fresh
/// install is the honest answer rather than a bug.
struct ActivityScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    /// Closes Activity and the drawer so the opened chat is what is on screen.
    var onOpenedChat: () -> Void = {}

    @State private var refreshing = false
    @State private var expanded: Set<String> = []
    @State private var resolving: Set<String> = []
    @State private var fixing: Set<String> = []
    @State private var fixNotes: [String: String] = [:]
    @State private var confirming: PendingFix?
    @State private var confirmingClear = false
    /// The routine a tapped routine event is about, open on its own page.
    @State private var openedRoutine: JobRow?
    @State private var routineNotice: String?
    /// Where a tapped action happened (`AgentActionsSection`).
    @State private var actionOpener = AgentActionOpener()

    private struct PendingFix: Identifiable {
        let id = UUID()
        let fix: AlertAdvice.Fix
        let event: AliceEvent
    }

    private var activitySections: (needsAttention: [AliceEvent], history: [AliceEvent]) {
        ActivityPresentation.partition(attention: store.attention, activity: store.activity)
    }

    var body: some View {
        List {
            if !activitySections.needsAttention.isEmpty {
                Section {
                    ForEach(activitySections.needsAttention) { row($0) }
                } header: {
                    Text("Needs attention")
                } footer: {
                    // Said, because a dismissed alert that reappears reads as
                    // the swipe not working rather than as the problem changing.
                    Text("Swipe left to dismiss. It comes back only if something changes.")
                }
            }

            // What agents did that changed something: the record people
            // most want of an assistant working on their behalf.
            AgentActionsSection(opener: actionOpener, onOpenedChat: onOpenedChat)

            // No record while something needs attention: an "Earlier" heading
            // over "Nothing yet" is a section about nothing. With nothing
            // anywhere, the empty state stays, so the screen is not blank.
            if !activitySections.history.isEmpty || activitySections.needsAttention.isEmpty {
            Section {
                if activitySections.history.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing yet")
                            .font(.body)
                        Text(
                            "No routines have run yet. Create one in Routines and its results will show here. "
                            + "Alice also records what it sees while it is running — "
                            + "connections dropping, answers finishing. It "
                            + "cannot show work that happened before it was watching."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Palette.card(scheme))
                } else {
                    ForEach(ActivityGroup.stack(activitySections.history)) { group in
                        row(group.latest, stacked: group)
                    }
                }
            } header: {
                Text(activitySections.needsAttention.isEmpty ? "Recent" : "Earlier")
            }

            }

            Section("History & usage") {
                NavigationLink { SessionsScreen() } label: {
                    Label("Sessions", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { InsightsScreen() } label: {
                    Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                }
                if store.dashboardReady {
                    NavigationLink { UsageScreen() } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        // One tap for the whole record, instead of a swipe per row.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { confirmingClear = true }
                    .disabled(!store.hasActivityHistory)
                    .accessibilityIdentifier("activity.clear")
                    // Attached here rather than to the list, which already
                    // carries the fix confirmation.
                    .confirmationDialog(
                        "Clear Alice’s activity record?",
                        isPresented: $confirmingClear,
                        titleVisibility: .visible
                    ) {
                        Button("Clear", role: .destructive) {
                            withAnimation { store.clearActivityHistory() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Removes everything under Recent. Current problems and anything waiting for your answer stay.")
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .refreshableWithFeedback { await refresh() }
        .modifier(AgentActionOpener.Presenting(opener: actionOpener, onOpenedChat: onOpenedChat))
        .sheet(item: $openedRoutine) { routine in
            RoutineDetailSheet(routine: routine) {}
                .preferredColorScheme(store.theme.colorScheme)
        }
        .alert(
            "Couldn’t open routine",
            isPresented: Binding(get: { routineNotice != nil }, set: { if !$0 { routineNotice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(routineNotice ?? "")
        }
        .task {
            // Seen the moment it opens. Marked only after the refresh, the
            // drawer's number stayed for as long as Hermes took to answer.
            store.markActivitySeen()
            await refresh()
            // Whatever the refresh brought in was on screen too.
            store.markActivitySeen()
        }
        .confirmationDialog(
            confirming?.fix.confirmation?.title ?? "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { pending in
            Button(
                pending.fix.label,
                role: pending.fix.confirmation?.destructive == true ? .destructive : nil
            ) {
                Task { await perform(pending.fix, for: pending.event) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.fix.confirmation?.message ?? "")
        }
        .accessibilityIdentifier("activity.list")
    }

    /// The icon column, shared by the header and by everything under it, so a
    /// button never starts further left than the sentence it belongs to.
    private static let gutter: CGFloat = 26

    private func row(_ event: AliceEvent, stacked: ActivityGroup? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(event, stacked: stacked)

            // Everything below lines up with the title, not with the icon.
            VStack(alignment: .leading, spacing: 4) {

            // Why it is here and what to do. The status alone used to be all a
            // row said, with the reason under More details in Hermes' words.
            if let advice = AlertAdvice.advice(for: event), !event.isActionable {
                Text(advice.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Fixes act on the present, so they are offered where the present
                // is listed. A failure from last week does not get "Try again now".
                if !advice.fixes.isEmpty, stacked == nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { fixButtons(advice.fixes, for: event) }
                        VStack(alignment: .leading, spacing: 8) { fixButtons(advice.fixes, for: event) }
                    }
                    .padding(.top, 2)
                }
                if let note = fixNotes[event.id] {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity.fixNote.\(event.id)")
                }
            }

            if event.isActionable, event.questions.isEmpty {
                // What is actually being asked. The buttons used to sit under
                // a one-line summary with no statement of what "allow" would
                // permit, which is the one thing a person needs before they
                // press it.
                // What it would do and what could go wrong, in plain words. The
                // card used to print Hermes' class name or the raw command, which
                // is accurate and left people with no idea what they approved.
                let explanation = ApprovalExplainer.explain(
                    description: event.approvalDescription, command: event.detail
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(explanation.risk)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if event.smartDenied {
                        Label {
                            Text(ApprovalExplainer.smartDeniedWarning)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)

                // Exactly what Hermes offered. A room-scoped approval may only
                // allow once/deny, so Activity must not invent session/always.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { choices(for: event) }
                    VStack(alignment: .leading, spacing: 8) { choices(for: event) }
                }
                .padding(.top, 2)
                Text(ApprovalExplainer.choiceHint(offered(event)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if event.standing == .gone || event.standing == .resolved {
                Label(
                    event.standing == .resolved ? "Answered" : "No longer waiting",
                    systemImage: event.standing == .resolved
                        ? "checkmark.circle" : "clock.badge.xmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let note = event.note, !note.isEmpty {
                Label {
                    Text(note)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .padding(.top, 2)
            }

            if let detail = event.detail, !detail.isEmpty, event.questions.isEmpty {
                // Hermes' exact words, one tap away. The human sentence never
                // replaces them; support and expert users need the original.
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(event.id) },
                        set: { open in
                            if open { expanded.insert(event.id) } else { expanded.remove(event.id) }
                        }
                    )
                ) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(isApproval(event) ? "Show exact command" : "More details").font(.caption)
                }
            }
            }
            .padding(.leading, Self.gutter)
        }
        .padding(.vertical, 2)
        .listRowBackground(Palette.card(scheme))
        .accessibilityElement(children: isApproval(event) ? .contain : .combine)
        // Only what is over. A live approval must be answered, not swiped away.
        .swipeActions(edge: .trailing, allowsFullSwipe: !event.isActionable) {
            if !event.isActionable {
                Button(role: .destructive) {
                    withAnimation {
                        for member in stacked?.events ?? [event] {
                            store.dismissActivity(member)
                        }
                    }
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                // Stated, not inherited: the app tints its whole environment
                // with the chosen accent, and that was painting a destructive
                // swipe action in it.
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func header(_ event: AliceEvent, stacked: ActivityGroup?) -> some View {
        if event.reference.routineKey != nil {
            Button { Task { await openRoutine(event) } } label: {
                headerContent(event, stacked: stacked)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity.open.\(event.id)")
            .accessibilityHint("Opens the routine")
        } else if event.opensAChat {
            Button { openReferencedChat(event) } label: {
                headerContent(event, stacked: stacked)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity.open.\(event.id)")
            .accessibilityHint("Opens the chat")
        } else {
            headerContent(event, stacked: stacked)
        }
    }

    private func headerContent(_ event: AliceEvent, stacked: ActivityGroup?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(event))
                // Colour says "now". A row in the record keeps its shape
                // but not the alarm; anything still waiting keeps both.
                .foregroundStyle(stacked != nil && !event.isActionable ? Color.secondary : tint(event))
                // A fixed column, centred on the title's own line. Baseline
                // alignment put the glyph a little low against a two-line
                // block and the row read as crooked.
                .frame(width: 18, height: 18)
                .padding(.top, 2)
                // The icon repeats what the words say rather than being
                // the only thing that says it — colour alone is not a
                // status anybody can rely on reading.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(event)).font(.body.weight(.semibold))
                Text(summary(for: event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                // Attention rows describe the present and are stamped with
                // "now", which a relative formatter renders as a countdown
                // — "in 0 seconds". They say so in words instead.
                if abs(event.occurred.timeIntervalSinceNow) < 60 {
                    Text("Now")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(event.occurred, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let stacked, stacked.count > 1 {
                    Text("×\(stacked.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Palette.background(scheme), in: .capsule)
                        .accessibilityLabel("\(stacked.count) times")
                }
            }
        }
    }

    /// A routine's report or failure opens that routine — its schedule, runs
    /// and controls — rather than the chat it reported into.
    private func openRoutine(_ event: AliceEvent) async {
        guard let key = event.reference.routineKey,
              let slash = key.lastIndex(of: "/")
        else { return }
        let profile = String(key[..<slash])
        let id = String(key[key.index(after: slash)...])
        do {
            let routines = try await store.routines(for: profile)
            if let routine = routines.first(where: { $0.id == id }) {
                openedRoutine = routine
            } else {
                routineNotice = "That routine no longer exists."
            }
        } catch {
            routineNotice = PlainWords.describe(error, doing: "open the routine")
        }
    }

    private func openReferencedChat(_ event: AliceEvent) {
        guard event.opensAChat else { return }
        if store.open(route(for: event)) {
            onOpenedChat()
        }
    }

    /// Titles Alice writes are sentence-cased; titles a person wrote are left
    /// exactly as they typed them.
    ///
    /// A routine called "chollos del dia" is that person's name for it and
    /// stays lower case; "platforms", which Hermes generated, does not get to
    /// arrive shouting or whispering depending on the subsystem.
    private func displayTitle(_ event: AliceEvent) -> String {
        // Anything carrying a routine or a bot is user-named.
        if event.reference.routineKey != nil || event.profile != nil {
            return event.title
        }
        guard let first = event.title.first else { return event.title }
        return first.uppercased() + event.title.dropFirst()
    }

    @ViewBuilder
    private func fixButtons(_ fixes: [AlertAdvice.Fix], for event: AliceEvent) -> some View {
        ForEach(Array(fixes.enumerated()), id: \.offset) { index, fix in
            Button(fix.label) {
                if fix.confirmation != nil {
                    confirming = PendingFix(fix: fix, event: event)
                } else {
                    Task { await perform(fix, for: event) }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(index == 0 ? .primary : .secondary)
            .disabled(fixing.contains(event.id))
            .accessibilityIdentifier("activity.fix.\(index).\(event.id)")
        }
    }

    private func perform(_ fix: AlertAdvice.Fix, for event: AliceEvent) async {
        fixing.insert(event.id)
        defer { fixing.remove(event.id) }
        // Said at once. A fix waits on Hermes — signing in, reading, writing —
        // and a button that only greyed out read as nothing happening, which is
        // reason enough to leave before it finished.
        fixNotes[event.id] = "Working on it…"
        switch await store.apply(fix, for: event) {
        case .done:
            fixNotes[event.id] = nil
        case .started:
            fixNotes[event.id] = "It's running now. Automations can take a few minutes — pull down to see when it's done."
        case .failed(let message):
            fixNotes[event.id] = message
        }
    }

    private func isApproval(_ event: AliceEvent) -> Bool {
        event.isActionable && event.questions.isEmpty
    }

    /// The line under the title. An approval says what it wants to do — for rows
    /// stored before approvals kept Hermes' class, the command still tells.
    private func summary(for event: AliceEvent) -> String {
        if isApproval(event) {
            let explanation = ApprovalExplainer.explain(
                description: event.approvalDescription, command: event.detail
            )
            return "Wants to \(explanation.action)"
        }
        return AlertAdvice.advice(for: event)?.headline ?? event.summary
    }

    private func offered(_ event: AliceEvent) -> [Message.ApprovalChoice] {
        event.approvalChoices.isEmpty ? [.once, .deny] : event.approvalChoices
    }

    @ViewBuilder
    private func choices(for event: AliceEvent) -> some View {
        let allowed = offered(event)
        ForEach(allowed, id: \.self) { choice in
            ApprovalChoiceButton(
                title: label(choice),
                deny: choice == .deny,
                disabled: resolving.contains(event.id),
                tint: store.accent.control(scheme),
                small: true
            ) {
                Task {
                    resolving.insert(event.id)
                    defer { resolving.remove(event.id) }
                    await store.resolvePendingRequest(event, choice: choice)
                }
            }
            .accessibilityIdentifier("activity.choice.\(choice.rawValue)")
        }
    }

    private func label(_ choice: Message.ApprovalChoice) -> String {
        ApprovalExplainer.label(choice)
    }

    private func route(for event: AliceEvent) -> Notifier.Route {
        var info: [AnyHashable: Any] = ["event": event.id]
        info["installation"] = event.reference.installation
        info["conversation"] = event.reference.conversationID
        info["profile"] = event.reference.profile
        info["session"] = event.reference.sessionID
        info["request"] = event.reference.requestID
        return Notifier.Route(userInfo: info) ?? Notifier.Route(userInfo: ["event": event.id])!
    }

    private func icon(_ event: AliceEvent) -> String {
        switch event.kind {
        case .finished, .automationSucceeded: "checkmark.circle"
        case .needsInput: "hand.raised"
        case .automationFailed: "exclamationmark.triangle"
        case .attention: "exclamationmark.circle"
        case .recovered: "arrow.clockwise.circle"
        }
    }

    private func tint(_ event: AliceEvent) -> Color {
        switch event.severity {
        case .informational: .secondary
        case .needsAttention: .orange
        case .failure: .red
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let actions: Void = store.refreshAgentActions()
        await store.syncEvents()
        await actions
    }
}
