import Foundation

/// A note in the store an agent keeps on Hermes (the Inbox agent's), as the
/// Alice plugin serves it. The text is exactly what was written; everything
/// else is the agent's reading of it, filled in when it sorts its notes.
struct Note: Identifiable, Equatable, Sendable {
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
}

struct NotesSnapshot: Equatable, Sendable {
    /// False when no agent on this Hermes keeps a notes store.
    let available: Bool
    /// The agent that keeps them.
    let agent: String?
    let notes: [Note]
}

enum NotesFeed {
    static func snapshot(from object: [String: Any]) throws -> NotesSnapshot {
        guard let available = object["available"] as? Bool,
              let rows = object["notes"] as? [[String: Any]]
        else { throw DashboardClient.Failure.unreadable }
        return NotesSnapshot(
            available: available,
            agent: (object["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            notes: rows.compactMap(note(from:))
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
            processed: (row["processed"] as? Bool) ?? false
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

    /// Newest first, under when they were written.
    static func groups(
        _ notes: [Note], now: Date = Date(), calendar: Calendar = .current
    ) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var buckets: [(String, [Note])] = [("Today", []), ("Yesterday", []), ("This week", []), ("Earlier", [])]
        let sorted = notes.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        for note in sorted {
            let when = note.createdAt ?? .distantPast
            let slot = when >= today ? 0 : when >= yesterday ? 1 : when >= week ? 2 : 3
            buckets[slot].1.append(note)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, notes: $0.1) }
    }

    /// Whether a note answers a search: its words, or how the agent sorted it.
    static func matches(_ note: Note, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = ([note.text, note.summary] + note.topics + note.types.map(label(forType:)))
        return haystack.contains { $0.localizedStandardContains(query) }
    }
}
