/**
 * The `alice://pair` payload a Hermes shows as a QR code and Alice opens —
 * through the system camera or the in-app scanner.
 *
 * V1 deliberately carries only what the iPhone can actually trust and use:
 * a short-lived bearer token plus the tailnet claim endpoint. An HMAC whose
 * secret exists only on the Mac would be unverifiable by Alice and therefore
 * security theatre; if a future protocol needs cryptographic issuer identity,
 * that belongs in a new version with a verifiable key distribution story.
 *
 * Pure logic, no I/O, so the helper that builds it and the tests that pin it
 * down stay honest. The wire contract lives in docs/pairing.md; the iOS side
 * parses the same shape in ios/Alice/Features/Connect/Pairing/.
 */
export const PAIR_VERSION = 1;
export const PAIR_TTL_MS = 5 * 60 * 1000;

/**
 * @typedef {object} PairingOffer
 * @property {string} c  Absolute claim URL the phone will POST the token to.
 * @property {string} t  One-time token.
 * @property {number} e  Expiry as Unix epoch seconds.
 * @property {string} [pr] Hermes profile name, informational only.
 */

/**
 * Node's "base64url" encoder is RFC 4648 §5 without padding, exactly what
 * the contract fixes. Decoding round-trips the text so a code padded,
 * using the standard alphabet, or carrying non-zero leftover bits is rejected
 * rather than silently accepted.
 * @param {string} text
 * @returns {Buffer | null}
 */
export function decodeBase64Url(text) {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) return null;
  const bytes = Buffer.from(text, "base64url");
  return bytes.toString("base64url") === text ? bytes : null;
}

/**
 * Fixed key order gives the wire payload one stable spelling.
 * @param {PairingOffer} offer
 * @returns {Buffer}
 */
export function canonicalOfferBytes(offer) {
  const payload = { c: offer.c, t: offer.t, e: offer.e };
  if (offer.pr !== undefined) payload.pr = offer.pr;
  return Buffer.from(JSON.stringify(payload), "utf8");
}

/**
 * @param {PairingOffer} offer
 * @returns {string} The full deep link, QR-ready.
 */
export function buildPairingLink(offer) {
  const bytes = canonicalOfferBytes(offer);
  return `alice://pair?v=${PAIR_VERSION}&p=${bytes.toString("base64url")}`;
}

/**
 * One exact v1 envelope, canonical payload and field types.
 * @param {unknown} text
 * @returns {{ offer: PairingOffer, payloadBytes: Buffer } | null}
 */
export function parsePairingLink(text) {
  if (typeof text !== "string") return null;
  let url;
  try {
    url = new URL(text.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "alice:" || url.host !== "pair") return null;
  if (url.pathname !== "" || url.hash !== "") return null;

  const queryKeys = [...url.searchParams.keys()];
  if (
    queryKeys.length !== 2 ||
    new Set(queryKeys).size !== 2 ||
    !queryKeys.every((key) => ["v", "p"].includes(key))
  ) {
    return null;
  }
  if (url.searchParams.get("v") !== String(PAIR_VERSION)) return null;

  const encoded = url.searchParams.get("p");
  if (!encoded || encoded.length > 4096) return null;
  const payloadBytes = decodeBase64Url(encoded);
  if (!payloadBytes) return null;

  let raw;
  try {
    raw = JSON.parse(payloadBytes.toString("utf8"));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const keys = Object.keys(raw);
  if (keys.some((key) => !["c", "t", "e", "pr"].includes(key))) return null;

  const { c, t, e } = raw;
  if (typeof c !== "string") return null;
  let claimURL;
  try {
    claimURL = new URL(c);
  } catch {
    return null;
  }
  if (
    !["http:", "https:"].includes(claimURL.protocol) ||
    !claimURL.hostname ||
    claimURL.username ||
    claimURL.password
  ) {
    return null;
  }
  if (typeof t !== "string" || t.length === 0 || t.length > 512) return null;
  if (!Number.isSafeInteger(e) || e < 0) return null;
  if (raw.pr !== undefined && typeof raw.pr !== "string") return null;

  const offer = { c: claimURL.href, t, e };
  if (typeof raw.pr === "string" && raw.pr.trim().length > 0) {
    offer.pr = raw.pr.trim();
  }
  return { offer, payloadBytes };
}

/**
 * Parse + expiry with the same boundary the claim store uses.
 * @param {string} text
 * @param {number} [nowMs]
 * @returns {{ ok: true, offer: PairingOffer } | { ok: false, reason: "malformed" | "expired" }}
 */
export function validatePairingLink(text, nowMs = Date.now()) {
  const parsed = parsePairingLink(text);
  if (!parsed) return { ok: false, reason: "malformed" };
  if (parsed.offer.e * 1000 <= nowMs) return { ok: false, reason: "expired" };
  return { ok: true, offer: parsed.offer };
}
