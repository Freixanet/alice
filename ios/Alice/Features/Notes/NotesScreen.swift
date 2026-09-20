import SwiftUI
import TipKit

/// Notes: write one down in a second, find it again later.
///
/// They live in the store an agent keeps on Hermes — the Inbox agent's — so a
/// note written here is sorted by that agent like one sent in its chat, and
/// one sent in its chat is here. A new note starts from the + beside the
/// search field at the bottom, the way Notes and Mail put compose beside
/// search, so the page itself is all notes.
///
/// A page, like Agents, not a sheet: a sheet closes on a stray downward swipe,
/// which is the gesture of someone scrolling back through what they wrote.
struct NotesScreen: View {
    /// The folder shown, opened from the folders page.
    var scope: NotesScope = .quick

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var loadFailure: String?
    @State private var loading = false
    @State private var opened: NoteEditor.Target?
    @State private var deleting: Note?
    /// The one row swiped open to show Delete.
    @State private var swipedOpen: String?
    @State private var swipedSide: SwipeSide = .trailing
    @State private var lastSwipe = Date.distantPast
    /// The row out of place, whose separators are hidden meanwhile.
    @State private var movingNote: String?
    @State private var deleteFailure: String?
    /// Ticking notes rather than opening them, and the ones ticked.
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// Naming a folder: a new one inside this, or this one again.
    @State private var naming: Naming?
    @State private var folderName = ""
    /// Choosing where something goes: this folder, or the notes ticked.
    @State private var moving: NoteMove?
    @State private var showingAttachments = false
    /// A folder inside this one, opened from the Folders section.
    @State private var openedSubfolder: NotesScope?
    @State private var deletingSelection = false

    private enum Naming: Identifiable {
        case add, rename
        var id: String { self == .add ? "add" : "rename" }
    }

    private var snapshot: NotesSnapshot? { store.notesSnapshot }
    private var showsCapture: Bool { snapshot?.available != false }
    private var shown: [Note] {
        store.notes(in: scope).filter { NotesFeed.matches($0, query: query) }
    }

    /// The folders inside this one, when it is a folder and has any.
    private var subfolders: [NoteFolder] {
        guard case let .folder(id) = scope, query.isEmpty else { return [] }
        return store.subfolders(of: id)
    }

    /// The notes in sections, in the order and grouping the folder's menu is set to.
    private var groups: [NotesFeed.Group] {
        NotesFeed.groups(
            shown, pinned: store.pinnedNotes,
            sort: store.notesSort, grouped: store.notesGroupByDate
        )
    }

    /// What stands in for the notes when there are none to show.
    private enum Status {
        case noStore, failed(String), loading, nothingYet, noResults
    }

