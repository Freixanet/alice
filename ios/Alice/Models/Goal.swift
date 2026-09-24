import Foundation

/// Something the person wants reached over days or weeks, and Alice's plan
/// for it (`hermes-plugin/goals.py`).
struct Goal: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case active, paused, done }

    struct Step: Identifiable, Hashable, Sendable {
        enum Status: String, Sendable { case todo, doing, done }
        let id: String
        var text: String
        var status: Status
        var due: String?
        var doneAt: Date?
    }

    struct Entry: Hashable, Sendable {
        let at: Date
        let byPerson: Bool
        let text: String
    }

    let id: String
    var title: String
    var why: String
    var status: Status
    var due: String?
    var createdAt: Date
    var updatedAt: Date
    var steps: [Step]
    var log: [Entry]
    var routines: [String]

    var done: Int { steps.filter { $0.status == .done }.count }
    var progress: Double { steps.isEmpty ? (status == .done ? 1 : 0) : Double(done) / Double(steps.count) }
    var next: Step? { steps.first { $0.status == .doing } ?? steps.first { $0.status == .todo } }
    /// "30 sept" from "2026-09-30".
    var dueDate: Date? { due.flatMap(Goal.dayFormatter.date(from:)) }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ row: [String: Any]) -> Goal? {
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        func date(_ value: Any?) -> Date? {
            (value as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (value as? Int).map { Date(timeIntervalSince1970: Double($0)) }
        }
        let steps = (row["steps"] as? [[String: Any]] ?? []).compactMap { step -> Step? in
            guard let id = step["id"] as? String, let text = step["text"] as? String else { return nil }
            return Step(id: id, text: text,
                        status: Step.Status(rawValue: step["status"] as? String ?? "") ?? .todo,
                        due: step["due"] as? String, doneAt: date(step["done_at"]))
        }
        let log = (row["log"] as? [[String: Any]] ?? []).compactMap { entry -> Entry? in
            guard let at = date(entry["at"]), let text = entry["text"] as? String else { return nil }
            return Entry(at: at, byPerson: (entry["by"] as? String) == "person", text: text)
        }
        return Goal(
            id: id, title: title, why: row["why"] as? String ?? "",
            status: Status(rawValue: row["status"] as? String ?? "") ?? .active,
            due: row["due"] as? String, createdAt: date(row["created_at"]) ?? Date(),
            updatedAt: date(row["updated_at"]) ?? Date(), steps: steps, log: log,
            routines: row["routines"] as? [String] ?? []
        )
    }
}

/// What the person changes on a goal from the Goals tab.
struct GoalChange: Sendable {
    var status: Goal.Status?
    var note: String?
    var stepID: String?
    var stepStatus: Goal.Step.Status?
    var addStep: String?
    var removeStep = false

    var body: [String: Any] {
        var body: [String: Any] = [:]
        if let status { body["status"] = status.rawValue }
        if let note { body["note"] = note }
        if let stepID { body["step_id"] = stepID }
        if let stepStatus { body["step_status"] = stepStatus.rawValue }
        if let addStep { body["add_step"] = addStep }
        if removeStep { body["remove_step"] = true }
        return body
    }
}

extension DashboardClient {
    func goals(profile: String = "default") async throws -> [Goal] {
        let object = try await get("api/plugins/alice/goals?profile=\(profile)")
        return (object["goals"] as? [[String: Any]] ?? []).compactMap(Goal.parse)
    }

    func createGoal(title: String, why: String, profile: String = "default") async throws -> Goal? {
        let object = try await send("POST", "api/plugins/alice/goals",
                                    ["profile": profile, "title": title, "why": why])
        return (object["goal"] as? [String: Any]).flatMap(Goal.parse)
    }

    func changeGoal(_ id: String, _ change: GoalChange, profile: String = "default") async throws -> Goal? {
        var body = change.body
        body["profile"] = profile
        let object = try await send("PATCH", "api/plugins/alice/goals/\(id)", body)
        return (object["goal"] as? [String: Any]).flatMap(Goal.parse)
    }

    func deleteGoal(_ id: String, profile: String = "default") async throws {
        _ = try await send("DELETE", "api/plugins/alice/goals/\(id)?profile=\(profile)")
    }
}
