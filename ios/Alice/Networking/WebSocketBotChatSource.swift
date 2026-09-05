import Foundation

/// The canonical Bot Chat over the dashboard's JSON-RPC WebSocket.
///
/// This is Hermes' own "app-global remote mode": `session.create` and
/// `session.resume` take a `profile`, and the agent then builds and persists
/// against *that* profile's home and state.db, re-binding `HERMES_HOME` on
/// every turn. So a chat resolved here is the bot's real forever-chat — the
/// one cron writes to with `deliver: bot-chat`, the one `message_agent` writes
/// to, the one the CLI resumes — and a turn sent into it runs as that bot,
/// with its own SOUL, memory, skills and config.
///
/// The gateway path this replaces could do none of that: it has no profile
/// routing at all, so every bot chat ran on the default profile wearing a
/// synthetic "you are <bot>" directive.
struct WebSocketBotChatSource: BotChatSessionSource {
    let rpc: HermesRPCTransport

    init(rpc: HermesRPCTransport) { self.rpc = rpc }

    static let canonicalTitle = "Bot Chat"

    // MARK: - Resolving

    /// The profile's canonical chat, as the server resolves it.
    ///
    /// `profiles.list` reports a `canonical_session` per profile — the row
    /// titled `Bot Chat`, with `resolved_id` naming the live tip when a
    /// compression lineage has moved the conversation onto a fresh row. Taking
    /// the server's answer means no client ever scans a transcript or carries
    /// a session pointer that can go stale.
    func canonicalBotChat(profile: String) async throws -> CanonicalBotChat? {
        let result = try await rpc.call("profiles.list", JSONObject(["include_sessions": true]))
        let rows = (result["profiles"] as? [[String: Any]]) ?? []
        guard let row = rows.first(where: { ($0["name"] as? String) == profile }),
              let canonical = row["canonical_session"] as? [String: Any],
              let id = canonical["id"] as? String, !id.isEmpty
        else { return nil }
        let resolved = (canonical["resolved_id"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        return CanonicalBotChat(id: id, resolvedID: resolved)
    }

    /// Creates the profile's canonical chat, then asks the server which one is
    /// canonical rather than assuming the row just made is it.
    ///
    /// Two devices opening a bot at once both end up pointing at whichever row
    /// the server considers canonical — one forever-chat, not two.
    func createCanonicalBotChat(profile: String) async throws -> CanonicalBotChat {
        _ = try? await rpc.call("session.create", JSONObject([
            "profile": profile,
            "title": Self.canonicalTitle,
            "hidden": true,
        ]))
        if let resolved = try await canonicalBotChat(profile: profile) { return resolved }
        // The roster has not caught up. Resume by exact title, then keep the
        // durable id Hermes says it resumed. `session_id` in this response is
        // the ephemeral runtime handle and must never be persisted as the chat.
        let resumed = try await resume(profile: profile, target: Self.canonicalTitle)
        guard let durable = (resumed["resumed"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        else {
            throw HermesRPCClient.Failure(
                reason: "Hermes did not report a canonical Bot Chat for '\(profile)'."
            )
        }
        _ = try await bindRuntimeSession(resumed, durableID: durable)
        return CanonicalBotChat(id: durable)
    }

    // MARK: - Reading

    func transcript(profile: String, sessionID: String) async throws -> [BotChatTurn] {
        // Resume binds this connection's active runtime session to the bot's
        // durable chat in the bot's profile; the history comes back with it.
        // Keep the durable id on Alice's Conversation and use the returned
        // runtime id only for live RPC calls on this socket.
        let resumed = try await resume(profile: profile, target: sessionID)
        _ = try await bindRuntimeSession(resumed, durableID: sessionID)
        return Self.turns(from: resumed.rows)
    }

    /// Resumes a durable session in a profile. `target` is a stored session id
    /// or an exact title. The result contains a *runtime* `session_id`; that id
    /// is valid for live RPC calls on this socket but is not the durable chat
    /// Alice stores for reconnects.
    @discardableResult
    func resume(profile: String, target: String) async throws -> JSONObject {
        try await rpc.call("session.resume", JSONObject([
            "session_id": target,
            "profile": profile,
        ]))
    }

    /// Maps the agent's projected history onto Alice's messages.
    ///
    /// The projection is `{role, text, timestamp?, row_id?}`. `row_id` is the
    /// durable identity of a persisted turn and is what makes the merge
    /// idempotent; a row without one has not been persisted yet and is left to
    /// the live stream. Tool and system rows are scaffolding this screen does
    /// not draw.
    static func turns(from rows: [[String: Any]]) -> [BotChatTurn] {
        rows.compactMap { row in
            guard let rawRole = row["role"] as? String,
                  let role = Message.Role(rawValue: rawRole),
                  let text = row["text"] as? String
            else { return nil }
            guard let rowID = Self.rowID(row) else { return nil }
            let seconds = (row["timestamp"] as? Double)
                ?? (row["timestamp"] as? NSNumber)?.doubleValue
            return BotChatTurn(
                id: rowID,
                role: role,
                content: text,
                createdAt: seconds.map(Date.init(timeIntervalSince1970:))
                    ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    private static func rowID(_ row: [String: Any]) -> String? {
        if let value = row["row_id"] as? String, !value.isEmpty { return value }
        if let value = row["row_id"] as? Int { return String(value) }
        if let value = row["row_id"] as? NSNumber { return value.stringValue }
        return nil
    }

    /// Records the runtime/durable pair and returns the runtime handle Hermes
    /// expects on live methods such as `prompt.submit`.
    private func bindRuntimeSession(
        _ resumed: JSONObject, durableID: String
    ) async throws -> String {
        guard let runtimeID = resumed["session_id"] as? String, !runtimeID.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "Hermes resumed the chat without a runtime session id."
            )
        }
        await rpc.aliasSession(runtimeID: runtimeID, durableID: durableID)
        return runtimeID
    }

    // MARK: - Writing

    /// Sends a turn into the bot's own chat.
    ///
    /// No system directive is added. The agent answering is the bot, so
    /// telling it who to pretend to be is both unnecessary and the thing that
    /// used to make one assistant impersonate another.
    func submit(profile: String, sessionID: String, text: String) async throws {
        let resumed = try await resume(profile: profile, target: sessionID)
        let runtimeID = try await bindRuntimeSession(resumed, durableID: sessionID)
        _ = try await rpc.call("prompt.submit", JSONObject([
            "session_id": runtimeID,
            "text": text,
        ]))
    }

    /// Stops the run in that session. During a live send `submit` has already
    /// bound the durable chat to its runtime id; a reconnect clears that map so
    /// a stale runtime handle is never reused.
    func interrupt(sessionID: String) async throws {
        let target = await rpc.runtimeSessionID(for: sessionID) ?? sessionID
        _ = try await rpc.call("session.interrupt", JSONObject(["session_id": target]))
    }

    /// Answers an approval in that session.
    func respondToApproval(
        sessionID: String, requestID: String, choice: String
    ) async throws {
        let target = await rpc.runtimeSessionID(for: sessionID) ?? sessionID
        _ = try await rpc.call("approval.respond", JSONObject([
            "session_id": target,
            "request_id": requestID,
            "choice": choice,
        ]))
    }

    // MARK: - Out of band

    /// Whether anything has been written to a session since a known point.
    ///
    /// Cheaper than re-reading a transcript, and the reason a visible bot chat
    /// can notice a cron delivery without polling for it.
    func hasChanged(sessionID: String, since cursor: Int) async throws -> Bool {
        let target = await rpc.runtimeSessionID(for: sessionID) ?? sessionID
        let result = try await rpc.call("session.events.stats", JSONObject([
            "session_id": target,
        ]))
        guard let latest = (result["latest"] as? Int)
            ?? (result["count"] as? Int)
            ?? (result["last_event_id"] as? Int)
        else { return true }
        return latest > cursor
    }
}
