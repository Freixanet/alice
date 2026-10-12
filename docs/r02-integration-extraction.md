# R02 — safe extraction plan (PR #76 → PR #77)

Status: **engineering plan / NO-GO**. Neither PR should be merged based only on
the synthetic or browser-fixture CI jobs.

## Current dependency and risk

- PR #76 (`security/r02-browser-authorization`, `fef46476`) contains the ADR
  and **historical negative evidence** showing why existing Hermes
  shopping/browser hooks cannot enforce transaction-level permission.
- PR #77 (`prototype/r02-alice-secure-runner`) is based on #76, so merging #77
  through the stacked GitHub UI can carry #76's old code. Do **not** merge or
  rebase either PR automatically. Keep their evidence and review history.
- Legacy `hermes-plugin/errands.py`, `browser_live.py` and `vault_cards.py`
  share the Hermes browser and payment capabilities; the old `Pagar` approval
  and run resume cannot authorize ASR payment effects. Enabling ASR must
  explicitly disable the legacy automated checkout path for ASR jobs rather
  than trusting pre-tool hooks, URL heuristics, or global Chrome CDP.

## Proposed bounded landing sequence (not performed)

1. From reviewed current `main`, create a fresh PR containing **only** the
   Alice-owned `alice_secure_runner` code, Python metadata and self-contained
   fictional HTTPS/browser tests. Rebase/cherry-pick _specific files or
   commits_ after security review, never the entire `#76..#77` history.
2. Separately import the _accepted architecture text_ of ADR 0002 and its
   evidence links. Keep the fail-open canary as historical negative evidence;
   do not reinterpret it as an ASR sandbox PASS.
3. Create a dedicated official-Hermes plugin integration PR registering
   `alice_secure_plan` and its feature probe. The model output stays untrusted;
   only Alice's authenticated coordinator can call ASR. Block legacy purchase
   auto-submit for jobs selecting ASR, and verify with an adversarial test.
4. Implement hosted ASR and its **real** principal-bound authorization,
   browser/system sandbox, private secrets, device approval, quotas, audit,
   durable effect fencing, merchant/PSP verification and exclusive human viewer.
   Apply a default-deny gate if any such capability is unavailable.
5. Validate a clean official Hermes installation with **no core patches**, an
   automatically provisioned Alice plugin or a separately verified zero-plugin
   interface, on supported OS versions. Test rollback and no manual executor
   installation. Only after independent review remove draft/enable checkout.

## Verified vs unverified

Verified: typed fictional HTTP action contract, local SQLite once-only attempt
and crash-state reconciliation, opt-in real Chromium DOM read on test origin,
application-level blocked POST in the initial local fixture test, no CDP
_endpoint_ exposed by Alice's API. New scoped browser-read credential, IPC
ACK and handoff-close fencing changes require post-change CI verification.

Not verified: actual authorized hosted browser OS/tenant isolation, standard
Hermes adversary unable to access same-UID env/process/VM manager, real
model-driven Hermes workflow, payment-provider receipt and consent, production
onboarding, browser-human control transfer, third-party script/beacon/network
effects. **R02 stays P0 / NO-GO.**
