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

    init(
        id: String, kind: Kind, severity: Severity, profile: String? = nil,
        title: String, summary: String, detail: String? = nil, occurred: Date
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.profile = profile
        self.title = title
        self.summary = summary
        self.detail = detail
        self.occurred = occurred
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
}
