import { beforeEach, describe, expect, it } from "vitest";
import { consumeRateLimit, resetRateLimitsForTests } from "./rate-limit.server";

beforeEach(resetRateLimitsForTests);

describe("consumeRateLimit", () => {
  it("isolates scopes and identities", () => {
    expect(consumeRateLimit("chat", "a", 1, 1_000, 0).ok).toBe(true);
    expect(consumeRateLimit("chat", "a", 1, 1_000, 1).ok).toBe(false);
    expect(consumeRateLimit("chat", "b", 1, 1_000, 1).ok).toBe(true);
    expect(consumeRateLimit("hermes", "a", 1, 1_000, 1).ok).toBe(true);
  });

  it("resets deterministically after the window", () => {
    consumeRateLimit("chat", "a", 1, 1_000, 0);
    expect(consumeRateLimit("chat", "a", 1, 1_000, 999).ok).toBe(false);
    expect(consumeRateLimit("chat", "a", 1, 1_000, 1_000).ok).toBe(true);
  });
});
