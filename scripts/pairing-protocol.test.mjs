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

const signature = "0".repeat(64);

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

function rawLink(json, extras = "") {
  return `alice://pair?v=${PAIR_VERSION}&p=${Buffer.from(json).toString("base64url")}&s=${signature}${extras}`;
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
    ["other scheme", `https://pair?v=1&p=AAAA&s=${signature}`],
    ["other host", `alice://evil?v=1&p=AAAA&s=${signature}`],
    ["wrong version", `alice://pair?v=2&p=AAAA&s=${signature}`],
    ["missing signature", "alice://pair?v=1&p=AAAA"],
    ["short signature", "alice://pair?v=1&p=AAAA&s=00"],
    ["empty query", "alice://pair"],
    ["garbage", "not a link at all"],
    ["empty", ""],
  ])("refuses %s", (_name, text) => {
    expect(parsePairingLink(text)).toBeNull();
  });

  it("refuses duplicate, extra, path and fragment envelope fields", () => {
    const valid = rawLink('{"c":"http://h:1/claim","t":"t","e":1}');
    expect(parsePairingLink(`${valid}&v=1`)).toBeNull();
    expect(parsePairingLink(`${valid}&x=1`)).toBeNull();
    expect(parsePairingLink(valid.replace("alice://pair?", "alice://pair/x?"))).toBeNull();
    expect(parsePairingLink(`${valid}#x`)).toBeNull();
  });

  it("refuses payload padding, standard alphabet and noncanonical leftover bits", () => {
    const padded = `alice://pair?v=1&p=eyJj=&s=${signature}`;
    expect(parsePairingLink(padded)).toBeNull();
    const plus = `alice://pair?v=1&p=AA+B&s=${signature}`;
    expect(parsePairingLink(plus)).toBeNull();
    expect(parsePairingLink(`alice://pair?v=1&p=AB&s=${signature}`)).toBeNull();
  });

  it("refuses offers whose fields or endpoint are unsafe", () => {
    expect(parsePairingLink(rawLink('{"c":"ftp://x","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://u:p@x","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":"soon"}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":1.5}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":1,"pr":7}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":1,"extra":true}'))).toBeNull();
    expect(parsePairingLink(rawLink("[]"))).toBeNull();
  });

  it("trims an optional profile and drops a blank one", () => {
    const blank = parsePairingLink(
      rawLink('{"c":"http://h:1/claim","t":"t","e":1,"pr":"   "}'),
    );
    expect(blank?.offer).toEqual({ c: "http://h:1/claim", t: "t", e: 1 });

    const named = parsePairingLink(
      rawLink('{"c":"http://h:1/claim","t":"t","e":1,"pr":"  radar-ia  "}'),
    );
    expect(named?.offer.pr).toBe("radar-ia");
  });
});
