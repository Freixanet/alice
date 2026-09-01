import { describe, expect, it } from "vitest";
import { classifyModelLimit, parseRetryAfter } from "./model-limit";

describe("model limit classification", () => {
  it("reads quota exhaustion out of a 429 the provider worded as usage", () => {
    // Hermes folds every 429 into a generic rate limit, so the wording is the
    // only thing that still says "waiting will not help".
    expect(
      classifyModelLimit({
        status: 429,
        message: "You exceeded your current quota, please check your plan.",
      }),
    ).toEqual({ kind: "quota" });

    expect(
      classifyModelLimit({ status: 429, message: "usage_limit_reached" }),
    ).toEqual({ kind: "quota" });
  });

  it("keeps a plain 429 as a retryable rate limit", () => {
    expect(
      classifyModelLimit({ status: 429, message: "Too Many Requests" }),
    ).toEqual({ kind: "rateLimit" });
  });

  it("treats server overload as transient, not as exhausted quota", () => {
    expect(
      classifyModelLimit({
        status: 429,
        message: "The model is temporarily overloaded.",
      }),
    ).toEqual({ kind: "rateLimit" });
  });

  it("treats 402 as quota whatever the wording", () => {
    expect(classifyModelLimit({ status: 402, message: "" })).toEqual({
      kind: "quota",
    });
  });

  it("separates a bad key from a spent allowance", () => {
    expect(
      classifyModelLimit({ status: 401, message: "invalid_api_key" }),
    ).toEqual({ kind: "auth" });
  });

  it("returns null when nothing points at a limit", () => {
    expect(
      classifyModelLimit({ status: 500, message: "internal error" }),
    ).toBeNull();
    expect(classifyModelLimit({})).toBeNull();
  });

  it("carries Retry-After only when the provider sent one", () => {
    expect(
      classifyModelLimit({
        status: 429,
        message: "rate limit",
        retryAfter: "30",
      }),
    ).toEqual({ kind: "rateLimit", retryAfterSeconds: 30 });

    expect(classifyModelLimit({ status: 429, message: "rate limit" })).toEqual({
      kind: "rateLimit",
    });
  });

  it("never attaches a countdown to an auth failure", () => {
    expect(
      classifyModelLimit({
        status: 401,
        message: "unauthorized",
        retryAfter: "60",
      }),
    ).toEqual({ kind: "auth" });
  });
});

describe("Retry-After parsing", () => {
  it("reads delay-seconds", () => {
    expect(parseRetryAfter("120")).toBe(120);
    expect(parseRetryAfter("0")).toBe(0);
  });

  it("reads an HTTP date relative to now", () => {
    const now = Date.parse("2026-09-01T12:00:00Z");
    expect(parseRetryAfter("Tue, 01 Sep 2026 12:01:00 GMT", now)).toBe(60);
  });

  it("never goes negative for a date already past", () => {
    const now = Date.parse("2026-09-01T12:00:00Z");
    expect(parseRetryAfter("Tue, 01 Sep 2026 11:59:00 GMT", now)).toBe(0);
  });

  it("returns undefined rather than guessing", () => {
    expect(parseRetryAfter(null)).toBeUndefined();
    expect(parseRetryAfter("")).toBeUndefined();
    expect(parseRetryAfter("soon")).toBeUndefined();
  });
});

describe("subscription providers", () => {
  it("reads a Codex weekly allowance as quota, not as a rate limit", () => {
    expect(
      classifyModelLimit({
        status: 429,
        message: "You have reached your weekly limit. Resets in 2 days.",
      }),
    ).toEqual({ kind: "quota" });
  });

  it("does not mistake a Hermes credential mislabel for an auth failure", () => {
    // Hermes reports some upstream 429 quota errors as missing Codex
    // credentials; the status is the reliable half of that signal.
    expect(
      classifyModelLimit({
        status: 429,
        message: "No Codex credentials available for this request.",
      }),
    ).toEqual({ kind: "quota" });
  });

  it("still treats a real 401 credentials error as auth", () => {
    expect(
      classifyModelLimit({
        status: 401,
        message: "No Codex credentials available for this request.",
      }),
    ).toEqual({ kind: "auth" });
  });
});

describe("wording Hermes actually shows", () => {
  // Taken from the error banner in the official Hermes app when a
  // subscription's allowance runs out. Keeping the literal string here means a
  // future edit to the marker list cannot silently stop recognising it.
  it("reads the official app's usage-limit banner as spent quota", () => {
    expect(
      classifyModelLimit({
        status: 429,
        message: "HTTP 429: The usage limit has been reached",
      }),
    ).toEqual({ kind: "quota" });
  });

  it("reads it without the status prefix too", () => {
    expect(
      classifyModelLimit({
        status: 429,
        message: "The usage limit has been reached",
      }),
    ).toEqual({ kind: "quota" });
  });

  it("still calls a plain overload a rate limit, not spent quota", () => {
    // The distinction only earns its keep if it does not collapse to "quota".
    expect(
      classifyModelLimit({ status: 429, message: "Provider is overloaded" }),
    ).toEqual({ kind: "rateLimit" });
  });
});
