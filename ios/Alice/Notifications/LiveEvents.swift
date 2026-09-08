import Foundation

/// Turns frames pushed over the dashboard socket into the events Activity and
/// notifications are built from.
///
/// Pure, so what a frame means can be checked against the contracts read out of
/// the installed Hermes rather than against how it happens to behave today.
///
/// The semantics matter more than the names here, and two of them are traps:
///
/// * `message.complete` is emitted three ways. A real turn outcome comes from
///   `_complete_turn_payload`, which always carries `status` — `complete`,
///   `error` or `interrupted`. The subagent mirror in `agent_callbacks` emits
///   `{"text": summary}` with **no** status, on the *parent's* session id, when
///   a child finishes. Treating that as "the bot finished" would announce a
///   completion in the middle of a run that is still going.
/// * `notification.show` is not a completion at all. It is the in-session
///   notice spine — credit warnings, "still starting the agent" — carrying a
///   `key` so it can be replaced in place, and `notification.clear` retracts
///   it. It belongs to a toast, not to a record of finished work.
enum LiveEvents {

    /// One pushed frame, as something worth telling someone about — or `nil`,
    /// which is the answer for most frames.
    ///
    /// `session` names the conversation the frame arrived on, so the event can
    /// carry the identity needed to reopen it.
    static func event(
        from frame: HermesRPCEvent,
        session: SessionIdentity,
        now: Date = Date()
    ) -> AliceEvent? {
        switch frame.type {
        case "message.complete":
            return completion(frame, session: session, now: now)
        case "approval.request":
            return intervention(
                frame, session: session, now: now, kind: "approval",
                title: "Needs your approval",
                summary: "\(session.label) is waiting for permission to continue."
            )
        case "clarify.request":
            return intervention(
                frame, session: session, now: now, kind: "clarify",
                title: "Needs an answer",
                summary: "\(session.label) asked you a question."
            )
        default:
            return nil
        }
    }

    /// Who the frame is about, resolved by the caller from its session id.
    struct SessionIdentity: Sendable, Equatable {
        var profile: String?
        var sessionID: String
        var sessionKey: String?
        var conversationID: String?
        /// The bot's display name, for the sentence a person reads. Never used
        /// as identity.
        var label: String
    }

    private static func completion(
        _ frame: HermesRPCEvent, session: SessionIdentity, now: Date
    ) -> AliceEvent? {
        // No status: a subagent mirror, not this turn ending.
        guard let status = frame.payload["status"] as? String, !status.isEmpty else {
            return nil
        }
        let failed = status == "error"
        // An interrupted turn was stopped on purpose. Reporting it as finished
        // work would be wrong, and reporting it as a failure would blame the
        // agent for doing what it was told.
        guard status != "interrupted" else { return nil }

        let reference = AliceEvent.Reference(
            profile: session.profile,
            sessionID: session.sessionID,
            sessionKey: session.sessionKey,
            conversationID: session.conversationID
        )
        return AliceEvent(
            // The turn is identified by where and when it ended: Hermes puts no
            // id on this frame, and the socket is the only source for it, so
            // there is nothing to collide with.
            id: "turn:\(session.sessionKey ?? session.sessionID):\(Int(now.timeIntervalSince1970))",
            kind: .finished,
            severity: failed ? .failure : .informational,
            profile: session.profile,
            title: session.label,
            summary: failed ? "This assistant stopped with an error." : "This assistant finished.",
            // Never the reply itself. The text of a finished turn is the thing
            // a lock screen must not carry, and it is already in the chat.
            detail: failed ? (frame.payload["error"] as? String) ?? status : nil,
            occurred: now,
            reference: reference
        )
    }

