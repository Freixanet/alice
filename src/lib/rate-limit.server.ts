type Bucket = { count: number; resetAt: number };

const buckets = new Map<string, Bucket>();
let operations = 0;

export type RateLimitResult =
  | { ok: true; remaining: number; resetAt: number }
  | { ok: false; retryAfter: number; resetAt: number };

export function consumeRateLimit(
  scope: string,
  identity: string,
  limit: number,
  windowMs: number,
  now = Date.now(),
): RateLimitResult {
  const key = `${scope}:${identity}`;
  const current = buckets.get(key);
  if (!current || current.resetAt <= now) {
    const resetAt = now + windowMs;
    buckets.set(key, { count: 1, resetAt });
    pruneExpired(now);
    return { ok: true, remaining: Math.max(0, limit - 1), resetAt };
  }
  if (current.count >= limit) {
    return {
      ok: false,
      retryAfter: Math.max(1, Math.ceil((current.resetAt - now) / 1_000)),
      resetAt: current.resetAt,
    };
  }
  current.count += 1;
  return {
    ok: true,
    remaining: Math.max(0, limit - current.count),
    resetAt: current.resetAt,
  };
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

function pruneExpired(now: number) {
  operations += 1;
  if (operations % 256 !== 0) return;
  for (const [key, value] of buckets) {
    if (value.resetAt <= now) buckets.delete(key);
  }
}

export function resetRateLimitsForTests() {
  buckets.clear();
  operations = 0;
}
