# R02 — integrated Secure Runner development ledger and release gate

**Status: P0 / NO-GO for real purchases.** This file is the public,
redacted, reproducible execution ledger for the work stacked on draft PR #80,
starting at `7ca692a3c034d2f118596f10f5d3bd8ce10d50bb`. The original
private Execution Ledger was not accessible; do not claim it was updated.

All tests below use **fictional goods, addresses, checkout signatures, money
and merchant accounts**. No card/payment, personal Hermes, real browser profile
or cloud service was used. The new branch preserves main and PRs #76–#80.

## Implemented boundaries

```text
 Host A: official Hermes (untrusted planner, plugin tool: alice_secure_plan)
    └─ unprivileged ONE typed action, never signing/payment/browser keys
         │ external API / pairing STILL PENDING
         ▼
 Trusted Alice issuer/control plane (prototype offline Ed25519 signer)
    └─ exact path+body+role+job+tenant+session+TTL capability
         │ verified TLS
         ▼
 Host B: independently managed Alice domain — external proof PENDING
    HTTPS gateway — public Ed25519 verifier, replay SQLite
         │ pinned TLS + separate backend bearer + ORIGINAL proof
         ▼
    ASR — independent verifier/replay; job/consent/dispatch ledger
      ├─ P-256 public device consent verifier; SOFTWARE test signer only
      ├─ private Chromium read-only; OS/browser split STILL PENDING
      └─ fixed HTTPS effect adapter, NEVER model-chosen URL
         │ merchant_private Docker internal network
         ▼
    Separate merchant PROCESS + separate SQLite VOLUME
       signed-case-independent fictional receipts / read-only order lookup
```

The gateway does not possess the issuer private key. The executor does not
possess issuer or device private keys. Test consent is P-256
`ECDSA-SHA256` over canonical UTF-8 exact challenge
(job/tenant/session/snapshot digest/nonce/expiry), verified against pinned
**public** (tenant,session) key. This is neither iOS hardware attestation
nor proof of biometric user presence. Previous H01 HMAC test callers remain
compatible; H02.1 alone can select P-256 fixture validation.

### Major changes in this branch

1. H02.1 Docker fixture has a **third, non-root merchant service**, linked to
   ASR only on a separate internal network. The gateway, hostile Hermes
   container and Host A cannot access its port through Compose. The merchant
   survives ASR destroy/recreate on its own SQLite named volume and uses
   fresh test certificates and tokens. A built-in test HTTPS shop still exists
   for H01/H02 compatibility; it is not used by H02.1's new Docker setup.
2. Merchant order records atomically bind checkout ID to SKU, **variant**,
   quantity, recipient, merchant identity, EUR integer subtotal, shipping,
   tax, discount and final total. Reusing a checkout ID for a changed
   immutable checkout fails instead of returning the old receipt.
3. ASR validates the entire independently quoted itemization **again** just
   before committing. Only one durable transition to `dispatching` can send
   the checkout. Loss of a response or crash yields `UNKNOWN`, never retry.
   Trusted owner-only `POST /v1/reconcile` issues a **GET receipt lookup**
   to the independent merchant, verifies exact receipt fields, and can
   change `UNKNOWN → confirmed`. No record/unavailable merchant keeps
   `UNKNOWN` and cannot re-enable submission.
4. Variants may be selected with typed `select_variant`, from bounded
   merchant-authoritative options. Product variants enter only a sanitized
   model observation; payer amount, recipient and card never do.
5. The optional official Hermes plugin registers `alice_secure_plan`
   through `ctx.register_tool`, with supported `ctx.llm.complete_structured`
   and a feature probe. It produces a single untrusted action and fails
   closed on malformed results, cancellation and uncertainty.
   **No official live Hermes ↔ Alice-hosted coordinator pairing or
   model-driven multistep run has been proven**. Never use unrestricted
   Hermes `/v1/runs` as a sandbox.
6. Explicit `ALICE_R02_ASR_ONLY=yes` disables legacy Hermes checkout
   approval, payment-card request, payment tool gate approval, and old
   approved-resume paths; it is **not** itself an OS/terminal sandbox.
   Existing ordinary Hermes checkout remains separately labeled as legacy
   when this opt-in mode is off. For flagged ASR errands, iOS displays
   only read-only, unverified status and blocks old payment controls.
   A trusted ASR iOS status/approval transport has **not** been implemented.
7. Host A probe records `PENDING_EXTERNAL_INDEPENDENT_PROOF` even when all
   negative routing checks pass. `--require-attested-proof` exits nonzero
   until independently verified provider IAM/firewall/routing/VM identity
   records can be attached. Failure to route to a Docker bridge address is
   not a demonstrated firewall deny.

## Integrated requirements matrix

