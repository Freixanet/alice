import SwiftUI

/// A chronological overview of updates Alice actually observed. Activity owns
/// the detailed record and its response controls; this page brings its news
/// together with the agent action log without inventing missing history.
struct FeedScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let onOpenedChat: () -> Void

    @State private var opener = AgentActionOpener()
    @State private var openedRoutine: JobRow?
    @State private var routineNotice: String?

    private enum Entry: Identifiable {
        case action(AgentAction)
        case event(AliceEvent)

        var id: String {
            switch self {
            case .action(let value): "action:\(value.id)"
            case .event(let value): "event:\(value.id)"
            }
        }
        var at: Date {
            switch self {
            case .action(let value): value.at
            case .event(let value): value.occurred
            }
        }
    }

    private var entries: [Entry] {
        let visible = ActivityPresentation.partition(attention: store.attention, activity: store.activity)
        return (store.allAgentActions.map(Entry.action)
                + (visible.needsAttention + visible.history).map(Entry.event))
            .sorted { $0.at > $1.at }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing new yet", systemImage: "rectangle.stack",
                    description: Text("Agent actions, routine runs and alerts Alice sees will appear here.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(entries) { entry in
                    switch entry {
                    case .action(let action):
                        Button {
                            opener.open(action, store: store, onOpenedChat: onOpenedChat)
                        } label: {
                            AgentActionRow(action: action)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("feed.action.\(action.id)")
                    case .event(let event):
                        eventRow(event)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task {
            store.markActivitySeen()
            await refresh()
            store.markActivitySeen()
        }
        .modifier(AgentActionOpener.Presenting(opener: opener, onOpenedChat: onOpenedChat))
        .sheet(item: $openedRoutine) { routine in
            RoutineDetailSheet(routine: routine) {}
                .preferredColorScheme(store.theme.colorScheme)
        }
        .alert("Couldn’t open routine", isPresented: Binding(
            get: { routineNotice != nil }, set: { if !$0 { routineNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(routineNotice ?? "")
        }
    }

    @ViewBuilder
    private func eventRow(_ event: AliceEvent) -> some View {
        if event.opensAChat || event.reference.routineKey != nil {
            Button { open(event) } label: { eventContent(event) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.event.\(event.id)")
        } else {
            NavigationLink { ActivityScreen(onOpenedChat: onOpenedChat) } label: {
                eventContent(event)
            }
            .accessibilityIdentifier("feed.event.\(event.id)")
        }
    }

    private func eventContent(_ event: AliceEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: event))
                .font(.body)
                .foregroundStyle(event.severity == .failure ? .red : .primary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                Text(event.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(event.occurred, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func symbol(for event: AliceEvent) -> String {
        switch event.kind {
        case .finished, .automationSucceeded: "checkmark.circle"
        case .needsInput: "hand.raised"
        case .automationFailed, .attention: "exclamationmark.triangle"
        case .recovered: "arrow.clockwise.circle"
        }
    }

    private func open(_ event: AliceEvent) {
        if let key = event.reference.routineKey, let slash = key.lastIndex(of: "/") {
            let profile = String(key[..<slash])
            let id = String(key[key.index(after: slash)...])
            Task {
                do {
                    if let routine = try await store.routines(for: profile).first(where: { $0.id == id }) {
                        openedRoutine = routine
                    } else {
                        routineNotice = String(localized: "That routine no longer exists.")
                    }
                } catch {
                    routineNotice = PlainWords.describe(error, doing: "open the routine")
                }
            }
            return
        }
        var info: [AnyHashable: Any] = ["event": event.id]
        info["installation"] = event.reference.installation
        info["conversation"] = event.reference.conversationID
        info["profile"] = event.reference.profile
        info["session"] = event.reference.sessionID
        info["request"] = event.reference.requestID
        guard let route = Notifier.Route(userInfo: info)
            ?? Notifier.Route(userInfo: ["event": event.id]), store.open(route) else { return }
        onOpenedChat()
    }

    private func refresh() async {
        async let actions: Void = store.refreshAgentActions()
        await store.syncEvents()
        await actions
    }
}
