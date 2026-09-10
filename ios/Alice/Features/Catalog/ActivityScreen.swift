import Foundation
import SwiftUI

/// Genuinely equivalent notification-like events collapse into one Activity row,
/// even when other event types happened between them. The underlying
/// `AppStore.activity` array is left untouched.
struct ActivityEventStack: Identifiable, Equatable {
    var events: [AliceEvent]

    var id: String { events[0].id }
    var latest: AliceEvent { events[0] }
    var count: Int { events.count }
}

enum ActivityEventStacking {
    static func stack(_ events: [AliceEvent]) -> [ActivityEventStack] {
        var result: [ActivityEventStack] = []
        for event in events {
            // `events` is newest-first. Merge into the first matching stack so
            // one notification type can never reappear farther down the list.
            // The stack itself stays where its newest occurrence belongs.
            if let index = result.firstIndex(where: { equivalent($0.latest, event) }) {
                result[index].events.append(event)
            } else {
                result.append(ActivityEventStack(events: [event]))
            }
        }
        return result
    }

    static func equivalent(_ lhs: AliceEvent, _ rhs: AliceEvent) -> Bool {
        guard lhs.kind != .needsInput, rhs.kind != .needsInput,
              lhs.standing == .none, rhs.standing == .none else { return false }

        return lhs.kind == rhs.kind
            && lhs.severity == rhs.severity
            && lhs.profile == rhs.profile
            && lhs.title == rhs.title
            && lhs.summary == rhs.summary
            && lhs.detail == rhs.detail
            && subjectIdentity(lhs) == subjectIdentity(rhs)
    }

    private static func subjectIdentity(_ event: AliceEvent) -> String? {
        event.reference.conversationID
            ?? event.reference.routineKey
            ?? event.reference.sessionKey
            ?? event.reference.profile
            ?? event.profile
    }

    static func partition(
        attention: [AliceEvent], activity: [AliceEvent]
    ) -> (needsAttention: [AliceEvent], history: [AliceEvent]) {
        // `attention` is the fresh server snapshot. `inferredAttention` is the
        // safety net for a partial refresh: if health could not be read, the
        // latest observed degraded/failed state must not silently fall back
        // into history. A later success/recovery clears that inferred state.
        let inferred = inferredAttention(from: activity)
        let candidates = attention + inferred + activity.filter(\.isActionable)

        var seen: Set<String> = []
        let needsAttention = candidates
            .filter { seen.insert(attentionIdentity($0)).inserted }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.occurred > $1.occurred
            }

        var suppressed = Set(needsAttention.map(\.id))
        // A fresh current-state row has a synthetic `attention:*` id while
        // Activity keeps the historical event id. Suppress that one matching
        // snapshot so the same problem is not shown both above and below.
        for current in needsAttention where !current.isActionable {
            guard let subject = stateSubject(current),
                  let historical = activity.first(where: {
                      stateSubject($0) == subject && sameState(current, $0)
                  }) else { continue }
            suppressed.insert(historical.id)
        }

