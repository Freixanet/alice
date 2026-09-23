import SwiftUI

/// Which reminders a list screen shows: one of Reminders' smart lists, or one
/// of the person's own.
enum ReminderScope: Hashable, Identifiable {
    case today, scheduled, all, completed
    case list(String)

    var id: String {
        switch self {
        case .today: "today"
        case .scheduled: "scheduled"
        case .all: "all"
        case .completed: "completed"
        case let .list(id): "list:\(id)"
        }
    }
}

/// Reminders' first screen: the smart lists as tiles with their counts,
/// then "My Lists" with each list's colour and count, and "Add List".
struct ReminderListsScreen: View {
    let model: AgendaModel
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var addingList = false
    @State private var deleting: AgendaSource.ReminderList?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        tile(.today, "Today", systemImage: "calendar", color: .blue, count: todayCount)
                        tile(.scheduled, "Scheduled", systemImage: "calendar", color: .red, count: scheduledCount)
                        tile(.all, "All", systemImage: "tray.fill", color: Color(white: 0.35), count: model.reminders.count)
                        tile(.completed, "Completed", systemImage: "checkmark", color: .gray, count: nil)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(model.lists) { list in
                        NavigationLink(value: ReminderScope.list(list.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(list.color.map(AgendaStyle.color) ?? .blue, in: .circle)
                                Text(list.title)
                                Spacer()
                                Text("\(model.count(in: list.id))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .swipeActions {
                            if list.editable {
                                Button("Delete", role: .destructive) { deleting = list }
                            }
                        }
                    }
                } header: {
                    Text("My Lists")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
                .listRowBackground(Palette.card(scheme))

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle("Lists")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ReminderScope.self) { scope in
                ReminderScopeScreen(model: model, scope: scope)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Add List") { addingList = true }
                }
            }
            .sheet(isPresented: $addingList) {
                NewListSheet { addingList = false }
            }
            .confirmationDialog(
                deleting.map { String(localized: "Delete “\($0.title)”?") } ?? "",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete List and Its Reminders", role: .destructive) {
                    if let list = deleting {
                        do { try AgendaSource.deleteList(list.id) } catch {
                            problem = String(localized: "That list could not be deleted.")
                        }
                    }
                    deleting = nil
                }
            }
        }
    }

    private var todayCount: Int {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return model.reminders.filter { ($0.start.map { $0 < end }) ?? false }.count
    }

    private var scheduledCount: Int { model.reminders.filter { $0.start != nil }.count }

    /// Reminders' tile: the symbol in a coloured circle and the count on top,
    /// the name under it.
    private func tile(_ scope: ReminderScope, _ title: LocalizedStringKey, systemImage: String,
                      color: Color, count: Int?) -> some View {
        NavigationLink(value: scope) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(color, in: .circle)
                    Spacer()
                    if let count {
                        Text("\(count)")
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// One list, smart or the person's: its title large in its colour, its
/// reminders, and "New Reminder" at the bottom, as in Reminders.
struct ReminderScopeScreen: View {
    let model: AgendaModel
    let scope: ReminderScope

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage("agenda.showCompleted") private var showCompleted = false
    @State private var composing: AgendaSource.ReminderDraft?
    @FocusState private var composeFocused: Bool
    @State private var ticking: Set<String> = []
    @State private var details: (identifier: String?, draft: AgendaSource.ReminderDraft)?
    @State private var choosingPlace = false
    @State private var problem: String?

    private var listInfo: AgendaSource.ReminderList? {
        if case let .list(id) = scope { return model.list(id) }
        return nil
    }

    private var title: String {
        switch scope {
        case .today: String(localized: "Today")
        case .scheduled: String(localized: "Scheduled")
        case .all: String(localized: "All")
        case .completed: String(localized: "Completed")
        case .list: listInfo?.title ?? ""
        }
    }

    private var color: Color {
        switch scope {
        case .today: .blue
        case .scheduled: .red
        case .all: .primary
        case .completed: .gray
        case .list: listInfo?.color.map(AgendaStyle.color) ?? .blue
        }
    }

    /// Sections of reminders: by day for Scheduled, by list for All, one
    /// section otherwise.
    private var sections: [(title: String?, items: [AgendaItem])] {
        let calendar = Calendar.current
        let now = Date()
        let open = model.reminders
        switch scope {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return [(nil, open.filter { ($0.start.map { $0 < end }) ?? false }.sorted(by: byDue))]
        case .scheduled:
            let dated = open.filter { $0.start != nil }.sorted(by: byDue)
            let groups = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.start!) }
            return groups.keys.sorted().map { day in
                (AgendaStyle.when(day, allDay: true, now: now), groups[day]!)
            }
        case .all:
            return model.lists.compactMap { list in
                let items = open.filter { $0.list == list.id }
                return items.isEmpty ? nil : (list.title, items.sorted(by: byDue))
            }
        case .completed:
            return [(nil, model.completed)]
        case let .list(id):
            var items = open.filter { $0.list == id }.sorted(by: byDue)
            if showCompleted { items += model.completed.filter { $0.list == id } }
            return [(nil, items)]
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            List {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(color)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.items) { item in
                            AgendaItemRow(item: item, now: context.date, showsTime: false,
                                          showsDate: scope != .scheduled, ticked: ticking.contains(item.id)) {
                                tick(item)
                            }
                            .contentShape(.rect)
                            .onTapGesture { open(item) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(item) }
                            }
                        }
                    } header: {
                        if let header = section.title {
                            Text(header)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if composing != nil {
                    ReminderComposer(
                        draft: Binding(get: { composing ?? .init() }, set: { composing = $0 }),
                        lists: model.lists, focused: $composeFocused,
                        onSubmit: commit,
                        onDetails: {
                            details = (nil, composing ?? .init())
                            composing = nil
                        },
                        onPlace: { choosingPlace = true }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if sections.allSatisfy(\.items.isEmpty) && composing == nil {
                    ContentUnavailableView(scope == .completed ? "No Completed Reminders" : "No Reminders",
                                           systemImage: "checklist")
                        .listRowBackground(Color.clear)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .list = scope {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: $showCompleted) { Label("Show Completed", systemImage: "eye") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            if scope != .completed {
                ToolbarItem(placement: .bottomBar) {
                    Button { start() } label: {
                        Label("New Reminder", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(color == .primary ? store.accent.primary(scheme) : color)
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
        }
        .task {
            if scope == .completed || showCompleted { await model.loadCompleted() }
        }
        .onChange(of: showCompleted) { _, on in if on { Task { await model.loadCompleted() } } }
        .onChange(of: composeFocused) { _, focused in
            guard !focused, composing != nil else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                if !composeFocused { finish() }
            }
        }
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            if let details {
                ReminderDetailsSheet(identifier: details.identifier, draft: details.draft, lists: model.lists) { saved in
                    self.details = nil
                    if saved { Task { await model.reload() } }
                }
            }
        }
        .sheet(isPresented: $choosingPlace) {
            PlaceSearch { place in
                if let place { composing?.place = place }
                choosingPlace = false
                composeFocused = true
            }
        }
    }

    // MARK: Writing

    private func start() {
        var draft = AgendaSource.ReminderDraft()
        switch scope {
        case .today, .scheduled: ReminderDates.set(&draft, dayOffset: 0)
        case let .list(id): draft.list = id
        default: break
        }
        composing = draft
        composeFocused = true
    }

    private func commit() {
        guard let draft = composing else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            composing = nil
            return
        }
        if save(draft) {
            var next = AgendaSource.ReminderDraft()
            next.due = draft.due
            next.hasTime = draft.hasTime
            next.list = draft.list
            composing = next
            composeFocused = true
        }
    }

    private func finish() {
        guard let draft = composing else { return }
        composing = nil
        if !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = save(draft) }
    }

    private func save(_ draft: AgendaSource.ReminderDraft) -> Bool {
        do {
            try AgendaSource.save(draft)
            problem = nil
            Task { await model.reload() }
            return true
        } catch {
            problem = String(localized: "That reminder could not be saved.")
            return false
        }
    }

    private func tick(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind else { return }
        do {
            try AgendaSource.setCompleted(identifier, !item.completed)
            withAnimation(.snappy(duration: 0.2)) { _ = ticking.insert(item.id) }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                ticking.remove(item.id)
                await model.reload()
            }
        } catch {
            problem = String(localized: "That reminder could not be completed.")
        }
    }

    private func open(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind,
              let draft = AgendaSource.draft(of: identifier) else { return }
        details = (identifier, draft)
    }

    private func delete(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind else { return }
        try? AgendaSource.delete(identifier)
        Task { await model.reload() }
    }

    private func byDue(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        switch (a.start, b.start) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.title.localizedCompare(b.title) == .orderedAscending
        }
    }
}

/// A new list: its name and one of Reminders' colours.
struct NewListSheet: View {
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var color = NewListSheet.colors[5]
    @State private var problem: String?

    static let colors: [AgendaColor] = [
        .init(red: 1.00, green: 0.23, blue: 0.19), .init(red: 1.00, green: 0.58, blue: 0.00),
        .init(red: 1.00, green: 0.80, blue: 0.00), .init(red: 0.20, green: 0.78, blue: 0.35),
        .init(red: 0.35, green: 0.78, blue: 0.98), .init(red: 0.00, green: 0.48, blue: 1.00),
        .init(red: 0.35, green: 0.34, blue: 0.84), .init(red: 1.00, green: 0.18, blue: 0.33),
        .init(red: 0.69, green: 0.32, blue: 0.87), .init(red: 0.64, green: 0.52, blue: 0.37),
        .init(red: 0.56, green: 0.56, blue: 0.58), .init(red: 0.85, green: 0.65, blue: 0.60),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(AgendaStyle.color(color), in: .circle)
                        TextField("List Name", text: $name)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AgendaStyle.color(color))
                            .padding(.vertical, 10)
                            .background(Palette.muted(scheme), in: .rect(cornerRadius: 10))
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(Self.colors, id: \.self) { option in
                            Button { color = option } label: {
                                Circle()
                                    .fill(AgendaStyle.color(option))
                                    .frame(width: 36, height: 36)
                                    .padding(3)
                                    .overlay {
                                        if option == color {
                                            Circle().strokeBorder(Color.secondary, lineWidth: 2.5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        do {
                            try AgendaSource.createList(title: name, color: color)
                            onDone()
                        } catch {
                            problem = String(localized: "That list could not be created.")
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
