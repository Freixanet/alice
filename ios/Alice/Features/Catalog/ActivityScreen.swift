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
