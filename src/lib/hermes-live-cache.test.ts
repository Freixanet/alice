import { beforeEach, describe, expect, it, vi } from "vitest";
import type { HermesLive } from "./hermes-live-types";
import {
  clearHermesLiveCache,
  HERMES_LIVE_CACHE_TTL_MS,
  hermesLiveCacheKey,
  invalidateHermesLiveCache,
  readHermesLiveCache,
  refreshHermesLiveCache,
  setHermesLiveCacheData,
} from "./hermes-live-cache";

const live = {
  ok: true,
  writable: true,
  owner: true,
  local: true,
  skills: [],
  toolsets: [],
  plugins: [],
  pluginsSupported: true,
  mcp: [],
  cron: [],
  cronDeliveryTargets: [],
  channels: [],
  sessions: [],
  pairing: [],
  pairingApproved: [],
  webhooks: { enabled: false, subscriptions: [] },
  projects: [],
  curator: null,
} satisfies HermesLive;

beforeEach(() => clearHermesLiveCache());

describe("shared Hermes live cache", () => {
  it("isolates entries by user, connection and profile", () => {
    const base = {
      userId: "user-1",
      place: "mac",
      url: "https://hermes.example",
      profile: "default",
    };
    expect(hermesLiveCacheKey(base)).not.toBe(
      hermesLiveCacheKey({ ...base, userId: "user-2" }),
    );
    expect(hermesLiveCacheKey(base)).not.toBe(
      hermesLiveCacheKey({ ...base, profile: "research" }),
    );
  });

  it("deduplicates simultaneous route loads and reuses fresh data", async () => {
    const key = "one";
    let resolve!: (value: HermesLive) => void;
    const load = vi.fn(
      () =>
        new Promise<HermesLive>((done) => {
          resolve = done;
        }),
    );
    const first = refreshHermesLiveCache(key, load, { now: 1_000 });
    const second = refreshHermesLiveCache(key, load, { now: 1_000 });
    await Promise.resolve();
    expect(load).toHaveBeenCalledOnce();
    expect(readHermesLiveCache(key)?.loading).toBe(true);
    resolve(live);
    await Promise.all([first, second]);
    expect(readHermesLiveCache(key)?.data).toBe(live);

    await refreshHermesLiveCache(key, load, {
      now: 1_000 + HERMES_LIVE_CACHE_TTL_MS - 1,
    });
    expect(load).toHaveBeenCalledOnce();
  });

  it("keeps stale data visible when a background refresh fails", async () => {
    const key = "one";
    setHermesLiveCacheData(key, live);
    const stale = readHermesLiveCache(key)!;
    // Move the timestamp back without relying on fake timers.
    await refreshHermesLiveCache(
      key,
      async () => ({ ok: false, error: "offline" }),
      {
        force: true,
        now: stale.updatedAt + HERMES_LIVE_CACHE_TTL_MS,
      },
    );
    expect(readHermesLiveCache(key)).toMatchObject({
      data: live,
      error: null,
      loading: false,
    });
  });

  it("does not overwrite a newer optimistic mutation", async () => {
    const key = "one";
    let resolve!: (value: HermesLive) => void;
    const request = refreshHermesLiveCache(
      key,
      () =>
        new Promise<HermesLive>((done) => {
          resolve = done;
        }),
    );
    await Promise.resolve();
    const optimistic = {
      ...live,
      skills: [
        {
          id: "browser",
          name: "browser",
          title: "Browser",
          description: "",
          group: "core",
          groupLabel: "Core",
          enabled: true,
        },
      ],
    } satisfies HermesLive;
    setHermesLiveCacheData(key, optimistic);
    resolve(live);
    await request;
    expect(readHermesLiveCache(key)?.data).toBe(optimistic);
  });

  it("discards a request that resolves after an account change", async () => {
    const key = "old-user";
    let resolve!: (value: HermesLive) => void;
    const request = refreshHermesLiveCache(
      key,
      () =>
        new Promise<HermesLive>((done) => {
          resolve = done;
        }),
    );
    await Promise.resolve();
    clearHermesLiveCache();
    resolve(live);
    await request;
    expect(readHermesLiveCache(key)).toBeUndefined();
  });

  it("aborts the transport when the account cache is cleared", async () => {
    const key = "old-user";
    let signal: AbortSignal | undefined;
    const load = vi.fn(
      (requestSignal: AbortSignal) =>
        new Promise<HermesLive>((_resolve, reject) => {
          signal = requestSignal;
          requestSignal.addEventListener(
            "abort",
            () => reject(new Error("aborted")),
            {
              once: true,
            },
          );
        }),
    );
    const request = refreshHermesLiveCache(key, load);
    await Promise.resolve();
    clearHermesLiveCache();
    expect(signal?.aborted).toBe(true);
    await request;
    expect(load).toHaveBeenCalledOnce();
    expect(readHermesLiveCache(key)).toBeUndefined();
  });

  it("invalidates one key without allowing its stale response back in", async () => {
    const key = "one";
    const otherKey = "two";
    setHermesLiveCacheData(otherKey, live);
    let resolve!: (value: HermesLive) => void;
    const request = refreshHermesLiveCache(
      key,
      () =>
        new Promise<HermesLive>((done) => {
          resolve = done;
        }),
    );
    await Promise.resolve();
    invalidateHermesLiveCache(key);
    resolve(live);
    await request;
    expect(readHermesLiveCache(key)).toBeUndefined();
    expect(readHermesLiveCache(otherKey)?.data).toBe(live);
  });
});
