import Foundation

/// What Hermes did with a message sent into a bot's chat.
///
/// A bot that is already working does not refuse a message. Hermes applies
/// `display.busy_input_mode`: the text is folded into the task it is running,
/// or queued to run once that task ends. Only a bot with nothing to do starts
/// a turn for it.
struct BotChatSubmission: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        /// A turn began for this message.
        case started
        /// The bot was busy; the message joins the task it is running.
        case foldedIn
        /// The bot was busy; the message runs after the current task.
        case queued

        /// `prompt.submit`'s `status`: `streaming` for a new turn, `steered`
        /// or `redirected` for a correction to the running one, `queued` for
        /// one behind it.
        init(status: String?) {
            switch status {
            case "queued": self = .queued
            case "steered", "redirected": self = .foldedIn
            default: self = .started
            }
        }
    }

    /// The runtime id this socket's resume minted, which pushed frames and
    /// `session.interrupt` both use. Not the stored chat id.
    let liveSessionID: String
    let disposition: Disposition
    /// Exact text Hermes accepted after attachment refs were staged. It can
    /// differ from the visible bubble and is the transcript-correlation key.
    let submittedText: String

    init(
        liveSessionID: String, disposition: Disposition, submittedText: String = ""
    ) {
        self.liveSessionID = liveSessionID
        self.disposition = disposition
        self.submittedText = submittedText
    }
}

/// A terminal turn Hermes retained because the client missed its ending.
struct BotTurnFailure: Equatable, Sendable {
    let message: String
    let partial: String
    let recoverable: Bool
}

/// A bot chat's runtime, as Hermes reports it when a socket re-attaches.
struct BotTurnState: Equatable, Sendable {
    let liveSessionID: String
    let running: Bool
    let failure: BotTurnFailure?

    init(
        liveSessionID: String, running: Bool, failure: BotTurnFailure? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.running = running
        self.failure = failure
    }

    /// From a `session.activate` or `session.resume` result.
    init?(_ payload: JSONObject) {
        guard let id = payload["session_id"] as? String, !id.isEmpty else { return nil }
        liveSessionID = id
        running = (payload["running"] as? Bool) == true
            || (payload["status"] as? String) == "streaming"
        if let inflight = payload["inflight"] as? [String: Any],
           (inflight["streaming"] as? Bool) != true,
           let raw = inflight["error"] as? String {
            let error = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            failure = error.isEmpty ? nil : BotTurnFailure(
                message: error,
                partial: (inflight["assistant"] as? String) ?? "",
                recoverable: (inflight["recoverable"] as? Bool) == true
            )
        } else {
            failure = nil
        }
    }
}

/// Follows one reply in a bot's chat to an ending the socket may never deliver.
///
/// A reply used to be a loop over pushed frames that ended only on the turn's
/// own completion. Radar IA spent ten minutes at a time waiting out a rate
/// limit, the phone locked, the socket died, and no frame could ever arrive:
/// the reply sat on "Thinking…", or came back drawn as a failure, while the
/// bot carried on. A message sent to a busy bot was followed as if its turn
/// had begun, so the task ahead of it was drawn as its answer.
///
/// The decisions live here, away from the store, so each can be tested: which
/// frames belong to this reply, when a quiet turn is worth asking about, and
/// what the answer means.
struct BotTurnWatch: Sendable {
    enum Signal: Sendable {
        case frame(HermesRPCEvent)
        /// Time passing, so a silent turn can be asked about.
        case tick
    }

    enum FrameStep: Equatable, Sendable {
        /// Not this reply's: another chat, or the task ahead of a queued message.
        case ignore
        /// Part of this reply.
        case apply
        /// This reply's turn ending. Apply it, then stop watching.
        case finish
        /// One queued turn ended. Re-read the canonical transcript; only the
        /// durable prompt/reply pair can prove whether it was ours.
        case queuedTurnEnded
    }

    enum CheckStep: Equatable, Sendable {
        /// Still working. The runtime id may have changed on re-attach.
        case keepWaiting(liveSessionIDChanged: Bool)
        /// Hermes could not be asked; it will be asked again.
        case reconnecting
        /// Nothing is running, and no ending was seen. Hermes may retain the
        /// terminal failure a disconnected client missed.
        case endedUnseen(failure: BotTurnFailure?)
        /// Hermes could not be reached, repeatedly.
        case lostTouch
    }

