# Purchase execution: observe, act, verify

Alice now adapts Open Instinct's computer interaction loop to its existing purchase
errands. This change addresses execution reliability, independently of payment
providers. It does not add a wallet, change the errand model, or replace the existing
product choice, price evidence, secure login, checkout approval and receipt services.

## What changed

Previously, an agent could report a browser step without checking that it changed
anything. Twelve steps on the same URL over four minutes could stop the errand even
when a one-page checkout had progressed from address to delivery to review.

`purchase_browser` exposes the current visible controls and their real options.
The agent selects one control from that observation. The service rechecks the page,
executes one preparation action, and returns the observed state after it. A page
change rejects the old observation before acting. The result distinguishes a DOM
change, no verified change, stale input, and an uncertain outcome after a lost
response. A DOM change is not a completed purchase.

The service runs in the errand's own pinned context and profile. It respects the existing human browser takeover and refuses preparation changes while the errand waits for approval or input. It accepts no
model-written JavaScript or CSS. Cross-process locks serialize actions on an errand.
Action intent is saved before execution, without input values; retrying the same
operation after a timeout does not execute it twice. It reports form validation
errors, pending loads, disabled controls, quantities and selected options, so the
agent can correct a specific obstacle rather than repeating clicks.

For recovery, `fields_to_fix` identifies required/invalid fields and `suggested_actions` supplies exact chosen quantity/variant or already-saved shipping data. Missing details and unmatched variants are left unresolved rather than invented. No input values are kept in the execution journal.
After a verified field correction, an old server error can remain visible until
the form is submitted again. When there are no remaining invalid/required empty
fields, the tool explains that distinction and allows one new validation with the
observed submit control. It never treats the correction itself as acceptance.

The no-progress detector uses observed state when available. A changing checkout
on one URL remains active. Repeated observations without changes can detect a loop
even when the agent writes no step comments. Existing errands without observations
retain their earlier detection behavior.

## Whole purchase path

1. Discovery and disposable cart verification remain `purchase_discover` /
   `purchase_verify`; prices come from saved evidence, not the agent's claims.
2. The person chooses a product/format and units. That choice starts its own errand.
3. The errand opens the chosen product in its own browser context, then uses
   `purchase_browser observe` and one `click`, `fill` or `select` at a time. The
   returned ids expire when the observed state changes.
4. Missing login or OTP uses the existing secure sheet. Passwords, verification
   codes and card fields cannot be filled by this preparation tool. The existing
   secret protection is applied before observations and returned text is redacted.
5. The cart is still checked with `purchase_check_cart`. The final visible total
   is still read by `checkout_request` and explicitly approved in Alice.
6. This preparation tool refuses payment actions using the existing payment-page
   classifier as well as the observed control's text. Existing payment tools and
   guards remain responsible for the approved payment. A receipt still requires
   confirmation from the merchant and `purchase_outcome`.

For custom widgets, canvas controls, shadow roots or frames absent from the DOM
observation, the agent retains the normal browser/screenshot tools: observe the
control, perform one action and verify again. Their established guards still apply.
This is not a new merchant API or a guarantee that every shop will accept automation.

## Recovery rules

- **Stale:** no operation was performed. Decide from the new observation.
- **Unchanged:** the attempted operation produced no verified state change. Read
  validation/loading/disabled state and choose a different step. A repeat of the
  identical operation is refused.
- **Unknown:** the operation may have executed. Observe and inspect cart units or
  the next checkout state before deciding; never infer failure from a timeout.
- **Secure step:** keep the errand and use secure login/OTP/card entry or takeover.
- **Paid:** only the existing confirmed receipt can finish the errand. Clicking,
  changing the screen or receiving a pending charge is not proof of an order.

## Validation

`hermes-plugin/tests/test_purchase_browser.py` exercises stale controls, same-URL
progress, form validation, duplicate/lost-response protection, concurrent actions,
redacted action metadata, secure/payment controls and read-only no-progress loops.
The complete plugin suite includes the existing profile, price, access, approval
and outcome tests.

`python scripts/verify-purchase-execution.py` runs production preparation actions in
a temporary headless Chrome, on a random loopback port distinct from the person's
browser. Every merchant request is intercepted: the only page is a fictitious
shop. It verifies variant, exactly two units, standard shipping, final EUR total,
missing-field errors, a server rejection that clears the postal code, progress on
the same URL and refusal to pay.

`--agent` runs the actual GPT-6 Luna errand model on that same shop, using the
production tool schema and execution service. No CSS selectors or scripted shop
operations are supplied to the model. The fixture bypasses Hermes runtime
maintenance on import, uses a temporary Hermes home, reads inference authorization
without refreshing it, and exposes no real gateway, file, messaging or payment tools.
It exercises preparation through final review, not an actual merchant charge.

Checked on 2026-10-05: the plugin suite ran 555 tests successfully (one skipped),
slash parity checked 52 commands, and the deterministic isolated Chrome scenario
passed, including a card field identified only by its label. Before the correction
hint was added, the real model stopped at the retained server-error message after
fixing the postal field. After that fix, two consecutive GPT-6 Luna runs recovered
and reached the correct review in ten actions each. Those runs used the same
execution logic; the subsequent label-only secret protection was checked by the
full suite and isolated deterministic browser scenario.

Live shops, CAPTCHA challenges, bank confirmation, real orders and visual phone
acceptance remain separate checks. An isolated model run cannot establish universal
shopping reliability. The failure states and execution journal make these checks
more specific and recoverable.

## Source

Adapted from Open Instinct's `skills/purchases/SKILL.md`,
`skills/maritime-computer/SKILL.md` and computer guidance at commit
`a4df7eea61a9c6dd824901e5c8068db2d89ecda6`.
The useful contract is fresh observation → one action → returned observation →
verification, plus explicit takeover and confirmation. Alice uses DOM observations
for ordinary forms and its existing screenshot tools for the visual fallback.
MIT attribution: `hermes-plugin/licenses/open-instinct-MIT.txt` (Maria Gorskikh).
