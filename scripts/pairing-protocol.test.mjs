import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";

import {
  PAIR_TTL_MS,
  PAIR_VERSION,
  buildPairingLink,
  canonicalOfferBytes,
  parsePairingLink,
  verifyPairingLink,
} from "./pairing-protocol.mjs";

/** A valid offer one second before the horizon the tests control. */
function offer(nowMs, overrides = {}) {
  return {
    c: "http://100.67.213.42:8643/claim",
    t: randomBytes(24).toString("base64url"),
    e: Math.floor((nowMs + PAIR_TTL_MS) / 1000),
    pr: "radar-ia",
    ...overrides,
  };
}

describe("pairing protocol", () => {
  it("round-trips a built link through parse and verify", () => {
    const secret = randomBytes(32);
    const now = 1_700_000_000_000;
    const link = buildPairingLink(offer(now), secret);

    const parsed = parsePairingLink(link);
    expect(parsed?.offer.c).toBe("http://100.67.213.42:8643/claim");
    expect(parsed?.offer.pr).toBe("radar-ia");
    expect(parsed?.offer.t).toBeTruthy();

    expect(verifyPairingLink(link, secret, now)).toEqual({
      ok: true,
      offer: parsed?.offer,
    });
  });

  it("builds the exact documented shape", () => {
    const link = buildPairingLink(
      { c: "http://host:1/claim", t: "tok", e: 123, pr: "p" },
      "s",
    );
    expect(link).toMatch(
      /^alice:\/\/pair\?v=1&p=[A-Za-z0-9_-]+&s=[0-9a-f]{64}$/,
    );
    // Key order is fixed: the same offer spelled differently signs the same.
    expect(
      buildPairingLink(
        { e: 123, pr: "p", t: "tok", c: "http://host:1/claim" },
        "s",
      ),
    ).toBe(link);
  });

  it("omits pr from the payload when the offer has none", () => {
    const bytes = canonicalOfferBytes({ c: "http://h:1/claim", t: "t", e: 1 });
    expect(JSON.parse(bytes.toString("utf8"))).toEqual({
      c: "http://h:1/claim",
      t: "t",
      e: 1,
    });
  });

  it("rejects a tampered payload", () => {
    const secret = randomBytes(32);
    const link = buildPairingLink(offer(1_700_000_000_000), secret);
    // Keep the original signature but change the token under it: a valid,
    // canonical payload whose signature no longer matches.
    const parsed = parsePairingLink(link);
    const tamperedPayload = Buffer.from(
      JSON.stringify({ ...parsed.offer, t: "different" }),
    ).toString("base64url");
    const tampered = `alice://pair?v=1&p=${tamperedPayload}&s=${parsed.signature}`;
    expect(verifyPairingLink(tampered, secret)).toEqual({
      ok: false,
      reason: "signature",
    });
  });

  it("rejects the wrong secret", () => {
    const link = buildPairingLink(offer(1_700_000_000_000), randomBytes(32));
    expect(verifyPairingLink(link, randomBytes(32))).toEqual({
      ok: false,
      reason: "signature",
    });
  });

  it("rejects an expired offer at the exact boundary", () => {
    const secret = randomBytes(32);
    const now = 1_700_000_000_000;
    const link = buildPairingLink(offer(now), secret);
    const atExpiry = offer(now).e * 1000;
    expect(verifyPairingLink(link, secret, atExpiry)).toEqual({
      ok: false,
      reason: "expired",
    });
  });

  it.each([
    ["other scheme", "https://pair?v=1&p=AAAA&s=00"],
    ["other host", "alice://evil?v=1&p=AAAA&s=00"],
    ["wrong version", "alice://pair?v=2&p=AAAA&s=00"],
    ["missing signature", "alice://pair?v=1&p=AAAA"],
    ["empty query", "alice://pair"],
    ["garbage", "not a link at all"],
    ["empty", ""],
  ])("refuses %s", (_name, text) => {
    expect(parsePairingLink(text)).toBeNull();
  });

  it("refuses payload padding and the standard base64 alphabet", () => {
    const padded = "alice://pair?v=1&p=eyJj%3D&s=00".replace("%3D", "=");
    expect(parsePairingLink(padded)).toBeNull();
    const plus = "alice://pair?v=1&p=AA%2BB&s=00".replace("%2B", "+");
    expect(parsePairingLink(plus)).toBeNull();
  });

  it("refuses offers whose fields are the wrong type", () => {
    const encode = (json) =>
      `alice://pair?v=${PAIR_VERSION}&p=${Buffer.from(json).toString("base64url")}&s=00`;
    expect(
      parsePairingLink(encode('{"c":"ftp://x","t":"t","e":1}')),
    ).toBeNull();
    expect(
      parsePairingLink(encode('{"c":"http://x","t":"","e":1}')),
    ).toBeNull();
    expect(
      parsePairingLink(encode('{"c":"http://x","t":"t","e":"soon"}')),
    ).toBeNull();
    expect(
      parsePairingLink(encode('{"c":"http://x","t":"t","e":1,"pr":7}')),
    ).toBeNull();
    expect(parsePairingLink(encode("[]"))).toBeNull();
  });

  it("keeps an empty-string pr out of the offer", () => {
    const encoded = Buffer.from(
      JSON.stringify({ c: "http://h:1/claim", t: "t", e: 1, pr: "" }),
    ).toString("base64url");
    const parsed = parsePairingLink(`alice://pair?v=1&p=${encoded}&s=00`);
    expect(parsed?.offer).toEqual({ c: "http://h:1/claim", t: "t", e: 1 });
  });
});
