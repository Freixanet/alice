/**
 * One-time pairing tokens. A token the helper has issued survives exactly
 * one claim and expires with its offer; the store lives in memory, so a
 * helper restart invalidates every QR it ever showed — the safe direction
 * to fail in.
 */
import { PAIR_TTL_MS } from "./pairing-protocol.mjs";

/**
 * @typedef {"ok" | "used" | "expired" | "unknown"} ConsumeResult
 */

/**
 * @param {{ ttlMs?: number, now?: () => number, capacity?: number }} [options]
 */
export function createClaimStore({
  ttlMs = PAIR_TTL_MS,
  now = () => Date.now(),
  capacity = 64,
} = {}) {
  /** @type {Map<string, { expiresAt: number, used: boolean }>} */
  const issued = new Map();

  function purge() {
    const t = now();
    for (const [token, entry] of issued) {
      if (entry.used || entry.expiresAt <= t) issued.delete(token);
    }
  }

  return {
    /**
     * Registers a fresh token and returns when it stops being claimable
     * (epoch ms, same clock the offer's `e` field carries).
     * @param {string} token
     */
    issue(token) {
      purge();
      if (issued.size >= capacity) {
        // A helper this chatty is not something the one-QR flow needs; drop
        // the oldest rather than grow without bound.
        const oldest = issued.keys().next().value;
        if (oldest !== undefined) issued.delete(oldest);
      }
      const expiresAt = now() + ttlMs;
      issued.set(token, { expiresAt, used: false });
      return expiresAt;
    },

    /**
     * @param {string} token
     * @returns {ConsumeResult} "ok" exactly once per issued token.
     */
    consume(token) {
      const entry = issued.get(token);
      if (!entry) return "unknown";
      if (entry.used) return "used";
      if (now() >= entry.expiresAt) {
        issued.delete(token);
        return "expired";
      }
      entry.used = true;
      return "ok";
    },
  };
}