    private static func intervention(
        _ frame: HermesRPCEvent, session: SessionIdentity, now: Date,
        kind: String, title: String, summary: String
    ) -> AliceEvent? {
        guard let requestID = Self.requestID(frame.payload) else { return nil }
        let reference = AliceEvent.Reference(
            profile: session.profile,
            sessionID: session.sessionID,
            sessionKey: session.sessionKey,
            requestID: requestID,
            conversationID: session.conversationID
        )
        return AliceEvent(
            // Keyed by the request Hermes will resolve against, so the same
            // request seen live and again in a pending snapshot is one row.
            id: "\(kind):\(requestID)",
            kind: .needsInput,
            severity: .needsAttention,
            profile: session.profile,
            title: title,
            summary: summary,
            // The command is already redacted by Hermes before it leaves the
            // agent; what is left is safe to keep for the detail disclosure.
            detail: (frame.payload["command"] as? String)
                ?? (frame.payload["question"] as? String)
                ?? (frame.payload["prompt"] as? String),
            occurred: now,
            reference: reference,
            standing: .waiting
        )
    }

    /// Hermes has used more than one spelling for this across its surfaces.
    static func requestID(_ payload: [String: Any]) -> String? {
        for key in ["request_id", "requestId", "id"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
            if let value = payload[key] as? Int { return String(value) }
        }
        return nil
    }

    /// The choices Hermes says are available, in the order it lists them.
    ///
    /// Falls back to the pair every approval supports. Inventing "always" for a
    /// request Hermes marked `smart_denied` would offer a permanent grant the
    /// server will refuse.
    static func choices(_ payload: [String: Any]) -> [Message.ApprovalChoice] {
        let raw = (payload["choices"] as? [String]) ?? []
        let mapped = raw.compactMap(Message.ApprovalChoice.init(rawValue:))
        return mapped.isEmpty ? [.once, .deny] : mapped
    }

    /// A pending approval as `session.resume` reports it, which is how a
    /// request still waiting is found without any event history.
    static func pendingApproval(
        _ payload: [String: Any], session: SessionIdentity, now: Date = Date()
    ) -> AliceEvent? {
        guard let requestID = Self.requestID(payload) else { return nil }
        return AliceEvent(
            id: "approval:\(requestID)",
            kind: .needsInput,
            severity: .needsAttention,
            profile: session.profile,
            title: "Needs your approval",
            summary: "\(session.label) is waiting for permission to continue.",
            detail: payload["command"] as? String,
            occurred: now,
            reference: AliceEvent.Reference(
                profile: session.profile, sessionID: session.sessionID,
                sessionKey: session.sessionKey, requestID: requestID,
                conversationID: session.conversationID
            ),
            standing: .waiting
        )
    }

    /// A pending clarify question, from the same snapshot.
    static func pendingClarify(
        _ payload: [String: Any], session: SessionIdentity, now: Date = Date()
    ) -> AliceEvent? {
        guard let requestID = Self.requestID(payload) else { return nil }
        return AliceEvent(
            id: "clarify:\(requestID)",
            kind: .needsInput,
            severity: .needsAttention,
            profile: session.profile,
            title: "Needs an answer",
            summary: "\(session.label) asked you a question.",
            detail: (payload["question"] as? String) ?? (payload["prompt"] as? String),
            occurred: now,
            reference: AliceEvent.Reference(
                profile: session.profile, sessionID: session.sessionID,
                sessionKey: session.sessionKey, requestID: requestID,
                conversationID: session.conversationID
            ),
            standing: .waiting
        )
    }

    /// Reconciles what Alice is holding against what the server still has
    /// pending for the sessions it just read.
    ///
    /// A request answered on the laptop, one that timed out, and one whose
    /// session was deleted all look the same from here — the server no longer
    /// lists it — and all three mean the same thing to the person holding it:
    /// there is nothing left to answer. `checked` names the sessions actually
    /// read, so a session that was not looked at leaves its requests alone
    /// rather than having them declared over on no evidence.
    static func reconcile(
        held: [AliceEvent], stillPending: Set<String>, checked: Set<String>
    ) -> [AliceEvent] {
        held.map { event in
            guard event.standing == .waiting,
                  let requestID = event.reference.requestID,
                  let session = event.reference.sessionKey ?? event.reference.sessionID,
                  checked.contains(session)
            else { return event }
            if stillPending.contains(requestID) { return event }
            var settled = event
            settled.standing = .gone
            settled.severity = .informational
            settled.summary = "This was already answered elsewhere, or it expired."
            return settled
        }
    }
}
