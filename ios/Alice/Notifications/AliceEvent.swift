import Foundation

/// Something that happened and that a person might want to know about.
///
/// This is Alice's vocabulary, not Hermes'. Hermes emits `message.complete`,
/// `approval.request`, cron run rows and component health; a person cares that
/// an assistant finished, that something is waiting on them, or that a
/// connection dropped. The translation happens once, here, so notifications
/// and any later Activity surface describe the same events in the same words.
///
/// Every event keeps `detail` — the exact technical statement Hermes made — so
/// the human sentence never has to be the only thing on record.
struct AliceEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// An assistant finished a turn of work.
        case finished
        /// Something is waiting on the person: an approval, a question.
        case needsInput
        /// A scheduled automation completed successfully.
        case automationSucceeded
        /// A scheduled automation failed.
        case automationFailed
        /// A component of the installation wants attention.
        case attention
        /// A component that wanted attention is well again.
        case recovered
    }

    enum Severity: Int, Sendable, Comparable {
        case informational
        case needsAttention
        case failure

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Everything needed to reopen what an event is about.
    ///
    /// Identity, never a visible name. A bot can be renamed and a routine's
    /// title is whatever someone typed; `session_key` is Hermes' durable
    /// handle for a conversation and survives the compression lineage moving
    /// it onto a fresh row, and `request_id` is what `approval.respond`
    /// resolves against — the server's own answer to "which one".
    /// Which half of Hermes answers this request.
    ///
    /// Not cosmetic: a bot chat's approval is resolved by `approval.respond`
    /// over the dashboard socket, keyed by `request_id`; a gateway run's is a
    /// POST to `/v1/runs/{id}/approval`, keyed by the run. Different protocols
    /// on different ports — sending one to the other resolves nothing while
    /// looking like it worked.
    enum Transport: String, Sendable, Codable {
        case socket
        case gatewayRun
    }

    struct Reference: Hashable, Sendable, Codable {
        /// Which installation this came from. An old notification must never
        /// answer on a Hermes the phone has since been repointed at.
        var installation: String?
        var transport: Transport = .socket
        /// The gateway run, when that is what is waiting.
        var runID: String?
        /// The Hermes profile, which is a bot's id and not its display name.
        var profile: String?
        /// The live session row.
        var sessionID: String?
        /// The durable session handle. Preferred over `sessionID`, which a
        /// compression rotation can retire.
        var sessionKey: String?
        /// Identifies a pending approval or clarify request.
        var requestID: String?
        /// Alice's own conversation, when one mirrors this session.
        var conversationID: String?
        /// `<profile>/<job id>` for a routine.
        var routineKey: String?

        var isEmpty: Bool {
            profile == nil && sessionID == nil && sessionKey == nil
                && requestID == nil && conversationID == nil && routineKey == nil
        }

        /// Whether this may be acted on against the installation Alice is
        /// currently pointed at. A reference from before Alice knew which
        /// installation it was talking to is allowed through; one that names a
        /// different server is not.
        func belongs(to current: String?) -> Bool {
            guard let installation else { return true }
            return installation == current
        }
    }

    /// Where a pending request stands.
    ///
    /// A request Alice is holding can be answered somewhere else, time out, or
    /// belong to a session that no longer exists. Showing it as still waiting
    /// in any of those cases would be asking someone to act on something that
    /// is already over.
    enum Standing: String, Sendable, Codable {
        /// Not a request; nothing to answer.
        case none
        /// Still waiting on this person.
        case waiting
        /// Answered — here or elsewhere.
        case resolved
        /// Hermes no longer has it: expired, or its session is gone.
        case gone
    }

    /// Stable across re-derivations of the same underlying fact, so an event
    /// polled twice is one event and is notified once.
    let id: String
    var kind: Kind
    var severity: Severity
    /// The bot this concerns, when it concerns one.
    var profile: String?
    /// What the person reads first.
    var title: String
    /// One human sentence. Never the agent's own output — see `Notifier`.
    var summary: String
    /// Hermes' exact words, for support and for expert users. Optional because
    /// not every event has a technical statement worth keeping.
    var detail: String?
    var occurred: Date
    var reference = Reference()
    var standing: Standing = .none
    /// A transient problem with *this* row — a reply that would not send.
    ///
    /// Separate from `summary` and `detail` on purpose: writing the error over
    /// those replaced "what this approval is asking for" with "the send
    /// failed", so a card offered Once/Always over the words "Couldn't reach
    /// that address from this iPhone".
    var note: String?
    /// What a clarify request is asking, when that is what this is. A batch
    /// keeps every question because Hermes locks them one-by-one by `qid`;
    /// reducing it to the first question would let one answer resolve the
    /// whole tool call accidentally.
    var questions: [Question] = []

    /// Compatibility/readability for the common one-question case.
    var question: Question? { questions.first }

    /// One question Hermes is blocked on.
    ///
    /// `choices` empty means it wants free text — `clarify` is called both
    /// ways, and offering only buttons for an open question would leave no way
    /// to answer it.
    struct Question: Hashable, Sendable, Codable {
        /// Present for a member of a batch; nil for the historical single
        /// question shape. Sent back as `question_id`, never invented locally.
        var id: String? = nil
        var text: String
        var choices: [String] = []
        var allowsMultiple = false
        /// A server-confirmed answer already locked for this qid. Pending
        /// snapshots carry these on reconnect, so Alice can resume mid-batch.
        var answer: String? = nil
    }

    /// What an approval actually allows. Empty for non-approval events.
    /// Keeping this on the event prevents Activity from offering `always`
    /// when Hermes deliberately exposed only `once`/`deny`.
    var approvalChoices: [Message.ApprovalChoice] = []

    /// Whether this still wants an answer.
    var isActionable: Bool { standing == .waiting }

    /// The thing this event is *about*, as opposed to this particular
    /// occurrence of it.
    ///
    /// Ids carry a timestamp so two runs of the same automation are two facts,
    /// which is right for the record and wrong for the list: an automation
    /// that fails every morning filled Activity with a week of identical rows.
    /// Events sharing a subject stack into one row that keeps a count.
    ///
    /// Requests are deliberately never grouped — each approval is a separate
    /// decision, and stacking two of them would hide one behind the other's
    /// buttons.
    var subject: String {
        if reference.requestID != nil { return id }
        if let routine = reference.routineKey { return "routine:\(routine)" }

        // Everything below reads the id, because rows already written to disk
        // predate the reference carrying that identity — and those are exactly
        // the rows that had piled up. An id is `<kind>:<what>:<when>`, so the
        // subject is the id without its trailing occurrence.
        for prefix in ["attention:routine:", "attention:component:"] where id.hasPrefix(prefix) {
            _ = prefix
            return String(id.dropFirst("attention:".count))
        }
        for prefix in ["routine:", "turn:", "component:"] where id.hasPrefix(prefix) {
            _ = prefix
            var parts = id.split(separator: ":").map(String.init)
            // The last part is the occurrence, not the thing: an epoch for a
            // run or a turn, a status word for a component.
            if parts.count > 2 { parts.removeLast() }
            return parts.joined(separator: ":")
        }
        if let session = reference.sessionKey ?? reference.sessionID {
            return "session:\(session)"
        }
        return id
    }

    init(
        id: String, kind: Kind, severity: Severity, profile: String? = nil,
        title: String, summary: String, detail: String? = nil, occurred: Date,
        reference: Reference = Reference(), standing: Standing = .none,
        question: Question? = nil, questions: [Question] = [],
        approvalChoices: [Message.ApprovalChoice] = [], note: String? = nil
    ) {
        self.note = note
        self.questions = questions.isEmpty ? question.map { [$0] } ?? [] : questions
        self.approvalChoices = approvalChoices
        self.id = id
        self.kind = kind
        self.severity = severity
        self.profile = profile
        self.title = title
        self.summary = summary
        self.detail = detail
        self.occurred = occurred
        self.reference = reference
        self.standing = standing
    }
}

