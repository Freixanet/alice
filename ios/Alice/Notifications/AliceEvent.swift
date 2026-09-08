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
    struct Reference: Hashable, Sendable, Codable {
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

    /// Whether this still wants an answer.
    var isActionable: Bool { standing == .waiting }

    init(
        id: String, kind: Kind, severity: Severity, profile: String? = nil,
        title: String, summary: String, detail: String? = nil, occurred: Date,
        reference: Reference = Reference(), standing: Standing = .none
    ) {
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
