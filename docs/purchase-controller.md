# Purchase controller: review boundary

The purchase model proposes observed controls and navigates unfamiliar pages. The
Alice plugin owns the durable intent, selected offer, browser context, checkout
approval, payment attempt and receipt. Model prose cannot declare a purchase paid.

`checkout_request` accepts visible CSS selectors for total, delivery, destination
and email. The controller reads the order and payment method from the pinned page,
uses a fixed server-owned cart inventory and requires exactly one verified row.
Model `all_lines` selectors cannot narrow that inventory. Hidden rows also prevent
approval. Product links preserve variant query parameters; tracking parameters
are ignored. The selected variant must match the dedicated row field exactly,
and a quoted SKU/Prozis variant ID must match the row reference when present.
Approval binds the full snapshot and exact saved card handle. Changed order facts require fresh approval.
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
are model-proposed but cannot define the complete inventory or make surrounding
text establish an order total. The fixed extraction requires a recognized cart
root, unique row-contained quantity/current price controls, an order-total
semantic marker or exact label, consistent visible totals and a breakdown that
exactly sums line amounts, shipping, tax, fees and discounts. Unknown structures
fail closed. SKU proof is conditional on a quoted reference; additional real-shop
adapters are still required before a release. Credential replacement after a failed login, startup recovery without opening
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

## Integrity extraction contract

The generic cart path recognizes a single `[data-order-items]`, `[data-cart-items]`,
`#cart-items`, `.cart-items` or `.cart__items` container. Its non-script direct
children are the inventory; nested/hidden or unrecognized layouts are refused.
The Prozis inventory uses the fixed `#chkLists .chk-prod-card` structure, not
model-narrowed locators. Neither path proves a store's hidden backend basket.

Rows need a product link or `data-product-url`, a dedicated variant field and,
where the verified quote supplies one, a matching `data-sku`/`data-product-id`.
The generic charge contract uses `data-order-shipping`, `data-order-tax`,
`data-order-fees` and `data-order-discount` to mark additive components (discounts
subtract). Shipping must be explicit, including free shipping. These markers are
a supported DOM contract, not a claim that arbitrary stores already supply them.
Informational VAT included in line prices, coupon allocation and unstructured
shipping rows require a store adapter; the controller must not invent their
meaning. Cart enumeration alone does not establish a complete Prozis checkout
adapter.

Chrome regression fixture: extra visible/hidden rows, variant URL changes, variant
label collisions, struck prices, absent shipping and contradictory totals all
refused before approval; a valid order still submitted exactly once. No real
shop/bank or iPhone UI validation follows from that fixture.
