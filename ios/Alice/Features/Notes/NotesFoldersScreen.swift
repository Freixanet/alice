import SwiftUI

/// Where Notes opens: the folders, with Quick Notes first.
///
/// Quick Notes holds every note not filed elsewhere, so nothing is ever out of
/// reach; the person's own folders follow; Recently Deleted comes last and only
/// while it holds something. New folders from the top right; search and a new
/// note from the bottom, as in Notes.
struct NotesFoldersScreen: View {
    var onClose: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var naming: Naming?
    @State private var folderName = ""
    @State private var deletingFolder: NoteFolder?
    @State private var opened: NoteEditor.Target?
    @State private var openedFolder: NotesScope?
    /// The one folder swiped open on its buttons, and when the swipe ended, so
    /// the tap that closes it does not also open the folder.
    @State private var swipedFolder: String?
    @State private var lastSwipe = Date.distantPast
    @State private var movingFolder: String?
    /// Folders closed by hand. Absent means open: a folder just put inside
    /// another must not look as if it had been lost.
    @State private var collapsed: Set<String> = []
    /// Where a folder is being moved to, when one is.
    @State private var moving: NoteMove?

    /// Making a folder, or renaming one.
    private enum Naming: Identifiable {
        case new
        case rename(NoteFolder)
        var id: String {
            switch self {
            case .new: "new"
            case let .rename(folder): folder.id
            }
        }
    }

