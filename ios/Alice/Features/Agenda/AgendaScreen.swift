import EventKit
import EventKitUI
import SwiftUI
import UIKit

/// The person's commitments, from now to two weeks ahead: what is next, then
/// each day, then — when they include Reminders — their open to-dos.
///
/// Everything here is read on the phone. Calendar events come from every
/// account iOS holds; nothing is sent to Hermes from this page, and nothing is
/// changed except a reminder the person ticks off.
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
    @State private var ticked: Set<String> = []
    @State private var opened: OpenedEvent?
    @State private var problem: String?

    private struct OpenedEvent: Identifiable {
        let id: String
        let start: Date?
    }

    private var items: [AgendaItem] {
        (local + fromAlice).filter { !ticked.contains($0.id) || isTicking($0.id) }
    }

    /// Ticked a moment ago: still shown, filled, before it goes.
    @State private var ticking: Set<String> = []
    private func isTicking(_ id: String) -> Bool { ticking.contains(id) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let days = Agenda.days(items, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(now: now, days: days)
                    if !hasCalendar && local.isEmpty {
                        ConnectCalendarCard(refused: CalendarSync.refused) { await connect() }
                    } else {
                        if let next = current(items, now: now) ?? Agenda.next(items, now: now) {
                            NextCard(item: next, now: now) { open(next) }
                        }
                        ForEach(days) { day in
                            daySection(day, now: now)
                        }
                        if loaded && days.isEmpty {
                            nothingAhead
                        }
                    }
                    remindersChoice
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger(scheme))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .animation(.snappy(duration: 0.3), value: items.map(\.id))
            }
            .scrollIndicators(.hidden)
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
                Button {
                    openURL(URL(string: "calshow:\(Date().timeIntervalSinceReferenceDate)")!)
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Open Calendar")
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
        .onChange(of: includeReminders) { Task { await load(fresh: false) } }
        .sheet(item: $opened) { event in
            EventDetail(identifier: event.id, start: event.start) { opened = nil }
                .ignoresSafeArea()
        }
    }

    // MARK: Header

    private func header(now: Date, days: [AgendaDay]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst)
                .font(.aliceTitle(.largeTitle))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(summary(now: now, days: days))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func summary(now: Date, days: [AgendaDay]) -> String {
        guard hasCalendar || !local.isEmpty else { return String(localized: "Your commitments, at a glance.") }
        let today = days.first { $0.label == .today }?.items.filter { !$0.isPast(now) } ?? []
        switch today.count {
        case 0: return String(localized: "Nothing left today.")
        case 1: return String(localized: "One more thing today.")
        default: return String(localized: "\(today.count) more things today.")
        }
    }

    /// Something under way: it comes before what is next.
    private func current(_ items: [AgendaItem], now: Date) -> AgendaItem? {
        items.first { $0.isNow(now) }
    }

    // MARK: Days

    private func daySection(_ day: AgendaDay, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(of: day.label))
                    .font(.headline)
                    .foregroundStyle(day.label == .overdue ? Palette.danger(scheme) : .primary)
                if let date = subtitle(of: day.label) {
                    Text(date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 76)
                    }
                    AgendaRow(
                        item: item, now: now, overdue: day.label == .overdue,
                        ticked: ticking.contains(item.id),
                        onTick: { tick(item) },
                        onOpen: { open(item) }
                    )
                }
            }
            .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Palette.border(scheme).opacity(0.5), lineWidth: 0.5)
            }
        }
    }

    private func title(of label: AgendaDay.Label) -> String {
        switch label {
        case .overdue: String(localized: "Overdue")
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case let .day(date): date.formatted(.dateTime.weekday(.wide)).capitalizedFirst
        case .someday: String(localized: "No date")
        }
    }

    private func subtitle(of label: AgendaDay.Label) -> String? {
        switch label {
        case let .day(date): date.formatted(.dateTime.day().month(.abbreviated))
        case .today: Date().formatted(.dateTime.day().month(.abbreviated))
        case .tomorrow: Calendar.current.date(byAdding: .day, value: 1, to: Date())?
            .formatted(.dateTime.day().month(.abbreviated))
        default: nil
        }
    }

    private var nothingAhead: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing in the next two weeks")
                .font(.headline)
            Text("New events in your calendar appear here on their own.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: Reminders

    @ViewBuilder
    private var remindersChoice: some View {
        if !includeReminders || !AgendaSource.remindersAllowed {
            Button {
                Task { await includeRemindersNow() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(store.accent.primary(scheme))
                        .frame(width: 36, height: 36)
                        .background(store.accent.primary(scheme).opacity(0.12), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Reminders")
                            .font(.subheadline.weight(.medium))
                        Text(AgendaSource.remindersRefused
                             ? "Turn on Reminders for Alice in Settings."
                             : "Your open to-dos, next to your events.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(store.accent.primary(scheme))
                }
                .padding(14)
                .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agenda.includeReminders")
        }
    }

    private func includeRemindersNow() async {
        if AgendaSource.remindersRefused {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        guard await AgendaSource.requestReminders() else { return }
        includeReminders = true
        await load(fresh: false)
    }

    private func tick(_ item: AgendaItem) {
        guard case let .reminder(identifier, _) = item.kind else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.snappy(duration: 0.25)) { _ = ticking.insert(item.id) }
        do {
            try AgendaSource.complete(identifier)
            problem = nil
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.snappy(duration: 0.3)) {
                    ticked.insert(item.id)
                    ticking.remove(item.id)
                }
            }
        } catch {
            ticking.remove(item.id)
            problem = String(localized: "That reminder could not be completed.")
        }
    }

    // MARK: Opening

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

    // MARK: Loading

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

// MARK: - Next

private struct NextCard: View {
    let item: AgendaItem
    let now: Date
    let onOpen: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(item.isNow(now) ? "HAPPENING NOW" : "UP NEXT")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let start = item.start, !item.isNow(now) {
                        Text(Agenda.countdown(to: start, now: now))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(store.accent.primary(scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(store.accent.primary(scheme).opacity(0.14), in: .capsule)
                    }
                }
                Text(item.title)
                    .font(.aliceTitle(.title))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                VStack(alignment: .leading, spacing: 6) {
                    Label(when, systemImage: item.isAlice ? "sparkles" : "clock")
                    if let location = item.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Palette.card(scheme))
                    .overlay(alignment: .leading) {
                        // The calendar's own colour, as a quiet edge.
                        Rectangle()
                            .fill(tint)
                            .frame(width: 4)
                    }
                    .clipShape(.rect(cornerRadius: 24))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 18, y: 8)
            }
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agenda.next")
    }

    private var tint: Color {
        AgendaRow.color(of: item, accent: store.accent.primary(scheme))
    }

    private var when: String {
        guard let start = item.start else { return "" }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(start) ? String(localized: "Today")
            : calendar.isDateInTomorrow(start) ? String(localized: "Tomorrow")
            : start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).capitalizedFirst
        let from = start.formatted(date: .omitted, time: .shortened)
        if item.isAlice { return String(localized: "\(day), \(from) · Alice will write to you") }
        guard let end = item.end, end > start else { return "\(day), \(from)" }
        return "\(day), \(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Row

private struct AgendaRow: View {
    let item: AgendaItem
    let now: Date
    let overdue: Bool
    let ticked: Bool
    let onTick: () -> Void
    let onOpen: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            time
                .frame(width: 52, alignment: .leading)
            marker
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .strikethrough(ticked)
                        .lineLimit(2)
                    if item.isNow(now) {
                        Text("Now")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.color(of: item, accent: store.accent.primary(scheme)), in: .capsule)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(overdue ? Palette.danger(scheme) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(item.isPast(now) || ticked ? 0.45 : 1)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Complete")) { if item.isReminder { onTick() } }
    }

    @ViewBuilder
    private var time: some View {
        if item.allDay || item.start == nil {
            Text(item.start == nil ? "—" : String(localized: "All day"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        } else if let start = item.start {
            VStack(alignment: .leading, spacing: 1) {
                Text(overdue ? start.formatted(.dateTime.day().month(.abbreviated)) : start.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .monospacedDigit()
                if !overdue, let end = item.end, end > start, !item.isReminder {
                    Text(end.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        let tint = Self.color(of: item, accent: store.accent.primary(scheme))
        switch item.kind {
        case .event:
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .frame(minHeight: 32)
        case .reminder:
            Button(action: onTick) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ticked ? tint : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete")
        case .alice:
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 24)
        }
    }

    private var detail: String? {
        if item.isAlice { return String(localized: "Alice will write to you") }
        return item.location
    }

    static func color(of item: AgendaItem, accent: Color) -> Color {
        switch item.kind {
        case let .event(_, color), let .reminder(_, color):
            color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? accent
        case .alice:
            accent
        }
    }
}

// MARK: - Connect

private struct ConnectCalendarCard: View {
    let refused: Bool
    let connect: () async -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(store.accent.primary(scheme))
                .frame(width: 56, height: 56)
                .background(store.accent.primary(scheme).opacity(0.12), in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text("See what's coming up")
                    .font(.aliceTitle(.title2))
                Text(refused
                     ? "Calendar access is off for Alice. Turn it on in Settings › Alice › Calendars."
                     : "Alice reads the calendars on this iPhone — iCloud, Google, Outlook — and shows your next two weeks here. She changes nothing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                working = true
                Task {
                    await connect()
                    working = false
                }
            } label: {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Text(refused ? "Open Settings" : "Show my calendar")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .background(scheme == .dark ? Color.white : Color.black, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(working)
            .accessibilityIdentifier("agenda.connect")
        }
        .padding(22)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
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
