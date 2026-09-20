import Foundation

/// How a note's autosave is going, and what the page should do about it.
///
/// Saving as one types must never interrupt the typing. A slow dashboard used
/// to raise a centred alert mid-sentence — "The dashboard took too long to
/// answer" — and reset the saved copy, so the very next keystroke raised it
/// again. Now a failed background save is retried on its own, with growing
/// pauses; the person sees a quiet line, never a dialog, unless they are
/// leaving with words still unsaved.
enum NoteSaveState: Equatable, Sendable {
    /// Everything typed is in the store.
    case saved
    /// A save is on its way.
    case saving
    /// A save failed; another try is scheduled. `attempt` counts failures in a row.
    case retrying(attempt: Int, reason: String)
    /// Retries are exhausted; the words are still on the phone, not in the store.
    case failed(reason: String)

    /// Pauses before each retry, in seconds. Beyond the last, the save is
    /// declared failed and waits for the person or for the app to come back.
    static let retryDelays: [Double] = [2, 5, 15]

    /// The pause before the next retry after `attempt` failures, or nil when
    /// the save should stop trying on its own.
    static func delay(afterFailures attempt: Int) -> Double? {
        guard attempt >= 1, attempt <= retryDelays.count else { return nil }
        return retryDelays[attempt - 1]
    }

    /// The state after one more failure, given how many already happened.
    static func afterFailure(previousFailures: Int, reason: String) -> NoteSaveState {
        let attempt = previousFailures + 1
        return delay(afterFailures: attempt) == nil
            ? .failed(reason: reason)
            : .retrying(attempt: attempt, reason: reason)
    }

    /// The quiet line under the title, or nil when there is nothing to say.
    var caption: String? {
        switch self {
        case .saved: nil
        case .saving: "Saving…"
        case .retrying: "Not saved yet — retrying"
        case .failed: "Not saved — kept on this phone"
        }
    }

    /// Only an explicit exit with unsaved words deserves a dialog.
    var blocksLeavingQuietly: Bool {
        if case .failed = self { return true }
        return false
    }
}