    private var status: Status? {
        if let snapshot, !snapshot.available { return .noStore }
        guard snapshot != nil else {
            if let loadFailure { return .failed(loadFailure) }
            return .loading
        }
        if store.notes(in: scope).isEmpty && subfolders.isEmpty { return .nothingYet }
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
        // Back to the folders without reaching for the screen's edge. The
        // rows take a sideways pan of their own first — a note's is Pin — so
        // this only ever gets the ones that start on empty space, which is
        // exactly where a swipe means "leave" and nothing else.
        .gesture(SidewaysPan(
            allowsRightward: true,
            onTouch: {},
            onChange: { _ in },
            onEnd: { translation, predicted in
                guard !selecting, translation > 90 || predicted > 220 else { return }
                dismiss()
            }
        ))
        .navigationTitle(store.name(of: scope))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .background {
            Palette.background(scheme)
                .ignoresSafeArea()
        }
        .searchable(text: $query, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button("Done") { endSelecting() }
                        .accessibilityIdentifier("notes.selectDone")
                } else {
                    NotesFolderMenu(
                        scope: scope,
                        selecting: $selecting,
                        shareText: shareText,
                        onAddFolder: { folderName = ""; naming = .add },
                        onMoveFolder: {
                            if case let .folder(id) = scope { moving = .folder(id) }
                        },
                        onRename: { folderName = store.name(of: scope); naming = .rename },
                        onAttachments: { showingAttachments = true }
                    )
                }
            }
            // While notes are being ticked the bottom bar is what is done with
            // them; search and a new note would both be beside the point.
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("Pin", systemImage: "pin") { pinSelection() }
                        .disabled(selected.isEmpty)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Move", systemImage: "folder") { moving = .notes(selected) }
                        .disabled(selected.isEmpty)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deletingSelection = true
                    }
                    .disabled(selected.isEmpty)
                    .tint(.red)
                }
            } else {
                // Search and compose share the bottom bar, search first and the
                // + on its right, as in the system apps.
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                if showsCapture {
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        // The same page as editing one, empty and ready to write in.
                        Button("New Note", systemImage: "plus") { opened = .new(UUID()) }
                            .accessibilityIdentifier("notes.new")
                    }
                }
            }
        }
        // No keyboard on arrival: most visits are to read, and a keyboard
        // covering half the notes is in the way of that.
        .task { await load() }
        .onAppear { store.notesFolderOpen = true }
        .onDisappear { store.notesFolderOpen = false }
        .refreshableWithFeedback { await load() }
        // Deleting is for good, and asked once more.
        .confirmationDialog(
            deleting.map(Self.deleteTitle(for:)) ?? "Delete this note?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { note in
            Button("Delete", role: .destructive) { delete(note) }
        } message: { _ in
            Text("It leaves the notes store, with what its agent made of it. Recently Deleted keeps a copy on this iPhone for 30 days.")
        }
        .alert(
            "Note not deleted",
            isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteFailure ?? "")
        }
        // A page to write in, not a sheet to read: opening a note is how it
        // is edited.
        .navigationDestination(item: $opened) { target in
            NoteEditor(
                target: target, agent: snapshot?.agent,
                // A note written in All Notes is not in any folder: it is a
                // Quick Note, like one written from the folders page.
                folder: scope == .all ? .quick : scope
            )
        }
        .navigationDestination(isPresented: $showingAttachments) {
            NoteAttachmentsScreen(scope: scope)
        }
        .navigationDestination(item: $openedSubfolder) { inner in
            NotesScreen(scope: inner)
        }
        .sheet(item: $moving) { what in
            NoteFolderPicker(moving: what, from: scope, onDone: endSelecting)
        }
        .alert(
            naming == .add ? "New Folder" : "Rename Folder",
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
        ) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveFolderName() }
        } message: {
            Text(naming == .add ? "A name for the folder inside this one." : "A name for this folder.")
        }
        .confirmationDialog(
            selectionDeleteTitle,
            isPresented: $deletingSelection, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelection() }
        } message: {
            Text("They leave the notes store. Recently Deleted keeps a copy on this iPhone for 30 days.")
        }
        // Leaving the folder leaves selection behind with it.
        .onDisappear { endSelecting() }
    }

    // MARK: - Selecting

    private func endSelecting() {
        selecting = false
        selected = []
    }

    private func toggle(_ note: Note) {
        if selected.contains(note.id) { selected.remove(note.id) } else { selected.insert(note.id) }
    }

    private var selectedNotes: [Note] {
        store.notes(in: scope).filter { selected.contains($0.id) }
    }

    /// Pins them all, or unpins them when every one is already pinned — the
    /// same button as one note's Pin, said of several.
    private func pinSelection() {
        let notes = selectedNotes
        let allPinned = notes.allSatisfy { store.pinnedNotes.contains($0.id) }
        withAnimation(.snappy(duration: 0.3)) {
            for note in notes where store.pinnedNotes.contains(note.id) == allPinned {
                store.togglePinned(note)
            }
        }
        endSelecting()
    }

    private func deleteSelection() {
        let notes = selectedNotes
        endSelecting()
        NoteActionsTip().invalidate(reason: .actionPerformed)
        Task {
            for note in notes {
                do {
                    try await store.deleteNote(note)
                } catch {
                    deleteFailure = (error as? LocalizedError)?.errorDescription
                        ?? "Hermes did not delete the note."
                    return
                }
            }
        }
    }

    private func saveFolderName() {
        let name = folderName
        switch naming {
        case .add:
            if case let .folder(id) = scope {
                Task { await store.createNoteFolder(named: name, inside: id) }
            }
        case .rename:
            if case let .folder(id) = scope {
                Task { await store.renameNoteFolder(id, to: name) }
            }
        case nil: break
        }
        naming = nil
    }

    /// Every note here as plain text, one after another, for Share Folder.
    /// A locked note is not in it: sharing a folder must not be a way around
    /// the lock.
    private func shareText() -> String {
        store.notes(in: scope)
            .filter { !hides($0) }
            .map(\.text)
            .joined(separator: "\n\n———\n\n")
    }

    // MARK: - List

    private var list: some View {
        List {
            if let status {
                Section { statusView(status) }
                    .listRowBackground(Color.clear)
            }
            if !shown.isEmpty {
                Section { TipView(NoteActionsTip()) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            // What is inside this folder, above what is in it: a subfolder is
            // a place, and places come before their contents. Only when there
            // is one — an empty "Folders" heading is a heading about nothing.
            if !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { folder in
                        subfolderRow(folder)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(Array(group.notes.enumerated()), id: \.element.id) { index, note in
                        row(
                            note,
                            below: index + 1 < group.notes.count ? group.notes[index + 1].id : nil
                        )
                    }
                } header: {
                    // With Group By Date off there is one run of notes and no
                    // date to head it with, so it has no header at all.
                    if !group.title.isEmpty { Text(group.title) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Clear of the page's header rather than tucked under its buttons.
        .contentMargins(.top, 20, for: .scrollContent)
    }

    /// `below` is the next note in the section, if any: the line between the
    /// two is this row's, and goes when either of them is swiped out.
    @ViewBuilder
    private func row(_ note: Note, below: String?) -> some View {
        if selecting {
            selectableRow(note, below: below)
        } else {
            openableRow(note, below: below)
        }
    }

    /// While notes are being ticked a row is a checkbox, not a way in: no
    /// swipe, no held menu, and a tap adds it to the selection rather than
    /// opening it. A locked note can be ticked and moved without being read.
    private func selectableRow(_ note: Note, below: String?) -> some View {
        Button {
            toggle(note)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(note.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        selected.contains(note.id)
                            ? AnyShapeStyle(store.accent.primary(scheme))
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                    )
                rowLabel(note)
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(NoteRowPressStyle())
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            if below != nil {
                Rectangle()
                    .fill(Color(uiColor: .opaqueSeparator))
                    .frame(height: 1)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Palette.card(scheme))
        .accessibilityAddTraits(selected.contains(note.id) ? [.isSelected] : [])
    }

    private func openableRow(_ note: Note, below: String?) -> some View {
        Button {
            // The end of a swipe is not a tap on the note.
            guard Date.now.timeIntervalSince(lastSwipe) > 0.35 else { return }
            guard swipedOpen == nil else {
                withAnimation(.snappy(duration: 0.25)) { swipedOpen = nil }
                store.noteRowOpen = false
                return
            }
            open(note)
        } label: {
            rowLabel(note)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .contentShape(.rect)
        }
        .buttonStyle(NoteRowPressStyle())
        .disabled(note.sending)
        .contextMenu { menu(note) } preview: { NotePreview(note: note, locked: hides(note)) }
        // The quick way; the same Delete is in the note's menu and its page.
        .modifier(SwipeToDelete(
            openSide: Binding(
                get: { swipedOpen == note.id ? swipedSide : nil },
                set: { side in
                    if let side {
                        swipedOpen = note.id
                        swipedSide = side
                    } else if swipedOpen == note.id {
                        swipedOpen = nil
                    }
                    store.noteRowOpen = swipedOpen != nil
                }
            ),
            shareText: hides(note) ? "" : note.text,
            pinned: store.pinnedNotes.contains(note.id),
            onPin: {
                withAnimation(.snappy(duration: 0.3)) { store.togglePinned(note) }
            },
            lastSwipe: $lastSwipe,
            moving: Binding(
                get: { movingNote == note.id },
                set: { now in movingNote = now ? note.id : (movingNote == note.id ? nil : movingNote) }
            ),
            onDelete: { deleting = note }
        ))
        // The list's own separators are not redrawn while a row moves, so the
        // rows draw their own: under each row but the last, gone while this
        // row or the one below is swiped out.
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            let outOfPlace: Set<String?> = [movingNote, swipedOpen]
            if let below, !outOfPlace.contains(note.id), !outOfPlace.contains(below) {
                // As visible as the list's own line, and inset the same on
                // both sides, clear of the row's edges.
                Rectangle()
                    .fill(Color(uiColor: .opaqueSeparator))
                    .frame(height: 1)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Palette.card(scheme))
    }

    /// A folder inside this one, as the folders page draws it: its name, how
    /// many notes it holds, and the way in.
    private func subfolderRow(_ folder: NoteFolder) -> some View {
        Button {
            openedSubfolder = .folder(folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 26)
                Text(folder.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(store.notes(in: .folder(folder.id)).count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            .contentShape(.rect)
        }
        .buttonStyle(NoteRowPressStyle())
        .listRowInsets(EdgeInsets())
    }

    /// As Notes lists them: the first line as a title, then when it was last
    /// written beside as much of the rest as fits.
    private func rowLabel(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(NotesFeed.title(of: note))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if store.isLocked(note) {
                    Image(systemName: hides(note) ? "lock.fill" : "lock.open.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if note.sending {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 8) {
                if let when = NotesFeed.whenLabel(note) {
                    Text(when)
                        .foregroundStyle(.primary.opacity(0.75))
                }
                Text(hides(note) ? "Locked" : NotesFeed.body(of: note) ?? "No additional text")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cards

    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let status {
                    statusView(status)
                        .frame(maxWidth: .infinity)
                }
                if !shown.isEmpty { TipView(NoteActionsTip()) }
                if !subfolders.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Folders")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(subfolders) { folder in
                            subfolderRow(folder)
                                .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
                        }
                    }
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if !group.title.isEmpty {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
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
            .padding(.top, 32)
            .padding(.bottom, 12)
        }
    }

    /// Held for its menu, unless notes are being ticked: then holding one
    /// would offer to open, share and delete the note under the finger, which
    /// is not what the page is for at that moment.
    @ViewBuilder
    private func card(_ note: Note) -> some View {
        if selecting {
            cardButton(note)
        } else {
            cardButton(note)
                .contextMenu { menu(note) } preview: { NotePreview(note: note, locked: hides(note)) }
        }
    }

    private func cardButton(_ note: Note) -> some View {
        Button {
            if selecting { toggle(note) } else { open(note) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(NotesFeed.title(of: note))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(hides(note) ? "Locked" : NotesFeed.body(of: note) ?? "No additional text")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let when = NotesFeed.whenLabel(note) {
                        Text(when)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if note.sending {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected.contains(note.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(
                            selected.contains(note.id)
                                ? AnyShapeStyle(store.accent.primary(scheme))
                                : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                        )
                        .padding(8)
                }
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(NoteCardPressStyle())
        .disabled(note.sending)
        .accessibilityAddTraits(selecting && selected.contains(note.id) ? [.isSelected] : [])
    }

    // MARK: - Shared

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
            Text("No notes yet. Tap + to write one; it is kept by the notes agent and shows up here.")
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
        let hidden = hides(note)
        // Share, Move and Delete side by side at the top, as for folders.
        ControlGroup {
            ShareLink(item: note.text) {
                Label("Share", systemImage: "square.and.arrow.up.fill")
            }
            .disabled(hidden)
            // Not wired to anything yet.
            Button("Move", systemImage: "folder.fill") {}
            Button(role: .destructive) {
                deleting = note
            } label: {
                // Already red: the compact row paints glyphs in the app's tint.
                Label {
                    Text("Delete")
                } icon: {
                    Image(uiImage: UIImage(systemName: "trash.fill")!
                        .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                }
            }
        }
        .controlGroupStyle(.compactMenu)
        let pinned = store.pinnedNotes.contains(note.id)
        Button(pinned ? "Unpin Note" : "Pin Note", systemImage: pinned ? "pin.slash" : "pin") {
            withAnimation(.snappy(duration: 0.3)) { store.togglePinned(note) }
            NoteActionsTip().invalidate(reason: .actionPerformed)
        }
        let locked = store.isLocked(note)
        Button(locked ? "Remove Lock" : "Lock Note", systemImage: locked ? "lock.open" : "lock") {
            toggleLock(note)
        }
        .disabled(!locked && !Biometrics.available)
        Button("Duplicate Note", systemImage: "plus.square.on.square") {
            duplicate(note)
        }
    }

    /// A locked note keeps its words out of sight until notes are unlocked.
    private func hides(_ note: Note) -> Bool {
        store.isLocked(note) && !store.lockedNotesOpen
    }

    /// Opens a note, asking for Face ID first when it is locked.
    private func open(_ note: Note) {
        guard store.isLocked(note) else {
            opened = .existing(note)
            return
        }
        Task {
            if await store.unlockNotes() { opened = .existing(note) }
        }
    }

    private func toggleLock(_ note: Note) {
        guard store.isLocked(note) else {
            withAnimation { store.setLocked(note, true) }
            return
        }
        // Taking a lock off is only for whoever can open it.
        Task {
            if await Biometrics.authenticate(reason: "Remove the lock from this note.") {
                withAnimation { store.setLocked(note, false) }
            }
        }
    }

    private func duplicate(_ note: Note) {
        Task {
            do {
                try await store.duplicate(note)
            } catch {
                deleteFailure = PlainWords.describe(error, doing: "copy the note")
            }
        }
    }

    private var selectionDeleteTitle: String {
        if selected.count == 1,
           let id = selected.first,
           let note = store.notes(in: scope).first(where: { $0.id == id }) {
            return Self.deleteTitle(for: note)
        }
        return selected.count <= 1 ? "Delete this note?" : "Delete these \(selected.count) notes?"
    }

    private static func deleteTitle(for note: Note) -> String {
        let name = NotesFeed.title(of: note)
        return name.isEmpty ? "Delete this note?" : "Delete the note “\(name)”?"
    }

    private func delete(_ note: Note) {
        NoteActionsTip().invalidate(reason: .actionPerformed)
        Task {
            do {
                try await store.deleteNote(note)
            } catch {
                deleteFailure = PlainWords.describe(error, doing: "delete the note")
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await store.refreshNotes()
            loadFailure = nil
        } catch {
            loadFailure = PlainWords.describe(error, doing: "load the notes")
        }
    }

}

/// A row darkens while a finger is on it, as rows in Notes do, so pressing
/// before a swipe or a tap is felt on screen.
private struct NoteCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0))
            }
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25),
                       value: configuration.isPressed)
    }
}

struct NoteRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0))
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25),
                       value: configuration.isPressed)
    }
}

