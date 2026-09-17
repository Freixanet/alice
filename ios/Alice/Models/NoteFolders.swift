import Foundation

/// A folder of notes the person made. Kept on this phone.
struct NoteFolder: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
}

/// A note deleted from its store, kept here for a while so it can come back.
struct DeletedNote: Codable, Hashable, Identifiable, Sendable {
    let note: Note
    let deletedAt: Date
    /// The folder it was in, to return to on recovery.
    let folderID: String?
    var id: String { note.id }

    /// How long Recently Deleted keeps a note, as Notes does.
    static let kept: TimeInterval = 30 * 24 * 60 * 60
}

/// Which notes a Notes page shows.
enum NotesScope: Hashable, Sendable {
    /// Every note there is, wherever it is filed.
    case all
    /// Every note not put in a folder of its own.
    case quick
    case folder(String)
    case deleted
}

/// Which folder sits inside which.
///
/// The notes store an agent keeps is a flat set of folders — it files a note
/// under one name and reads it back under that name — so nesting is an
/// arrangement of the folders page, kept on the phone as a child → parent map.
/// The rules are here, away from the store, because they are the part that can
/// be got wrong: a folder inside itself takes it and everything in it off the
/// page, with no way back to either.
enum NoteFolderTree {
    /// The folders shown at the top level: the ones with no parent, and the
    /// ones whose parent is gone — an orphan comes back rather than vanishing
    /// with the folder that held it.
    static func roots(_ folders: [NoteFolder], parent: [String: String]) -> [NoteFolder] {
        let known = Set(folders.map(\.id))
        return folders.filter { folder in
            guard let above = parent[folder.id] else { return true }
            return !known.contains(above)
        }
    }

    static func children(of id: String, in folders: [NoteFolder], parent: [String: String]) -> [NoteFolder] {
        folders.filter { parent[$0.id] == id }
    }

    /// Whether `id` is inside `ancestor`, at any depth. Walks up, and stops if
    /// the map ever loops so a broken map cannot hang the page.
    static func isInside(_ id: String, _ ancestor: String, parent: [String: String]) -> Bool {
        var seen: Set<String> = []
        var walk = parent[id]
        while let current = walk, !seen.contains(current) {
            if current == ancestor { return true }
            seen.insert(current)
            walk = parent[current]
        }
        return false
    }

    /// The map after moving `id` into `parentID` (nil = the top level), or the
    /// map unchanged when the move would put a folder inside itself.
    static func moving(
        _ id: String, into parentID: String?, parent: [String: String]
    ) -> [String: String] {
        var map = parent
        guard let parentID else {
            map[id] = nil
            return map
        }
        guard parentID != id, !isInside(parentID, id, parent: parent) else { return parent }
        map[id] = parentID
        return map
    }

    /// The map after a folder is deleted: it is forgotten, and whatever was
    /// inside it comes back to the top level.
    static func removing(_ id: String, from parent: [String: String]) -> [String: String] {
        parent.filter { $0.key != id && $0.value != id }
    }
}

/// The order notes are listed in.
enum NotesSort: String, CaseIterable, Identifiable, Sendable {
    case dateEdited, dateCreated, title
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateEdited: "Date Edited"
        case .dateCreated: "Date Created"
        case .title: "Title"
        }
    }
}