        let history = activity.filter { !suppressed.contains($0.id) && !$0.isActionable }
        return (needsAttention, history)
    }

    /// Reconstruct the last known state of routines/components from Activity.
    /// Newest wins: failure/degraded means attention; success/recovered clears it.
    static func inferredAttention(from activity: [AliceEvent]) -> [AliceEvent] {
        var seenSubjects: Set<String> = []
        var result: [AliceEvent] = []
        for event in activity.sorted(by: { $0.occurred > $1.occurred }) {
            guard let subject = stateSubject(event), seenSubjects.insert(subject).inserted else {
                continue
            }
            switch event.kind {
            case .automationFailed, .attention:
                if event.severity != .informational { result.append(event) }
            default:
                break
            }
        }
        return result
    }

    private static func attentionIdentity(_ event: AliceEvent) -> String {
        if event.isActionable { return "request:\(event.id)" }
        return stateSubject(event) ?? "event:\(event.id)"
    }

    private static func sameState(_ lhs: AliceEvent, _ rhs: AliceEvent) -> Bool {
        // Titles and summaries are presentation copy and can change between app
        // versions. The raw detail is server-owned state, so it distinguishes a
        // genuinely different failure without making old wording reappear as a
        // duplicate after an Alice copy update.
        lhs.kind == rhs.kind
            && lhs.severity == rhs.severity
            && lhs.profile == rhs.profile
            && lhs.detail == rhs.detail
    }

    private static func stateSubject(_ event: AliceEvent) -> String? {
        switch event.kind {
        case .automationSucceeded, .automationFailed:
            if let key = event.reference.routineKey { return "routine:\(key)" }
            if event.id.hasPrefix("attention:routine:") {
                return "routine:" + String(event.id.dropFirst("attention:routine:".count))
            }
            if event.id.hasPrefix("routine:") {
                let body = String(event.id.dropFirst("routine:".count))
                guard let split = body.lastIndex(of: ":") else { return nil }
                return "routine:" + String(body[..<split])
            }
        case .attention, .recovered:
            if event.id.hasPrefix("attention:component:") {
                return "component:" + String(event.id.dropFirst("attention:component:".count))
            }
            if event.id.hasPrefix("component:") {
                let body = String(event.id.dropFirst("component:".count))
                guard let split = body.lastIndex(of: ":") else { return nil }
                return "component:" + String(body[..<split])
            }
        default:
            break
        }
        return nil
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

    @State private var refreshing = false
    @State private var expanded: Set<String> = []
    @State private var resolving: Set<String> = []
    @State private var answers: [String: String] = [:]
    @State private var selectedOptions: [String: Set<String>] = [:]
    @Environment(\.dismiss) private var dismiss

    /// Current attention always leads; history never repeats promoted items.
    private var activitySections: (needsAttention: [AliceEvent], history: [AliceEvent]) {
        ActivityEventStacking.partition(attention: store.attention, activity: store.activity)
    }

    var body: some View {
        List {
            if !activitySections.needsAttention.isEmpty {
                Section("Needs attention") {
                    ForEach(activitySections.needsAttention) { row($0, isCurrentAttention: true) }
                }
            }

            if !activitySections.history.isEmpty {
                Section(activitySections.needsAttention.isEmpty ? "Recent" : "Earlier") {
                    ForEach(ActivityEventStacking.stack(activitySections.history)) { stack in
                        row(
                            stack.latest, count: stack.count,
                            dismissIDs: stack.events.map(\.id), isCurrentAttention: false
                        )
                    }
                }
            } else if activitySections.needsAttention.isEmpty {
                Section("Recent") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing yet")
                            .font(.body)
                        Text(
                            "Alice records what it sees while it is running — "
                            + "automations finishing, connections dropping. It "
                            + "cannot show work that happened before it was watching."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Palette.card(scheme))
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
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .refreshable { await refresh() }
        .task {
            await refresh()
            store.markActivitySeen()
        }
        .accessibilityIdentifier("activity.list")
    }

    private func row(
        _ event: AliceEvent, count: Int = 1, dismissIDs: [String] = [],
        isCurrentAttention: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(event))
                    .foregroundStyle(tint(event, isCurrentAttention: isCurrentAttention))
                    .frame(width: 22, height: 22, alignment: .center)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle(event))
                        .font(.body.weight(isCurrentAttention ? .medium : .regular))
                        .frame(minHeight: 22, alignment: .center)
                    Text(displaySummary(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    if count > 1 {
                        Text("×\(count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.12), in: .capsule)
                            .accessibilityLabel("\(count) similar notifications")
                    }
                    Text(event.occurred, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if event.isActionable, !event.questions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(event.questions.enumerated()), id: \.offset) { offset, question in
                            questionView(
                                question,
                                number: event.questions.count > 1 ? offset + 1 : nil,
                                event: event
                            )
                        }
                    }
                } else if event.isActionable {
                    if isApproval(event) { approvalContext(event) }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { choices(for: event) }
                        VStack(alignment: .leading, spacing: 8) { choices(for: event) }
                    }
                } else if event.standing == .gone || event.standing == .resolved {
                    Label(
                        event.standing == .resolved ? "Handled" : "No longer waiting",
                        systemImage: event.standing == .resolved
                            ? "checkmark.circle" : "clock.badge.xmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if event.reference.conversationID != nil {
                    Button { store.open(route(for: event)) } label: {
                        Label("View related chat", systemImage: "bubble.left")
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("activity.open.\(event.id)")
                }

                if let detail = event.detail, !detail.isEmpty,
                   !isApproval(event), event.questions.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(event.id) },
                            set: { open in
                                if open { expanded.insert(event.id) } else { expanded.remove(event.id) }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Exact message from Hermes")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("More details").font(.caption)
                    }
                }
            }
            // Body content lines up with the title, not with the leading edge
            // of the status icon. This also keeps approval buttons symmetrical.
            .padding(.leading, 30)
        }
        .padding(.vertical, 3)
        .listRowBackground(Palette.card(scheme))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !dismissIDs.isEmpty {
                Button(role: .destructive) {
                    store.dismissActivity(dismissIDs)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func approvalContext(_ event: AliceEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What \(agentName(event)) wants to do")
                .font(.caption.weight(.semibold))

            if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Hermes did not provide a readable description of the requested action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Only allow this if you expected this action. “Allow once” is the safest choice when you do not want to grant broader permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func displayTitle(_ event: AliceEvent) -> String {
        if isApproval(event) { return "Approval needed" }
        if isClarification(event) { return "Answer needed" }
        if let component = componentName(event) { return EventDigest.label(for: component) }
        return event.title
    }

    private func displaySummary(_ event: AliceEvent) -> String {
        if event.standing == .resolved || event.standing == .gone { return event.summary }

        if isApproval(event) {
            return "\(agentName(event)) is paused until you decide whether to allow the action below."
        }
        if isClarification(event) {
            return "\(agentName(event)) needs your answer before it can continue."
        }

        switch event.kind {
        case .finished:
            return event.severity == .failure
                ? "\(agentName(event)) stopped because something went wrong."
                : "\(agentName(event)) finished its task."
        case .automationSucceeded:
            return "This routine finished successfully."
        case .automationFailed:
            return "This routine didn’t finish successfully."
        case .attention, .recovered:
            guard let component = componentName(event) else { return event.summary }
            let vague = event.summary.lowercased() == "\(event.title.lowercased()) needs attention."
                || event.summary.lowercased() == "\(component.lowercased()) needs attention."
            if !vague { return event.summary }
            let healthy = event.kind == .recovered
            switch component.lowercased() {
            case "platforms":
                return healthy
                    ? "Your messaging connections are working normally again."
                    : "One or more messaging connections are offline or not working normally."
            case "gateway":
                return healthy
                    ? "Alice can reach the Hermes service again."
                    : "Alice is having trouble reaching the Hermes service."
            case "dashboard":
                return healthy
                    ? "The Hermes dashboard is responding normally again."
                    : "The Hermes dashboard is not responding normally."
            case "storage":
                return healthy
                    ? "Hermes can access its saved data again."
                    : "Hermes is having trouble accessing its saved data."
            default:
                let name = EventDigest.label(for: component)
                return healthy ? "\(name) is working normally again." : "\(name) is not working normally."
            }
        case .needsInput:
            return event.summary
        }
    }

    private func agentName(_ event: AliceEvent) -> String {
        guard let profile = event.profile, !profile.isEmpty else { return "Alice" }
        return profile == "default" ? "Alice" : store.botCurrentName(for: profile)
    }

    private func isApproval(_ event: AliceEvent) -> Bool {
        event.kind == .needsInput && (event.id.hasPrefix("approval:") || !event.approvalChoices.isEmpty)
    }

    private func isClarification(_ event: AliceEvent) -> Bool {
        event.kind == .needsInput && (event.id.hasPrefix("clarify:") || !event.questions.isEmpty)
    }

    private func componentName(_ event: AliceEvent) -> String? {
        if event.id.hasPrefix("attention:component:") {
            return String(event.id.dropFirst("attention:component:".count))
        }
        guard event.id.hasPrefix("component:") else { return nil }
        let body = String(event.id.dropFirst("component:".count))
        guard let split = body.lastIndex(of: ":") else { return nil }
        return String(body[..<split])
    }

    @ViewBuilder
    private func questionView(
        _ question: AliceEvent.Question, number: Int?, event: AliceEvent
    ) -> some View {
        let key = questionKey(event, question)
        VStack(alignment: .leading, spacing: 8) {
            if let number {
                Text("Question \(number) of \(event.questions.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.text).font(.footnote)

            if let answer = question.answer {
                Label("Answered: \(answer)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !question.choices.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { options(question, key: key, for: event) }
                        VStack(alignment: .leading, spacing: 8) {
                            options(question, key: key, for: event)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        question.allowsMultiple ? "Other answer (optional)" : "Your answer",
                        text: answerBinding(key), axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("activity.answer.field.\(question.id ?? "single")")

                    Button("Send") {
                        Task { await sendQuestion(question, key: key, event: event) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(resolving.contains(event.id) || !hasAnswer(question, key: key))
                    .accessibilityIdentifier("activity.answer.send.\(question.id ?? "single")")
                }
            }
        }
    }

    @ViewBuilder
    private func options(
        _ question: AliceEvent.Question, key: String, for event: AliceEvent
    ) -> some View {
        ForEach(question.choices, id: \.self) { option in
            if question.allowsMultiple {
                Button {
                    var selected = selectedOptions[key] ?? []
                    if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
                    selectedOptions[key] = selected
                } label: {
                    Label(
                        option,
                        systemImage: (selectedOptions[key] ?? []).contains(option)
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(resolving.contains(event.id))
            } else {
                Button(option) {
                    Task { await send(option, questionID: question.id, key: key, for: event) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(resolving.contains(event.id))
            }
        }
    }

    private func questionKey(_ event: AliceEvent, _ question: AliceEvent.Question) -> String {
        "\(event.id)|\(question.id ?? "single")"
    }

    private func answerBinding(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
    }

    private func hasAnswer(_ question: AliceEvent.Question, key: String) -> Bool {
        let typed = (answers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return true }
        return question.allowsMultiple && !(selectedOptions[key] ?? []).isEmpty
    }

    private func sendQuestion(
        _ question: AliceEvent.Question, key: String, event: AliceEvent
    ) async {
        let typed = (answers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if question.allowsMultiple {
            var values = question.choices.filter { (selectedOptions[key] ?? []).contains($0) }
            if !typed.isEmpty { values.append(typed) }
            guard !values.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: values),
                  let encoded = String(data: data, encoding: .utf8)
            else { return }
            // Hermes explicitly accepts JSON arrays for multi-select replies;
            // this preserves labels containing commas unlike a comma join.
            answer = encoded
        } else {
            guard !typed.isEmpty else { return }
            answer = typed
        }
        await send(answer, questionID: question.id, key: key, for: event)
    }

    private func send(
        _ answer: String, questionID: String?, key: String, for event: AliceEvent
    ) async {
        resolving.insert(event.id)
        defer { resolving.remove(event.id) }
        if await store.answerClarification(event, questionID: questionID, answer: answer) {
            answers[key] = nil
            selectedOptions[key] = nil
        }
    }

    @ViewBuilder
    private func choices(for event: AliceEvent) -> some View {
        let allowed = event.approvalChoices.isEmpty
            ? [Message.ApprovalChoice.once, .deny]
            : event.approvalChoices
        ForEach(allowed, id: \.self) { choice in
            Button(label(choice)) {
                Task {
                    resolving.insert(event.id)
                    defer { resolving.remove(event.id) }
                    await store.resolvePendingRequest(event, choice: choice)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(resolving.contains(event.id))
            .tint(choice == .deny ? .secondary : .primary)
            .accessibilityIdentifier("activity.choice.\(choice.rawValue)")
        }
    }

    private func label(_ choice: Message.ApprovalChoice) -> String {
        switch choice {
        case .once: "Allow once"
        case .session: "Allow this session"
        case .always: "Always allow"
        case .deny: "Don’t allow"
        }
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

    private func tint(_ event: AliceEvent, isCurrentAttention: Bool) -> Color {
        // Red/orange are reserved for things that are current. Historical
        // failures keep their warning shape but not an urgency colour.
        guard isCurrentAttention else { return .secondary }
        switch event.severity {
        case .informational: return .secondary
        case .needsAttention: return .orange
        case .failure: return .red
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.syncEvents()
    }
}