enum SwipeSide { case leading, trailing }

/// Swiped left, a row slides aside for a round red Delete; swiped right, for a
/// round gold Pin — as in Notes. Swiped back, tapped, or another row opened, it
/// closes.
///
/// While it is moved, the row is drawn as a card of its own — the list's
/// corner radius, over the page — so it reads as lifted off the list rather
/// than as its text sliding across a background that stays put.
struct SwipeToDelete: ViewModifier {
    @Binding var openSide: SwipeSide?
    let shareText: String
    let pinned: Bool
    let onPin: () -> Void
    /// When the last swipe ended, so the tap that ends a swipe does not also
    /// open the note.
    @Binding var lastSwipe: Date
    /// On while the row is out of place, so the list can hide its separators.
    @Binding var moving: Bool
    let onDelete: () -> Void
    /// Not wired to anything yet.
    var onMove: () -> Void = {}
    /// Off for rows that cannot be pinned: nothing opens to the right.
    var allowsPin = true
    /// How tall the row is, when it is a fixed height. Given rather than
    /// measured: a stack is as tall as its tallest child, so the buttons
    /// decided the height of a short row and it grew the moment it was
    /// swiped. Nil keeps a note's behaviour, where the row is the taller one.
    var rowHeight: CGFloat? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var drag: CGFloat = 0
    @State private var passedOpen: SwipeSide?
    @State private var rowWidth: CGFloat = 390
    /// Past the middle of the row, letting go pins, as a tap on Pin would.
    @State private var fullSwipe = false
    /// How far a row opens to the right for Pin, and the width of each action.
    private static let reveal: CGFloat = 92
    private static let slot: CGFloat = 62
    /// Share, Move and Delete, side by side.
    private static let trailingReveal: CGFloat = slot * 3 + 8
    private static let corner: CGFloat = 26
    private static let gold = Color(red: 0.95, green: 0.60, blue: 0.10)

