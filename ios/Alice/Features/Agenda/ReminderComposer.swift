import SwiftUI

/// The reminder being written, in the box iOS 27's Reminders draws around
/// it: the circle and the title, notes under it, and the reminder's details
/// as buttons at the bottom of the box — Date, Time, Repeat, Location,
/// Priority, List — with (i) for everything at once. A date said in the title
/// ("mañana a las 18:00") is offered as the first button, and taken out of
/// the title when tapped, as Reminders does.
///
/// Return saves it and starts the next one, on the same day and list.
struct ReminderComposer: View {
    @Binding var draft: AgendaSource.ReminderDraft
    let lists: [AgendaSource.ReminderList]
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onDetails: () -> Void
    let onPlace: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var choosingDate = false
    @State private var choosingTime = false

    private var list: AgendaSource.ReminderList? {
        lists.first { $0.id == draft.list } ?? lists.first
    }

    private var tint: Color {
        list?.color.map(AgendaStyle.color) ?? store.accent.primary(scheme)
    }

    private var suggestion: ReminderDateSuggestion? {
        ReminderParsing.suggestion(in: draft.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("New Reminder", text: $draft.title, axis: .vertical)
                        .font(.body)
                        .focused(focused)
                        .submitLabel(.next)
                        .onSubmit(onSubmit)
                        .accessibilityIdentifier("agenda.composer.title")
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1...4)
                }
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let suggestion, draft.due == nil || !sameAs(suggestion) {
                        chip(suggestionLabel(suggestion), systemImage: "calendar.badge.plus", on: true) {
                            apply(suggestion)
                        }
                        .accessibilityHint("Adds this date and takes it out of the title.")
                    }
                    dateMenu
                    chip(draft.hasTime ? timeText : String(localized: "Time"), systemImage: "clock",
                         on: draft.hasTime) {
                        choosingTime = true
                    }
                    repeatMenu
                    chip(draft.place?.title ?? String(localized: "Location"),
                         systemImage: "location", on: draft.place != nil, action: onPlace)
                    priorityMenu
                    if lists.count > 1 { listMenu }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()
        }
        .padding(14)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(tint.opacity(0.55), lineWidth: 1)
        }
        .sheet(isPresented: $choosingDate) {
            DateOnlyPicker(date: Binding(get: { draft.due ?? Date() }, set: { setDay($0) }))
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $choosingTime) {
            TimePicker(draft: $draft)
                .presentationDetents([.height(320)])
        }
    }

    // MARK: Buttons

    private var dateMenu: some View {
        Menu {
            Button { setDayOffset(0) } label: { Label("Today", systemImage: "calendar") }
            Button { setDayOffset(1) } label: { Label("Tomorrow", systemImage: "sunrise") }
            Button { setWeekend() } label: { Label("This Weekend", systemImage: "sofa") }
            Button { setDayOffset(7) } label: { Label("Next Week", systemImage: "calendar.badge.clock") }
            Button { choosingDate = true } label: { Label("Custom…", systemImage: "calendar.circle") }
            if draft.due != nil {
                Divider()
                Button(role: .destructive) {
                    draft.due = nil
                    draft.hasTime = false
                    draft.repeats = .never
                } label: { Label("No Date", systemImage: "xmark") }
            }
        } label: {
            chipLabel(draft.due.map { AgendaStyle.when($0, allDay: true, now: Date()) } ?? String(localized: "Date"),
                      systemImage: "calendar", on: draft.due != nil)
        }
    }

    private var repeatMenu: some View {
        Menu {
            Picker("Repeat", selection: Binding(
                get: { draft.repeats },
                set: { value in
                    draft.repeats = value
                    if value != .never, draft.due == nil { setDayOffset(0) }
                }
            )) {
                ForEach(ReminderRepeat.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            chipLabel(draft.repeats == .never ? String(localized: "Repeat") : draft.repeats.title,
                      systemImage: "repeat", on: draft.repeats != .never)
        }
    }

    private var priorityMenu: some View {
        Menu {
            Picker("Priority", selection: $draft.priority) {
                ForEach(ReminderPriority.allCases.reversed()) { priority in
                    Text(priority == .none ? priority.title : "\(priority.marks) \(priority.title)").tag(priority)
                }
            }
        } label: {
            chipLabel(draft.priority == .none ? String(localized: "Priority") : draft.priority.title,
                      systemImage: "exclamationmark", on: draft.priority != .none)
        }
    }

    private var listMenu: some View {
        Menu {
            Picker("List", selection: Binding(get: { draft.list ?? lists.first?.id ?? "" }, set: { draft.list = $0 })) {
                ForEach(lists.filter(\.editable)) { Text($0.title).tag($0.id) }
            }
        } label: {
            chipLabel(list?.title ?? String(localized: "List"), systemImage: "list.bullet", on: false)
        }
    }

    private func chip(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, systemImage: systemImage, on: on) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, systemImage: String, on: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(on ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(on ? tint : .primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(on ? tint.opacity(0.14) : Palette.muted(scheme), in: .capsule)
    }

    // MARK: Dates

    private var timeText: String {
        draft.due.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "Time")
    }

    private func suggestionLabel(_ suggestion: ReminderDateSuggestion) -> String {
        AgendaStyle.when(suggestion.date, allDay: !suggestion.hasTime, now: Date())
    }

    private func sameAs(_ suggestion: ReminderDateSuggestion) -> Bool {
        draft.due == suggestion.date && draft.hasTime == suggestion.hasTime
    }

    private func apply(_ suggestion: ReminderDateSuggestion) {
        draft.due = suggestion.date
        draft.hasTime = suggestion.hasTime
        if !suggestion.remainingTitle.isEmpty { draft.title = suggestion.remainingTitle }
    }

    private func setDayOffset(_ offset: Int) {
        ReminderDates.set(&draft, dayOffset: offset)
    }

    private func setWeekend() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let toSaturday = (7 - weekday + 7) % 7
        setDayOffset(toSaturday)
    }

    private func setDay(_ day: Date) {
        let calendar = Calendar.current
        if draft.hasTime, let due = draft.due {
            let time = calendar.dateComponents([.hour, .minute], from: due)
            draft.due = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day)
        } else {
            draft.due = calendar.startOfDay(for: day)
        }
    }
}

/// A day, chosen on Calendar's own graphical picker.
struct DateOnlyPicker: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            Spacer(minLength: 0)
        }
    }
}

/// A time for the reminder, on today when it had no day yet.
struct TimePicker: View {
    @Binding var draft: AgendaSource.ReminderDraft
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .navigationTitle("Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if draft.hasTime {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Remove", role: .destructive) {
                                if let due = draft.due { draft.due = Calendar.current.startOfDay(for: due) }
                                draft.hasTime = false
                                dismiss()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            let calendar = Calendar.current
                            let day = draft.due ?? calendar.startOfDay(for: Date())
                            let parts = calendar.dateComponents([.hour, .minute], from: time)
                            draft.due = calendar.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0,
                                                      second: 0, of: day)
                            draft.hasTime = true
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            let calendar = Calendar.current
            if draft.hasTime, let due = draft.due {
                time = due
            } else {
                // The next whole hour, as Reminders suggests.
                time = calendar.dateInterval(of: .hour, for: Date())?.end ?? Date()
            }
        }
    }
}
