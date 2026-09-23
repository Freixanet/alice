import EventKit
import SwiftUI
import UIKit

/// Calendar and Reminders as one page, the way iOS 18 began to join them:
/// the week strip or the month on top, then the chosen day's hours (Day),
/// everything ahead by day with the to-dos after it (List), or the month
/// with the chosen day under it (Month). Reminders sit among the events,
/// ticked where they are; "+" adds either; "Lists" is Reminders' own first
/// screen. Everything is the phone's own Calendar and Reminders — it syncs
/// wherever they do, and nothing here goes to Hermes.
struct AgendaScreen: View {
    var onClose: () -> Void = {}

    enum Mode: String, CaseIterable, Identifiable {
        case day, list, month
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .day: "Day"
            case .list: "List"
            case .month: "Month"
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = AgendaModel()
    @AppStorage("agenda.mode") private var modeRaw = Mode.list.rawValue
    @State private var selected = Date()
    @State private var ticking: Set<String> = []
    @State private var problem: String?

    @State private var composing: AgendaSource.ReminderDraft?
    @FocusState private var composeFocused: Bool
    @State private var details: DetailsTarget?
    @State private var openedEvent: OpenedEvent?
    @State private var newEvent: NewEvent?
    @State private var showingLists = false
    @State private var searching = false
    @State private var choosingPlace = false

    fileprivate struct DetailsTarget: Identifiable {
        let id = UUID()
        let identifier: String?
        let draft: AgendaSource.ReminderDraft
    }

    fileprivate struct OpenedEvent: Identifiable {
        let id: String
        let start: Date?
    }

