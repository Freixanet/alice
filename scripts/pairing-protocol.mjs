/**
 * The `alice://pair` payload: the signed deep link a Hermes shows as a QR
 * code and Alice opens — through the system camera or the in-app scanner.
 * Pure logic, no I/O, so the helper that builds it and the tests that pin it
 * down stay honest. The wire contract lives in docs/pairing.md; the iOS side
 * parses the same shape in ios/Alice/Features/Connect/Pairing/.
 */
import { createHmac, timingSafeEqual } from "node:crypto";

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
 * padded with standard alphabet, or otherwise not canonical is rejected
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
 * Fixed key order keeps signatures stable regardless of how the caller
 * spelled the offer object.
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
 * @param {string | Buffer} secret
 * @returns {string} The full deep link, QR-ready.
 */
export function buildPairingLink(offer, secret) {
  const bytes = canonicalOfferBytes(offer);
  const signature = createHmac("sha256", secret).update(bytes).digest("hex");
  return `alice://pair?v=${PAIR_VERSION}&p=${bytes.toString("base64url")}&s=${signature}`;
}

/**
 * Shape-only parse: scheme, version, canonical payload, field types. It
 * deliberately says nothing about expiry or the signature — those need a
 * clock (verifyPairingLink) or the issuing secret.
 * @param {unknown} text
 * @returns {{ offer: PairingOffer, signature: string, payloadBytes: Buffer } | null}
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
  if (url.searchParams.get("v") !== String(PAIR_VERSION)) return null;
  const encoded = url.searchParams.get("p");
  const signature = url.searchParams.get("s");
  if (!encoded || !signature) return null;
  const payloadBytes = decodeBase64Url(encoded);
  if (!payloadBytes) return null;
  let raw;
  try {
    raw = JSON.parse(payloadBytes.toString("utf8"));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;
  const { c, t, e } = raw;
  if (typeof c !== "string" || !/^https?:\/\//.test(c)) return null;
  if (typeof t !== "string" || t.length === 0) return null;
  if (!Number.isInteger(e) || e < 0) return null;
  if (raw.pr !== undefined && typeof raw.pr !== "string") return null;
  const offer = { c, t, e };
  if (typeof raw.pr === "string" && raw.pr.length > 0) offer.pr = raw.pr;
  return { offer, signature, payloadBytes };
}

/**
 * Parse + signature + expiry. Only the issuer holds the secret, so this is
 * the helper's own round-trip guard (and the future dashboard's check once
 * a secret is pinned per install) — Alice's v1 trust is the claim endpoint.
 * @param {string} text
 * @param {string | Buffer} secret
 * @param {number} [nowMs]
 * @returns {{ ok: true, offer: PairingOffer } | { ok: false, reason: "malformed" | "signature" | "expired" }}
 */
export function verifyPairingLink(text, secret, nowMs = Date.now()) {
  const parsed = parsePairingLink(text);
  if (!parsed) return { ok: false, reason: "malformed" };
  const expected = Buffer.from(
    createHmac("sha256", secret).update(parsed.payloadBytes).digest("hex"),
    "hex",
  );
  const actual = Buffer.from(parsed.signature, "hex");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    return { ok: false, reason: "signature" };
  }
  if (parsed.offer.e * 1000 <= nowMs) return { ok: false, reason: "expired" };
  return { ok: true, offer: parsed.offer };
}
