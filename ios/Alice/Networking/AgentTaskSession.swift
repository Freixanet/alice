import Foundation

/// An independent task uses the profile's tools and defaults, without opening,
/// clearing or changing its canonical Bot Chat. A missing saved session is an
/// error: replacing it could lose pending work or repeat an external action.
extension WebSocketBotChatSource {
    func openAgentTask(profile: String, taskID: String, storedID: String?) async throws -> HomeChatSession {
        let snapshot: JSONObject
        if let storedID {
            snapshot = try await resume(profile: profile, target: storedID)
        } else {
            // Recover a create whose response was lost before Alice could save
            // its ID. The UUID title is scoped to the profile by Hermes.
            let title = "Alice task \(taskID)"
            do {
                snapshot = try await resume(profile: profile, target: title)
            } catch let error where Self.isNotFound(error) {
                snapshot = try await rpc.call("session.create", JSONObject([
                    "profile": profile, "title": title,
                ]))
            }
        }
        guard let liveID = snapshot["session_id"] as? String, !liveID.isEmpty,
              let durableID = Self.durableID(of: snapshot),
              durableID != "Alice task \(taskID)"
        else {
            throw HermesRPCClient.Failure(reason: "Hermes did not return this task's session. Nothing was sent.")
        }
        let info = snapshot["info"] as? [String: Any]
        return HomeChatSession(
            storedID: durableID, liveID: liveID,
            model: info?["model"] as? String, provider: info?["provider"] as? String
        )
    }
}
