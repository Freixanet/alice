import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";

import {
  PAIR_TTL_MS,
  PAIR_VERSION,
  buildPairingLink,
  canonicalOfferBytes,
  parsePairingLink,
  validatePairingLink,
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

function rawLink(json, extras = "") {
  return `alice://pair?v=${PAIR_VERSION}&p=${Buffer.from(json).toString("base64url")}${extras}`;
}

describe("pairing protocol", () => {
  it("round-trips a built link through parse and validation", () => {
    const now = 1_700_000_000_000;
    const link = buildPairingLink(offer(now));

    const parsed = parsePairingLink(link);
    expect(parsed?.offer.c).toBe("http://100.67.213.42:8643/claim");
    expect(parsed?.offer.pr).toBe("radar-ia");
    expect(parsed?.offer.t).toBeTruthy();

    expect(validatePairingLink(link, now)).toEqual({
      ok: true,
      offer: parsed?.offer,
    });
  });

  it("builds the exact documented shape", () => {
    const link = buildPairingLink({
      c: "http://host:1/claim",
      t: "tok",
      e: 123,
      pr: "p",
    });
    expect(link).toMatch(/^alice:\/\/pair\?v=1&p=[A-Za-z0-9_-]+$/);

    // Key order is fixed: the same offer spelled differently gets one wire form.
    expect(
      buildPairingLink({
        e: 123,
        pr: "p",
        t: "tok",
        c: "http://host:1/claim",
      }),
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

  it("rejects an expired offer at the exact boundary", () => {
    const now = 1_700_000_000_000;
    const built = offer(now);
    const link = buildPairingLink(built);
    expect(validatePairingLink(link, built.e * 1000)).toEqual({
      ok: false,
      reason: "expired",
    });
  });

  it.each([
    ["other scheme", "https://pair?v=1&p=AAAA"],
    ["other host", "alice://evil?v=1&p=AAAA"],
    ["wrong version", "alice://pair?v=2&p=AAAA"],
    ["missing payload", "alice://pair?v=1"],
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
    expect(
      parsePairingLink(valid.replace("alice://pair?", "alice://pair/x?")),
    ).toBeNull();
    expect(parsePairingLink(`${valid}#x`)).toBeNull();
  });

  it("refuses payload padding, standard alphabet and noncanonical leftover bits", () => {
    expect(parsePairingLink("alice://pair?v=1&p=eyJj=")).toBeNull();
    expect(parsePairingLink("alice://pair?v=1&p=AA+B")).toBeNull();
    expect(parsePairingLink("alice://pair?v=1&p=AB")).toBeNull();
  });

  it("refuses offers whose fields or endpoint are unsafe", () => {
    expect(parsePairingLink(rawLink('{"c":"ftp://x","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://u:p@x","t":"t","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"","e":1}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":"soon"}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":1.5}'))).toBeNull();
    expect(parsePairingLink(rawLink('{"c":"http://x","t":"t","e":1,"pr":7}'))).toBeNull();
    expect(
      parsePairingLink(
        rawLink('{"c":"http://x","t":"t","e":1,"extra":true}'),
      ),
    ).toBeNull();
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