    private var found: [Note] {
        (store.notesSnapshot?.notes ?? []).filter { NotesFeed.matches($0, query: query) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                // Quick Notes on its own: every note starts there, and it is
                // not one folder among the person's own.
                Section {
                    folderRow(.quick, systemImage: "note.text")
                        .contextMenu {
                            ShareLink(item: shareText(.quick)) {
                                Label("Share", systemImage: "square.and.arrow.up.fill")
                            }
                        } preview: {
                            FolderPreview(name: store.name(of: .quick), notes: store.notes(in: .quick))
                        }
                        .listRowInsets(EdgeInsets())
                }
                .listRowBackground(Palette.card(scheme))
                Section {
                    // All Notes heads the folders, as the whole store rather
                    // than a folder of it: it is where everything can be found
                    // at once, so it belongs with the places, not above them.
                    folderRow(.all, systemImage: "tray.full")
                        .contextMenu {} preview: {
                            FolderPreview(name: store.name(of: .all), notes: store.notes(in: .all))
                        }
                        .listRowInsets(EdgeInsets())
                    // Then the person's own, each followed by what is inside
                    // it, one step indented. The store keeps its folders flat;
                    // the nesting is this phone's arrangement.
                    ForEach(store.rootNoteFolders) { folder in
                        let children = store.subfolders(of: folder.id)
                        customFolderRow(folder, expanded: children.isEmpty ? nil : Binding(
                            get: { !collapsed.contains(folder.id) },
                            set: { open in
                                if open { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
                            }
                        ))
                        if !collapsed.contains(folder.id) {
                            ForEach(children) { child in
                                customFolderRow(child, depth: 1)
                            }
                        }
                    }
                    if !store.recentlyDeleted.isEmpty {
                        folderRow(.deleted, systemImage: "trash")
                            .contextMenu {} preview: {
                                FolderPreview(name: store.name(of: .deleted), notes: store.notes(in: .deleted))
                            }
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listRowBackground(Palette.card(scheme))
            } else {
                Section {
                    if found.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(found) { note in
                        Button {
                            guard store.isLocked(note) else { opened = .existing(note); return }
                            Task { if await store.unlockNotes() { opened = .existing(note) } }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NotesFeed.title(of: note))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    if let when = NotesFeed.whenLabel(note) {
                                        Text(when).foregroundStyle(.primary.opacity(0.75))
                                    }
                                    Text(store.isLocked(note) && !store.lockedNotesOpen
                                         ? "Locked" : NotesFeed.body(of: note) ?? "No additional text")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .font(.subheadline)
                                Text(store.name(of: store.noteFolderOf[note.id].map { .folder($0) } ?? .quick))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .contentMargins(.top, 36, for: .scrollContent)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.inline)
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
                    folderName = ""
                    naming = .new
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
                .accessibilityIdentifier("notes.newFolder")
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if store.notesSnapshot?.available != false {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    // A new note from here is a Quick Note.
                    Button("New Note", systemImage: "plus") { opened = .new(UUID()) }
                        .accessibilityIdentifier("notes.new")
                }
            }
        }
        .task { try? await store.refreshNotes() }
        .refreshableWithFeedback { try? await store.refreshNotes() }
        .navigationDestination(item: $openedFolder) { scope in
            if scope == .deleted {
                RecentlyDeletedScreen()
            } else {
                NotesScreen(scope: scope)
            }
        }
        .navigationDestination(item: $opened) { target in
            NoteEditor(target: target, agent: store.notesSnapshot?.agent, folder: .quick)
        }
        .sheet(item: $moving) { what in
            NoteFolderPicker(moving: what)
        }
        .alert(
            namingTitle,
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
        ) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
        } message: {
            Text("A name for this folder.")
        }
        .alert(
            "Folder not changed",
            isPresented: Binding(
                get: { store.noteFolderFailure != nil },
                set: { if !$0 { store.noteFolderFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.noteFolderFailure ?? "")
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible,
            presenting: deletingFolder
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                Task { await store.deleteNoteFolder(folder.id) }
            }
        } message: { _ in
            Text("Its notes are not deleted. They go back to Quick Notes.")
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename Folder" }
        return "New Folder"
    }

    private func saveName() {
        switch naming {
        case .new:
            let name = folderName
            Task { await store.createNoteFolder(named: name) }
        case let .rename(folder):
            let name = folderName
            Task { await store.renameNoteFolder(folder.id, to: name) }
        case nil: break
        }
        naming = nil
    }

    /// A folder the person made: opened by a tap, and swiped or held for Share,
    /// Move and Delete, and Rename.
    private func customFolderRow(
        _ folder: NoteFolder, depth: Int = 0, expanded: Binding<Bool>? = nil
    ) -> some View {
        folderRow(.folder(folder.id), systemImage: "folder", depth: depth, expanded: expanded)
            .contextMenu {
                // Share, Move and Delete side by side at the top, as in Notes;
                // solid glyphs, Delete's red.
                ControlGroup {
                    ShareLink(item: shareText(.folder(folder.id))) {
                        Label("Share", systemImage: "square.and.arrow.up.fill")
                    }
                    Button("Move", systemImage: "folder.fill") { moving = .folder(folder.id) }
                    Button(role: .destructive) {
                        deletingFolder = folder
                    } label: {
                        // The compact row draws its glyphs in the app's tint,
                        // destructive or not; an image already red stays red.
                        Label {
                            Text("Delete")
                        } icon: {
                            Image(uiImage: UIImage(systemName: "trash.fill")!
                                .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                        }
                    }
                }
                .controlGroupStyle(.compactMenu)
                Button("Rename", systemImage: "pencil") {
                    folderName = folder.name
                    naming = .rename(folder)
                }
            } preview: {
                FolderPreview(name: store.name(of: .folder(folder.id)), notes: store.notes(in: .folder(folder.id)))
            }
            // The same swipe a note has, so a folder darkens under the finger
            // and stays darkened while it is left open on its buttons — the
            // system's own swipe actions draw the buttons but never touch the
            // row, which is what made folders feel like a different app.
            // Nothing to pin: a folder opens to the left only.
            .modifier(SwipeToDelete(
                openSide: Binding(
                    get: { swipedFolder == folder.id ? .trailing : nil },
                    set: { side in
                        if side != nil {
                            swipedFolder = folder.id
                        } else if swipedFolder == folder.id {
                            swipedFolder = nil
                        }
                        store.noteRowOpen = swipedFolder != nil
                    }
                ),
                shareText: shareText(.folder(folder.id)),
                pinned: false,
                onPin: {},
                lastSwipe: $lastSwipe,
                moving: Binding(
                    get: { movingFolder == folder.id },
                    set: { now in
                        movingFolder = now ? folder.id : (movingFolder == folder.id ? nil : movingFolder)
                    }
                ),
                onDelete: { deletingFolder = folder },
                onMove: { moving = .folder(folder.id) },
                allowsPin: false,
                rowHeight: Self.rowHeight
            ))
            .listRowInsets(EdgeInsets())
    }

    /// Every note in a folder as plain text, one after another, for Share.
    private func shareText(_ scope: NotesScope) -> String {
        store.notes(in: scope).map(\.text).joined(separator: "\n\n———\n\n")
    }

    private static let rowHeight: CGFloat = 50

    /// A folder as a row. `expanded` is given only to a folder with folders
    /// inside it: its chevron then opens and closes them instead of being the
    /// arrow every row has.
    private func folderRow(
        _ scope: NotesScope, systemImage: String, depth: Int = 0, expanded: Binding<Bool>? = nil
    ) -> some View {
        Button {
            // The end of a swipe is not a tap on the folder, and a tap while
            // one is open closes it rather than opening a page.
            guard Date.now.timeIntervalSince(lastSwipe) > 0.35 else { return }
            guard swipedFolder == nil else {
                withAnimation(.snappy(duration: 0.25)) { swipedFolder = nil }
                store.noteRowOpen = false
                return
            }
            openedFolder = scope
        } label: {
            HStack(spacing: 12) {
                if depth > 0 {
                    // Enough to read as "inside the one above", no more: a deep
                    // indent pushed the name away from every other row's.
                    Spacer().frame(width: CGFloat(depth) * 12)
                }
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 26)
                Text(store.name(of: scope))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(store.notes(in: scope).count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // The arrow's place. It is drawn over the row rather than in
                // it, so that a folder with folders inside can give it its own
                // tap without nesting a button inside a button — which SwiftUI
                // resolves by giving the tap to the outer one.
                Color.clear.frame(width: 10, height: 14)
            }
            // Exactly the row's height, so the press darkens all of it: shorter
            // than the list's minimum row, it left light bands above and below.
            .padding(.horizontal, 20)
            .frame(height: Self.rowHeight)
            .contentShape(.rect)
        }
        // Darkens under the finger, as a note does.
        .buttonStyle(NoteRowPressStyle())
        .overlay(alignment: .trailing) { chevron(expanded) }
    }

    /// The arrow at the end of a folder's row: a plain one, or the control that
    /// shows and hides what is inside.
    @ViewBuilder
    private func chevron(_ expanded: Binding<Bool>?) -> some View {
        let arrow = Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        if let expanded {
            Button {
                withAnimation(.snappy(duration: 0.28)) { expanded.wrappedValue.toggle() }
            } label: {
                arrow
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    // A 14pt glyph is not a target; the padding is.
                    .padding(.vertical, 12)
                    .padding(.leading, 16)
                    .padding(.trailing, 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded.wrappedValue ? "Hide folders inside" : "Show folders inside")
        } else {
            arrow.padding(.trailing, 20)
        }
    }
}

/// What a folder holds, shown above its menu when held: its name and the first
/// of its notes, as titles with when they were written.
///
/// Handed its notes rather than reading the store: a context menu's preview is
/// drawn outside the app's view hierarchy, without its environment, and
/// reading the store there stopped the app.
private struct FolderPreview: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    let notes: [Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name)
                .font(.headline)
            if notes.isEmpty {
                Text("No notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(notes.prefix(6)) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(NotesFeed.title(of: note))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let when = NotesFeed.whenLabel(note) {
                            Text(when).foregroundStyle(.primary.opacity(0.75))
                        }
                        Text(NotesFeed.body(of: note) ?? "No additional text")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
            }
            if notes.count > 6 {
                Text("\(notes.count - 6) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .topLeading)
        .background(Palette.card(scheme))
    }
}

/// Deleted notes, kept on this phone for thirty days: recovered into their
/// store and folder, or let go.
struct RecentlyDeletedScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var recovering: Set<String> = []
    @State private var failure: String?
    @State private var confirmingAll = false

    private var deleted: [DeletedNote] {
        store.recentlyDeleted.sorted { $0.deletedAt > $1.deletedAt }
    }

    var body: some View {
        List {
            Section {
                ForEach(deleted) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NotesFeed.title(of: item.note))
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(daysLeft(item))
                                .foregroundStyle(.primary.opacity(0.75))
                            Text(NotesFeed.body(of: item.note) ?? "No additional text")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                        if recovering.contains(item.id) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Recover", systemImage: "arrow.uturn.backward") { recover(item) }
                        Button("Delete Now", systemImage: "trash", role: .destructive) {
                            withAnimation { store.deleteForever(item) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Recover", systemImage: "arrow.uturn.backward") { recover(item) }
                            .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            withAnimation { store.deleteForever(item) }
                        }
                    }
                }
            } footer: {
                Text("Notes are available here for 30 days, then deleted from this iPhone. Recovering one writes it back to the notes store.")
            }
            .listRowBackground(Palette.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 36, for: .scrollContent)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete All", role: .destructive) { confirmingAll = true }
                    .disabled(deleted.isEmpty)
            }
        }
        .onAppear { store.notesFolderOpen = true }
        .onDisappear { store.notesFolderOpen = false }
        .onChange(of: deleted.isEmpty) { _, empty in if empty { dismiss() } }
        .confirmationDialog("Delete all these notes now?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAllForever() }
        } message: {
            Text("They can’t be recovered afterwards.")
        }
        .alert(
            "Note not recovered",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func daysLeft(_ item: DeletedNote) -> String {
        let left = item.deletedAt.addingTimeInterval(DeletedNote.kept).timeIntervalSinceNow
        let days = max(1, Int((left / 86_400).rounded(.up)))
        return days == 1 ? "1 day" : "\(days) days"
    }

    private func recover(_ item: DeletedNote) {
        recovering.insert(item.id)
        Task {
            defer { recovering.remove(item.id) }
            do {
                try await store.recover(item)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not take the note back."
            }
        }
    }
}
