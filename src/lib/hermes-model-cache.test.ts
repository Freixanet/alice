import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearHermesModelCache,
  hermesModelCacheKey,
  readHermesModelsCached,
} from "./hermes-model-cache";

beforeEach(() => clearHermesModelCache());

describe("Hermes model read cache", () => {
  it("isolates models by account, connection and profile", () => {
    const base = {
      userId: "one",
      url: "https://hermes.example",
      place: "cloud",
      profile: "default",
    };
    expect(hermesModelCacheKey(base)).not.toBe(
      hermesModelCacheKey({ ...base, userId: "two" }),
    );
    expect(hermesModelCacheKey(base)).not.toBe(
      hermesModelCacheKey({ ...base, profile: "research" }),
    );
  });

  it("deduplicates forced reads and never caches failures", async () => {
    const result = { ok: true, models: [] };
    const load = vi.fn(async () => result);
    const [first, second] = await Promise.all([
      readHermesModelsCached("key", load, { force: true }),
      readHermesModelsCached("key", load, { force: true }),
    ]);
    expect(load).toHaveBeenCalledOnce();
    expect(first).toBe(result);
    expect(second).toBe(result);

    const failed = vi.fn(async () => ({ ok: false, models: [] }));
    await readHermesModelsCached("failed", failed);
    await readHermesModelsCached("failed", failed);
    expect(failed).toHaveBeenCalledTimes(2);
  });
});
