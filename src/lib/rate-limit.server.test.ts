import { describe, expect, it } from "vitest";
import type { Sql } from "./db";
import { consumeSharedRateLimit } from "./rate-limit.server";

function counterSql() {
  const rows = new Map<string, { hits: number; window_started_at: number }>();
  const calls: unknown[][] = [];
  const sql = (async () => []) as unknown as Sql;
  sql.query = async <T>(_text: string, params: unknown[] = []) => {
    calls.push(params);
    const [scope, identityHash, rawWindow] = params;
    const key = `${String(scope)}:${String(identityHash)}`;
    const windowStartedAt = Number(rawWindow);
    const current = rows.get(key);
    const next = !current
      ? { hits: 1, window_started_at: windowStartedAt }
      : windowStartedAt > current.window_started_at
        ? { hits: 1, window_started_at: windowStartedAt }
        : windowStartedAt === current.window_started_at
          ? { ...current, hits: current.hits + 1 }
          : current;
    rows.set(key, next);
    return [next] as T[];
  };
  sql.transaction = async (work) => work(sql);
  return { sql, calls, rows };
}

describe("consumeSharedRateLimit", () => {
  it("isolates scopes and pseudonymous identities", async () => {
    const state = counterSql();
    expect(
      (await consumeSharedRateLimit("chat", "a", 1, 1_000, 0, state.sql)).ok,
    ).toBe(true);
    expect(
      (await consumeSharedRateLimit("chat", "a", 1, 1_000, 1, state.sql)).ok,
    ).toBe(false);
    expect(
      (await consumeSharedRateLimit("chat", "b", 1, 1_000, 1, state.sql)).ok,
    ).toBe(true);
    expect(
      (await consumeSharedRateLimit("hermes", "a", 1, 1_000, 1, state.sql)).ok,
    ).toBe(true);
    expect(state.calls.flat()).not.toContain("a");
    expect(String(state.calls[0]?.[1])).toMatch(/^[a-f0-9]{64}$/);
  });

  it("resets at a deterministic fixed-window boundary", async () => {
    const { sql } = counterSql();
    await consumeSharedRateLimit("chat", "a", 1, 1_000, 0, sql);
    const denied = await consumeSharedRateLimit(
      "chat",
      "a",
      1,
      1_000,
      999,
      sql,
    );
    expect(denied).toEqual({
      ok: false,
      retryAfter: 1,
      resetAt: 1_000,
    });
    await expect(
      consumeSharedRateLimit("chat", "a", 1, 1_000, 1_000, sql),
    ).resolves.toMatchObject({ ok: true, remaining: 0, resetAt: 2_000 });
  });

  it("does not let an older clock window overwrite the current counter", async () => {
    const state = counterSql();
    await consumeSharedRateLimit("sync", "a", 2, 1_000, 2_000, state.sql);
    await consumeSharedRateLimit("sync", "a", 2, 1_000, 1_000, state.sql);
    expect([...state.rows.values()]).toEqual([
      { hits: 1, window_started_at: 2_000 },
    ]);
  });

  it("rejects invalid limiter configuration", async () => {
    const { sql } = counterSql();
    await expect(
      consumeSharedRateLimit("", "a", 1, 1_000, 0, sql),
    ).rejects.toBeInstanceOf(TypeError);
    await expect(
      consumeSharedRateLimit("chat", "", 1, 1_000, 0, sql),
    ).rejects.toBeInstanceOf(TypeError);
  });
});
