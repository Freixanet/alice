import { afterEach, describe, expect, it, vi } from "vitest";
import {
  resetTailnetHostCacheForTest,
  tailnetHost,
  tailnetHttpsOrigin,
} from "./tailnet.server";

afterEach(() => {
  resetTailnetHostCacheForTest();
  vi.unstubAllEnvs();
});

describe("tailnet status cache", () => {
  it("reuses both online and offline results inside the bounded window", () => {
    let reads = 0;
    const read = () => {
      reads += 1;
      return reads === 1 ? null : "alice.tailnet.ts.net";
    };
    expect(tailnetHost({ now: 1_000, read })).toBeNull();
    expect(tailnetHost({ now: 5_000, read })).toBeNull();
    expect(reads).toBe(1);
    expect(tailnetHost({ now: 11_000, read })).toBe("alice.tailnet.ts.net");
    expect(reads).toBe(2);
  });

  it("prefers the explicit host without invoking the system command", () => {
    vi.stubEnv("ALICE_TAILNET_HOST", "alice.tailnet.ts.net.");
    const read = vi.fn(() => null);
    expect(tailnetHost({ read })).toBe("alice.tailnet.ts.net");
    expect(tailnetHttpsOrigin()).toBe("https://alice.tailnet.ts.net");
    expect(read).not.toHaveBeenCalled();
  });
});
