# Alice request lifecycle

Alice treats reads and mutations differently because retrying an uncertain
mutation can repeat an external effect.

## Idempotent reads

- Concurrent model reads share one transport request per account, Hermes
  connection and profile.
- A caller owns only its subscription. Cancelling one view does not cancel work
  still needed by another; when the last subscriber leaves, the transport is
  aborted.
- Successful model reads have a 30-second TTL. Failures are never cached.
- Explicit refresh bypasses stored data but still joins an equivalent in-flight
  refresh.
- Account changes, successful reconnection and model mutations invalidate the
  relevant cache before another read can reuse it.
- MCP health and usage caches include the account identity as well as the
  Hermes connection and profile.

The larger Hermes management snapshot follows the same account/connection/
profile isolation and rejects stale responses after mutations or account
changes.

## Mutations and long-running work

- Alice never automatically retries a mutable Hermes action.
- Existing Hermes run starts use deterministic idempotency keys when the
  negotiated transport supports them.
- Skill and MCP action polling, run recovery, delayed Computer Use refreshes and
  cloud sync stop when their owning view or account disappears.
- Cloud sync checks cancellation between key derivation, encryption batches,
  network batches, pull pages and decryption records.
- All polling delays remove their timers immediately on abort.

Unit tests exercise deduplication, per-subscriber cancellation, last-subscriber
transport abort, failed-value exclusion, invalidation, account isolation and
pre-network sync cancellation.
