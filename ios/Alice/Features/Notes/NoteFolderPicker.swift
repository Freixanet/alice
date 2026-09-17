import SwiftUI

/// What is being moved, and where it may go.
enum NoteMove: Identifiable {
    /// A folder, into another or back out to the top level.
    case folder(String)
    /// Notes, into a folder of the store or back to Quick Notes.
    case notes(Set<String>)

    var id: String {
        switch self {
        case let .folder(id): "folder:\(id)"
        case let .notes(ids): "notes:\(ids.sorted().joined(separator: ","))"
        }
    }
}

/// Where it goes: the folders, as a list to pick one from.
///
/// One sheet for both kinds of move, because the question is the same one. What
/// changes is what may be picked: notes can go to Quick Notes, a folder can go
/// to the top level, and a folder can never be moved into itself or into
/// anything already inside it — that would take it and everything in it off
/// the page with no way back.
struct NoteFolderPicker: View {
    let moving: NoteMove
    /// The folder the move was started from, so it is not offered as a
    /// destination for its own notes.
    var from: NotesScope = .all
    var onDone: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var isFolder: Bool { if case .folder = moving { true } else { false } }

    private var title: String {
        switch moving {
        case .folder: "Move Folder"
        case let .notes(ids): ids.count == 1 ? "Move Note" : "Move \(ids.count) Notes"
        }
    }

    /// The folders that may be picked.
    private var choices: [NoteFolder] {
        switch moving {
        case let .folder(id):
            store.noteFolders.filter { $0.id != id && !store.noteFolder($0.id, isInside: id) }
        case .notes:
            store.noteFolders.filter { folder in
                if case let .folder(current) = from { return folder.id != current }
                return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        move(to: nil)
                    } label: {
                        row(
                            name: isFolder ? "Top Level" : "Quick Notes",
                            systemImage: isFolder ? "tray.full" : "note.text"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Palette.card(scheme))

                if !choices.isEmpty {
                    Section {
                        ForEach(choices) { folder in
                            Button {
                                move(to: folder.id)
                            } label: {
                                row(name: folder.name, systemImage: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background { Palette.background(scheme).ignoresSafeArea() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(name: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(store.accent.primary(scheme))
                .frame(width: 24)
            Text(name).foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    /// `nil` is the top level for a folder, Quick Notes for notes.
    private func move(to destination: String?) {
        switch moving {
        case let .folder(id):
            store.moveNoteFolder(id, into: destination)
        case let .notes(ids):
            let scope: NotesScope = destination.map { .folder($0) } ?? .quick
            Task {
                for id in ids { await store.put(id, in: scope) }
            }
        }
        onDone()
        dismiss()
    }
}
