import { afterEach, describe, expect, it, vi } from "vitest";
import { openGate, sealGate } from "./gateway.server";

afterEach(() => vi.unstubAllEnvs());

describe("Hermes credential encryption", () => {
  it("versions and authenticates sealed credentials", () => {
    vi.stubEnv("HERMES_COOKIE_KEYS", "current:test-secret-current");
    const token = sealGate({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
      uid: "user-1",
    });
    expect(token).toMatch(/^v1\.current\./);
    expect(openGate(token)).toEqual({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
      uid: "user-1",
    });
    expect(openGate(`${token.slice(0, -1)}x`)).toBeNull();
  });

  it("can decrypt with a retained rotation key", () => {
    vi.stubEnv("HERMES_COOKIE_KEYS", "old:test-secret-old");
    const oldToken = sealGate({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
    });
    vi.stubEnv(
      "HERMES_COOKIE_KEYS",
      "current:test-secret-current,old:test-secret-old",
    );
    expect(openGate(oldToken)?.k).toBe("hermes-key");
  });

  it("fails closed in production without a persistent key", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("HERMES_COOKIE_KEYS", "");
    vi.stubEnv("HERMES_COOKIE_SECRET", "");
    vi.stubEnv("BETTER_AUTH_SECRET", "");
    expect(() =>
      sealGate({ k: "key", u: "https://hermes.example", p: "cloud" }),
    ).toThrow("Persistent Hermes credential encryption key is missing");
  });
});
