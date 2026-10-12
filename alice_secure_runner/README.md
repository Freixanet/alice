# Alice Secure Runner — R02 runnable security-contract prototype

**New post-H02.1 integrated development ledger:** see
[`docs/r02-integrated-readiness.md`](../docs/r02-integrated-readiness.md).
The new synthetic third-process merchant, independent durable receipts,
read-only unknown reconciliation, exact tax/variant consent and public-only
P-256 consent verification are covered there. These are **not** real PSP,
biometric attestation, deployment or two-administrator isolation guarantees.

**Prototype only: optional REAL Chromium fixture, but no isolated cloud host,
real browser vault, merchant integration or live payment. Never run this as a
real shopping service.**

This separate Python 3.11+ package uses only the standard library and can run
independently from Hermes on Linux, macOS or Windows. Its fictional merchant and
Alice backend simulation each use **real TLS on loopback**, with an ephemeral
test CA and token; only `tests/test_alice_secure_runner.py` and
`tests/test_alice_runner_http.py` start/stop these services automatically.

The separate **opt-in browser-read fixture** requires Node, Playwright and
headless Chromium _on Alice's runner host only_. It uses one subprocess over
inherited stdin/stdout (no published CDP), one ephemeral browser context per
job, and allows only typed product search/read on one fictional HTTPS origin.
The browser child receives only a scoped **read token**; the merchant fixture
rejects this token for cart/quote/commit operations. The Python runner keeps
the independent checkout-effect token. The browser attaches its read token
only to specifically allowlisted GET requests, not global context headers;
all HTTP redirects are denied using `route.fetch(maxRedirects=0)` before any
HTML is fulfilled, preventing the scoped token from following a 302;
WebSocket interception is required, otherwise the browser session fails closed.
Browser IPC has per-command IDs and
operation-specific close acknowledgements; missing/mismatched replies kill the
disposable process group rather than accepting a stale acknowledgement.
The real Chromium fixture deliberately uses `ignoreHTTPSErrors` for its
disposable self-signed localhost certificate; the authenticated Python
checkout adapter independently validates the pinned test CA. Chromium
blocks JavaScript-initiated POSTs, redirects and other destinations through
Playwright routing. **That is an application-level request filter, NOT a
verified OS egress firewall or security sandbox.** Browser/host same-UID
process inspection, Playwright bypasses and Chromium escapes are not covered.
Real browser execution and per-job context isolation are tested in a separate
CI job, not in the ordinary mock test suite. This module must never be
installed or launched within the user's official Hermes environment.

```sh
# Alice runner CI/ephemeral lab ONLY: point to its own Playwright installation.
ALICE_TEST_PLAYWRIGHT_MODULE=/path/to/isolated/node_modules/playwright \
  python3.11 -m unittest discover -s tests -p test_alice_real_browser.py -v
```

```shell
python3.11 -m unittest discover -s tests -p 'test_alice*.py' -v
python3.11 -m unittest discover -s hermes-plugin/tests -p test_r02_planner.py -v
```

The first suite obtains product information and updates a cart through fixed,
typed HTTPS merchant endpoints. It then requests approval of the exact
checkout digest, applies a **test HMAC** signature, and performs at most one
synthetic `/commit`. It tests rejected scripts/CDP/terminal, stale epoch,
wrong tenant/session, changed amount, forged/expired/replayed approval,
simultaneous submits, failure before dispatch, unknown outcome after dispatch,
crash/restart reconciliation, and simulated exclusive human completion. No
checkout is a real-world purchase. After restarting, `dispatching` becomes
`unknown`, so **a potentially dispatched operation cannot be retried**.
A disposable subprocess test actually exits with `os._exit()` after the
fictional HTTPS merchant accepts a checkout and verifies no resubmission on
restart. This is a local SQLite crash-window test, not cloud HA evidence.

