import SwiftUI

/// Notes: write one down in a second, find it again later.
///
/// They live in the store an agent keeps on Hermes — the Inbox agent's — so a
/// note written here is sorted by that agent like one sent in its chat, and
/// one sent in its chat is here. Opening the page puts the cursor in the
/// field: writing a note is the reason most people come.
///
/// A page, like Agents, not a sheet: a sheet closes on a stray downward swipe,
/// which is the gesture of someone scrolling back through what they wrote.
struct NotesScreen: View {
    var onClose: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var draft = ""
    @FocusState private var writing: Bool
    @State private var query = ""
    @State private var saving = false
    @State private var saveFailure: String?
    @State private var saved = false
    @State private var loadFailure: String?
    @State private var loading = false
    @State private var opened: Note?

    private var snapshot: NotesSnapshot? { store.notesSnapshot }
    private var canSave: Bool {
        !saving && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var showsCapture: Bool { snapshot?.available != false }
    private var shown: [Note] {
        (snapshot?.notes ?? []).filter { NotesFeed.matches($0, query: query) }
    }

    /// What stands in for the notes when there are none to show.
    private enum Status {
        case noStore, failed(String), loading, nothingYet, noResults
    }

    private var status: Status? {
        if let snapshot, !snapshot.available { return .noStore }
        guard let snapshot else {
            if let loadFailure { return .failed(loadFailure) }
            return .loading
        }
        if snapshot.notes.isEmpty { return .nothingYet }
        return shown.isEmpty ? .noResults : nil
    }

    var body: some View {
        Group {
            if store.notesAsCards {
                cards
            } else {
                list
            }
        }
        // One field for both views, held above them: the same form whichever
        // way the notes are laid out, and in reach however far down you are.
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsCapture {
                VStack(alignment: .leading, spacing: 6) {
                    capture
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
                    captureFooter
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Palette.background(scheme))
            }
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .background {
            Palette.background(scheme)
                .ignoresSafeArea()
        }
        .searchable(text: $query, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("notes.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { store.notesAsCards.toggle() }
                } label: {
                    Image(systemName: store.notesAsCards ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(store.notesAsCards ? "Show as list" : "Show as cards")
                .accessibilityIdentifier("notes.layout")
            }
        }
        // No keyboard on arrival: most visits are to read, and a keyboard
        // covering half the notes is in the way of that. The field is one tap.
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { note in
            NoteDetail(note: note, agent: snapshot?.agent)
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let status {
                Section { statusView(status) }
                    .listRowBackground(Color.clear)
            }
            ForEach(NotesFeed.groups(shown), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.notes) { note in
                        row(note)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ note: Note) -> some View {
        Button {
            opened = note
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    when(note)
                    ForEach(note.types.prefix(2), id: \.self) { type in
                        TypeChip(type: type)
                    }
                    if note.sending {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(note.sending)
        .listRowBackground(Palette.card(scheme))
        .contextMenu { menu(note) }
    }

    // MARK: - Cards

    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let status {
                    statusView(status)
                        .frame(maxWidth: .infinity)
                }
                ForEach(NotesFeed.groups(shown), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(group.notes) { note in
                                card(note)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func card(_ note: Note) -> some View {
        Button {
            opened = note
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(note.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let type = note.types.first {
                        TypeChip(type: type)
                    }
                    Spacer(minLength: 0)
                    if note.sending {
                        ProgressView().controlSize(.mini)
                    } else {
                        when(note)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Palette.border(scheme), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(note.sending)
        .contextMenu { menu(note) }
    }

    // MARK: - Shared

    private var capture: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Write a note…", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                // As tall as the button beside it, so a single line sits in
                // the middle of the field rather than on its floor.
                .frame(minHeight: 32, alignment: .leading)
                .focused($writing)
                .accessibilityIdentifier("notes.field")
            Button(action: save) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSave ? Color.white : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        canSave ? store.accent.control(scheme) : Palette.background(scheme),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityLabel("Save note")
            .accessibilityIdentifier("notes.save")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var captureFooter: some View {
        if let saveFailure {
            Text(saveFailure).foregroundStyle(.red)
        } else if saved {
            Label(savedNote, systemImage: "checkmark")
        }
    }

    private var savedNote: String {
        guard let agent = snapshot?.agent else { return "Saved." }
        return "Saved. \(store.botCurrentName(for: agent)) will sort it."
    }

    @ViewBuilder
    private func statusView(_ status: Status) -> some View {
        switch status {
        case .noStore:
            ContentUnavailableView(
                "No notes agent", systemImage: "note.text",
                description: Text("Notes are kept by an agent with a notes store, like Inbox. None was found on this Hermes.")
            )
        case let .failed(reason):
            ContentUnavailableView("Notes", systemImage: "note.text", description: Text(reason))
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .nothingYet:
            Text("Nothing written down yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .noResults:
            ContentUnavailableView.search(text: query)
        }
    }

    /// The time for a note from today or yesterday — the section already says
    /// the day — and the date for anything older.
    @ViewBuilder
    private func when(_ note: Note) -> some View {
        if let date = note.createdAt {
            let recent = Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date)
            Text(recent
                 ? date.formatted(date: .omitted, time: .shortened)
                 : date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func menu(_ note: Note) -> some View {
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = note.text
        }
        ShareLink(item: note.text)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await store.refreshNotes()
            loadFailure = nil
        } catch {
            loadFailure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not send the notes."
        }
    }

    private func save() {
        let text = draft
        guard canSave else { return }
        saving = true
        saveFailure = nil
        saved = false
        draft = ""
        Task {
            defer { saving = false }
            do {
                try await store.addNote(text)
                saved = true
            } catch {
                // Nothing is lost: the words go back where they were written.
                if draft.isEmpty { draft = text }
                saveFailure = (error as? LocalizedError)?.errorDescription ?? "The note was not saved."
            }
            writing = true
        }
    }
}

private struct TypeChip: View {
    @Environment(\.colorScheme) private var scheme
    let type: String

    var body: some View {
        Text(NotesFeed.label(forType: type))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Palette.background(scheme), in: .capsule)
    }
}

/// One note in full, with what its agent made of it.
private struct NoteDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let note: Note
    let agent: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(note.text)
                        .textSelection(.enabled)
                } footer: {
                    if let when = note.createdAt {
                        Text(when.formatted(date: .complete, time: .shortened))
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if !note.summary.isEmpty {
                    Section("Summary") { Text(note.summary) }
                        .listRowBackground(Palette.card(scheme))
                }
                if !note.types.isEmpty || !note.topics.isEmpty {
                    Section("Sorted as") {
                        if !note.types.isEmpty {
                            Text(note.types.map(NotesFeed.label(forType:)).joined(separator: " · "))
                        }
                        if !note.topics.isEmpty {
                            Text(note.topics.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
                if !note.actions.isEmpty {
                    Section("To do") {
                        ForEach(note.actions, id: \.self) { Label($0, systemImage: "circle") }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
                if !note.openQuestions.isEmpty {
                    Section("Open questions") {
                        ForEach(note.openQuestions, id: \.self) { Text($0) }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
                if !note.urls.isEmpty {
                    Section("Links") {
                        ForEach(note.urls, id: \.self) { raw in
                            if let url = URL(string: raw) {
                                Link(raw, destination: url).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
                if !note.processed {
                    Section {
                        EmptyView()
                    } footer: {
                        Text(agent.map { "\(store.botCurrentName(for: $0)) hasn't sorted this note yet. It does so in its routine." }
                             ?? "This note hasn't been sorted yet.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: note.text)
                }
            }
        }
    }
}
