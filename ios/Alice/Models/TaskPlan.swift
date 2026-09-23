import Foundation

/// The steps an agent set itself for a task, and where each stands.
///
/// Hermes' `todo` tool keeps the list. A bot chat's socket sends the whole
/// list after every change (`todo.updated`, with a revision); a gateway run
/// only says the tool was called, with the arguments — the whole list, or,
/// with `merge`, just the items that changed. Both end up here, so the chat
/// can show the plan as the work goes, not only a trace of tools.
struct TaskPlan: Hashable, Sendable, Codable {
    enum Status: String, Hashable, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
    }

    struct Item: Hashable, Sendable, Codable, Identifiable {
        let id: String
        var content: String
        var status: Status
        /// A subtask's parent, when Hermes nested it.
        var parent: String?
    }

    var items: [Item]
    /// Hermes' own counter; an older snapshot never replaces a newer one.
    var revision: Int

    var done: Int { items.filter { $0.status == .completed }.count }
    /// Steps that still count: cancelled ones are not part of the work.
    var total: Int { items.filter { $0.status != .cancelled }.count }
    var current: Item? { items.first { $0.status == .inProgress } }
    var isFinished: Bool { total > 0 && items.allSatisfy { $0.status == .completed || $0.status == .cancelled } }

    /// `{todos, revision}` from `todo.updated`, or the tool's own result.
    static func snapshot(_ payload: [String: Any]) -> TaskPlan? {
        guard let rows = payload["todos"] as? [[String: Any]] else { return nil }
        let revision = (payload["revision"] as? Int) ?? (payload["revision"] as? NSNumber)?.intValue ?? 0
        let items = rows.compactMap(item)
        guard !items.isEmpty || revision > 0 else { return nil }
        return TaskPlan(items: items, revision: revision)
    }

    /// The list after a change: a newer snapshot replaces it; a `todo` call
    /// replaces it, or with `merge` changes or adds the items it names.
    func applying(_ change: TaskPlanChange) -> TaskPlan? {
        switch change {
        case let .snapshot(plan):
            return plan.revision >= revision || items.isEmpty ? plan : nil
        case let .call(rows, merge):
            guard merge else {
                let items = rows.compactMap(\.item)
                return items.isEmpty ? nil : TaskPlan(items: items, revision: revision + 1)
            }
            var next = items
            for row in rows {
                if let index = next.firstIndex(where: { $0.id == row.id }) {
                    if let content = row.content { next[index].content = content }
                    if let status = row.status { next[index].status = status }
                } else if let item = row.item {
                    next.append(item)
                }
            }
            return TaskPlan(items: next, revision: revision + 1)
        }
    }

    static let empty = TaskPlan(items: [], revision: 0)

    private static func item(_ row: [String: Any]) -> Item? {
        guard let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init),
              let content = (row["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return nil }
        let status = (row["status"] as? String).flatMap { Status(rawValue: $0.lowercased()) } ?? .pending
        let parent = (row["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Item(id: id, content: content, status: status, parent: parent)
    }

    /// A `todo` call's arguments as a change, whichever shape the transport
    /// carried them in: a dictionary, or its JSON text.
    static func call(_ raw: Any?) -> TaskPlanChange? {
        var args = raw as? [String: Any]
        if args == nil, let text = raw as? String, let data = text.data(using: .utf8) {
            args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let args, let rows = args["todos"] as? [[String: Any]] else { return nil }
        let patches = rows.compactMap { row -> TaskPlanChange.Patch? in
            guard let id = ((row["id"] as? String) ?? (row["id"] as? Int).map(String.init))?
                .trimmingCharacters(in: .whitespaces), !id.isEmpty
            else { return nil }
            let content = (row["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TaskPlanChange.Patch(
                id: id,
                content: content?.isEmpty == false ? content : nil,
                status: (row["status"] as? String).flatMap { Status(rawValue: $0.lowercased()) },
                parent: (row["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return .call(patches, merge: (args["merge"] as? Bool) ?? false)
    }

    static func isTodoTool(_ name: String) -> Bool { name == "todo" || name == "todo_list" }
}

/// One change to a plan, as a transport reports it.
enum TaskPlanChange: Hashable, Sendable {
    /// The whole list (`todo.updated`).
    case snapshot(TaskPlan)
    /// A `todo` call: the items it names, replacing the list unless `merge`.
    case call([Patch], merge: Bool)

    struct Patch: Hashable, Sendable {
        let id: String
        var content: String?
        var status: TaskPlan.Status?
        var parent: String?

        /// As a new item; one without words is only an update.
        var item: TaskPlan.Item? {
            content.map { TaskPlan.Item(id: id, content: $0, status: status ?? .pending, parent: parent) }
        }
    }
}
