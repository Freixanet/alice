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
        // A chat made moments ago — by a clear, or by another device — has no
        // stored row until its first prompt, so the roster does not know it,
        // while Hermes still holds it live under its title. That one is the
        // bot's chat; making another leaves a second forever-chat behind and
        // sends the turn into whichever Hermes happens to find first.
        if let live = try? await resume(profile: profile, target: Self.canonicalTitle),
           let id = Self.durableID(of: live) {
            return CanonicalBotChat(id: id)
        }
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
        guard let durableID = Self.durableID(of: resumed) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes did not report a durable Bot Chat for '\(profile)'."
            )
        }
        return CanonicalBotChat(id: durableID)
    }

    /// The identity a resumed chat keeps across reconnects.
    ///
    /// `session_id` is the ephemeral runtime id. The durable identity is
    /// `stored_session_id` for an unpersisted draft and `session_key` once a
    /// row exists. Persisting the runtime id made a brand-new bot work once and
    /// then 4007 after that runtime was reaped. The title itself is never an
    /// id: a fake or an older Hermes echoing the lookup back is not a chat.
    static func durableID(of resumed: JSONObject) -> String? {
        let candidate = (resumed["stored_session_id"] as? String)
            ?? (resumed["session_key"] as? String)
        guard let candidate, !candidate.isEmpty, candidate != canonicalTitle else { return nil }
        return candidate
    }

    // MARK: - Clearing

    /// Empties a bot's chat for good and gives it a new, empty one.
    ///
    /// Hermes will not rename a bot's canonical chat — its title is its
    /// identity, and it refuses rather than orphan the conversation — so there
    /// is nowhere to file the old one away. Clearing deletes it (the row and,
    /// after a compression, its live tip) and makes a fresh canonical chat.
    /// The bot's instructions, memory, skills and routines live in its profile,
    /// not in the chat, and are untouched. Hermes refuses to delete a chat that
    /// is open live somewhere else; that refusal is the error thrown.
    @discardableResult
    func clearCanonicalBotChat(profile: String) async throws -> CanonicalBotChat {
        guard let chat = try await canonicalBotChat(profile: profile) else {
            return try await createCanonicalBotChat(profile: profile)
        }
        var ids = [chat.resolvedID]
        if chat.id != chat.resolvedID { ids.append(chat.id) }
        for id in ids {
            try await delete(id, profile: profile)
        }
        let fresh = try await createCanonicalBotChat(profile: profile)
        // Only a new chat is a cleared one. Handed the old chat back, Alice
        // emptied the screen and the next refresh put every message back.
        guard !ids.contains(fresh.id), !ids.contains(fresh.resolvedID) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes kept the old chat, so nothing was cleared. Try again."
            )
        }
        return fresh
    }

    /// Deletes one stored chat, letting go of it first.
    ///
    /// Hermes will not delete a session held live, and every read of a chat
    /// resumes it: a refresh on this socket can take hold of it again between
    /// the release and the delete. The release is repeated a couple of times
    /// before Hermes' refusal is passed on.
    private func delete(_ id: String, profile: String) async throws {
        var attempt = 0
        while true {
            if let resumed = try? await resume(profile: profile, target: id),
               let live = resumed["session_id"] as? String, !live.isEmpty {
                // Closing waits only briefly for a running turn and then lets
                // it carry on, writing into a chat that no longer exists — one
                // held up by a question for as long as an hour. Stop it first.
                if BotTurnState(resumed)?.running == true {
                    _ = try? await rpc.call("session.interrupt", JSONObject(["session_id": live]))
                }
                _ = try? await rpc.call("session.close", JSONObject(["session_id": live]))
            }
            do {
                _ = try await rpc.call("session.delete", JSONObject([
                    "session_id": id,
                    "profile": profile,
                ]))
                return
            } catch let error where Self.isNotFound(error) {
                // Already gone is exactly what clearing wants.
                return
            } catch let error where Self.isHeldLive(error) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.localizedCaseInsensitiveContains("not found")
    }

    private static func isHeldLive(_ error: Error) -> Bool {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.localizedCaseInsensitiveContains("active session")
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
    /// canonical chat is addressed. No profile is Alice's own: the profile the
    /// dashboard runs as.
    @discardableResult
    func resume(
        profile: String?, target: String, omitMessages: Bool = false
    ) async throws -> JSONObject {
        var params: [String: Any] = ["session_id": target]
        if let profile { params["profile"] = profile }
        if omitMessages { params["omit_messages"] = true }
        return try await rpc.call("session.resume", JSONObject(params))
    }

    /// Rewinds the chat's last exchange in Hermes, so a retry replaces it
    /// instead of sending the same message a second time.
    ///
    /// Retrying used to resend the text as a new turn while Hermes kept the
    /// failed one, and the message appeared twice. Hermes' own `/retry` drops
    /// the last user turn and everything after it. It runs only when that turn
    /// is the message being retried: one that never reached Hermes has nothing
    /// to rewind, and `/retry` would then undo the exchange before it.
    ///
    /// - Returns: whether Hermes rewound the exchange.
    func rewindForRetry(
        profile: String, sessionID: String, turnID: String, text: String
    ) async throws -> Bool {
        // Asked twice at most. A retry on a phone met a connection that dropped
        // while the rewind was on its way: the error went unseen, the message was
        // sent again, and Hermes kept both. Asked again after reconnecting,
        // Hermes' own history says whether the first attempt took, so a rewind
        // that already happened is never repeated onto the exchange before it.
        var dispatched = false
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let resumed = try await resume(profile: profile, target: sessionID)
                guard let liveID = resumed["session_id"] as? String, !liveID.isEmpty else { return false }
                let lastUser = resumed.rows.last { ($0["role"] as? String) == "user" }
                guard let lastUser,
                      Self.rowID(lastUser) == turnID,
                      let lastText = lastUser["text"] as? String,
                      lastText.trimmingCharacters(in: .whitespacesAndNewlines)
                        == text.trimmingCharacters(in: .whitespacesAndNewlines)
                else {
                    // A lost response after a successful dispatch lands here:
                    // the exact row is gone, so the rewind already happened.
                    if dispatched,
                       !resumed.rows.contains(where: { Self.rowID($0) == turnID }) {
                        return true
                    }
                    throw HermesRPCClient.Failure(
                        reason: "Hermes' chat changed before Alice could retry this message."
                    )
                }
                dispatched = true
                let result = try await rpc.call("command.dispatch", JSONObject([
                    "name": "retry",
                    "session_id": liveID,
                ]))
                guard (result["type"] as? String) == "send" else {
                    throw HermesRPCClient.Failure(
                        reason: "Hermes did not accept the retry command."
                    )
                }
                return true
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HermesRPCClient.Failure(reason: "Hermes did not rewind the exchange.")
    }

    /// Maps the agent's projected history onto Alice's messages.
    ///
    /// The projection is `{role, text, timestamp?, row_id?}`. `row_id` is the
    /// durable identity of a persisted turn and is what makes the merge
    /// idempotent; a row without one has not been persisted yet and is left to
    /// the live stream. Tool and system rows are scaffolding this screen does
    /// not draw.
    static func turns(from rows: [[String: Any]]) -> [BotChatTurn] {
        rows.indices.compactMap { index in
            let row = rows[index]
            // Text an assistant row carries alongside a tool call is the model
            // on its way to an answer, not the answer: Hermes lists that call's
            // tool rows straight after it. A free model echoed a tool's own
            // description — "Required parameters (if any): query — via
            // default.hermes_web_search." — and it showed as the bot's reply.
            if (row["role"] as? String) == "assistant",
               index + 1 < rows.count, (rows[index + 1]["role"] as? String) == "tool" {
                return nil
            }
            guard let rawRole = row["role"] as? String,
                  let role = Message.Role(rawValue: rawRole),
                  let text = row["text"] as? String
            else { return nil }
            guard let rowID = Self.rowID(row) else { return nil }
            // Hermes hands a background delegation's results back to the agent
            // as a user turn. The person did not write it, and its raw JSON
            // showed in the chat as if they had.
            if role == .user, Self.isDelegationReport(text) { return nil }
            // Hermes persists assistant rows whose only payload is a tool call.
            // The projected history exposes those as assistant + empty text, while
            // the tool rows themselves are intentionally hidden. Rendering the
            // empty assistant shell therefore produced a timestamp-only ghost row
            // for every tool call in a Bot Chat. Only final/partial assistant text
            // belongs in Alice's transcript.
            if role == .assistant && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
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

    /// `[ASYNC DELEGATION BATCH COMPLETE — …]`, `[ASYNC DELEGATION COMPLETE — …]`
    /// and `[ASYNC DELEGATION TASK FAILED — …]`, as Hermes writes them.
    static func isDelegationReport(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[ASYNC DELEGATION ")
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
        profile: String, sessionID: String, text: String, attachments: [Attachment] = []
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
        return try await submit(liveSessionID: liveID, text: text, attachments: attachments)
    }

    /// Sends a turn into a session this socket already holds live.
    ///
    /// A chat Alice has just created has no stored row until its first prompt,
    /// so it cannot be resumed by its stored id yet; its live id is used as is.
    func submit(
        liveSessionID liveID: String, text: String, attachments: [Attachment] = []
    ) async throws -> BotChatSubmission {
        // Stage attachments on the SAME live runtime before submit, matching
        // Hermes Desktop's remote-client contract. Images become attached
        // image bytes; files return workspace-relative @file: refs that must be
        // included in the prompt text the agent sees.
        //
        // They go up together, not one after another: three photos over
        // Wi-Fi were three full round trips before the first letter reached
        // the model. Refs keep the order the person attached them in.
        var fileRefs: [String] = []
        var hasImage = false
        if !attachments.isEmpty {
            let staged: [(index: Int, ref: String?)] = try await withThrowingTaskGroup(
                of: (Int, String?).self
            ) { group in
                for (index, attachment) in attachments.enumerated() {
                    group.addTask { (index, try await self.stage(attachment, on: liveID)) }
                }
                var results: [(Int, String?)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map { (index: $0.0, ref: $0.1) }
            }
            for entry in staged {
                if let ref = entry.ref {
                    fileRefs.append(ref)
                } else {
                    hasImage = true
                }
            }
        }

        let refs = fileRefs.joined(separator: "\n")
        var submittedText = [refs, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if submittedText.isEmpty, hasImage { submittedText = "What do you see in this image?" }

        let result = try await rpc.call("prompt.submit", JSONObject([
            "session_id": liveID,
            "text": submittedText,
        ]))
        return BotChatSubmission(
            liveSessionID: liveID,
            disposition: .init(status: result["status"] as? String),
            submittedText: submittedText
        )
    }

    /// Puts one attachment on the live runtime. A file answers with the
    /// `@file:` ref the prompt must carry; an image answers nil, having been
    /// attached as bytes.
    private func stage(_ attachment: Attachment, on liveID: String) async throws -> String? {
        switch attachment.kind {
        case .image:
            let attached = try await rpc.call("image.attach_bytes", JSONObject([
                "session_id": liveID,
                "content_base64": attachment.data.base64EncodedString(),
                "filename": attachment.name,
            ]))
            guard (attached["attached"] as? Bool) == true else {
                throw HermesRPCClient.Failure(
                    reason: (attached["message"] as? String)
                        ?? "Hermes could not attach \(attachment.name)."
                )
            }
            return nil
        case .file:
            let attached = try await rpc.call("file.attach", JSONObject([
                "session_id": liveID,
                "name": attachment.name,
                "data_url": attachment.dataURL,
            ]))
            guard (attached["attached"] as? Bool) == true,
                  let ref = attached["ref_text"] as? String, !ref.isEmpty else {
                throw HermesRPCClient.Failure(
                    reason: (attached["message"] as? String)
                        ?? "Hermes could not attach \(attachment.name)."
                )
            }
            return ref
        }
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
        profile: String?, storedSessionID: String, liveSessionID: String?
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
        profile: String?, storedSessionID: String, liveSessionID: String?
    ) async throws -> BotTurnState {
        let snapshot = try await turnSnapshot(
            profile: profile, storedSessionID: storedSessionID, liveSessionID: liveSessionID
        )
        guard let state = BotTurnState(snapshot) else {
            throw HermesRPCClient.Failure(reason: "Hermes returned no live session id.")
        }
        return state
    }

    /// Retains the open requests as well as the running flag. A resumed turn
    /// can be blocked on a question whose original frame the phone missed.
    func turnSnapshot(
        profile: String?, storedSessionID: String, liveSessionID: String?
    ) async throws -> JSONObject {
        if let liveSessionID, !liveSessionID.isEmpty,
           let active = try? await rpc.call("session.activate", JSONObject([
               "session_id": liveSessionID,
               "omit_messages": true,
           ])),
           BotTurnState(active) != nil {
            return active
        }
        let resumed = try await resume(
            profile: profile, target: storedSessionID, omitMessages: true
        )
        guard BotTurnState(resumed) != nil else {
            throw HermesRPCClient.Failure(reason: "Hermes resumed the chat without a live session id.")
        }
        return resumed
    }

    private func resumedState(
        profile: String?, storedSessionID: String
    ) async throws -> BotTurnState {
        // Only the runtime is wanted, not the transcript. Reading a long chat
        // back just to learn whether a turn is running made this check slower
        // than the watch's deadline on a busy Mac, so it failed, the socket was
        // dropped, and a reply that had long finished said "Reconnecting to
        // Hermes…" until the watch gave up.
        let resumed = try await resume(
            profile: profile, target: storedSessionID, omitMessages: true
        )
        guard let state = BotTurnState(resumed) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes resumed the chat without a live session id."
            )
        }
        return state
    }

    /// Runs a Hermes slash command on a live session, not as a prompt.
    ///
    /// Desktop and the TUI send `/reasoning`, `/status`, `/compress` and the
    /// rest through `slash.exec` so the model never sees them as chat. Alice
    /// used to `prompt.submit` the typed line, and Alice-the-agent then went
    /// looking up what the command meant.
    func execSlash(
        liveSessionID: String, command: String, profile: String? = nil
    ) async throws -> String {
        var body = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasPrefix("/") { body.removeFirst() }
        guard !body.isEmpty else {
            throw HermesRPCClient.Failure(reason: "That slash command is empty.")
        }
        var params: [String: Any] = [
            "session_id": liveSessionID,
            "command": body,
        ]
        if let profile, !profile.isEmpty { params["profile"] = profile }
        let result = try await rpc.call("slash.exec", JSONObject(params))
        return Self.slashOutput(result, command: body)
    }

    /// Text Alice can put in the chat from a `slash.exec` result.
    ///
    /// Worker commands return `output` (and sometimes `warning`). Commands
    /// rerouted to `command.dispatch` set `type` and may carry `display` or
    /// `notice` instead — never the model-facing `message` of a skill.
    static func slashOutput(_ result: JSONObject, command: String) -> String {
        let warning = (result["warning"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = (result["output"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty, output != "(no output)" {
            return warning.isEmpty ? output : "\(warning)\n\n\(output)"
        }
        let display = (result["display"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty {
            return warning.isEmpty ? display : "\(warning)\n\n\(display)"
        }
        let notice = (result["notice"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !notice.isEmpty {
            return warning.isEmpty ? notice : "\(warning)\n\n\(notice)"
        }
        if !warning.isEmpty { return warning }
        let name = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return "Hermes ran /\(name) with nothing to show."
    }

    /// Answers an approval in that session.
    ///
    /// A server→client request (`srq-…`) is answered with a response frame, and
    /// nothing comes back: a delivered answer counts as resolved, and a request
    /// that had already ended is withdrawn by `request.cancel`. An older Hermes
    /// resolves `approval.respond` and reports how many it resolved.
    @discardableResult
    func respondToApproval(
        sessionID: String, requestID: String, choice: String
    ) async throws -> JSONObject {
        if GatewayServerRequests.isServerRequestID(requestID) {
            try await rpc.respond(toServerRequest: requestID, result: JSONObject(["choice": choice]))
            return JSONObject(["resolved": 1])
        }
        return try await rpc.call("approval.respond", JSONObject([
            "session_id": sessionID,
            "request_id": requestID,
            "choice": choice,
        ]))
    }

    /// Answers a secure request (a login, a code, a key) with the one string
    /// Hermes asked for; `""` declines it.
    func answerSecureRequest(_ requestID: String, value: String) async throws {
        try await rpc.respond(toServerRequest: requestID, result: JSONObject(["value": value]))
    }

    /// Answers a clarify question in that session.
    ///
    /// For a server→client request, a single question is answered by a response
    /// frame `{answer}`; one question of a batch is locked with `clarify.lock`,
    /// and the lock that completes the set resolves the request. An older Hermes
    /// takes both through `clarify.respond`. Every path returns the
    /// `{status, remaining}` envelope `LiveEvents.clarifyReply` reads.
    func answerClarify(
        sessionID: String?, requestID: String, questionID: String?, answer: String
    ) async throws -> JSONObject {
        if GatewayServerRequests.isServerRequestID(requestID) {
            guard let questionID else {
                try await rpc.respond(toServerRequest: requestID, result: JSONObject(["answer": answer]))
                return JSONObject(["status": "ok"])
            }
            return try await rpc.call("clarify.lock", JSONObject([
                "request_id": requestID,
                "question_id": questionID,
                "answer": answer,
            ]))
        }
        var params: [String: Any] = ["request_id": requestID, "answer": answer]
        if let sessionID { params["session_id"] = sessionID }
        if let questionID { params["question_id"] = questionID }
        return try await rpc.call("clarify.respond", JSONObject(params))
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
