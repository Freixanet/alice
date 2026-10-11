# ADR 0002 — Browser purchase authority at the executor (R02)

**Status: Proposed / BLOCKED (2026-10-11).** This is an upstream Hermes contract
proposal, **not** an implemented security boundary. [PR #76](https://github.com/Freixanet/alice/pull/76)
must stay **draft and unmerged** while R02 is P0. Do not interpret a green
plugin CI as approval to automate payments.

## Problem and demonstrated boundary

The Hermes source inspected for R02 has this execution path:

1. `agent/tool_executor.py` builds a tool dispatch and enters official
   `tool_request` / `tool_execution` middleware.
2. `_dispatch_authorized_once` runs scope, `pre_tool_call`, argument-pruning
   and Hermes guardrails before the final **top-level** tool call.
3. `_pre_tool_block` catches exceptions and returns `(None, original_args)`:
   the missing security decision becomes **allow**. `hermes_cli/middleware.py`
   likewise skips a middleware that raises before `next_call()`.
4. The registry receives `skip_pre_tool_call_hook=True`. Native browser
   `click(ref)` / `press(key)` / `type(ref,text)`, `browser_console`, raw
   `browser_cdp` and `browser_dialog` reach different executors. `browser_exec`
   runs a separate browser-use CLI process that can issue further actions
   without another Alice hook. Alice's tab/context preamble covers only
   `browser_exec`, not every native tool.

The factual canary `scripts/verify-r02-executor-contract.py` supplies only
synthetic requests and effect callbacks. As of this proposal it finds FIVE
independent `unsafe_*` failures: pre-hook exception, middleware exception,
an unlabeled final-review `browser_click(ref='@e7')`, and an Alice guard
exception that lets that click pass, plus repeated acceptance of one checkout
at the non-consuming `pay_gate` layer (this does not prove two payments). The
canary intentionally exits **2** if
the desired authority is missing. Its positives demonstrate only that
existing restricted tool flows remain available at the _tool-hook_ level.

**Crucial limitation:** checking button labels, URLs, DOM state or a card-input
field cannot establish the effect of clicking an arbitrary element. Scripted
navigation, `fetch`, deferred UI callbacks, GET side effects, server-side
payment captures, embedded gateway frames and redirects can have effects the
caller cannot infer. Even a browser-network interceptor cannot universally
classify a merchant's private API request as a charge. An approved checkout
does **not** authorize every browser operation on the same site.

## Decision proposed for Hermes, not Alice-only

Keep optional generic middleware for observability and rewriting; introduce a
**separate, mandatory, fail-closed action-authority seam** in the trusted
Hermes executor. Alice supplies policy for its purchase sessions via a
versioned **official** registration, e.g.
`register_action_authorizer('browser.effect', authorize)`; this name is a
_proposed API_, **not an existing Hermes feature**.

### Where checks must execute

| Hermes component                                                         | Required change (upstream proposal)                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `agent/tool_executor.py`                                                 | Establish a server-trusted actor/run/scope and fail closed if required authorization cannot be obtained, including callback exceptions/timeouts; do not treat generic prehooks as authoritative.                                                      |
| `hermes_cli/plugins.py` / `middleware.py`                                | Add a versioned, required-authorizer registration distinct from best-effort hooks/middleware. No skip-on-error for required policies; unavailable/unregistered policy for protected scope = reject.                                                   |
| `tools/browser_tool.py` / `browser_tool_session.py`                      | Validate every actual click/press/fill/navigation operation **after** resolving the real target/ref and **immediately before** issuing its browser command; reject changed target/document.                                                           |
| `tools/browser_use_cli.py` and browser-use helper/CLI executor           | Replace unrestricted multi-action scripting for protected runs with individual brokered commands (or a restricted declarative interpreter); every helper calls the authority. No unchecked JS/aliases/imports or ambient CDP transport.               |
| `tools/browser_console`, `browser_cdp_tool.py`, `browser_dialog_tool.py` | Make all script, raw protocol and dialog paths pass through the same broker, including explicit target/frame and indirect `Runtime.evaluate`/input. Reject unprovable effects rather than using tool-name regex.                                      |
| Agent tool registry/scope and child-process isolation                    | Remove direct shell, filesystem/network/CDP escape paths in protected runs at _execution_, not merely prompt/tool advertisement. Child processes must have no separate usable browser/debug credentials or unrestricted egress.                       |
| Browser broker / network egress                                          | Enforce session-owned browser context, target/frame, document epoch and approved egress policy. Classify uncertain externally mutating operations as requiring manual execution. A generic broker cannot itself prove a third-party payment semantic. |
| Dashboard/phone browser input                                            | Distinguish human-controlled authenticated actions from agent actions with trustworthy provenance. A human handoff must atomically revoke the agent's ability to act on that context.                                                                 |

If upstream cannot provide these hooks for every active execution backend,
Hermes should **not advertise automated, safely authorized purchase submission**.
An Alice-owned proxy is viable only if it becomes the sole transport and all
other executable/browser/network routes are removed at a trusted scope boundary;
attaching it as one more optional tool is insufficient.

### Proposed required-authorizer contract

The executor constructs the action request from trusted runtime state, never
from a model-supplied tool argument or mutable prompt:

```text
AuthorityRequest v1
  actor_kind              agent | authenticated_human
  run_id, session_id, profile_id, errand_id
  browser_context_id, target_id, frame_id, document_epoch
  observed_url, canonical_https_origin
  operation_kind          navigate | read | input | click | dialog | script | network
  resolved_target         browser-issued control ref/DOM node identity if present
  normalized_operation    exact requested key/button/action and effect surface
  checkout_id             exact approved checkout (payment intents only)
  merchant_origin         exact merchant/approved PSP allowlist where justified
  order_fingerprint       canonical item IDs, variants, quantities, delivery and recipient
  amount_minor, currency  exact approved total + ISO currency
  idempotency_key         unique for this intent and effect
```

The authorizer returns an opaque, signed/unguessable **single-use capability**
or a denial. The capability is scoped to the exact action hash, audience,
run/session, target/document epoch, merchant, checkout fingerprint, amount and
currency, and a short expiration. The **trusted broker** atomically checks
and consumes it before dispatch. No other action, frame, tab, merchant,
amount, currency, retries or script may reuse it. On timeout, hook exception,
process crash, tab switch, document change, missing proof, disputed payment
effect or unknown operation: **deny or stop for human action**, never allow.
Mark a sent-but-unconfirmed payment `unknown / reconciliation required`;
do **not** automatically retry after consuming a capability. Merchant
idempotency keys help only where the merchant actually supports them.

There are two distinct authorities: **browser interaction** may allow safe
product exploration or cart preparation under a constrained executor, whereas
**irreversible external transaction** needs its own reliable approval/operation
binding. Permission to click or fill a card is not permission to charge. If
Hermes cannot prove the merchant-side effect or securely mediate final submit,
it must reserve that submit for a person.

### Compatibility and maintenance

- Upstream must feature-advertise `browser_action_authority_v1`, preserve
  behavior of non-protected tools/sessions, and let Alice fail closed for
  protected sessions when the feature is absent.
- Maintain a single normal browser API: bounded DOM inspection and product
  interactions still work through the broker; script/terminal/CDP alternate
  transports are either properly brokered or absent in protected sessions.
- Browsers have independent tab navigation, popups and cross-origin PSP
  frames; no global "current tab" or auto-approved PSP domain is sufficient.
- This is not achieved by modifying personal `~/.hermes` files, monkeypatching
  subprocesses, intercepting Python imports or adding another heuristic
  `pre_tool_call` veto. Review upstream compatibility tests before any opt-in.

## Interim alternative: human performs the irreversible submission

Until the required executor is available, **do not resume an autonomous
purchase run from the existing `checkout_request` approval**. Currently
`errands.decide_checkout` sets status `working`, `resume` starts a new run,
`approved_message` instructs the model to pay, and `_answer_approval`
automatically approves some Hermes payment-card confirmations. Thus the
current iPhone **“Permitir” is NOT a safe manual-finalization handoff**.

A replacement **proposed (not implemented)** workflow needs a protocol and UI
change to make the control unambiguous:

1. In a broker-constrained, no-payment-credential context, the agent researches
   products, reads bounded data, and (if the broker can prove its actions safe)
   prepares the cart and total. No ambiguous write reaches payment submission.
2. Save a review snapshot; **stop/revoke** the agent's write scope and wait
   until in-flight operations have settled before exposing human controls.
3. Show “Revisar y finalizar personalmente” rather than “Permitir pagar”. The
   person operates the actual retailer/payment page directly, in an
   authenticated human-only session. Sharing cart/cookies across browsers is
   not guaranteed; show a link or instructions without promising continuity.
4. Do **not** auto-resume the agent or auto-approve Hermes card/payment prompts.
   Record `awaiting_human_finalization` and later `unknown/pending_check`,
   never `paid` from a button press or unverified agent statement. Verify an
   independent merchant order/receipt before claiming success.

Without isolation at the trusted executor, even preparatory **agent writes**
may produce unintended effects. For older Hermes versions the defensible
fallback is **read-only comparison with no authenticated browser, card or
payment capability**, then a human opens and completes the purchase. A plugin
hook alone cannot guarantee that fallback against every alternate executor.

## Required acceptance evidence before R02 may close

| Negative (must deny)                                                                           | Positive (must preserve)                                                 |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Required policy missing, exception, timeout or crash at every dispatch stage                   | Normal read-only DOM inspection, product title/price, screenshots        |
| Unknown final button and JS-driven network side effect despite harmless labels                 | Navigation and item selection within constrained fixture                 |
| Raw console JS, `Runtime.evaluate`, CDP mouse/key/dialog and indirect JavaScript               | Separate sanctioned product click, cart adjustment and checkout review   |
| Agent changes tab, popup, frame, document after authorization                                  | Two authorized consecutive interactions each with fresh action authority |
| Replays, mismatched session/profile/target/checkout/merchant/item/qty/recipient/total/currency | Valid one-use authorization for a specific **mock** checkout request     |
| Back-to-back submits, crash after dispatch, unknown transaction outcome                        | Correct no-retry/reconciliation state and human-control handoff          |
| Network, shell or subprocess bypassing browser broker                                          | Authenticated person performs final submission with agent scope revoked  |

Use an isolated HTTPS **fictional store** and captured/mocked payment endpoint;
no real merchants, orders, money, personal browser, vault or service effects.
Run both unit tests of the broker and integration tests through the actual
Hermes dispatch + Chrome and all alternative paths, not the old fixture that
directly calls `_isolate_errand_browser` before creating a purchase offer.
Force race conditions, cancellation, faults and restart/recovery; audit
positive compatibility for products, login, cart and PSP handoff. Repeat on
each supported upstream Hermes version before enabling automatic submission.

## Decision boundaries / alternatives rejected

- **More `PAY_WORDS`, URL and DOM heuristics:** rejected; a final-review button
  may have no telltale controls, and it cannot prove merchant-side effect.
- **Using the current generic `tool_execution` middleware:** rejected as a
  mandatory authority; failures before `next_call` are skipped, and the hook
  only covers the top-level tool, not helper actions.
- **One unrestricted checkout approval for a session/merchant:** rejected;
  does not bind the action, order fingerprint or one-use semantics.
- **A plugin-local proxy while other browser/CDP/shell transports remain:**
  rejected; routes around it remain usable.
- **Safe human completion** remains the default design until a tested trusted
  broker exists; the existing automatic `decide_checkout` UI is not that design.

**Revisit when:** Hermes supplies a fail-closed, action-level official API and
broker/backend coverage with isolated browser proof; or an explicitly accepted
manual-only purchase flow replaces automated checkout. R03/R07 remain separate.