    private var resting: CGFloat {
        switch openSide {
        case .trailing: -Self.trailingReveal
        case .leading: Self.reveal
        case nil: 0
        }
    }

    private var offset: CGFloat {
        let raw = resting + drag
        // A little give past fully open to delete; to pin, the row follows
        // the finger all the way, stretching the button.
        if raw < -Self.trailingReveal {
            return -Self.trailingReveal + (raw + Self.trailingReveal) * 0.3
        }
        return min(raw, allowsPin ? rowWidth - 24 : 0)
    }

    private func side(at position: CGFloat) -> SwipeSide? {
        position < -Self.trailingReveal / 2 ? .trailing : position > Self.reveal / 2 ? .leading : nil
    }

    /// How much of the `position`th action from the right edge the swipe has
    /// uncovered: each comes in over its own stretch of the swipe, Delete
    /// first and Share last, as the row reveals them.
    private func revealed(_ position: Int) -> CGFloat {
        // Each grows over the first two thirds of its stretch and is whole
        // for the last third, so one is finished, a little more pull changes
        // nothing, and only then does the next begin.
        let uncovered = max(0, -offset) - CGFloat(position) * Self.slot
        return min(1, max(0, uncovered / (Self.slot * 0.66)))
    }

    /// True for a row too short to hold a button with its name under it — a
    /// folder's, at 50pt. A note's is 74 and keeps both.
    private var compact: Bool { (rowHeight ?? 74) < 72 }

