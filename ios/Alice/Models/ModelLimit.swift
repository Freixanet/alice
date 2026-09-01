import Foundation

/// Tells "you ran out of quota" apart from "slow down" and from every other
/// failure, so the chat can say which one happened.
///
/// This is the Swift half of the same rule the web client applies. Hermes does
/// not hand over a clean signal: it folds upstream 429s into a generic
/// rate-limit reason and drops the provider's `error.type`, so the split has to
/// come from what survives — the status, `Retry-After`, and the provider text
/// it forwards.
struct ModelLimit: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        /// The allowance is spent. Waiting for the reset, or paying, is the
        /// only fix; retrying now burns time for nothing.
        case quota
        /// Too fast, not too much. Retrying shortly works.
        case rateLimit
        /// The key is wrong, or lacks access to this model.
        case auth
    }

    var kind: Kind
    /// Seconds to wait, when the provider said so. Never invented.
    var retryAfterSeconds: Int?
}

enum ModelLimitClassifier {
    /// Markers meaning the allowance itself is exhausted. A short backoff never
    /// clears these — only the billing period rolling over, or a top-up, does.
    private static let quotaMarkers = [
        "insufficient_quota", "insufficient quota",
        "usage_limit_reached", "usage limit reached", "usage limit",
        "monthly usage limit", "daily usage limit", "weekly limit",
        "quota exceeded", "exceeded your current quota",
        "out of credits", "credit balance", "not enough credits",
        "no credits remaining", "billing_hard_limit_reached",
        "billing hard limit", "plan limit reached", "plan usage",
        "subscription limit", "spending limit", "payment required",
        "upgrade your plan", "you have reached your",
        "resets at", "resets in",
    ]

    /// Transient pressure, worth a retry. Checked after the quota markers so a
    /// body carrying both is treated as exhausted.
    private static let rateMarkers = [
        "rate limit", "rate_limit", "ratelimit", "too many requests",
        "requests per minute", "tokens per minute", "overloaded",
        "capacity", "try again later", "slow down",
    ]

    private static let authMarkers = [
        "invalid_api_key", "invalid api key", "incorrect api key",
        "unauthorized", "authentication", "no access to model",
        "does not have access", "permission",
    ]

    /// Hermes reports some upstream 429 quota errors as missing credentials.
    /// A 429 is never an authentication problem, so when both signals arrive
    /// the status wins. See NousResearch/hermes-agent#32790 and #26388.
    private static let credentialMislabel = [
        "credential", "credentials", "not signed in", "no account",
    ]

    /// Returns nil when nothing points at a limit, so the caller keeps whatever
    /// error it already had rather than guessing.
    static func classify(
        status: Int?,
        message: String?,
        retryAfter: String? = nil,
        now: Date = Date()
    ) -> ModelLimit? {
        let text = (message ?? "").lowercased()
        let seconds = parseRetryAfter(retryAfter, now: now)

        func limit(_ kind: ModelLimit.Kind) -> ModelLimit {
            ModelLimit(kind: kind, retryAfterSeconds: seconds)
        }

        // Text beats status: a provider saying "insufficient_quota" behind a
        // 429 is exhausted, not throttled, and Hermes cannot tell us so.
        if quotaMarkers.contains(where: text.contains) { return limit(.quota) }
        if status == 402 { return limit(.quota) }
        if status == 429, credentialMislabel.contains(where: text.contains) {
            return limit(.quota)
        }
        if rateMarkers.contains(where: text.contains) { return limit(.rateLimit) }
        if status == 429 { return limit(.rateLimit) }
        if status == 401 || status == 403
            || authMarkers.contains(where: text.contains) {
            return ModelLimit(kind: .auth, retryAfterSeconds: nil)
        }
        return nil
    }

    /// `Retry-After` is either delay-seconds or an HTTP date. Anything else
    /// returns nil so no countdown is ever fabricated.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if raw.allSatisfy(\.isNumber), let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}
