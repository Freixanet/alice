import Foundation

/// Alice's own chat, held as a Hermes session over the dashboard socket.
///
/// The gateway's run API cannot ask anything: its toolset leaves `clarify`
/// out, because an HTTP run has nobody to put a question to. The socket does —
/// Hermes sends the question to the client and waits for the answer — so an
/// ordinary chat goes through it whenever the dashboard is connected, one
/// session per conversation, the way Hermes Desktop holds its chats.
struct HomeChatSession: Equatable, Sendable {
    /// The durable session, kept on the conversation.
    let storedID: String
    /// This socket's runtime for it, which prompts and pushed frames use.
    let liveID: String
    /// The model the session runs, as Hermes reports it.
    let model: String?
    let provider: String?
}

extension WebSocketBotChatSource {
    /// The Hermes session a home conversation continues in.
    ///
    /// The session this chat already has, or a new one that opens with the
    /// conversation as it stands on screen, so the model still knows what was
    /// said. Never the gateway's copy from before chats used the socket: that
    /// one still holds exchanges a retry has since replaced.
    func openHomeChat(
        storedID: String?, model: String?, provider: String?,
        history: [[String: String]]
    ) async throws -> HomeChatSession {
        if let storedID, !storedID.isEmpty {
            do {
                return try await resumeHomeChat(storedID)
            } catch let error where Self.isNotFound(error) {
                // Deleted in Hermes. A new session carries the conversation on.
            }
        }

        var params: [String: Any] = [:]
        if let model, !model.isEmpty {
            params["model"] = model
            if let provider, !provider.isEmpty { params["provider"] = provider }
        }
        if !history.isEmpty { params["messages"] = history }
        let created = try await rpc.call("session.create", JSONObject(params))
        guard let liveID = Self.text(created["session_id"]),
              let storedID = Self.text(created["stored_session_id"])
        else {
            throw HermesRPCClient.Failure(reason: "Hermes did not open a chat for Alice.")
        }
        let info = created["info"] as? [String: Any]
        return HomeChatSession(
            storedID: storedID, liveID: liveID,
            model: Self.text(info?["model"]) ?? model,
            provider: Self.text(info?["provider"]) ?? provider
        )
    }

    private func resumeHomeChat(_ id: String) async throws -> HomeChatSession {
        let resumed = try await resume(profile: nil, target: id)
        guard let liveID = Self.text(resumed["session_id"]) else {
            throw HermesRPCClient.Failure(
                reason: "Hermes resumed the chat without a live session id."
            )
        }
        let info = resumed["info"] as? [String: Any]
        return HomeChatSession(
            storedID: Self.text(resumed["session_key"])
                ?? Self.text(info?["stored_session_id"]) ?? id,
            liveID: liveID,
            model: Self.text(info?["model"]),
            provider: Self.text(info?["provider"])
        )
    }

    /// Puts the session on the model Alice's picker names, from its next turn.
    ///
    /// Hermes' own `/model` switch, scoped to this session: the profile's
    /// default and every other chat keep theirs. A model Hermes wants
    /// confirmed first is refused with Hermes' reason rather than confirmed
    /// on somebody's behalf.
    ///
    /// `force` sets it even when the session says it already runs that model.
    /// A resumed session reports the configured model rather than the one its
    /// runtime was rebuilt on, which after a provider fallback is the fallback.
    func useModel(
        _ model: String, provider: String?, in session: HomeChatSession, force: Bool = false
    ) async throws -> HomeChatSession {
        guard force || !Self.session(session, runs: model, provider: provider) else { return session }
        var value = model
        if let provider, !provider.isEmpty { value += " --provider \(provider)" }
        let result = try await rpc.call("config.set", JSONObject([
            "session_id": session.liveID,
            "key": "model",
            "value": value,
        ]))
        if (result["confirm_required"] as? Bool) == true {
            throw HermesRPCClient.Failure(
                reason: Self.text(result["confirm_message"])
                    ?? "Hermes wants confirmation before using \(model)."
            )
        }
        return HomeChatSession(
            storedID: session.storedID, liveID: session.liveID,
            model: model, provider: provider ?? session.provider
        )
    }

    static func session(_ session: HomeChatSession, runs model: String, provider: String?) -> Bool {
        guard session.model == model else { return false }
        guard let provider, !provider.isEmpty,
              let current = session.provider, !current.isEmpty
        else { return true }
        return provider == current
    }

    /// The persisted turns of a home chat.
    func homeTranscript(_ storedID: String) async throws -> [BotChatTurn] {
        try await homeState(storedID).turns
    }

    /// The persisted turns of a home chat, and whether a turn is still running
    /// in it: one read answers both.
    func homeState(_ storedID: String) async throws -> (turns: [BotChatTurn], running: Bool) {
        try await sessionState(profile: nil, storedID: storedID)
    }

    /// The same for any agent's session: `profile` nil is Alice's own.
    func sessionState(
        profile: String?, storedID: String
    ) async throws -> (turns: [BotChatTurn], running: Bool) {
        let resumed = try await resume(profile: profile, target: storedID)
        return (Self.turns(from: resumed.rows), BotTurnState(resumed)?.running == true)
    }

    /// The conversation so far, as the text history a new session opens with.
    ///
    /// Only what was said: attachments were read once already, and a failed or
    /// unfinished reply is not something the model said. The newest turns are
    /// kept when a conversation is long.
    static func openingHistory(_ messages: [Message], limit: Int = 60) -> [[String: String]] {
        let said: [[String: String]] = messages.compactMap { message in
            guard !message.pending, message.error == nil,
                  message.role == .user || message.role == .assistant
            else { return nil }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return ["role": message.role.rawValue, "content": content]
        }
        return Array(said.suffix(limit))
    }

    /// The answer a turn left in Hermes while nobody was watching it finish:
    /// the last row, when it is the assistant's and answers a message sent
    /// then — not the reply before it, when this message never arrived.
    ///
    /// `asking` is the text Hermes was sent, when known. With it the answer
    /// must follow that exact message, so a reply to the message before —
    /// sent under a minute earlier — is never taken for this one.
    static func finishedReply(
        in turns: [BotChatTurn], sentAt: Date, asking: String? = nil
    ) -> String? {
        guard let last = turns.last, last.role == .assistant,
              let asked = turns.dropLast().last(where: { $0.role == .user }),
              asked.createdAt >= sentAt.addingTimeInterval(-BotChatSync.copyClockSlack)
        else { return nil }
        if let asking,
           asked.content.trimmingCharacters(in: .whitespacesAndNewlines)
            != asking.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        return last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : last.content
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
