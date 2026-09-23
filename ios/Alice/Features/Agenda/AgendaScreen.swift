import EventKit
import EventKitUI
import SwiftUI
import UIKit

/// The person's commitments, from today to two weeks ahead, day by day — and,
/// when they include Reminders, their open to-dos.
///
/// Built from the system's own parts, as Calendar and Reminders are: a list,
/// section headers, a time column, the calendar's colour as a dot. What is
/// next says so in its own row rather than in a card of its own.
///
/// Everything is read on the phone. Nothing is sent to Hermes from this page,
/// and nothing is changed except a reminder the person ticks off.
struct AgendaScreen: View {
    var onClose: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("agenda.includeReminders") private var includeReminders = false
    @State private var local: [AgendaItem] = []
    @State private var fromAlice: [AgendaItem] = []
    @State private var loaded = false
    @State private var hasCalendar = CalendarSync.hasAccess
    /// Ticked a moment ago: shown checked, then gone.
    @State private var ticking: Set<String> = []
    @State private var ticked: Set<String> = []
    @State private var opened: OpenedEvent?
    @State private var problem: String?

    private struct OpenedEvent: Identifiable {
        let id: String
        let start: Date?
    }

    private var items: [AgendaItem] {
        (local + fromAlice).filter { !ticked.contains($0.id) }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let days = Agenda.days(items, now: now)
            let next = Agenda.next(items, now: now)?.id
            List {
                Text(Agenda.dayTitle(now))
                    .font(.aliceTitle(.largeTitle))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)

                if !hasCalendar && local.isEmpty {
                    noAccess
                        .listRowBackground(Color.clear)
                } else if loaded && days.isEmpty {
                    ContentUnavailableView(
                        "Nothing in the next two weeks",
                        systemImage: "calendar",
                        description: Text("New events in your calendar appear here on their own.")
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            AgendaRow(
                                item: item, now: now, overdue: day.label == .overdue,
                                isNext: item.id == next, ticked: ticking.contains(item.id),
                                onTick: { tick(item) }
                            )
                            .contentShape(.rect)
                            .onTapGesture { open(item) }
                            .swipeActions(edge: .trailing) {
                                if item.isReminder {
                                    Button("Complete") { tick(item) }
                                        .tint(Palette.success(scheme))
                                }
                            }
                        }
                    } header: {
                        header(day.label)
                    }
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
            .animation(.snappy(duration: 0.3), value: items.map(\.id))
        }
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Agenda")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("agenda.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { includeReminders && AgendaSource.remindersAllowed },
                        set: { on in Task { await setReminders(on) } }
                    )) {
                        Label("Show Reminders", systemImage: "checklist")
                    }
                    Button {
                        openURL(URL(string: "calshow:\(Date().timeIntervalSinceReferenceDate)")!)
                    } label: {
                        Label("Open Calendar", systemImage: "calendar")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Agenda options")
                .accessibilityIdentifier("agenda.options")
            }
        }
        .refreshable { await load(fresh: true) }
        .task { await load(fresh: false) }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await load(fresh: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(fresh: false) } }
        }
        .sheet(item: $opened) { event in
            EventDetail(identifier: event.id, start: event.start) { opened = nil }
                .ignoresSafeArea()
        }
    }

    // MARK: Parts

    private func header(_ label: AgendaDay.Label) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title(of: label))
                .font(.headline)
                .foregroundStyle(label == .overdue ? Palette.danger(scheme) : .primary)
            if let date = subtitle(of: label) {
                Text(date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }

    private func title(of label: AgendaDay.Label) -> String {
        switch label {
        case .overdue: String(localized: "Overdue")
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case let .day(date): Agenda.weekday(date)
        case .someday: String(localized: "No date")
        }
    }

    private func subtitle(of label: AgendaDay.Label) -> String? {
        let calendar = Calendar.current
        switch label {
        case let .day(date): return date.formatted(.dateTime.day().month(.abbreviated))
        case .today: return Date().formatted(.dateTime.day().month(.abbreviated))
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: Date())?.formatted(.dateTime.day().month(.abbreviated))
        default: return nil
        }
    }

    private var noAccess: some View {
        ContentUnavailableView {
            Label("Your calendar", systemImage: "calendar")
        } description: {
            Text(CalendarSync.refused
                 ? "Calendar access is off for Alice. Turn it on in Settings › Alice › Calendars."
                 : "Alice shows the next two weeks from the calendars on this iPhone. She changes nothing.")
        } actions: {
            Button(CalendarSync.refused ? "Open Settings" : "Allow Access") {
                Task { await connect() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agenda.connect")
        }
    }

    // MARK: Actions

    private func setReminders(_ on: Bool) async {
        guard on else {
            includeReminders = false
            await load(fresh: false)
            return
        }
        if AgendaSource.remindersRefused {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        guard await AgendaSource.requestReminders() else { return }
        includeReminders = true
        await load(fresh: false)
    }

    private func tick(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind, !ticking.contains(item.id) else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        do {
            try AgendaSource.complete(identifier)
            problem = nil
            withAnimation(.snappy(duration: 0.2)) { _ = ticking.insert(item.id) }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.snappy(duration: 0.3)) {
                    _ = ticked.insert(item.id)
                    _ = ticking.remove(item.id)
                }
            }
        } catch {
            problem = String(localized: "That reminder could not be completed.")
        }
    }

    private func open(_ item: AgendaItem) {
        switch item.kind {
        case let .event(identifier, _):
            guard AgendaSource.event(identifier, starting: item.start) != nil else {
                problem = String(localized: "That event is no longer in your calendar.")
                return
            }
            opened = OpenedEvent(id: identifier, start: item.start)
        case .reminder:
            if let url = URL(string: "x-apple-reminderkit://") { openURL(url) }
        case .alice:
            // Where Alice will write when the time comes.
            onClose()
            store.openToday()
        }
    }

    private func connect() async {
        if CalendarSync.refused {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        hasCalendar = await CalendarSync.requestAccess()
        await load(fresh: false)
    }

    private func load(fresh: Bool) async {
        hasCalendar = CalendarSync.hasAccess
        var found = AgendaSource.events()
        if includeReminders { found += await AgendaSource.reminders() }
        local = found
        loaded = true
        store.noteCommitments(found)
        // Alice's own promises come from Hermes; the page never waits on them.
        if fresh || fromAlice.isEmpty, let routines = try? await store.allRoutines() {
            fromAlice = Agenda.aliceReminders(routines.values.flatMap { $0 }, now: Date())
        }
    }
}

// MARK: - Row

/// Time, a dot in the calendar's colour, the title and where. The next thing
/// says how soon on the right; what is under way says "Now".
private struct AgendaRow: View {
    let item: AgendaItem
    let now: Date
    let overdue: Bool
    let isNext: Bool
    let ticked: Bool
    let onTick: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            time
                .frame(width: 54, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(item.isPast(now) || ticked ? .secondary : .primary)
                        .strikethrough(ticked, color: .secondary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if item.isNow(now) {
                Text("Now")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(store.accent.primary(scheme))
            } else if isNext, let start = item.start {
                Text(Agenda.countdown(to: start, now: now))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var time: some View {
        let style: Color = item.isPast(now) ? .secondary : .primary
        if item.start == nil {
            Text(" ")
        } else if item.allDay {
            Text("All day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let start = item.start {
            VStack(alignment: .leading, spacing: 1) {
                Text(overdue
                     ? start.formatted(.dateTime.day().month(.abbreviated))
                     : start.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(overdue ? Palette.danger(scheme) : style)
                if !overdue, let end = item.end, end > start {
                    Text(end.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch item.kind {
        case let .event(_, color):
            Circle()
                .fill(Self.color(color, fallback: store.accent.primary(scheme)))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        case let .reminder(_, color):
            Button(action: onTick) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(ticked ? Self.color(color, fallback: store.accent.primary(scheme)) : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete")
        case .alice:
            Image(systemName: "bell")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var detail: String? {
        if item.isAlice { return String(localized: "Alice will write to you") }
        return item.location
    }

    private static func color(_ color: AgendaColor?, fallback: Color) -> Color {
        color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? fallback
    }
}

// MARK: - Event detail

/// iOS's own event page: details, alerts, travel time, and its edit and delete.
private struct EventDetail: UIViewControllerRepresentable {
    let identifier: String
    let start: Date?
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = EKEventViewController()
        controller.event = AgendaSource.event(identifier, starting: start)
        controller.allowsEditing = true
        controller.allowsCalendarPreview = true
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, EKEventViewDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
            onDone()
        }
    }
}
