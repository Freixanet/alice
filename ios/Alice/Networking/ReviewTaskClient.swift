import Foundation

struct ReviewTaskClient: Sendable {
    let dashboard: DashboardClient
    func load() async throws -> ReviewTaskSnapshot { try await dashboard.reviewTaskSnapshot() }
    func configure(_ autonomy: String) async throws { try await dashboard.configureTaskAutonomy(autonomy) }
    func respond(_ task: ReviewTask, action: String, message: String = "") async throws -> ReviewTask { try await dashboard.respondToTask(task, action: action, message: message) }
    func claim(_ task: ReviewTask, aliases: [String]) async throws { try await dashboard.claimTaskContinuation(task, aliases: aliases) }
    func continuationResult(_ task: ReviewTask, state: String) async throws { try await dashboard.recordTaskContinuation(task, state: state) }
}

extension DashboardClient {
    func reviewTaskSnapshot() async throws -> ReviewTaskSnapshot {
        try decode(ReviewTaskSnapshot.self, from: await get("api/plugins/alice/review-tasks"))
    }
    func configureTaskAutonomy(_ autonomy: String) async throws {
        _ = try await send("PUT", "api/plugins/alice/review-tasks/autonomy", ["autonomy": autonomy])
    }
    func respondToTask(_ task: ReviewTask, action: String, message: String = "") async throws -> ReviewTask {
        let object = try await send("POST", path(task, "decision"), ["version": task.version, "action": action, "message": message])
        return try decode(ReviewTask.self, from: object["task"] as? [String: Any] ?? [:])
    }
    func claimTaskContinuation(_ task: ReviewTask, aliases: [String]) async throws {
        _ = try await send("POST", path(task, "continue"), ["version": task.version, "aliases": aliases])
    }
    func recordTaskContinuation(_ task: ReviewTask, state: String) async throws {
        _ = try await send("POST", path(task, "continuation-result"), ["version": task.version, "state": state])
    }
    private func path(_ task: ReviewTask, _ action: String) throws -> String {
        guard task.id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw DashboardClient.Failure.unreadable }
        return "api/plugins/alice/review-tasks/\(task.id)/\(action)"
    }
    private func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}
