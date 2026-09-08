import SwiftUI

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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !store.attention.isEmpty {
                Section("Needs attention") {
                    ForEach(store.attention) { row($0) }
                }
            }

            Section(store.attention.isEmpty ? "Recent" : "Earlier") {
                if store.activity.isEmpty {
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
                } else {
                    ForEach(store.activity) { row($0) }
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

    private func row(_ event: AliceEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(event))
                    .foregroundStyle(tint(event))
                    // The icon repeats what the words say rather than being
                    // the only thing that says it — colour alone is not a
                    // status anybody can rely on reading.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.body)
                    Text(event.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(event.occurred, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if event.isActionable, let question = event.question {
                // A clarify request. Hermes calls `clarify` both with options
                // and without, so both have to be answerable: the buttons when
                // it offered any, and a box either way for the open case.
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text).font(.footnote)
                    if !question.choices.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { options(question, for: event) }
                            VStack(alignment: .leading, spacing: 8) { options(question, for: event) }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Your answer", text: answerBinding(event.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("activity.answer.field")
                        Button("Send") {
                            Task { await send(answers[event.id] ?? "", for: event) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            resolving.contains(event.id)
                                || (answers[event.id] ?? "").trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                        )
                        .accessibilityIdentifier("activity.answer.send")
                    }
                }
                .padding(.top, 2)
            } else if event.isActionable {
                // The same choices Hermes offered, answered over the same
                // socket the request arrived on. Nothing here invents an option
                // the server did not list.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { choices(for: event) }
                    VStack(alignment: .leading, spacing: 8) { choices(for: event) }
                }
                .padding(.top, 2)
            } else if event.standing == .gone || event.standing == .resolved {
                Label(
                    event.standing == .resolved ? "Answered" : "No longer waiting",
                    systemImage: event.standing == .resolved
                        ? "checkmark.circle" : "clock.badge.xmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if event.reference.conversationID != nil {
                Button("Open conversation") { store.open(route(for: event)) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("activity.open.\(event.id)")
            }

            if let detail = event.detail, !detail.isEmpty {
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
                    Text("Technical details").font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Palette.card(scheme))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func options(_ question: AliceEvent.Question, for event: AliceEvent) -> some View {
        ForEach(question.choices, id: \.self) { option in
            Button(option) { Task { await send(option, for: event) } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(resolving.contains(event.id))
        }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func send(_ answer: String, for event: AliceEvent) async {
        resolving.insert(event.id)
        defer { resolving.remove(event.id) }
        if await store.answerClarification(event, answer: answer) {
            answers[event.id] = nil
        }
    }

    @ViewBuilder
    private func choices(for event: AliceEvent) -> some View {
        ForEach(Message.ApprovalChoice.allCases, id: \.self) { choice in
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
        case .once: "Once"
        case .session: "This session"
        case .always: "Always"
        case .deny: "Deny"
        }
    }

    private func route(for event: AliceEvent) -> Notifier.Route {
        var info: [AnyHashable: Any] = ["event": event.id]
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
        await store.syncEvents()
    }
}
