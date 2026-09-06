import { describe, expect, it } from "vitest";

import { createClaimStore } from "./pairing-claims.mjs";

describe("claim store", () => {
  it("lets a token be consumed exactly once", () => {
    let now = 1_000_000;
    const store = createClaimStore({ now: () => now });
    store.issue("tok");

    expect(store.consume("tok")).toBe("ok");
    expect(store.consume("tok")).toBe("used");
    expect(store.consume("tok")).toBe("used");
  });

  it("expires tokens at the boundary, not before", () => {
    let now = 1_000_000;
    const store = createClaimStore({ ttlMs: 5_000, now: () => now });
    store.issue("tok");

    now += 4_999;
    expect(store.consume("tok")).toBe("ok");
  });

  it("refuses a token whose window has passed", () => {
    let now = 1_000_000;
    const store = createClaimStore({ ttlMs: 5_000, now: () => now });
    store.issue("tok");

    now += 5_000;
    expect(store.consume("tok")).toBe("expired");
  });

  it("reports unknown tokens without touching the store", () => {
    const store = createClaimStore();
    expect(store.consume("never-issued")).toBe("unknown");
  });

  it("a restart is a clean slate — nothing persists", () => {
    const first = createClaimStore();
    first.issue("tok");
    expect(createClaimStore().consume("tok")).toBe("unknown");
  });

  it("purges dead entries as new ones arrive, bounded", () => {
    let now = 1_000_000;
    const store = createClaimStore({
      ttlMs: 1_000,
      now: () => now,
      capacity: 2,
    });
    store.issue("a");
    store.issue("b");
    now += 2_000; // a and b are dead now
    store.issue("c");
    store.issue("d");
    expect(store.consume("a")).toBe("unknown");
    expect(store.consume("c")).toBe("ok");
    expect(store.consume("d")).toBe("ok");
  });
});
