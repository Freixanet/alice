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
        // The roster has not caught up. The sanctioned fallback is the
        // exact-title registry lookup, which resolves hidden rows and
        // un-archives a canonical one a reaper had filed away.
        let resumed = try await resume(profile: profile, target: Self.canonicalTitle)
        guard let id = resumed["session_id"] as? String, !id.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "Hermes did not report a canonical Bot Chat for '\(profile)'."
            )
        }
        return CanonicalBotChat(id: id)
    }

    // MARK: - Reading

    func transcript(profile: String, sessionID: String) async throws -> [BotChatTurn] {
        // Resume binds this connection's active session to the bot's chat in
        // the bot's profile; the history comes back with it, so this is one
        // round trip rather than two.
        let resumed = try await resume(profile: profile, target: sessionID)
        return Self.turns(from: resumed.rows)
    }

    /// Resumes a session in a profile. `target` is a session id or an exact
    /// title — the agent accepts either, and the title form is how Bot Mode's
    /// canonical chat is addressed.
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

    // MARK: - Writing

    /// Sends a turn into the bot's own chat.
    ///
    /// No system directive is added. The agent answering is the bot, so
    /// telling it who to pretend to be is both unnecessary and the thing that
    /// used to make one assistant impersonate another.
    ///
    /// What Hermes did with it comes back too. A bot that is already working
    /// does not refuse a message: it folds the text into the task it is
    /// running or queues it behind it, and reading every accepted send as a
    /// turn that had started drew the other task's answer as this one's.
    @discardableResult
    func submit(
        profile: String, sessionID: String, text: String
    ) async throws -> BotChatSubmission {
        let resumed = try await resume(profile: profile, target: sessionID)
        // Alice persists the durable SQLite row id. `session.resume` binds that
        // row to this socket and returns the live id `_sess_nowait` requires
        // for prompt.submit. The durable id itself is not a live RPC session.
        guard let liveID = resumed["session_id"] as? String, !liveID.isEmpty else {
            throw HermesRPCClient.Failure(
                reason: "Hermes resumed the chat without a live session id."
            )
        }
        let result = try await rpc.call("prompt.submit", JSONObject([
            "session_id": liveID,
            "text": text,
        ]))
        return BotChatSubmission(
            liveSessionID: liveID,
            disposition: .init(status: result["status"] as? String)
        )
    }

    /// Stops the turn running in a bot's chat.
    ///
    /// `session.interrupt` takes the runtime id a resume minted, never the
    /// stored row. Sent the stored id, Hermes answered "session not found",
    /// the error was swallowed, and the bot carried on working. The live id
    /// this device last used is tried first; when that runtime is gone — the
    /// socket dropped, or Hermes reaped it — the stored chat is resumed to find
    /// the one that is actually running.
    ///
    /// - Returns: whether a running turn was told to stop.
    @discardableResult
    func interrupt(
        profile: String, storedSessionID: String, liveSessionID: String?
    ) async throws -> Bool {
        if let liveSessionID, !liveSessionID.isEmpty,
           (try? await rpc.call(
               "session.interrupt", JSONObject(["session_id": liveSessionID])
           )) != nil {
            return true
        }
        let state = try await resumedState(profile: profile, storedSessionID: storedSessionID)
        guard state.running else { return false }
        _ = try await rpc.call(
            "session.interrupt", JSONObject(["session_id": state.liveSessionID])
        )
        return true
    }

    /// Whether the bot is still working in this chat, and under which live id.
    ///
    /// Asked while a long turn is quiet: Hermes pushes nothing while it waits
    /// out a provider's rate limit, and a locked phone loses the socket
    /// without being told. `session.activate` re-attaches this socket to a
    /// runtime it already knows and leaves the transcript out, which makes it
    /// the cheap question. A runtime Hermes no longer holds is an error, and
    /// then the stored chat is resumed, which mints a live id again.
    func turnState(
        profile: String, storedSessionID: String, liveSessionID: String?
    ) async throws -> BotTurnState {
        if let liveSessionID, !liveSessionID.isEmpty,
           let active = try? await rpc.call("session.activate", JSONObject([
               "session_id": liveSessionID,
               "omit_messages": true,
           ])),
           let state = BotTurnState(active) {
            return state
        }
        return try await resumedState(profile: profile, storedSessionID: storedSessionID)
    }

    private func resumedState(
        profile: String, storedSessionID: String
    ) async throws -> BotTurnState {
        let resumed = try await resume(profile: profile, target: storedSessionID)
        guard let state = BotTurnState(resumed) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes resumed the chat without a live session id."
            )
        }
        return state
    }

    /// Answers an approval in that session.
    @discardableResult
    func respondToApproval(
        sessionID: String, requestID: String, choice: String
    ) async throws -> JSONObject {
        try await rpc.call("approval.respond", JSONObject([
            "session_id": sessionID,
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
        let result = try await rpc.call("session.events.stats", JSONObject([
            "session_id": sessionID,
        ]))
        guard let latest = (result["latest"] as? Int)
            ?? (result["count"] as? Int)
            ?? (result["last_event_id"] as? Int)
        else { return true }
        return latest > cursor
    }
}