| Frontier | Implemented / tested | Remains blocked (cannot claim GO) |
| --- | --- | --- |
| H01/H02/H02.1 cryptographic authorization | Ed25519 issuer not on services; two public verifiers, separate durable replay, bounded HTTPS, idempotent job creation and previous fixture tests | Two independent administrators and real Host A/B attack with evidence; production workload mTLS/IdP, trusted ingress edge |
| Network and browser | Docker internal egress islands; separate merchant network; no published ASR/merchant/CDP; browser route rejects redirects, POST, WS; bounded transport | Real OS-enforced per-process browser sandbox and full DNS/IPv4/IPv6/UDP/WebRTC egress controls under adversarial root |
| User identity and consent | P-256 detached software signatures for exact canonical challenge, public-only key registry, expired/replayed consent refused | Secure Enclave enroll/attestation, iOS approval flow and trusted Alice account/device pairing, real key lifecycle |
| Official Hermes | Official public plugin API registration contract and pure typed planner tests | Clean official installation + real model/supported versions, authenticated pairing and durable remote observe/act cycle |
| Fictional checkout / related R03 | Real separate process merchant, durable SQLite receipt, exact itemization and variants, one dispatch, UNKNOWN, receipt-only reconciliation across **both** process crashes, exclusive simulated handoff | Real PSP/merchant adapter certification, external durable receipts, 3DS, encryption/compliance and no blind payment retries under real network |
| iOS / distribution | Swift read-only status vocabulary and legacy checkout isolation, synthetic wheel and Docker image builds | Real authenticated ASR status feed, P-256 consent enrollment, secure hosted onboarding, actual deployment/update/recovery and real iOS device tests |

## Evidence rules and tests

- `python3 -m unittest discover -s tests -q`: full repository Python
  test suite, excluding optional browser tests when local Chromium is absent.
- `python3 -m unittest discover -s hermes-plugin/tests -p 'test_r02_*.py' -q`:
  legacy payment cutover fixture tests.
- `python3 -m unittest discover -s tests -p 'test_h021_external_merchant.py' -v`:
  **independent Python merchant PROCESS over real pinned TLS**,
  merchant crash and ASR reboot, durable receipt, read-only lookup, no
  retry, variant, tax and role denials.
- `bash scripts/verify-r02-h021-docker.sh`: disposable new H02.1
  **single-host Docker CI only**. It now brings up three distinct services
  and must be rerun on the new SHA; prior PR #80 green CI is not evidence
  for this branch.

Do not treat `xcrun swiftc -frontend -parse` as an iOS build/UI test.
The Hermes general-plugin suites require an isolated official Hermes
environment and FastAPI/WebSocket dependencies absent from this minimal
Mac Python environment. Record those omissions rather than marking PASS.

## Attacks and negative outcomes

| Attempt | Expected result |
| --- | --- |
| Stolen gateway backend bearer without signed OWNER/COMMIT | Denied by independent ASR verifier |
| Mutated Ed25519 role/path/job/body/tenant/session/replayed token | Denied by both verifiers and durable replay |
| Forged/expired P-256 exact checkout consent | Denied by public-key device verifier and one-use job ledger |
| Alter variant/tax/shipping/discount while keeping same final total | Denied before any merchant commit |
| Different recipient with reused merchant checkout ID | Merchant rejects immutable receipt conflict |
| Lost merchant reply / both independent processes restarted | `UNKNOWN` until exact durable merchant receipt read; no POST retry |
| Read-only Chromium credential tries merchant cart/receipt | Denied; cannot access effect token through typed read endpoint |
| Legacy Hermes approval/resume while `ALICE_R02_ASR_ONLY=yes` | Denied; no fallback to shared browser or saved card |
| Root Host A scans B private Docker bridge IP | Cannot assert firewall success from routing failure; independent evidence PENDING |

## Cost, distribution and operations

Configured H02.1 limits are **ceilings**, not measured RSS: ASR 2 GiB /
2 vCPU, gateway 256 MiB and independent merchant 128 MiB. Docker images,
database volume size, cloud bill, hosted RAM peak and browser session cost
have not been measured. All new disposable tests use locally generated
software keys and loopback or GitHub Actions; no paid resources were ordered.
The runbook in `docs/r02-h021-final-verification.md` still governs
explicitly approved independent-host testing. Operators must independently
verify provider account/IAM/SSH ownership, OS firewall effective policy,
real ASR and merchant listening ports, evidence freshness and cleanup.

No Docker/Chromium installation belongs on Host A. The official Alice
plugin can provide only typed planning on Host A; Alice must host the
executor, private browser, issuer and effect vault in independently controlled
infrastructure. A clean end-user onboarding and remote identity pairing
workflow are still missing. A built wheel alone is not a distributed product.

**Release decision: R02 P0 / NO-GO.** Do not merge previous draft PRs, ship
real checkout capability, connect live merchants, or label the single-host
CI an interhost security proof. Priority external gates: independent B
administration and adversarial A→B proof, authenticated service/device
pairing, real user consent and iOS transport, official Hermes integration,
per-tenant OS/browser fencing, PSP certification and production operations.

## Link to the larger plan

The integrated branch advances plan A (security/architecture), B
(identity contracts), C (official Hermes compatibility), D (shopping and
recovery/R03), and E (distribution/iOS). The next **large mission** after
local security remediation is **Hosted Alice Control Plane + Secure Device
Pairing**: independently operated infrastructure, authenticated official
Hermes pairing, iOS verified consent and status transport, real isolation
proof, deploy/rollback/observability and sandboxed browser effect service.
No work here authorizes a real purchase before its release gates pass.