The Hermes adapter `hermes-plugin/r02_planner.py` uses official
`ctx.llm.complete_structured()` to request **one JSON proposal**, validates it
again in Python and never calls the runner or owns its keys. The Alice
Coordinator (`coordinator.py`) owns the state/observe/replan loop; its E2E
planner is deterministic. The optional `alice_secure_plan` Hermes tool returns
proposals, not privileged runner operations. Real model calls are deliberately
**not** made in tests, and genuine multi-step reliability is **not proven**.

**Hermes compatibility inspection:** the official plugin LLM API exists in
the sampled upstream source tags `v2026.5.16`, `v2026.7.1`, `v2026.8.13` and
`v2026.9.24`, and in the read-only installed checkout
`6b2fe92af66a` (reported `v0.21.4+canary...`). Those are **source/API
presence observations**, not actual end-to-end model runs on those versions.
The plugin must feature-probe `ctx.llm.complete_structured`; if absent, it
fails closed. It does not need provider/model overrides, and uses the model
already configured in Hermes. Actual plugin installation, authorization,
different model JSON-schema behavior and recovery remain compatibility gates.

`/v1/runs` is a less suitable authority-free planner surface because it starts
the general Hermes agent loop and may execute ordinary tools. A zero-extra-plugin
planner mode is still unimplemented; a compatible account cannot currently use
this new workflow without the plugin, and the required user-facing setup is
not complete. Do not treat the old `checkout_request` / `Pagar` UI as the new
security path.

## Packaging and hosted path

`pyproject.toml` allows building a platform-neutral source/wheel package
(`python -m build` with normal package build dependencies). `python -m
alice_secure_runner` is intentionally **disabled by default** and requires
`ALICE_RUNNER_FIXTURE_ONLY=yes`, pinned fictional HTTPS origin/CA, fixture
merchant token, 32-byte approval key, separate backend/human authorization
tokens of at least 32 characters each, fixed test principal identity via
`ALICE_RUNNER_FIXTURE_TENANT` and `ALICE_RUNNER_FIXTURE_SESSION`, service TLS
certificate/key and SQLite file. It only binds `127.0.0.1` and refuses
non-loopback merchant destinations. Its keys must never be supplied to Hermes.

Packaging smoke check: `python3.11 -m pip wheel --no-deps
--no-build-isolation .` builds `alice_secure_runner_prototype-0.1.0-py3-none-any.whl`;
installing that wheel into a disposable target and importing `AliceRunner`
passed locally. This verifies Python packaging, **not** a cloud deployment or
automatic onboarding in the iOS app.

For eventual **hosted Alice** operation, deploy a hardened ASR behind Alice's
authenticated backend, with per-tenant OS/container/VM isolation, managed TLS,
private secret storage, trusted device-approval verification, a durable job
store, per-tenant rate limits/quotas and enforced network egress. Users then
pair official Hermes normally; they do not install a custom executor on their
Hermes computer. **None** of this infrastructure is deployed in this PR.
A truly portable product also needs an independently verified zero-plugin
structured planning option or an automatically installed official Alice
plugin with appropriate user consent.

## Limits and NO-GO gates

- An optional **real browser read-only fixture now exists** behind the typed
  Python runner. It does **not** prove Hermes cannot obtain its process memory,
  secrets, cookies or debugging handles as an equally privileged OS user. It
  does not support arbitrary shops, browser checkout, or a secure remote viewer.
  A Playwright `route()` is not a system egress policy; page scripts and new
  web APIs may escape unverified request paths. No unknown-shop security claim.
- No OS security boundary on a common host: a privileged Hermes terminal can
  inspect same-user processes, memory and environment. An authenticated local
  HTTPS bearer is insufficient against that threat; remote isolation and
  adversarial process/network tests are mandatory before release.
