import { createHash } from "node:crypto";
import { getSql, type Sql } from "./db";

export type RateLimitResult =
  | { ok: true; remaining: number; resetAt: number }
  | { ok: false; retryAfter: number; resetAt: number };

export async function consumeSharedRateLimit(
  scope: string,
  identity: string,
  limit: number,
  windowMs: number,
  now = Date.now(),
  sql?: Sql,
): Promise<RateLimitResult> {
  if (
    !scope ||
    scope.length > 32 ||
    !identity ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    !Number.isSafeInteger(windowMs) ||
    windowMs < 1
  ) {
    throw new TypeError("Invalid rate-limit configuration");
  }
  const db = sql ?? (await getSql());
  const identityHash = createHash("sha256").update(identity).digest("hex");
  const windowStartedAt = Math.floor(now / windowMs) * windowMs;
  const [row] = await db.query<{ hits: number; window_started_at: number }>(
    `insert into alice_rate_limit
       (scope, identity_hash, window_started_at, hits, updated_at)
     values ($1, $2, $3, 1, now())
     on conflict (scope, identity_hash) do update set
       hits = case
         when excluded.window_started_at > alice_rate_limit.window_started_at then 1
         when excluded.window_started_at = alice_rate_limit.window_started_at
           then alice_rate_limit.hits + 1
         else alice_rate_limit.hits
       end,
       window_started_at = greatest(
         alice_rate_limit.window_started_at,
         excluded.window_started_at
       ),
       updated_at = now()
     returning hits, window_started_at`,
    [scope, identityHash, windowStartedAt],
  );
  if (!row) throw new Error("Rate-limit counter returned no row");
  const resetAt = row.window_started_at + windowMs;
  if (row.hits > limit) {
    return {
      ok: false,
      retryAfter: Math.max(1, Math.ceil((resetAt - now) / 1_000)),
      resetAt,
    };
  }
  return { ok: true, remaining: Math.max(0, limit - row.hits), resetAt };
}

export function rateLimitResponse(
  result: Extract<RateLimitResult, { ok: false }>,
) {
  return Response.json(
    { ok: false, error: { code: "rate_limited" } },
    {
      status: 429,
      headers: {
        "Cache-Control": "no-store",
        "Retry-After": String(result.retryAfter),
      },
    },
  );
}
