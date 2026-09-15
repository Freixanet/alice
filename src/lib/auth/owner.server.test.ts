import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Ownership decides who may drive the Hermes on this machine, so these cover
 * the ways somebody could be handed it without being given it: an address
 * anyone can register, an account that was merely first, and a database that
 * did not answer.
 */

type Row = Record<string, unknown>;

let rows: { user: Row[] };
let queries: string[];

function sqlStub() {
  return {
    query: vi.fn(async (text: string, params?: unknown[]) => {
      queries.push(text.replace(/\s+/g, " ").trim());
      if (/count\(\*\)/.test(text)) return [{ n: rows.user.length }];
      if (/from "user"/.test(text)) {
        const wantsVerified = /emailVerified" = true/.test(text);
        const email = String(params?.[0] ?? "").toLowerCase();
        return rows.user.filter((u) => {
          if (email && String(u.email).toLowerCase() !== email) return false;
          if (wantsVerified && u.emailVerified !== true) return false;
          return true;
        });
      }
      return [];
    }),
  };
}

vi.mock("../db", () => ({
  ensureDbReady: vi.fn(async () => {}),
  getSql: vi.fn(async () => sqlStub()),
}));

vi.mock("./verify.server", () => ({
  DEV_USER_ID: "dev-user",
  sessionsEnabled: () => true,
}));

vi.mock("better-auth/crypto", () => ({
  hashPassword: vi.fn(async () => "hashed"),
}));

async function subject() {
  vi.resetModules();
  return await import("./owner.server");
}

beforeEach(() => {
  rows = { user: [] };
  queries = [];
  delete process.env.ALICE_OWNER_EMAIL;
  delete process.env.ALICE_OWNER_PASSWORD;
  delete process.env.ALICE_OWNER_CLAIM_LOCAL;
  process.env.ALICE_LOCAL_HERMES = "1";
  const boot = globalThis as typeof globalThis & {
    __aliceOwnerPasswordBoot__?: Promise<void>;
    __aliceOwnerClaim__?: Promise<void>;
  };
  delete boot.__aliceOwnerPasswordBoot__;
  delete boot.__aliceOwnerClaim__;
});

afterEach(() => {
  delete process.env.ALICE_LOCAL_HERMES;
});

describe("isLocalHermesOwner", () => {
  it("provisions once while concurrent authorization checks stay read-only", async () => {
    process.env.ALICE_OWNER_EMAIL = "owner@example.test";
    process.env.ALICE_OWNER_PASSWORD = "test-only-owner-password";
    rows.user = [
      { id: "owner", email: "owner@example.test", emailVerified: true },
    ];
    const { isLocalHermesOwner } = await subject();
    const checks = await Promise.all(
      Array.from({ length: 8 }, () => isLocalHermesOwner("owner")),
    );
    expect(checks.every(Boolean)).toBe(true);
    expect(
      queries.filter((q) => q.includes('insert into "account"')),
    ).toHaveLength(1);
    const provisioned = queries.length;
    expect(await isLocalHermesOwner("owner")).toBe(true);
    expect(
      queries.slice(provisioned).every((q) => q.startsWith("select ")),
    ).toBe(true);
  });

  it("refuses an account that merely claims the pinned address", async () => {
    process.env.ALICE_OWNER_EMAIL = "owner@example.test";
    rows.user = [
      { id: "stranger", email: "owner@example.test", emailVerified: false },
    ];
    const { isLocalHermesOwner } = await subject();
    expect(await isLocalHermesOwner("stranger", "owner@example.test")).toBe(
      false,
    );
  });

  it("refuses a signed-in stranger while the owner exists", async () => {
    process.env.ALICE_OWNER_EMAIL = "owner@example.test";
    rows.user = [
      { id: "owner", email: "owner@example.test", emailVerified: true },
      { id: "other", email: "other@example.test", emailVerified: true },
    ];
    const { isLocalHermesOwner } = await subject();
    expect(await isLocalHermesOwner("other", "owner@example.test")).toBe(false);
    expect(await isLocalHermesOwner("owner", null)).toBe(true);
  });

  it("gives a fresh install no owner at all", async () => {
    rows.user = [
      { id: "first", email: "first@example.test", emailVerified: true },
    ];
    const { isLocalHermesOwner } = await subject();
    expect(await isLocalHermesOwner("first", "first@example.test")).toBe(false);
  });

  it("denies when the owner cannot be read", async () => {
    process.env.ALICE_OWNER_EMAIL = "owner@example.test";
    const db = await import("../db");
    vi.mocked(db.getSql).mockRejectedValueOnce(new Error("database is down"));
    const { isLocalHermesOwner } = await subject();
    expect(await isLocalHermesOwner("owner", "owner@example.test")).toBe(false);
  });

  it("never promotes a local account unless asked to", async () => {
    process.env.ALICE_OWNER_EMAIL = "owner@example.test";
    rows.user = [
      { id: "scratch", email: "someone@local.test", emailVerified: false },
    ];
    const { isLocalHermesOwner } = await subject();
    expect(await isLocalHermesOwner("scratch", "owner@example.test")).toBe(
      false,
    );
    expect(queries.some((q) => q.includes('update "user"'))).toBe(false);
  });
});
