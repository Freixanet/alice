import { beforeAll, describe, expect, it } from "vitest";
import type { Sql } from "./db";

let sql: Sql;
let consume: typeof import("./rate-limit.server").consumeSharedRateLimit;

beforeAll(async () => {
  process.env.ALICE_PGLITE_MEMORY = "1";
  sql = await (await import("./db")).getSql();
  ({ consumeSharedRateLimit: consume } = await import("./rate-limit.server"));
}, 30_000);

describe("shared rate-limit persistence", () => {
  it("atomically limits concurrent requests in the real database", async () => {
    const identity = crypto.randomUUID();
    const results = await Promise.all(
      Array.from({ length: 12 }, () =>
        consume("chat", identity, 5, 60_000, 120_000, sql),
      ),
    );
    expect(results.filter((result) => result.ok)).toHaveLength(5);
    expect(results.filter((result) => !result.ok)).toHaveLength(7);
  });

  it("reuses one constant-space row across windows", async () => {
    const identity = crypto.randomUUID();
    await consume("test-space", identity, 2, 1_000, 1_000, sql);
    await consume("test-space", identity, 2, 1_000, 2_000, sql);
    const [{ count = 0 } = {}] = await sql.query<{ count: number }>(
      `select count(*)::bigint as count
       from alice_rate_limit where scope = 'test-space'`,
    );
    expect(count).toBe(1);
  });
});