    private func actionFace(_ title: String, symbol: String, tint: Color) -> some View {
        let circle = Image(systemName: symbol)
            .font(.system(size: compact ? 15 : 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: compact ? 38 : 50, height: compact ? 38 : 50)
            .background(tint, in: .circle)
        return VStack(spacing: 6) {
            circle
            // The name is what made the buttons taller than a folder's row,
            // and a row that grew when swiped was the bug. The glyph says it
            // on its own at this size; the held menu still spells it out.
            if !compact {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: Self.slot)
        .contentShape(.rect)
    }

    private func action(
        _ title: String, symbol: String, tint: Color, shown: CGFloat, run: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { openSide = nil }
            run()
        } label: {
            actionFace(title, symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        // From almost nothing, not from a smaller button.
        .scaleEffect(max(0.01, shown))
        .opacity(shown)
        .accessibilityLabel(title)
    }

    /// Round at rest; pulled further, it stretches right behind the row, with
    /// its glyph and its name kept in the middle of it.
    private func pinAction(shown: CGFloat) -> some View {
        let inset = (Self.reveal - 50) / 2
        let width = max(50, offset - inset * 2)
        let title = pinned ? "Unpin" : "Pin"
        return Button {
            withAnimation(.snappy(duration: 0.25)) { openSide = nil }
            onPin()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Capsule().fill(Self.gold)
                    Image(systemName: pinned ? "pin.slash.fill" : "pin.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: width, height: 50)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: width)
            .padding(.leading, inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .scaleEffect(0.6 + 0.4 * shown, anchor: .leading)
        .opacity(shown)
        .allowsHitTesting(openSide == .leading && drag == 0)
        .accessibilityLabel(title)
    }

    func body(content: Content) -> some View {
        let leadingShown = min(1, max(0, offset) / Self.reveal)
        let moved = offset != 0
        ZStack {
            // The page shows through where the row has moved away from.
            if moved {
                Palette.background(scheme)
            }
            HStack(spacing: 0) {
                if allowsPin { pinAction(shown: leadingShown) }
                Spacer(minLength: 0)
                // Close together once all three are out; pulled further, they
                // spread apart with the pull.
                HStack(spacing: max(0, -offset - Self.trailingReveal) / 2) {
                    ShareLink(item: shareText.isEmpty ? " " : shareText) {
                        actionFace("Share", symbol: "square.and.arrow.up.fill", tint: .blue)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        withAnimation(.snappy(duration: 0.25)) { openSide = nil }
                    })
                    .scaleEffect(max(0.01, revealed(2)))
                    .opacity(revealed(2))
                    .accessibilityLabel("Share")
                    // Not wired to anything yet.
                    action("Move", symbol: "folder.fill", tint: .purple, shown: revealed(1), run: onMove)
                    action("Delete", symbol: "trash.fill", tint: .red, shown: revealed(0), run: onDelete)
                }
                .padding(.trailing, 4)
                .allowsHitTesting(openSide == .trailing && drag == 0)
            }
            // Never taller than the row it sits behind: a stack is as tall as
            // its tallest child, and the buttons were making short rows grow
            // the moment they were swiped.
            .frame(height: rowHeight)

            content
                // Darkened while out of place, as a held row is: a pan takes
                // the touch from the row's button, which then stops showing
                // it is pressed.
                .background {
                    RoundedRectangle(cornerRadius: moved ? Self.corner : 0)
                        .fill(Palette.card(scheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: moved ? Self.corner : 0)
                                // And stays so while left open on its buttons.
                                .fill(Color.primary.opacity(moving || openSide != nil ? 0.09 : 0))
                        }
                }
                .offset(x: offset)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // A UIKit pan that only starts when the finger starts sideways. A
        // SwiftUI drag on every row took the list's own scrolling from it:
        // flicks that began on a note did not scroll, and let go, opened it.
        .gesture(SidewaysPan(
            // Without Pin a rightward swipe is not the row's: it closes Notes.
            allowsRightward: allowsPin || openSide != nil,
            onTouch: { if allowsPin { store.noteRowTouchedAt = .now } },
            onChange: { translation in
                lastSwipe = .now
                if !moving { moving = true }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { drag = translation }
                let past = side(at: offset)
                if past != passedOpen {
                    // Felt only on the way to Pin; opening onto Share, Move
                    // and Delete is silent.
                    if past == .leading || passedOpen == .leading {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    passedOpen = past
                }
                let full = offset > rowWidth / 2
                if full != fullSwipe {
                    fullSwipe = full
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            },
            onEnd: { _, projected in
                lastSwipe = .now
                if fullSwipe {
                    fullSwipe = false
                    passedOpen = nil
                    withAnimation(.snappy(duration: 0.3)) {
                        drag = 0
                        openSide = nil
                    } completion: {
                        moving = false
                    }
                    onPin()
                    return
                }
                let landing = side(at: resting + projected)
                withAnimation(.snappy(duration: 0.3)) {
                    drag = 0
                    openSide = landing
                } completion: {
                    moving = false
                }
                passedOpen = landing
            }
        ))
        .accessibilityAction(named: pinned ? "Unpin" : "Pin") { onPin() }
        .accessibilityAction(named: "Delete") { onDelete() }
    }
}

/// A horizontal pan that declines to begin when the movement starts vertical,
/// leaving it to the scroll view, and cancels the row's tap once it has begun.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    /// Whether a swipe to the right is this row's to take.
    var allowsRightward = true
    /// A finger came down on the row, before anything is known of its movement.
    let onTouch: () -> Void
    let onChange: (CGFloat) -> Void
    /// The translation, and where a fling would carry it.
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(onTouch: onTouch)
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowsRightward = allowsRightward
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .began, .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, translation + pan.velocity(in: pan.view).x * 0.15)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onTouch: () -> Void
        var allowsRightward = true
        init(onTouch: @escaping () -> Void) { self.onTouch = onTouch }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            onTouch()
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            if velocity.x > 0, !allowsRightward { return false }
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

/// A note as it reads, shown above its menu when held: its styled text, its
/// date, and as much of it as fits.
private struct NotePreview: View {
    @Environment(\.colorScheme) private var scheme
    let note: Note
    var locked = false

    private var body_: AttributedString {
        let styled = RichNote.attributed(from: note)
        return (try? AttributedString(styled, including: \.uiKit)) ?? AttributedString(note.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let when = note.editedAt ?? note.createdAt {
                Text(when.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if locked {
                Label("This note is locked.", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(body_)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 340, alignment: .topLeading)
        .frame(minHeight: 160, maxHeight: 460, alignment: .topLeading)
        .background(Palette.card(scheme))
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
struct NoteDetail: View {
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
                if let tags = note.tags, !tags.isEmpty {
                    Section("Tags") {
                        Text(tags.map { "#\($0)" }.joined(separator: "  "))
                            .foregroundStyle(store.accent.primary(scheme))
                    }
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
