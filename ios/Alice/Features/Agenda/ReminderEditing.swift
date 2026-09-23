import EventKit
import EventKitUI
import SwiftUI

/// The row a new reminder is typed into, as in Reminders: an empty circle,
/// the title field, and — while typing — the (i) that opens its details.
struct ReminderDraftRow: View {
    @Binding var draft: AgendaSource.ReminderDraft
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onDetails: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(" ")
                .frame(width: 54, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("New Reminder", text: $draft.title)
                        .font(.body)
                        .focused(focused)
                        .submitLabel(.next)
                        .onSubmit(onSubmit)
                        .accessibilityIdentifier("agenda.newReminder.title")
                    if let when = ReminderDates.describe(draft) {
                        Text(when)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if focused.wrappedValue {
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The quick dates above the keyboard, as Reminders offers them.
struct ReminderQuickDates: View {
    @Binding var draft: AgendaSource.ReminderDraft
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            chip("Today", selected: ReminderDates.isDay(draft, offset: 0)) { ReminderDates.set(&draft, dayOffset: 0) }
            chip("Tomorrow", selected: ReminderDates.isDay(draft, offset: 1)) { ReminderDates.set(&draft, dayOffset: 1) }
            chip("No Date", selected: draft.due == nil) { draft.due = nil; draft.hasTime = false }
            Spacer(minLength: 0)
            Button(action: onMore) {
                Image(systemName: "calendar")
            }
            .accessibilityLabel("Date and Time")
        }
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if selected {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }
}

/// A reminder's details, as Reminders shows them: title and notes, date and
/// time, and the list it belongs to.
struct ReminderDetailsSheet: View {
    let identifier: String?
    @State var draft: AgendaSource.ReminderDraft
    let onDone: (_ saved: Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var lists: [AgendaSource.ReminderList] = []
    @State private var problem: String?
    @State private var confirmingDelete = false

    private var hasDate: Binding<Bool> {
        Binding(
            get: { draft.due != nil },
            set: { on in
                if on {
                    draft.due = draft.due ?? Calendar.current.startOfDay(for: Date())
                } else {
                    draft.due = nil
                    draft.hasTime = false
                }
            }
        )
    }

    private var hasTime: Binding<Bool> {
        Binding(
            get: { draft.hasTime },
            set: { on in
                draft.hasTime = on
                if on {
                    // The next whole hour on that day, as Reminders suggests.
                    let base = draft.due ?? Date()
                    let hour = Calendar.current.component(.hour, from: Date()) + 1
                    draft.due = Calendar.current.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: base)
                } else if let due = draft.due {
                    draft.due = Calendar.current.startOfDay(for: due)
                }
            }
        )
    }

    private var dueDate: Binding<Date> {
        Binding(get: { draft.due ?? Date() }, set: { draft.due = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Toggle(isOn: hasDate) {
                        Label("Date", systemImage: "calendar")
                    }
                    if draft.due != nil {
                        DatePicker("Date", selection: dueDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                    Toggle(isOn: hasTime) {
                        Label("Time", systemImage: "clock")
                    }
                    .disabled(draft.due == nil)
                    if draft.hasTime {
                        DatePicker("Time", selection: dueDate, displayedComponents: .hourAndMinute)
                    }
                }
                if lists.count > 1 {
                    Section {
                        Picker(selection: Binding(
                            get: { draft.list ?? lists.first?.id ?? "" },
                            set: { draft.list = $0 }
                        )) {
                            ForEach(lists) { list in
                                Text(list.title).tag(list.id)
                            }
                        } label: {
                            Label("List", systemImage: "list.bullet")
                        }
                    }
                }
                if identifier != nil {
                    Section {
                        Button("Delete Reminder", role: .destructive) { confirmingDelete = true }
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle(identifier == nil ? "New Reminder" : "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(identifier == nil ? "Add" : "Done") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            }
            .onAppear { lists = AgendaSource.reminderLists() }
        }
    }

    private func save() {
        do {
            try AgendaSource.save(draft, identifier: identifier)
            onDone(true)
        } catch {
            problem = String(localized: "That reminder could not be saved.")
        }
    }

    private func delete() {
        guard let identifier else { return }
        do {
            try AgendaSource.delete(identifier)
            onDone(true)
        } catch {
            problem = String(localized: "That reminder could not be deleted.")
        }
    }
}

/// Calendar's own new-event page.
struct NewEventSheet: UIViewControllerRepresentable {
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = AgendaSource.store
        let event = EKEvent(eventStore: AgendaSource.store)
        // The next whole hour, an hour long, as Calendar suggests.
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: Date())?.end ?? Date()
        event.startDate = hour
        event.endDate = hour.addingTimeInterval(3600)
        event.calendar = AgendaSource.store.defaultCalendarForNewEvents
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onDone()
        }
    }
}

/// Dates for a reminder being written: which quick date is chosen, and how
/// to say it under the title.
enum ReminderDates {
    static func set(_ draft: inout AgendaSource.ReminderDraft, dayOffset: Int, now: Date = Date()) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { return }
        if draft.hasTime, let due = draft.due {
            let time = calendar.dateComponents([.hour, .minute], from: due)
            draft.due = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day)
        } else {
            draft.due = day
        }
    }

    static func isDay(_ draft: AgendaSource.ReminderDraft, offset: Int, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        guard let due = draft.due,
              let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return false }
        return calendar.isDate(due, inSameDayAs: day)
    }

    /// "Today", "Tomorrow, 9:00", "Fri 25 Sep" — nil for no date.
    static func describe(_ draft: AgendaSource.ReminderDraft, now: Date = Date()) -> String? {
        guard let due = draft.due else { return nil }
        let calendar = Calendar.current
        let day = calendar.isDate(due, inSameDayAs: now) ? String(localized: "Today")
            : calendar.isDateInTomorrow(due) ? String(localized: "Tomorrow")
            : due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard draft.hasTime else { return day }
        return "\(day), \(due.formatted(date: .omitted, time: .shortened))"
    }
}
