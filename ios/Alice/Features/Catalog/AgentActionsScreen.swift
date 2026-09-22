import SwiftUI

/// One thing an agent did: who, what, where, and whether it went through.
///
/// Who is the agent's face, what is a sentence with a small glyph on the
/// face's corner, and where is the chat or routine it happened in. Tapping it
/// opens that place at that moment.
struct AgentActionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let action: AgentAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentFace(profile: action.profile, size: 30)
                .overlay(alignment: .bottomTrailing) { badge.offset(x: 5, y: 5) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.sentence)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !action.ok {
                    Label("Didn’t go through", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var badge: some View {
        Image(systemName: action.ok ? action.symbol : "exclamationmark")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(action.ok ? (action.weighty ? store.accent.primary(scheme) : Color.secondary) : .white)
            .frame(width: 17, height: 17)
            .background(action.ok ? Palette.card(scheme) : Palette.danger(scheme), in: .circle)
            .overlay { Circle().stroke(Palette.border(scheme), lineWidth: 0.5) }
    }

    /// "Inbox · in “Plan de viaje” · 10:42", "Radar · routine “Informe” · 7:00".
    private var context: String {
        var parts = [store.botCurrentName(for: action.profile)]
        let title = action.originTitle.trimmingCharacters(in: .whitespaces)
        switch action.place {
        case .routine:
            parts.append(title.isEmpty ? String(localized: "a routine") : String(localized: "routine “\(title)”"))
        case .phone:
            parts.append(String(localized: "on this iPhone"))
        case .chat:
            if !title.isEmpty, title != "Bot Chat" { parts.append(String(localized: "in “\(title)”")) }
        }
        parts.append(action.at.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

/// What agents did lately, at the top of Activity's record.
struct AgentActionsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    /// Owned by the screen, whose list presents what it opens: a sheet hung
    /// on a section does not reliably present.
    let opener: AgentActionOpener
    var onOpenedChat: () -> Void = {}

    private static let shown = 4

    var body: some View {
        let actions = store.allAgentActions
        Section {
            if actions.isEmpty {
                Text(store.agentActionsAvailable == false
                     ? LocalizedStringKey("Update the Alice plugin on your Mac to see what your agents do.")
                     : LocalizedStringKey("Emails sent, routines created, sign-ins and anything else your agents do that changes something will show here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            } else {
                ForEach(actions.prefix(Self.shown)) { action in
                    Button { opener.open(action, store: store, onOpenedChat: onOpenedChat) } label: {
                        AgentActionRow(action: action)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.card(scheme))
                }
                if actions.count > Self.shown {
                    NavigationLink {
                        AgentActionsScreen(onOpenedChat: onOpenedChat)
                    } label: {
                        Text("See all \(actions.count)")
                            .font(.subheadline)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
        } header: {
            Text("Done by your agents")
        }
    }
}

/// Everything agents did, by day, for one agent or all.
struct AgentActionsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var onOpenedChat: () -> Void = {}

    @State private var agent: String?
    @State private var opener = AgentActionOpener()

    var body: some View {
        let all = store.allAgentActions
        let agents = Array(Set(all.map(\.profile))).sorted {
            store.botCurrentName(for: $0).localizedCaseInsensitiveCompare(store.botCurrentName(for: $1)) == .orderedAscending
        }
        let shown = agent.map { name in all.filter { $0.profile == name } } ?? all
        List {
            if agents.count > 1 {
                Section {
                    filters(agents)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(AgentActionDays.group(shown), id: \.day) { day in
                Section {
                    ForEach(day.actions) { action in
                        Button { opener.open(action, store: store, onOpenedChat: onOpenedChat) } label: {
                            AgentActionRow(action: action)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Palette.card(scheme))
                    }
                } header: {
                    Text(Self.dayTitle(day.day))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .navigationTitle("Done by your agents")
        .navigationBarTitleDisplayMode(.inline)
        .refreshableWithFeedback { await store.refreshAgentActions() }
        .modifier(AgentActionOpener.Presenting(opener: opener, onOpenedChat: onOpenedChat))
    }

    private func filters(_ agents: [String]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(nil)
                ForEach(agents, id: \.self) { chip($0) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ profile: String?) -> some View {
        let selected = agent == profile
        return Button {
            withAnimation(.snappy(duration: 0.2)) { agent = profile }
        } label: {
            HStack(spacing: 6) {
                if let profile { AgentFace(profile: profile, size: 18) }
                Text(profile.map { store.botCurrentName(for: $0) } ?? String(localized: "All"))
                    .font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(selected ? store.accent.primary(scheme).opacity(0.16) : Palette.card(scheme), in: .capsule)
            .overlay { Capsule().stroke(selected ? store.accent.primary(scheme).opacity(0.5) : Palette.border(scheme), lineWidth: 0.5) }
            .contentShape(.capsule)
            .frame(minHeight: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Opens where an action happened: a routine's page, a chat, or the receipt
/// of that moment — presented from Activity, which is itself a sheet.
@MainActor
@Observable
final class AgentActionOpener {
    var receipt: RichReceipt?
    var routine: JobRow?
    var notice: String?

    func open(_ action: AgentAction, store: AppStore, onOpenedChat: @escaping () -> Void) {
        if let key = action.routineKey, let slash = key.lastIndex(of: "/") {
            let profile = String(key[..<slash])
            let id = String(key[key.index(after: slash)...])
            Task {
                do {
                    if let found = try await store.routines(for: profile).first(where: { $0.id == id }) {
                        routine = found
                    } else if let session = action.session {
                        // The routine is gone; its run is still on record.
                        receipt = RichReceipt(profile: action.profile, session: session, at: action.at)
                    } else {
                        notice = String(localized: "That routine no longer exists.")
                    }
                } catch {
                    notice = PlainWords.describe(error, doing: "open the routine")
                }
            }
            return
        }
        let opened = store.openAction(action)
        if opened.openedChat {
            onOpenedChat()
        } else if let receipt = opened.receipt {
            self.receipt = receipt
        } else {
            notice = String(localized: "There is no conversation on record for this one.")
        }
    }

    struct Presenting: ViewModifier {
        @Environment(AppStore.self) private var store
        @Bindable var opener: AgentActionOpener
        let onOpenedChat: () -> Void

        func body(content: Content) -> some View {
            content
                .sheet(item: $opener.receipt) { receipt in
                    ReceiptSheet(receipt: receipt, onOpenedChat: onOpenedChat)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .preferredColorScheme(store.theme.colorScheme)
                }
                .sheet(item: $opener.routine) { routine in
                    RoutineDetailSheet(routine: routine) {}
                        .preferredColorScheme(store.theme.colorScheme)
                }
                .alert(
                    "Couldn’t open it",
                    isPresented: Binding(get: { opener.notice != nil }, set: { if !$0 { opener.notice = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(opener.notice ?? "")
                }
        }
    }
}
