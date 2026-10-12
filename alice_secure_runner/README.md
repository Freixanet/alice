# Alice Secure Runner — R02 runnable security-contract prototype

**Prototype only: no real browser, vault, isolated cloud host, merchant integration or live payment.**

This separate Python 3.11+ package uses only the standard library and can run
independently from Hermes on Linux, macOS or Windows. Its fictional merchant and
Alice backend simulation each use **real TLS on loopback**, with an ephemeral
test CA and token; only `tests/test_alice_secure_runner.py` and
`tests/test_alice_runner_http.py` start/stop these services automatically.

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
tokens of at least 32 characters each, service TLS
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

- No actual browser/CDP: this **cannot** prove Hermes cannot read browser
  cookies/session or trigger JavaScript/GET/POST side effects in unknown shops.
  The runner currently has **no browser to expose**, which is a narrower claim.
- No OS security boundary on a common host: a privileged Hermes terminal can
  inspect same-user processes, memory and environment. An authenticated local
  HTTPS bearer is insufficient against that threat; remote isolation and
  adversarial process/network tests are mandatory before release.
- Tenant/session are supplied by a trusted coordinator, not a production OIDC
  identity provider. The synthetic service now separates its static coordinator
  and simulated human-completion bearers, but **neither is real user/device
  authentication**. A compromised trusted backend could still impersonate
  tenant/session values. No multi-tenant authentication, quotas, user/device key
  lifecycle or audit.
- HMAC is a fictional device consent stand-in, not an iOS Secure Enclave
  signature or biometric-attested approval. `human_handoff()` is a pure state
  transition, not an authenticated browser viewer or PSP handoff.
- Synthetic jobs, epochs and checkout attempts are now persisted in SQLite;
  startup reconciles their states, invalidates in-flight checkout attempts to
  `unknown` and never automatically retries them. Human handoff handles are
  stored only as hashes. There is still **no real browser-session recovery**, no
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
