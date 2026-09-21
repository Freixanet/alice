import Foundation

/// A note in the store an agent keeps on Hermes (the Inbox agent's), as the
/// Alice plugin serves it. The text is exactly what was written; everything
/// else is the agent's reading of it, filled in when it sorts its notes.
struct Note: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let createdAt: Date?
    let text: String
    var urls: [String] = []
    var types: [String] = []
    var topics: [String] = []
    var actions: [String] = []
    var openQuestions: [String] = []
    var summary = ""
    /// The agent has read and sorted it.
    var processed = false
    /// Written on this phone, not yet confirmed saved by Hermes.
    var sending = false
    /// The styled copy written in the note editor, as base64 RTF. `text` stays
    /// the plain words, which is what agents read.
    var rich: String? = nil
    var editedAt: Date? = nil
    /// The folder it is filed in, by id; nil is Quick Notes.
    var folder: String? = nil
    /// What it is about, as its agent tagged it.
    var tags: [String]? = nil
}

struct NotesSnapshot: Equatable, Sendable, Codable {
    /// False when no agent on this Hermes keeps a notes store.
    let available: Bool
    /// The agent that keeps them.
    let agent: String?
    let notes: [Note]
    /// The store's folders, in the order made. Optional so a snapshot cached
    /// before folders existed still reads.
    var folders: [NoteFolder]? = nil

    /// The same snapshot with other notes (or folders), everything else kept.
    func with(notes: [Note]? = nil, folders: [NoteFolder]? = nil) -> NotesSnapshot {
        NotesSnapshot(
            available: available, agent: agent, notes: notes ?? self.notes,
            folders: folders ?? self.folders
        )
    }
}

/// Why Notes last failed to refresh, or that the store is ready / missing.
/// A failed refresh does not wipe the cached snapshot.
enum NotesAccess: Equatable, Sendable {
    case unknown
    case ready
    case noStore
    case offline
    case unauthorized
    case notConfigured
    case pluginMissing
    case failed(String)

    static func from(snapshot: NotesSnapshot) -> NotesAccess {
        snapshot.available ? .ready : .noStore
    }

    static func from(error: Error) -> NotesAccess {
        if let failure = error as? DashboardClient.Failure {
            switch failure {
            case .notConfigured: return .notConfigured
            case .unreachable, .timedOut: return .offline
            case .http(401, _): return .unauthorized
            case .http(404, _): return .pluginMissing
            default: break
            }
        }
        return .failed(PlainWords.describe(error, doing: "load the notes"))
    }
}

enum NotesFeed {
    static func snapshot(from object: [String: Any]) throws -> NotesSnapshot {
        guard let available = object["available"] as? Bool,
              let rows = object["notes"] as? [[String: Any]]
        else { throw DashboardClient.Failure.unreadable }
        return NotesSnapshot(
            available: available,
            agent: (object["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            notes: rows.compactMap(note(from:)),
            folders: (object["folders"] as? [[String: Any]])?.compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return NoteFolder(id: id, name: name)
            }
        )
    }

    static func note(from row: [String: Any]) -> Note? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let text = row["text"] as? String
        else { return nil }
        func strings(_ key: String) -> [String] { (row[key] as? [String]) ?? [] }
        return Note(
            id: id,
            createdAt: date(row["ts"] as? String),
            text: text,
            urls: strings("urls"),
            types: strings("types"),
            topics: strings("topics"),
            actions: strings("actions"),
            openQuestions: strings("open_questions"),
            summary: (row["summary"] as? String) ?? "",
            processed: (row["processed"] as? Bool) ?? false,
            rich: (row["rich"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            editedAt: date(row["edited_ts"] as? String),
            folder: (row["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            tags: row["tags"] as? [String]
        )
    }

    /// The store writes local time with its offset (`2026-09-14T09:00:00+02:00`).
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// The store's own words for what a note is, said in the app's.
    static func label(forType type: String) -> String {
        switch type {
        case "idea": "Idea"
        case "pensamiento": "Thought"
        case "observacion": "Observation"
        case "tarea": "Task"
        case "pregunta": "Question"
        case "dato": "Fact"
        case "decision": "Decision"
        case "recordatorio": "Reminder"
        case "recurso": "Link"
        case "proyecto": "Project"
        case "posible_proyecto": "Possible project"
        case "revisar": "To review"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    struct Group: Equatable {
        let title: String
        let notes: [Note]
    }

    /// Notes in the order asked for. Dates newest first; titles the way a phone
    /// sorts names, so accents and case fall where a reader expects them.
    static func ordered(_ notes: [Note], by sort: NotesSort) -> [Note] {
        switch sort {
        case .dateEdited:
            notes.sorted { when($0) > when($1) }
        case .dateCreated:
            notes.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .title:
            notes.sorted {
                title(of: $0).localizedStandardCompare(title(of: $1)) == .orderedAscending
            }
        }
    }

    /// When a note last changed, which is what Date Edited means for a note
    /// nobody has edited since writing it.
    private static func when(_ note: Note) -> Date {
        note.editedAt ?? note.createdAt ?? .distantPast
    }

    /// The notes in sections, under when they were written.
    ///
    /// `pinned` notes come first, under Pinned, and only there — whatever the
    /// order or the grouping, a pinned note is at the top or the pin did
    /// nothing. With `grouped` off there are no dates: one run of notes in the
    /// chosen order, which is the point of turning it off.
    static func groups(
        _ notes: [Note], pinned: Set<String> = [], sort: NotesSort = .dateCreated,
        grouped: Bool = true, now: Date = Date(), calendar: Calendar = .current
    ) -> [Group] {
        let sorted = ordered(notes, by: sort)
        let pinnedNotes = sorted.filter { pinned.contains($0.id) }
        let rest = sorted.filter { !pinned.contains($0.id) }
        let pinnedGroup = pinnedNotes.isEmpty ? [] : [Group(title: "Pinned", notes: pinnedNotes)]

        guard grouped else {
            return pinnedGroup + (rest.isEmpty ? [] : [Group(title: "", notes: rest)])
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var buckets: [(String, [Note])] = [("Today", []), ("Yesterday", []), ("This week", []), ("Earlier", [])]
        for note in rest {
            // Grouped by the same date the order is on, or a list sorted by
            // when it was edited would sit under the day it was written.
            let stamp = sort == .dateEdited ? when(note) : (note.createdAt ?? .distantPast)
            let slot = stamp >= today ? 0 : stamp >= yesterday ? 1 : stamp >= week ? 2 : 3
            buckets[slot].1.append(note)
        }
        return pinnedGroup + buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, notes: $0.1) }
    }

    /// A note's title: its first line with words in it.
    static func title(of note: Note) -> String {
        note.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// What follows the title, on one line; nil when the note is its title alone.
    static func body(of note: Note) -> String? {
        var lines = note.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }
        lines.removeFirst()
        let rest = lines.filter { !$0.isEmpty }.joined(separator: " ")
        return rest.isEmpty ? nil : rest
    }

    /// When a note was last written: the time today, the date before that.
    static func whenLabel(_ note: Note, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date = note.editedAt ?? note.createdAt else { return nil }
        guard calendar.isDate(date, inSameDayAs: now) else {
            return date.formatted(date: .numeric, time: .omitted)
        }
        // 24-hour, two digits each, whatever the phone's clock style: 09:05.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Whether a note answers a search: its words, or how the agent sorted it.
    static func matches(_ note: Note, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = ([note.text, note.summary] + note.topics + note.types.map(label(forType:))
            + (note.tags ?? []).flatMap { [$0, "#\($0)"] })
        return haystack.contains { $0.localizedStandardContains(query) }
    }
}
