import SwiftUI

/// Notes: write one down in a second, find it again later.
///
/// They live in the store an agent keeps on Hermes — the Inbox agent's — so a
/// note written here is sorted by that agent like one sent in its chat, and
/// one sent in its chat is here. Opening the screen puts the cursor in the
/// field: writing a note is the reason most people come.
struct NotesScreen: View {
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

    var body: some View {
        List {
            if snapshot?.available != false {
                Section {
                    capture
                        .listRowBackground(Palette.card(scheme))
                } footer: {
                    if let saveFailure {
                        Text(saveFailure).foregroundStyle(.red)
                    } else if saved {
                        Label(savedNote, systemImage: "checkmark")
                    }
                }
            }

            if let snapshot, !snapshot.available {
                Section {
                    ContentUnavailableView(
                        "No notes agent", systemImage: "note.text",
                        description: Text("Notes are kept by an agent with a notes store, like Inbox. None was found on this Hermes.")
                    )
                }
                .listRowBackground(Color.clear)
            } else if let loadFailure, snapshot == nil {
                Section {
                    ContentUnavailableView(
                        "Notes", systemImage: "note.text", description: Text(loadFailure)
                    )
                }
                .listRowBackground(Color.clear)
            } else if loading && snapshot == nil {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else if let snapshot {
                let shown = snapshot.notes.filter { NotesFeed.matches($0, query: query) }
                if snapshot.notes.isEmpty {
                    Section {
                        Text("Nothing written down yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } else if shown.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: query)
                    }
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
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background(scheme))
        .searchable(text: $query, prompt: "Search notes")
        .task {
            writing = true
            await load()
        }
        .refreshable { await load() }
        .sheet(item: $opened) { note in
            NoteDetail(note: note, agent: snapshot?.agent)
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    private var savedNote: String {
        guard let agent = snapshot?.agent else { return "Saved." }
        return "Saved. \(store.botCurrentName(for: agent)) will sort it."
    }

    private var capture: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Write a note…", text: $draft, axis: .vertical)
                .lineLimit(1...8)
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
                    if let when = note.createdAt {
                        Text(when.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = note.text
            }
            ShareLink(item: note.text)
        }
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