- Tenant/session and coordinator/human role are now derived from explicit
  server-provisioned **fixture principals**, NOT untrusted JSON claims. Other
  tenants' tokens cannot impersonate this job even when the job ID is known.
  These are still static bearer secrets, **not production authentication**:
  there is no real user/device identity provider, expiry, key rotation, quotas,
  independently authenticated enrollment or audit. No OS tenant isolation.
- HMAC is a fictional device consent stand-in, not an iOS Secure Enclave
  signature or biometric-attested approval. `human_handoff()` is a pure state
  transition, not an authenticated browser viewer or PSP handoff.
- Synthetic jobs, epochs and checkout attempts are now persisted in SQLite;
  startup reconciles their states, invalidates in-flight checkout attempts to
  `unknown` and never automatically retries them. Human handoff handles are
  stored only as hashes. Trusted Alice can resume a partial job without
  resetting its epoch through `resume_job` / `POST /v1/resume`; a lost simulated
  human handoff reply can be recovered by an **explicit human-side** call to
  `POST /v1/human-reissue` using a capability distinct from the backend's.
  Duplicate coordinator handoffs are rejected; explicit recovery rotates the
  handle and invalidates the previous one without restoring agent writes.
  A real-browser handoff must first reach a durable
  `handoff_pending_close` state and receive an acknowledged session closure
  before human-only authority is issued. A failed close blocks both agent and
  human reissue. This does not prove prior Chrome processes have been destroyed
  after a power loss/restart, because no verified OS/VM lease fencing exists.
  The ledger now records whether a browser was ever opened and its synthetic
  owner generation: a job that never opened Chrome does not close other jobs'
  sessions; after restart a different browser generation cannot falsely
  confirm closure of the previous owner's session. That conservative denial
  can prevent recovery until a trusted OS/VM destruction fence exists. An
  adapter downgrade from browser-backed to HTTP-only does not bypass the fence.
  **Legacy SQLite jobs written before the browser-ownership fields existed
  are intentionally considered potentially browser-backed on restore**;
  this may block even genuinely HTTP-only legacy jobs. No automatic unsafe
  migration/reset is performed; a future explicit trusted recovery mechanism
  must distinguish them or safely invalidate and restart without replaying
  any uncertain checkout attempt.
  Stopped, confirmed and unknown jobs now attempt best-effort browser-session
  cleanup AFTER persisting the terminal state. Cleanup failure does not alter
  an unknown/confirmed payment result or restore agent authority. A malicious
  or crashed process may still survive without a verified OS-level fence.
  That rotation is NOT safe
  to apply during real human/PSP payment execution until an additional
  effect-in-flight fence is implemented. There is still **no real
  browser-session recovery**, no
  encryption-at-rest/key-management strategy, no high-availability coordinator
  and no independent merchant status reconciliation. Production-grade durable
  recovery remains a release blocker.
- No merchant/PSP adapter is certified; only the strictly loopback fictional
  contract can submit. Cloud/browser availability, region, WebAuthn, 3DS,
  Apple Pay and merchant anti-bot/ToS compatibility remain unresolved.

**Cost planning (USD, illustrative 2026 list prices, NOT a bill):** Browserbase
Developer advertises $20/mo including 100 browser hours, then $0.12/hour;
Startup $99/mo includes 500 hours, then $0.10/hour. Thus 1,000 sessions of
10 minutes imply ~166.7 browser hours, which would fit the Startup 500-hour
allowance, or ~$28 on Developer assuming the published 100-hour allowance and
$0.12/hour overage. This excludes **model tokens, proxy data, identity, CAPTCHA,
storage, TLS, databases, observability, compliance and engineering**. The
current prototype has **no persistent browser hours at all**. The final cost
depends on concurrency, actual median session duration, user volume and vendor.
Pricing sources: https://www.browserbase.com/pricing and
https://cloud.google.com/run/pricing (verify before budgeting).

R02 remains **P0 / NO-GO**. The predecessor [PR #76](https://github.com/Freixanet/alice/pull/76)
remains unmerged; this prototype should be reviewed independently.
