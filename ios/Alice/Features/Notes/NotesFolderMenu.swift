import SwiftUI

/// The one button a folder has, top right, and everything it can do.
///
/// Notes puts all of this behind a single `•••` rather than a row of glyphs,
/// and so does this: a folder's own actions (share it, nest one inside it,
/// move it, rename it) sit together under the divider, and how the notes are
/// shown — gallery, order, dates, attachments — stays in the same place in
/// every folder, so it is found in the same place every time.
///
/// All Notes is every note there is, wherever it is filed. It has no folder
/// actions because there is no folder: it cannot be renamed, moved, shared as
/// a folder or nested. Quick Notes keeps the ones that mean something for it —
/// the store owns that name, so it cannot be renamed or moved either.
struct NotesFolderMenu: View {
    let scope: NotesScope
    /// Turns on the mode where notes are ticked rather than opened.
    @Binding var selecting: Bool
    /// The folder's notes as one piece of text. A closure, not a string: menu
    /// content is built when the menu opens, so nothing is joined until then.
    var shareText: () -> String = { "" }
    var onAddFolder: () -> Void = {}
    var onMoveFolder: () -> Void = {}
    var onRename: () -> Void = {}
    var onAttachments: () -> Void = {}

    @Environment(AppStore.self) private var store

    /// Whether this is a folder of the person's own, with folder actions.
    private var isOwnFolder: Bool { if case .folder = scope { true } else { false } }
    /// Quick Notes and the person's folders can be shared; All Notes is not a
    /// folder to share, it is everything.
    private var isShareable: Bool { scope != .all }

    var body: some View {
        @Bindable var store = store
        Menu {
            // Says what the tap does, not what is on screen, the way Notes
            // does: in a list it offers the gallery, in the gallery the list.
            Button(
                store.notesAsCards ? "View as List" : "View as Gallery",
                systemImage: store.notesAsCards ? "list.bullet" : "square.grid.2x2"
            ) {
                withAnimation(.snappy(duration: 0.25)) { store.notesAsCards.toggle() }
            }

            Divider()

            if isShareable {
                ShareLink(item: shareText()) {
                    Label("Share Folder", systemImage: "square.and.arrow.up")
                }
            }
            if isOwnFolder {
                Button("Add Folder", systemImage: "folder.badge.plus", action: onAddFolder)
                Button("Move This Folder", systemImage: "folder", action: onMoveFolder)
                Button("Rename", systemImage: "pencil", action: onRename)
            }
            Button("Select Notes", systemImage: "checkmark.circle") { selecting = true }

            // The chosen option is written under the row, quietly, so the menu
            // says how the notes are ordered without being opened twice.
            Menu {
                Picker("Sort By", selection: $store.notesSort) {
                    ForEach(NotesSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort By")
                Text(store.notesSort.label)
                Image(systemName: "arrow.up.arrow.down")
            }

            Menu {
                Picker("Sort Folders", selection: $store.noteFolderSort) {
                    ForEach(NoteFolderSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort Folders")
                Text(store.noteFolderSort.label)
                Image(systemName: "folder")
            }

            Menu {
                Picker("Group By Date", selection: $store.notesGroupByDate) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Text("Group By Date")
                Text(store.notesGroupByDate ? "On" : "Off")
                Image(systemName: "calendar")
            }

            Button("View Attachments", systemImage: "paperclip", action: onAttachments)
        } label: {
            Image(systemName: "ellipsis")
                .contentShape(.circle)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("notes.folderMenu")
    }
}
