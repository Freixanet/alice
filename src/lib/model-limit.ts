/**
 * Tell "you ran out of quota" apart from "slow down" and from every other
 * failure, so the chat can say which one happened.
 *
 * Hermes itself does not hand us a clean signal: its classifier folds every
 * upstream 429 into a generic rate-limit reason and drops the provider's
 * `error.type` (for example OpenAI's `insufficient_quota` or Codex's
 * `usage_limit_reached`) before the error reaches Alice. So we classify from
 * what does survive — the HTTP status, the `Retry-After` header, and the
 * provider text Hermes forwards in `detail`.
 *
 * The split that matters to the user is whether waiting helps:
 *   - `quota`      the allowance is spent; waiting for the reset (or paying) is
 *                  the only fix. Retrying now burns time for nothing.
 *   - `rateLimit`  too fast, not too much. Retrying shortly works.
 *   - `auth`       the key is wrong or lacks access to this model.
 */
export type ModelLimitKind = "quota" | "rateLimit" | "auth";

export type ModelLimit = {
  kind: ModelLimitKind;
  /** Seconds to wait, when the provider told us. Never invented. */
  retryAfterSeconds?: number;
  /** Provider/plan name when we could name it, for the message. */
  scope?: string;
};

/**
 * Markers that mean the allowance itself is exhausted. Waiting out a short
 * backoff does not clear these — only the billing period rolling over, or the
 * user topping up, does. Kept as substrings because providers word the same
 * condition differently and Hermes forwards the text verbatim.
 */
const QUOTA_MARKERS = [
  "insufficient_quota",
  "insufficient quota",
  "usage_limit_reached",
  "usage limit reached",
  "monthly usage limit",
  "daily usage limit",
  "quota exceeded",
  "exceeded your current quota",
  "out of credits",
  "credit balance",
  "not enough credits",
  "no credits remaining",
  "billing_hard_limit_reached",
  "billing hard limit",
  "plan limit reached",
  "spending limit",
  "payment required",
  "upgrade your plan",
  // Subscription-backed providers (Codex/ChatGPT, xAI OAuth, Gemini AI Studio,
  // OpenCode Free) phrase a spent allowance in their own terms.
  "usage limit",
  "weekly limit",
  "plan usage",
  "subscription limit",
  "you have reached your",
  "resets at",
  "resets in",
];

/**
 * Hermes has a known bug where an upstream 429 from a Codex/ChatGPT
 * subscription is reported as missing credentials rather than as a spent
 * allowance. A 429 is never an authentication problem, so when both signals
 * arrive together the status wins and we call it quota.
 *
 * See NousResearch/hermes-agent#32790 and #26388.
 */
const CREDENTIAL_MISLABEL_MARKERS = [
  "credential",
  "credentials",
  "not signed in",
  "no account",
];

/**
 * Markers for transient pressure. These are worth a retry; the quota markers
 * above are checked first so a body carrying both is treated as exhausted.
 */
const RATE_MARKERS = [
  "rate limit",
  "rate_limit",
  "ratelimit",
  "too many requests",
  "requests per minute",
  "tokens per minute",
  "overloaded",
  "capacity",
  "try again later",
  "slow down",
];

const AUTH_MARKERS = [
  "invalid_api_key",
  "invalid api key",
  "incorrect api key",
  "unauthorized",
  "authentication",
  "no access to model",
  "does not have access",
  "permission",
];

function has(haystack: string, markers: readonly string[]): boolean {
  return markers.some((marker) => haystack.includes(marker));
}

/**
 * Parse `Retry-After`, which is either delay-seconds or an HTTP date.
 * Returns undefined for anything we cannot read, so callers never show a
 * fabricated countdown.
 */
export function parseRetryAfter(
  value: string | null | undefined,
  now: number = Date.now(),
): number | undefined {
  if (!value) return undefined;
  const raw = value.trim();
  if (!raw) return undefined;
  if (/^\d+$/.test(raw)) {
    const seconds = Number(raw);
    return Number.isFinite(seconds) && seconds >= 0 ? seconds : undefined;
  }
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return undefined;
  return Math.max(0, Math.round((at - now) / 1000));
}

/**
 * Classify a failed model call. Returns null when nothing indicates a limit —
 * the caller then keeps whatever error it already had, rather than guessing.
 */
export function classifyModelLimit(input: {
  status?: number | undefined;
  message?: string | undefined;
  retryAfter?: string | null | undefined;
  now?: number | undefined;
}): ModelLimit | null {
  const text = (input.message ?? "").toLowerCase();
  const status = input.status;
  const retryAfterSeconds = parseRetryAfter(input.retryAfter, input.now);
  const withRetry = (limit: ModelLimit): ModelLimit =>
    retryAfterSeconds === undefined ? limit : { ...limit, retryAfterSeconds };

  // Text wins over status: a provider that says "insufficient_quota" behind a
  // 429 is exhausted, not throttled, and Hermes cannot tell us so on its own.
  if (has(text, QUOTA_MARKERS)) return withRetry({ kind: "quota" });

  // 402 is unambiguous regardless of wording.
  if (status === 402) return withRetry({ kind: "quota" });

  // Known Hermes mislabel: a 429 dressed up as a credentials problem.
  if (status === 429 && has(text, CREDENTIAL_MISLABEL_MARKERS)) {
    return withRetry({ kind: "quota" });
  }

  if (has(text, RATE_MARKERS)) return withRetry({ kind: "rateLimit" });

  if (status === 429) return withRetry({ kind: "rateLimit" });

  if (status === 401 || status === 403 || has(text, AUTH_MARKERS)) {
    return { kind: "auth" };
  }

  return null;
}
