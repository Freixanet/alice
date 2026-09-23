import EventKit
import EventKitUI
import MapKit
import SwiftUI

/// A reminder's details, as Reminders lays them out: title, notes and URL;
/// date and time; repeat; location; priority; list. What Reminders keeps to
/// itself — flags, tags, subtasks, images — is not offered, because nothing
/// set here could reach it.
struct ReminderDetailsSheet: View {
    let identifier: String?
    @State var draft: AgendaSource.ReminderDraft
    let lists: [AgendaSource.ReminderList]
    let onDone: (_ saved: Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var choosingPlace = false

    private var hasDate: Binding<Bool> {
        Binding(
            get: { draft.due != nil },
            set: { on in
                if on {
                    draft.due = draft.due ?? Calendar.current.startOfDay(for: Date())
                } else {
                    draft.due = nil
                    draft.hasTime = false
                    draft.repeats = .never
                }
            }
        )
    }

    private var hasTime: Binding<Bool> {
        Binding(
            get: { draft.hasTime },
            set: { on in
                let calendar = Calendar.current
                if on {
                    let day = draft.due ?? calendar.startOfDay(for: Date())
                    let next = calendar.component(.hour, from: Date()) + 1
                    draft.due = calendar.date(bySettingHour: min(next, 23), minute: 0, second: 0, of: day)
                    draft.hasTime = true
                } else {
                    draft.hasTime = false
                    if let due = draft.due { draft.due = calendar.startOfDay(for: due) }
                }
            }
        )
    }

    private var hasPlace: Binding<Bool> {
        Binding(get: { draft.place != nil }, set: { on in
            if on { choosingPlace = true } else { draft.place = nil }
        })
    }

    private var due: Binding<Date> {
        Binding(get: { draft.due ?? Date() }, set: { draft.due = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...8)
                    TextField("URL", text: $draft.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle(isOn: hasDate) {
                        row("Date", systemImage: "calendar", color: .red,
                            detail: draft.due.map { AgendaStyle.when($0, allDay: true, now: Date()) })
                    }
                    if draft.due != nil {
                        DatePicker("Date", selection: due, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                    Toggle(isOn: hasTime) {
                        row("Time", systemImage: "clock.fill", color: .blue,
                            detail: draft.hasTime ? draft.due?.formatted(date: .omitted, time: .shortened) : nil)
                    }
                    if draft.hasTime {
                        DatePicker("Time", selection: due, displayedComponents: .hourAndMinute)
                    }
                    if draft.due != nil {
                        Picker(selection: $draft.repeats) {
                            ForEach(ReminderRepeat.allCases) { Text($0.title).tag($0) }
                        } label: {
                            row("Repeat", systemImage: "repeat", color: .gray, detail: nil)
                        }
                    }
                }

                Section {
                    Toggle(isOn: hasPlace) {
                        row("Location", systemImage: "location.fill", color: .blue, detail: draft.place?.title)
                    }
                    if let place = draft.place {
                        Picker("When", selection: Binding(
                            get: { place.arriving },
                            set: { draft.place?.arriving = $0 }
                        )) {
                            Text("Arriving").tag(true)
                            Text("Leaving").tag(false)
                        }
                        .pickerStyle(.segmented)
                        Button("Change Location") { choosingPlace = true }
                    }
                }

                Section {
                    Picker(selection: $draft.priority) {
                        ForEach(ReminderPriority.allCases) { Text($0.title).tag($0) }
                    } label: {
                        row("Priority", systemImage: "exclamationmark", color: .red, detail: nil)
                    }
                    if lists.count > 1 {
                        Picker(selection: Binding(
                            get: { draft.list ?? lists.first?.id ?? "" },
                            set: { draft.list = $0 }
                        )) {
                            ForEach(lists.filter(\.editable)) { list in
                                Text(list.title).tag(list.id)
                            }
                        } label: {
                            row("List", systemImage: "list.bullet", color: listColor, detail: nil)
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
            .navigationTitle("Details")
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
            .sheet(isPresented: $choosingPlace) {
                PlaceSearch { place in
                    if let place { draft.place = place }
                    choosingPlace = false
                }
            }
        }
    }

    private var listColor: Color {
        lists.first { $0.id == draft.list }?.color.map(AgendaStyle.color) ?? .blue
    }

    /// Settings' own row: a white symbol on a coloured rounded square, the
    /// name, and what is set under it in blue.
    private func row(_ title: LocalizedStringKey, systemImage: String, color: Color, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
            }
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

/// A place from Apple Maps' own search, for a reminder that goes off on
/// arriving or leaving. The search runs on Apple's service, as in Reminders.
struct PlaceSearch: View {
    let onPick: (ReminderPlace?) -> Void

    @State private var query = ""
    @State private var completer = PlaceCompleter()
    @State private var looking = false

    var body: some View {
        NavigationStack {
            List(completer.results, id: \.self) { result in
                Button {
                    Task { await pick(result) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if looking { ProgressView() }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a place")
            .onChange(of: query) { _, text in completer.search(text) }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onPick(nil) } }
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        looking = true
        defer { looking = false }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return }
        let coordinate = item.location.coordinate
        onPick(ReminderPlace(title: item.name ?? completion.title,
                             latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

@MainActor
@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(_ text: String) {
        completer.queryFragment = text
        if text.isEmpty { results = [] }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // The completer calls back on the main thread, where it was made.
        MainActor.assumeIsolated { results = self.completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

/// Calendar's own new-event page, starting at `start`.
struct NewEventSheet: UIViewControllerRepresentable {
    var start: Date?
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = AgendaSource.store
        let event = EKEvent(eventStore: AgendaSource.store)
        // The next whole hour, an hour long, as Calendar suggests.
        let from = start ?? Calendar.current.dateInterval(of: .hour, for: Date())?.end ?? Date()
        event.startDate = from
        event.endDate = from.addingTimeInterval(3600)
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

/// Calendar's own event page: details, alerts, and its edit and delete.
struct EventDetail: UIViewControllerRepresentable {
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

/// Dates for a reminder being written.
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
        return AgendaStyle.when(due, allDay: !draft.hasTime, now: now)
    }
}
