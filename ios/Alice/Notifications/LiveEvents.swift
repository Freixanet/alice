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
            // Who is asking and what for, in words. "Needs your approval — X is
            // waiting for permission to continue" said neither.
            let description = frame.payload["description"] as? String
            let explanation = ApprovalExplainer.explain(
                description: description, command: frame.payload["command"] as? String
            )
            var event = intervention(
                frame, session: session, now: now, kind: "approval",
                title: "\(session.label) needs your OK",
                summary: "Wants to \(explanation.action)"
            )
            event?.approvalDescription = description
            event?.smartDenied = (frame.payload["smart_denied"] as? Bool) == true
            return event
        case "clarify.request":
            return clarify(frame.payload, session: session, now: now)
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

    /// Whether a frame is this turn ending, as opposed to a child's.
    ///
    /// `_complete_turn_payload` always sets `status`; the subagent mirror in
    /// `agent_callbacks` emits `{"text": summary}` without one, on the parent's
    /// session id. This is the whole difference, and every consumer needs it.
    static func isTurnOutcome(_ frame: HermesRPCEvent) -> Bool {
        guard frame.type == "message.complete" else { return false }
        guard let status = frame.payload["status"] as? String else { return false }
        return !status.isEmpty
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
            standing: .waiting,
            approvalChoices: choices(frame.payload)
        )
    }

    /// A clarify request, from a live frame or from a pending snapshot.
    ///
    /// Hermes calls `clarify` two ways. A single question is
    /// `{question, choices, multi_select?}`; a batch is
    /// `{questions: [{qid, question, choices, multi_select}]}`. Batch snapshots
    /// may also carry `answers: {qid: answer}` for questions already locked
    /// before a reconnect. Alice preserves every qid and those answers so the
    /// batch can resume in Activity without accidentally resolving the whole
    /// request after the first question.
    static func clarify(
        _ payload: [String: Any], session: SessionIdentity, now: Date = Date()
    ) -> AliceEvent? {
        guard let requestID = Self.requestID(payload) else { return nil }

        let questions: [AliceEvent.Question]
        if let batch = payload["questions"] as? [[String: Any]], !batch.isEmpty {
            let locked = payload["answers"] as? [String: Any] ?? [:]
            questions = batch.compactMap { row in
                guard let qid = row["qid"] as? String, !qid.isEmpty,
                      let text = row["question"] as? String, !text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ).isEmpty
                else { return nil }
                let answer = locked[qid] as? String
                return AliceEvent.Question(
                    id: qid,
                    text: text,
                    choices: (row["choices"] as? [String]) ?? [],
                    allowsMultiple: (row["multi_select"] as? Bool) ?? false,
                    answer: answer
                )
            }
        } else {
            guard let text = payload["question"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            questions = [AliceEvent.Question(
                text: text,
                choices: (payload["choices"] as? [String]) ?? [],
                allowsMultiple: (payload["multi_select"] as? Bool) ?? false
            )]
        }
        guard !questions.isEmpty else { return nil }

        let answered = questions.filter { $0.answer != nil }.count
        let summary = questions.count == 1
            ? "\(session.label) asked you a question."
            : "\(session.label) asked \(questions.count) questions"
                + (answered > 0 ? " (\(answered) answered)." : ".")
        return AliceEvent(
            id: "clarify:\(requestID)",
            kind: .needsInput,
            severity: .needsAttention,
            profile: session.profile,
            title: "Needs an answer",
            summary: summary,
            detail: questions.count == 1 ? questions[0].text : nil,
            occurred: now,
            reference: AliceEvent.Reference(
                profile: session.profile, sessionID: session.sessionID,
                sessionKey: session.sessionKey, requestID: requestID,
                conversationID: session.conversationID
            ),
            standing: .waiting,
            questions: questions
        )
    }

    /// Whether Hermes actually resolved what it was asked to.
    ///
    /// `approval.respond` answers `{"resolved": <count>}` and `clarify.respond`
    /// answers `{"status": "ok"｜"expired"}` — both as *successful* replies. A
    /// call that did not throw is therefore not evidence that anything was
    /// answered, and treating it as such would mark a request settled that is
    /// still blocking the agent, or that somebody else already handled.
    static func didResolve(_ result: JSONObject) -> Bool {
        if let resolved = result["resolved"] as? Int { return resolved > 0 }
        if let resolved = result["resolved"] as? NSNumber { return resolved.intValue > 0 }
        if let status = result["status"] as? String { return status == "ok" }
        return false
    }

    enum ClarifyReply: Equatable {
        case resolved
        case partial(remaining: [String])
        case expired
        case invalid
    }

    /// Interprets the success envelope of `clarify.respond`. For a batch, an
    /// `ok` without `remaining` is deliberately invalid: transport success
    /// cannot be upgraded into "the whole request is resolved".
    static func clarifyReply(_ result: JSONObject, questionID: String?) -> ClarifyReply {
        guard let status = result["status"] as? String else { return .invalid }
        if status == "expired" { return .expired }
        guard status == "ok" else { return .invalid }
        guard questionID != nil else { return .resolved }
        guard let remaining = stringList(result["remaining"]) else { return .invalid }
        return remaining.isEmpty ? .resolved : .partial(remaining: remaining)
    }

    private static func stringList(_ value: Any?) -> [String]? {
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] {
            let strings = values.compactMap { $0 as? String }
            return strings.count == values.count ? strings : nil
        }
        return nil
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
        let description = payload["description"] as? String
        let explanation = ApprovalExplainer.explain(
            description: description, command: payload["command"] as? String
        )
        var event = AliceEvent(
            id: "approval:\(requestID)",
            kind: .needsInput,
            severity: .needsAttention,
            profile: session.profile,
            title: "\(session.label) needs your OK",
            summary: "Wants to \(explanation.action)",
            detail: payload["command"] as? String,
            occurred: now,
            reference: AliceEvent.Reference(
                profile: session.profile, sessionID: session.sessionID,
                sessionKey: session.sessionKey, requestID: requestID,
                conversationID: session.conversationID
            ),
            standing: .waiting,
            approvalChoices: choices(payload)
        )
        event.approvalDescription = description
        event.smartDenied = (payload["smart_denied"] as? Bool) == true
        return event
    }

    /// A pending clarify question, from the same snapshot. Identical shape to
    /// the live frame, so it goes through the same reader.
    static func pendingClarify(
        _ payload: [String: Any], session: SessionIdentity, now: Date = Date()
    ) -> AliceEvent? {
        clarify(payload, session: session, now: now)
    }

    /// Everything a `session.resume` result says is still waiting on a person.
    ///
    /// A Hermes on gateway contract v7 lists its open server→client requests as
    /// `open_requests`, keyed by the id the answer must carry. It may still send
    /// `pending_approval`, naming the same approval by the queue's id — read
    /// alongside, the one approval would become two rows, and the second could
    /// not be answered. An older Hermes reports only the `pending_*` pair.
    static func pendingEvents(
        from resumed: JSONObject, session: SessionIdentity, now: Date = Date()
    ) -> [AliceEvent] {
        if let open = GatewayServerRequests.openRequests(in: resumed) {
            return open.compactMap { frame in
                switch frame.type {
                case "approval.request": return pendingApproval(frame.payload, session: session, now: now)
                case "clarify.request": return pendingClarify(frame.payload, session: session, now: now)
                default: return nil
                }
            }
        }
        var events: [AliceEvent] = []
        if let approval = resumed["pending_approval"] as? [String: Any],
           let event = pendingApproval(approval, session: session, now: now) {
            events.append(event)
        }
        if let clarify = resumed["pending_clarify"] as? [String: Any],
           let event = pendingClarify(clarify, session: session, now: now) {
            events.append(event)
        }
        return events
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
