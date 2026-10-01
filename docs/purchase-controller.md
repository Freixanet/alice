# Purchase controller: review boundary

The purchase model proposes observed controls and navigates unfamiliar pages. The
Alice plugin owns the durable intent, selected offer, browser context, checkout
approval, payment attempt and receipt. Model prose cannot declare a purchase paid.

`checkout_request` accepts visible CSS selectors for total, delivery, destination
and email. The controller reads the order and payment method from the pinned page,
requires one cart line matching the selected offer and binds approval to the full
snapshot and exact saved card handle. Changed order facts require fresh approval.
For a recognized cash-on-delivery or invoice method, no card is requested.

Commercial clicks use `purchase_action`, with observed, unique visible controls.
Raw browser execution and vault fills are blocked inside errands. Submission is
journaled before dispatch; a lost response cannot authorize another dispatch.
Merchant handoff and a known bank page share one attempt in the same context.
Unknown outcomes retain that attempt. Confirmation requires an observed order
reference and approved amount. Stopping after submission preserves reconciliation.

Atomic private state files preserve malformed archives instead of discarding
purchase evidence. Gateway retries reuse a durable idempotency key only when
Hermes advertises support. Missing support stops an uncertain submission. Replays additionally require a
persisted submission time and a live, finite retention window; expired or legacy
keys remain blocked. A definitive unpaid attempt can be retried by the person,
but its checkout approval is retired and a new isolated browser/order requires
fresh consent. Unknown payment or gateway submissions are never cleared by this
retry. Bank submission verifies the observed approved amount independently of
its decimal formatting and rechecks that visible value in the click expression.

## Boundaries still requiring work

This is a draft implementation, not universal purchase support. Search coverage
and arbitrary page navigation still depend on the model and shop adapters. Complex
constraints, arbitrary variants, multi-item baskets, frames, stored merchant payment
methods and unrecognized payment providers are incomplete or refused. Selectors
are model-proposed: SKU identity, complete basket enumeration and total semantics
need stronger adapters before a release. Credential replacement after a failed login, startup recovery without opening
the errands API and notification delivery need additional work. Rejection evidence
and browser cleanup still need real gateway integration validation. Generic non-purchase errand workflows
must be reviewed against the more restrictive execution boundary.

The iOS browser is scoped to the errand target and profile. Transcript anchoring
uses the preparation reply instead of moving cards to the latest message. Visual
behavior, old archive migration and real phone interaction remain unverified here.

## Verification of this draft

The plugin suite, isolated intercepted Chrome checkout fixture, slash parity and
generic iOS device build are recorded in the accompanying implementation report.
The fixture proves the controller path from a prepared basket through exact consent
to one synthetic submission and receipt, with zero model calls in that segment.
It does not prove autonomous discovery or checkout across arbitrary real shops.
No live Hermes prompts, simulator, real purchases or payments are part of this check.

## Retention contract inspected

Inspected the installed Hermes distribution's `gateway/platforms/api_server_runs.py`
(`runs_idempotency.retention_seconds`) and `api_server_run_idempotency.py` (24-hour
terminal replay retention). This was a read-only source check, not a live API test.
For reproducibility, their SHA-256 values were respectively
`67315fb146f3f5d124675c4dd0e2c5fbe233618c94af2799c438175592dfba97` and
`c3f25711695a5aad97b207581e0c532d1291bb9f12ca3c1e32add19e5f0f153a`.
The client uses the advertised window, never a hard-coded 24-hour assumption.