    fileprivate struct NewEvent: Identifiable {
        let id = UUID()
        let start: Date?
    }

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .list }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { composer }
        .animation(.snappy(duration: 0.25), value: composing == nil)
        .task { await load(fresh: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(fresh: false) } }
        }
        .onChange(of: selected) { _, day in Task { await model.look(at: day) } }
        .onChange(of: model.events.count + model.reminders.count) { store.noteCommitments(model.all) }
        .onChange(of: composeFocused) { _, focused in leftComposer(focused) }
        .modifier(AgendaSheets(
            model: model, details: $details, openedEvent: $openedEvent, newEvent: $newEvent,
            showingLists: $showingLists, searching: $searching, choosingPlace: $choosingPlace,
            composing: $composing, composeFocused: $composeFocused, onOpen: open
        ))
    }

    @ViewBuilder
    private var composer: some View {
        if composing != nil {
            ReminderComposer(
                draft: Binding(get: { composing ?? .init() }, set: { composing = $0 }),
                lists: model.lists, focused: $composeFocused,
                onSubmit: commitDraft,
                onDetails: {
                    details = DetailsTarget(identifier: nil, draft: composing ?? .init())
                    composing = nil
                },
                onPlace: { choosingPlace = true }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(now: Date) -> some View {
        if model.loaded && !model.hasCalendar && !model.hasReminders {
            noAccess
        } else {
            VStack(spacing: 0) {
                Text(Agenda.dayTitle(selected))
                    .font(.aliceTitle(.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                if mode == .month {
                    AgendaMonthGrid(selected: $selected, hasItems: { model.hasItems(on: $0) }, now: now)
                        .padding(.bottom, 6)
                } else {
                    AgendaWeekStrip(selected: $selected, hasItems: { model.hasItems(on: $0) }, now: now)
                }
                Divider()
                modeContent(now: now)
            }
        }
    }

    @ViewBuilder
    private func modeContent(now: Date) -> some View {
        switch mode {
        case .day:
            AgendaDayView(
                day: selected, items: model.items(on: selected, now: now), now: now, ticking: ticking,
                onOpen: open, onTick: tick, onNewEvent: { start in Task { await startEvent(start) } }
            )
        case .list:
            AgendaListContent(model: model, selected: selected, now: now, ticking: ticking,
                              problem: problem, onOpen: open, onTick: tick)
        case .month:
            dayList(now: now)
        }
    }

    private var noAccess: some View {
        let refused = CalendarSync.refused && AgendaSource.remindersRefused
        return ContentUnavailableView {
            Label("Calendar and Reminders", systemImage: "calendar")
        } description: {
            Text(refused
                 ? "Access is off for Alice. Turn on Calendars and Reminders in Settings › Alice."
                 : "Alice shows your calendars and reminders from this iPhone, and adds to them when you ask.")
        } actions: {
            Button(refused ? "Open Settings" : "Allow Access") {
                Task { await allowAccess() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("agenda.connect")
        }
    }

    /// Under the month: the chosen day, as a list.
    private func dayList(now: Date) -> some View {
        let items = model.items(on: selected, now: now).sorted {
            ($0.allDay ? 0 : 1, $0.start ?? .distantPast) < ($1.allDay ? 0 : 1, $1.start ?? .distantPast)
        }
        return List {
            if items.isEmpty {
                Text("Nothing on this day")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                AgendaItemRow(item: item, now: now, ticked: ticking.contains(item.id)) { tick(item) }
                    .contentShape(.rect)
                    .onTapGesture { open(item) }
                    .listRowBackground(Palette.card(scheme))
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onClose) { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("agenda.back")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $modeRaw) {
                ForEach(Mode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .accessibilityIdentifier("agenda.mode")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search")
        }

        ToolbarItem(placement: .bottomBar) {
            Button("Today") {
                withAnimation(.snappy) { selected = Date() }
            }
            .accessibilityIdentifier("agenda.today")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button {
                Task { if await remindersReady() { showingLists = true } }
            } label: {
                Label("Lists", systemImage: "list.bullet")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("agenda.lists")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button { Task { await startComposing() } } label: {
                    Label("New Reminder", systemImage: "checklist")
                }
                Button { Task { await startEvent(nil) } } label: {
                    Label("New Event", systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
            .accessibilityIdentifier("agenda.add")
        }
    }

    // MARK: Opening and ticking

    private func open(_ item: AgendaItem) {
        switch item.kind {
        case let .event(identifier, _):
            guard AgendaSource.event(identifier, starting: item.start) != nil else {
                problem = String(localized: "That event is no longer in your calendar.")
                return
            }
            openedEvent = OpenedEvent(id: identifier, start: item.start)
        case let .reminder(identifier, _):
            guard let draft = AgendaSource.draft(of: identifier) else {
                problem = String(localized: "That reminder is no longer in Reminders.")
                return
            }
            details = DetailsTarget(identifier: identifier, draft: draft)
        case .alice:
            // Where Alice will write when the time comes.
            onClose()
            store.openToday()
        }
    }

    private func tick(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind, !ticking.contains(item.id) else { return }
        do {
            try AgendaSource.setCompleted(identifier, true)
            problem = nil
            withAnimation(.snappy(duration: 0.2)) { _ = ticking.insert(item.id) }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                await model.reload()
                ticking.remove(item.id)
            }
        } catch {
            problem = String(localized: "That reminder could not be completed.")
        }
    }

    // MARK: Writing

    /// Reminders has its own permission; asking for it here is asking for
    /// what the person is about to do.
    private func remindersReady() async -> Bool {
        if AgendaSource.remindersAllowed { return true }
        if AgendaSource.remindersRefused {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return false
        }
        let granted = await AgendaSource.requestReminders()
        await model.reload()
        return granted
    }

    private func startComposing() async {
        guard await remindersReady() else { return }
        var draft = AgendaSource.ReminderDraft()
        // On the day being looked at, as Calendar's new reminder does; in the
        // list view, today.
        let calendar = Calendar.current
        let day = mode == .list ? Date() : selected
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                             to: calendar.startOfDay(for: day)).day ?? 0
        ReminderDates.set(&draft, dayOffset: offset)
        composing = draft
        composeFocused = true
    }

    private func startEvent(_ start: Date?) async {
        if !CalendarSync.hasAccess {
            guard !CalendarSync.refused else {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                return
            }
            _ = await CalendarSync.requestAccess()
            await model.reload()
        }
        guard CalendarSync.hasAccess else { return }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date()) + 1
        newEvent = NewEvent(start: start ?? calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: selected))
    }

    /// Return: this one is saved and the next box opens, same day and list.
    private func commitDraft() {
        guard let draft = composing else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            composing = nil
            composeFocused = false
            return
        }
        if saveDraft(draft) {
            var next = AgendaSource.ReminderDraft()
            next.due = draft.due
            next.hasTime = draft.hasTime
            next.list = draft.list
            composing = next
            composeFocused = true
        }
    }

    /// Leaving the box keeps what was typed, as Reminders does. Return hands
    /// the focus straight to the next one, and a picker takes it for a
    /// moment, so a brief loss of it is not leaving.
    private func leftComposer(_ focused: Bool) {
        guard !focused, composing != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !composeFocused, !choosingPlace, details == nil { finishDraft() }
        }
    }

    private func finishDraft() {
        guard let draft = composing else { return }
        composing = nil
        if !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = saveDraft(draft) }
    }

    private func saveDraft(_ draft: AgendaSource.ReminderDraft) -> Bool {
        do {
            try AgendaSource.save(draft)
            problem = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await model.reload() }
            return true
        } catch {
            problem = String(localized: "That reminder could not be saved.")
            return false
        }
    }

    // MARK: Loading

    private func allowAccess() async {
        if CalendarSync.refused && AgendaSource.remindersRefused {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        await model.requestAccess()
    }

    private func load(fresh: Bool) async {
        await model.reload()
        store.noteCommitments(model.all)
        // Alice's own promises come from Hermes; the page never waits on them.
        if fresh || model.fromAlice.isEmpty, let routines = try? await store.allRoutines() {
            model.setAlice(Agenda.aliceReminders(routines.values.flatMap { $0 }, now: Date()))
        }
    }
}

/// The agenda's sheets, apart so the page's body stays small enough to
/// type-check.
private struct AgendaSheets: ViewModifier {
    let model: AgendaModel
    @Binding var details: AgendaScreen.DetailsTarget?
    @Binding var openedEvent: AgendaScreen.OpenedEvent?
    @Binding var newEvent: AgendaScreen.NewEvent?
    @Binding var showingLists: Bool
    @Binding var searching: Bool
    @Binding var choosingPlace: Bool
    @Binding var composing: AgendaSource.ReminderDraft?
    var composeFocused: FocusState<Bool>.Binding
    let onOpen: (AgendaItem) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $details) { target in
                ReminderDetailsSheet(identifier: target.identifier, draft: target.draft, lists: model.lists) { saved in
                    details = nil
                    if saved { Task { await model.reload() } }
                }
            }
            .sheet(item: $openedEvent) { event in
                EventDetail(identifier: event.id, start: event.start) { openedEvent = nil }
                    .ignoresSafeArea()
            }
            .sheet(item: $newEvent) { event in
                NewEventSheet(start: event.start) { newEvent = nil }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showingLists, onDismiss: { Task { await model.reload() } }) {
                ReminderListsScreen(model: model) { showingLists = false }
            }
            .sheet(isPresented: $searching) {
                AgendaSearch(model: model) { item in
                    searching = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        onOpen(item)
                    }
                }
            }
            .sheet(isPresented: $choosingPlace) {
                PlaceSearch { place in
                    if let place { composing?.place = place }
                    choosingPlace = false
                    composeFocused.wrappedValue = true
                }
            }
    }
}

/// The list view: overdue reminders, then each day from today with its
/// events and reminders, then the to-dos with no date. Choosing a day in the
/// strip scrolls to it.
struct AgendaListContent: View {
    let model: AgendaModel
    let selected: Date
    let now: Date
    let ticking: Set<String>
    var problem: String?
    let onOpen: (AgendaItem) -> Void
    let onTick: (AgendaItem) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let days = Agenda.days(model.all, now: now)
        ScrollViewReader { proxy in
            List {
                if model.loaded && days.isEmpty {
                    ContentUnavailableView("Nothing in the next two weeks", systemImage: "calendar",
                                           description: Text("New events and reminders appear here on their own."))
                        .listRowBackground(Color.clear)
                }
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            AgendaItemRow(item: item, now: now, showsTime: day.label != .someday,
                                          ticked: ticking.contains(item.id)) { onTick(item) }
                                .contentShape(.rect)
                                .onTapGesture { onOpen(item) }
                        }
                    } header: {
                        header(day.label)
                    }
                    .id(day.id)
                    .listRowBackground(Palette.card(scheme))
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .onChange(of: selected) { _, day in
                let id = "d\(Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970))"
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func header(_ label: AgendaDay.Label) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title(label))
                .font(.headline)
                .foregroundStyle(label == .overdue ? Color.red : .primary)
            if let date = subtitle(label) {
                Text(date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }

    private func title(_ label: AgendaDay.Label) -> String {
        switch label {
        case .overdue: String(localized: "Overdue")
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case let .day(date): Agenda.weekday(date)
        case .someday: String(localized: "To-dos")
        }
    }

    private func subtitle(_ label: AgendaDay.Label) -> String? {
        let calendar = Calendar.current
        switch label {
        case let .day(date): return date.formatted(.dateTime.day().month(.abbreviated))
        case .today: return now.formatted(.dateTime.day().month(.abbreviated))
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: now)?.formatted(.dateTime.day().month(.abbreviated))
        default: return nil
        }
    }
}

/// Searching everything the agenda holds, as Calendar and Reminders search:
/// titles, notes and places.
struct AgendaSearch: View {
    let model: AgendaModel
    let onPick: (AgendaItem) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var found: [AgendaItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return (model.all + model.completed)
            .filter {
                $0.title.localizedStandardContains(needle)
                    || ($0.notes?.localizedStandardContains(needle) ?? false)
                    || ($0.location?.localizedStandardContains(needle) ?? false)
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            List(found) { item in
                AgendaItemRow(item: item, now: Date(), showsTime: false, showsDate: true)
                    .contentShape(.rect)
                    .onTapGesture { onPick(item) }
                    .listRowBackground(Palette.card(scheme))
            }
            .overlay {
                if !query.isEmpty && found.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .aliceFormPaper(scheme)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Events and reminders")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
