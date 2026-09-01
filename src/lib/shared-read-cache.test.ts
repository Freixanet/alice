import { describe, expect, it, vi } from "vitest";
import { SharedReadCache } from "./shared-read-cache";

describe("shared idempotent read cache", () => {
  it("deduplicates concurrent reads and reuses a fresh value", async () => {
    const cache = new SharedReadCache<number>(1_000);
    let resolve!: (value: number) => void;
    const load = vi.fn(() => new Promise<number>((done) => (resolve = done)));
    const first = cache.read("key", load, { now: 100 });
    const second = cache.read("key", load, { now: 100 });
    await Promise.resolve();
    expect(load).toHaveBeenCalledOnce();
    resolve(7);
    await expect(Promise.all([first, second])).resolves.toEqual([7, 7]);
    await expect(cache.read("key", load, { now: 1_099 })).resolves.toBe(7);
    expect(load).toHaveBeenCalledOnce();
  });

  it("lets one subscriber abort without cancelling the other", async () => {
    const cache = new SharedReadCache<number>(1_000);
    const firstController = new AbortController();
    let transportSignal!: AbortSignal;
    let resolve!: (value: number) => void;
    const load = (signal: AbortSignal) => {
      transportSignal = signal;
      return new Promise<number>((done) => (resolve = done));
    };
    const first = cache.read("key", load, { signal: firstController.signal });
    const second = cache.read("key", load);
    await Promise.resolve();
    firstController.abort();
    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    expect(transportSignal.aborted).toBe(false);
    resolve(9);
    await expect(second).resolves.toBe(9);
  });

  it("aborts the transport when every subscriber leaves", async () => {
    const cache = new SharedReadCache<number>(1_000);
    const one = new AbortController();
    const two = new AbortController();
    let transportSignal!: AbortSignal;
    const load = (signal: AbortSignal) => {
      transportSignal = signal;
      return new Promise<number>((_resolve, reject) =>
        signal.addEventListener("abort", () => reject(signal.reason), {
          once: true,
        }),
      );
    };
    const first = cache.read("key", load, { signal: one.signal });
    const second = cache.read("key", load, { signal: two.signal });
    await Promise.resolve();
    one.abort();
    two.abort();
    await Promise.allSettled([first, second]);
    expect(transportSignal.aborted).toBe(true);
  });

  it("does not cache rejected values and invalidation aborts stale work", async () => {
    const cache = new SharedReadCache<{ ok: boolean }>(1_000, (value) =>
      Boolean(value.ok),
    );
    const failed = vi.fn(async () => ({ ok: false }));
    await cache.read("key", failed, { now: 1 });
    await cache.read("key", failed, { now: 2 });
    expect(failed).toHaveBeenCalledTimes(2);

    let signal!: AbortSignal;
    const request = cache.read("stale", (nextSignal) => {
      signal = nextSignal;
      return new Promise<{ ok: boolean }>(() => undefined);
    });
    await Promise.resolve();
    cache.invalidate("stale");
    await expect(request).rejects.toBeDefined();
    expect(signal.aborted).toBe(true);
  });
});