    /// How long a turn may be silent before Hermes is asked about it. Hermes
    /// pushes nothing while it waits out a provider's rate limit — ten minutes
    /// at a time for a free model — so silence alone is not an ending.
    static let quietInterval: TimeInterval = 30
    /// Failed checks in a row before the reply is left to arrive on its own.
    static let attemptsBeforeLosingTouch = 4

    private(set) var liveSessionID: String
    private var waitingForQueuedOrigin: Bool
    private var lastHeard: Date
    private var failedChecks = 0

    init(submission: BotChatSubmission, now: Date) {
        liveSessionID = submission.liveSessionID
        waitingForQueuedOrigin = submission.disposition == .queued
        lastHeard = now
    }

    mutating func receive(_ frame: HermesRPCEvent, now: Date) -> FrameStep {
        guard frame.sessionID.isEmpty || frame.sessionID == liveSessionID else { return .ignore }
        // Only this turn's own frames prove it is alive. A frame with no
        // session is any traffic at all — a foreground refresh of every bot
        // sends plenty — and counting it kept a finished turn from ever being
        // asked about.
        if !frame.sessionID.isEmpty { lastHeard = now }
        // Only a real turn outcome ends a turn. The subagent mirror emits
        // `message.complete` with no `status`, on the parent's session id,
        // when a child finishes — breaking on that abandoned the parent.
        let ending = LiveEvents.isTurnOutcome(frame)
        if waitingForQueuedOrigin {
            // There may be any number of queued turns ahead. A terminal frame
            // is only a boundary, never proof that the next frames are ours.
            return ending ? .queuedTurnEnded : .ignore
        }
        return ending ? .finish : .apply
    }

    var needsTranscriptCorrelation: Bool { waitingForQueuedOrigin }

    /// The canonical transcript now contains the exact persisted user row for
    /// this queued submission. From this point, frames on the live session are
    /// ours and can stream normally.
    mutating func confirmQueuedOrigin(now: Date) {
        waitingForQueuedOrigin = false
        lastHeard = now
        failedChecks = 0
    }

    func shouldCheck(now: Date) -> Bool {
        now.timeIntervalSince(lastHeard) >= Self.quietInterval
    }

    mutating func checked(_ result: Result<BotTurnState, Error>, now: Date) -> CheckStep {
        switch result {
        case let .success(state):
            failedChecks = 0
            lastHeard = now
            let changed = state.liveSessionID != liveSessionID
            liveSessionID = state.liveSessionID
            return state.running
                ? .keepWaiting(liveSessionIDChanged: changed)
                : .endedUnseen(failure: state.failure)
        case .failure:
            failedChecks += 1
            return failedChecks >= Self.attemptsBeforeLosingTouch ? .lostTouch : .reconnecting
        }
    }

    /// Frames as they arrive, with a tick every `interval` in between.
    static func signals(
        from frames: AsyncStream<HermesRPCEvent>, every interval: Duration
    ) -> AsyncStream<Signal> {
        AsyncStream { continuation in
            let listening = Task {
                for await frame in frames { continuation.yield(.frame(frame)) }
            }
            let ticking = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    continuation.yield(.tick)
                }
            }
            continuation.onTermination = { _ in
                listening.cancel()
                ticking.cancel()
            }
        }
    }

    /// How long a check may take before the connection is treated as dead.
    static let checkDeadline: Duration = .seconds(20)

    /// Hermes did not answer a check in time.
    struct NoAnswer: Error, LocalizedError {
        var errorDescription: String? { "Hermes did not answer in time." }
    }

    /// Runs `operation`, giving up after `limit`.
    ///
    /// A call on a socket that died without saying so — the phone changed
    /// networks, say — waits for a reply that will never come, and the watch
    /// waited with it: no further check, no "lost touch", a reply that looked
    /// busy forever. The abandoned call ends whenever the socket is finally
    /// torn down; nothing waits on it.
    static func answer<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.arm(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(with: .failure(NoAnswer()))
            }
            Task {
                do {
                    once.resume(with: .success(try await operation()))
                } catch {
                    once.resume(with: .failure(error))
                }
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<T, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
