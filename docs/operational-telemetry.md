# Alice operational telemetry

Alice emits a deliberately small first-party operational contract. It exists to
detect regressions in availability and latency, not to analyse people or their
conversations.

## Collected fields

- Deployment version.
- A closed route category.
- A coarse browser family and viewport bucket.
- A stable error category or HTTP outcome.
- Request or initial-navigation latency.
- LCP, INP and CLS using their standard browser performance entries.

Successful server requests are sampled at 10%; failures are retained. Anonymous
client ingestion is bounded per runtime window. Vercel runtime logs are the only
production sink and must be configured with a retention of no more than 30 days.

## Fields that are never accepted

The Zod contract rejects content, prompts, responses, filenames, raw paths,
query strings, Hermes URLs, keys, complete user-agent strings, email addresses,
user ids, session ids and arbitrary error messages. The client omits credentials
and restricts the referrer to the Alice origin.

`tests/e2e/performance.spec.ts` enforces the initial p95 budget of 100 ms for a
normal Alice API handler, excluding Hermes latency. Every observed API response
also exposes its Alice overhead through the `Server-Timing` header.
