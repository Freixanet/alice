import Foundation

/// How the Mac answered one event from the outbox (`POST /feed/{id}/events`).
enum FeedEventOutcome: Sendable, Equatable {
    /// Applied now, or already applied (the same id arrived before): either way it is done.
    case accepted
    /// The post is no longer kept on the Mac (404/410): nothing to retry.
    case expired
    /// The Mac refused it as malformed (400): retrying would never help.
    case invalid(String)
    /// Unreachable, or the Mac failed (5xx): kept and tried again on the next sync.
    case retry
}

/// The feed's routes on the Alice dashboard plugin (`feed.py`). JSON is decoded into
/// `FeedPayload`; nothing here keeps state.
extension DashboardClient {
    private static let feedDecoder = JSONDecoder()

    func feed() async throws -> FeedPayload {
        let (data, response) = try await raw("GET", "api/plugins/alice/feed")
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return try Self.feedDecoder.decode(FeedPayload.self, from: data)
    }

    func feedStatus() async throws -> FeedPayload {
        let (data, response) = try await raw("GET", "api/plugins/alice/feed/status")
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return try Self.feedDecoder.decode(FeedPayload.self, from: data)
    }

    func generateFeed() async throws {
        try await send("POST", "api/plugins/alice/feed/generate")
    }

    /// Saves the brief; true when it changed and a run was asked for (or left pending).
    @discardableResult
    func saveFeedBrief(_ text: String) async throws -> Bool {
        let object = try await send("PUT", "api/plugins/alice/feed/brief", ["text": text])
        return object["changed"] as? Bool ?? false
    }

    func postFeedEvent(_ event: FeedEvent) async -> FeedEventOutcome {
        var body: [String: Any] = [
            "id": event.id.uuidString.lowercased(),
            "kind": event.kind.rawValue,
            "createdAt": event.createdAt.timeIntervalSince1970,
        ]
        if let on = event.on { body["on"] = on }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let postID = event.postID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return .invalid("unencodable") }
        do {
            let (reply, response) = try await raw(
                "POST", "api/plugins/alice/feed/\(postID)/events", body: data, contentType: "application/json"
            )
            switch response.statusCode {
            case 200..<300: return .accepted
            case 404, 410: return .expired
            case 400, 422: return .invalid(String(data: reply, encoding: .utf8) ?? "")
            default: return .retry
            }
        } catch {
            return .retry
        }
    }
}