/// One row in Activity: the newest event about a thing, and how many times
/// that thing has happened.
struct ActivityGroup: Identifiable, Sendable {
    var id: String { latest.subject }
    /// The one that is drawn.
    var latest: AliceEvent
    /// Every event in the stack, newest first — what a dismiss has to clear.
    var events: [AliceEvent]
    var count: Int { events.count }

    /// Stacks events by what they are about, keeping order by recency.
    ///
    /// Stable: the group takes the position of its newest member, so a row
    /// does not jump around as older occurrences are folded into it.
    static func stack(_ events: [AliceEvent]) -> [ActivityGroup] {
        var order: [String] = []
        var buckets: [String: [AliceEvent]] = [:]
        for event in events.sorted(by: { $0.occurred > $1.occurred }) {
            let key = event.subject
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(event)
        }
        return order.compactMap { key in
            guard let bucket = buckets[key], let latest = bucket.first else { return nil }
            return ActivityGroup(latest: latest, events: bucket)
        }
    }
}

/// What Alice last saw, so the same fact is not reported twice.
///
/// Hermes has no durable event history — `session.events.since` is a 512-entry
/// in-memory ring per session that resets when the gateway restarts, which
/// makes it a reconnect aid and not a record. So "what changed" is derived by
/// comparing durable server state against what Alice last recorded, which is
/// what this holds.
struct EventWatermarks: Codable, Equatable, Sendable {
    /// `"<profile>/<job id>"` → the run Alice already reported.
    var routineRuns: [String: Date] = [:]
    /// Component name → the status Alice already reported.
    var componentStatus: [String: String] = [:]
    /// Set once Alice has seen the installation at all, so a first sync does
    /// not announce the entire existing state as news.
    var primed = false
    /// Which installation these were taken from.
    ///
    /// Cursors from one Hermes say nothing about another. Pointing Alice at a
    /// different server with these still in place would suppress that
    /// server's real events as "already seen" and let one installation's
    /// activity appear under another's name.
    var installation: String?
}
