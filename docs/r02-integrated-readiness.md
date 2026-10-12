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
   approved-resume paths. A sticky `.alice/r02-asr-only-v1` marker in the
   Hermes account prevents an accidentally lost environment setting on
   restart from re-enabling legacy checkout. **All older Hermes errands
   are conservatively paused under ASR-only mode**, even non-shopping
   tasks: their unrestricted native tools cannot reliably be classified
   as read-only from a natural-language request. Running old sessions are
   sent a stop request at orchestration boundaries and on cold restart.
   An unconfirmed remote gateway stop remains durably marked pending, with
   bounded status rechecks on recovery and a best-effort 30-second daemon
   reaper in the long-lived official Hermes plugin process, **not** deemed
   stopped. If Hermes itself is dead or hostile, its reaper cannot prove
   cessation: operator inspection and independently managed Alice credential
   revocation remain mandatory.
   A payment already sent remains uncertain, never implicitly refunded
   or retried. The marker is **not**
   an OS/terminal sandbox and cannot resist Host A root deliberately deleting
   local files. Credential migration and disabling Hermes' old card vault
   must be handled by independently managed Alice policy before production.
   Existing ordinary Hermes checkout remains separately labeled as legacy
   when this opt-in mode is off. For flagged ASR errands, iOS displays
   only read-only, unverified status and blocks old payment controls.
   A trusted ASR iOS status/approval transport has **not** been implemented.
   **Additional PR #81 consolidation:** invocation-time ASR-only quarantine
   now blocks already registered legacy browser/login/cart/checkout tools,
   `purchase_outcome` receipt mutations, and old-errand `ask_person` writes.
   Ordinary non-shopping conversations retain their tools. The reaper uses
   the shared account root for Hermes named profiles, not a profile folder.
   Before any legacy `/v1/runs` submission, a cooperative cross-process
   admission barrier checks the sticky cutover flag and durably records
   `run_start_uncertain`; the barrier is held until the returned run ID is
   persisted. A lost remote response forbids another automatic launch and
   requires operator inspection. **An unidentifiable Hermes run cannot be
   positively stopped** without an official idempotent launch/recovery API.
   None of these local guards constitute OS isolation against Host A root.
7. Host A probe records `PENDING_EXTERNAL_INDEPENDENT_PROOF` even when all
   negative routing checks pass. `--require-attested-proof` exits nonzero
   until independently verified provider IAM/firewall/routing/VM identity
   records can be attached. Failure to route to a Docker bridge address is
   not a demonstrated firewall deny.
8. The trusted H02.1 ASR process also retries terminal Chromium session
   cleanup every ten seconds when an earlier close was not acknowledged.
   It never reissues merchant commits, never clears an uncertain payment,
   and only attests closures belonging to the **same browser generation**.
   After process recreation, an old unknown browser owner remains durably
   fenced. OS-level destruction/isolation of orphan Chromium still needs
   independently attested host controls; a fresh child cannot certify it.

## Integrated requirements matrix

| Frontier                                  | Implemented / tested                                                                                                                                                                                    | Remains blocked (cannot claim GO)                                                                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| H01/H02/H02.1 cryptographic authorization | Ed25519 issuer not on services; two public verifiers, separate durable replay, bounded HTTPS, idempotent job creation and previous fixture tests                                                        | Two independent administrators and real Host A/B attack with evidence; production workload mTLS/IdP, trusted ingress edge                           |
| Network and browser                       | Docker internal egress islands; separate merchant network; no published ASR/merchant/CDP; browser route rejects redirects, POST, WS; bounded transport                                                  | Real OS-enforced per-process browser sandbox and full DNS/IPv4/IPv6/UDP/WebRTC egress controls under adversarial root                               |
| User identity and consent                 | P-256 detached software signatures for exact canonical challenge, public-only key registry, expired/replayed consent refused                                                                            | Secure Enclave enroll/attestation, iOS approval flow and trusted Alice account/device pairing, real key lifecycle                                   |
| Official Hermes                           | Official public plugin API registration contract and pure typed planner tests                                                                                                                           | Clean official installation + real model/supported versions, authenticated pairing and durable remote observe/act cycle                             |
| Fictional checkout / related R03          | Real separate process merchant, durable SQLite receipt, exact itemization and variants, one dispatch, UNKNOWN, receipt-only reconciliation across **both** process crashes, exclusive simulated handoff | Real PSP/merchant adapter certification, external durable receipts, 3DS, encryption/compliance and no blind payment retries under real network      |
| iOS / distribution                        | Swift read-only status vocabulary and legacy checkout isolation, synthetic wheel and Docker image builds                                                                                                | Real authenticated ASR status feed, P-256 consent enrollment, secure hosted onboarding, actual deployment/update/recovery and real iOS device tests |

## Evidence rules and tests

- `python3 -m unittest discover -s tests -q`: full repository Python
  test suite, excluding optional browser tests when local Chromium is absent.
- `python3 -m unittest discover -s hermes-plugin/tests -p 'test_r02_*.py' -q`:
  legacy payment cutover, restart and official plugin registration fixture
  tests; complete plugin registration rejects duplicate tool names. Includes
  handler cutover, named-profile reaper, uncertain remote launch and
  interleaved marker/dispatch admission tests.
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

### PR #81 consolidation validation (post-baseline changes)

- Baseline commit `d769969a6429e7702800d5bc1c47c4f8dce87c3e`:
  H01, H02, H02.1 same-host Docker, synthetic HTTPS, real Chromium,
  Quality verify and browser SUCCESS on GitHub; Quality iOS remained in
  progress at the last baseline check. Results are _not_ for later changes.
- After the new local plugin edits: **24/24 R02 plugin tests PASS** with
  Python 3.11; `git diff --check` PASS. These are mocked registration and
  security-contract tests, not installed official-Hermes or remote pairing.
- Two additional disposable ASR terminal-browser tests pass: a failed close
  is safely retried and an old-generation close remains unverified. This
  does not certify orphan cleanup after an OS/container crash.
- Repository Python test suite before these plugin-only edits: 105 run,
  9 skipped, no failures. Structured Hermes-to-ASR mock bridge: 7/7 PASS.
- Attempted full Hermes plugin suite using the Mac's Python 3.9:
  584 tests, 21 errors, 3 failures, 27 skipped. Missing Hermes modules,
  FastAPI, WebSockets and incompatible Python 3.9 features were among the
  causes; **this is not a passing suite or a validated source regression**.
  A Python 3.11 focused 106-test errands suite had one missing-WebSockets
  dependency error. An isolated official Hermes test environment is needed.
- No hardware-backed presence, real payment authorization, administrative
  separation or provable stop of an unidentifiable old run was demonstrated.

### Continued local hardening after SHA `7192e262` (not yet release evidence)

- The exact previous SHA's Quality `verify` job **FAILED**, at
  `npm run format:check`, because Prettier rejected this ledger's Markdown.
  Its `browser` job passed; `ios` was in progress at investigation time.
  Formatting was corrected in the subsequent local worktree. The previous
  failed job cannot be relabeled green. Every new SHA needs its own CI.
- The exact Hermes source pinned by Quality
  (`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`) implements durable,
  credential-scoped `Idempotency-Key` reservations for `POST /v1/runs`.
  The gateway now probes `GET /v1/capabilities` and sends a unique
  admission key **only** when `features.runs_idempotency` advertises both
  `supported=true` and `durable=true`. That key and the exact request
  are saved before network admission and cleared after a durable `run_id`.
  A lost response still produces `stuck` and **never triggers an automatic
  replay**. With old/memory-only gateways, the conservative keyless state
  remains. A durable reservation alone is not evidence that a run is
  stopped, nor proof that an old key survives arbitrary gateway database
  replacement, retention expiry or adversarial control of Host A.
- A separate Alice-administered SQLite P-256 public-key registry now supports
  exactly one enrolled key for a trusted tenant/session/account/installation
  association, finite expiry, CAS-style rotation and durable revocation.
  The runner can serialize a verified approval and its durable state update
  against concurrent administrative revocation, including through another
  SQLite connection. H02.1 offers an explicitly **synthetic-only opt-in**,
  `H021_DEVICE_CONSENT_REGISTRY_FIXTURE_ONLY=yes`, requiring a previously
  populated private `/var/lib/h01/device_enrollments.sqlite3` file.
  Restart does not auto-enroll a key or resurrect a revoked one. This is
  NOT account authentication, Secure Enclave attestation, Face ID, real
  user-presence proof, remote enrollment or a production device service.
- Local checks before publication: repository Python **111 tests PASS**
  (**9 skipped**, optional Chromium); focused R02 Hermes plugin **26 PASS**;
  device enrollment/rotation/revocation/concurrency tests **4 PASS**.
  H02.1 Docker, official live model, iOS XCTest and whole-suite Hermes
  verification of these NEW edits are still pending exact SHA checks.

## Attacks and negative outcomes

### Continued local proposal-only bridge (additional worktree, pending CI)

The [Hermes-to-Alice proposal mailbox](r02-proposal-mailbox.md) introduces
an optional official Hermes plugin tool, separate trusted Alice ownership of
the SQLite proposal-only pairing ledger, expiring/revocable capabilities, a
sanitized one-step observation and a durable one-shot claim. The trusted
PairedRemoteCoordinator resumes known jobs and rejects replay after a
claimed effect; tests drive a fake Hermes-model tool over disposable HTTPS
through five actual fictional merchant steps to awaiting_approval with zero
checkout submissions. This DOES NOT prove live Hermes installation,
actual cloud pairing, hardware consent, independent-host isolation or
release suitability.

Current local validation: Python **120 tests PASS (9 skipped)**; focused
R02 Hermes plugin **26 PASS**; remote proposal-mailbox **8 PASS** and
device registry **5 PASS** (both included in the 120); Prettier and
git whitespace PASS. An
isolated Python wheel was built and installed outside the checkout; its
mailbox and coordinator imported successfully. The wheel file was **59,787
bytes** on this Mac, which is a packaging measurement, not RAM, hosting
cost, secure distribution or a tested product installation. Exact-SHA
hosted GitHub CI and iOS are pending for this subsequent bridge.

The device registry also fences approved fictional
checkout submission against revocation and expiry with a SQLite writer
transaction. A revocation that completed first denies commit before the
merchant is contacted; a revocation racing an already-admitted dispatch
cannot falsely claim it prevented that in-flight effect. The new regression
test checks revocation after approval produces zero checkout submissions.
Exact-SHA GitHub CI remains required separately from these local checks.

### Device key-rotation fence (new candidate SHA)

The approved job now durably records the exact version of its public P-256
device key. The fictional commit path rechecks both active enrollment and
that precise version before dispatch. A subsequent key rotation **invalidates
an existing approval** even after restart, rather than silently treating the
new key as approval of the old checkout. Older records without a recorded
version fail closed when using the revocable registry. A new synthetic
restart/rotation test passes; the full local Python suite now has **121
tests PASS, 9 optional Chromium skipped**; focused R02 Hermes **26 PASS**.
This still cannot prove a live iOS Secure Enclave or production user identity.

### New local recovery/security hardening after e2c8ac0

At exact HEAD `e2c8ac04f065410881d0efcacbd14f9262fdcac4`,
H01/H02/H02.1 same-host, synthetic HTTPS/Chromium and Quality browser
passed; Quality **verify failed** because an existing test's registered
tool-name expectation omitted `alice_secure_plan_remote`. The official
Hermes suite ran 629 tests, one failed, 22 skipped. The expectation is
corrected locally, but exact-SHA CI must rerun. Quality iOS was in progress.

Device consent changes in the current worktree now commit an exact
P-256 grant in the independent device SQLite registry **before** publishing
AliceRunner approval, and commit consumption of that grant **before** invoking
the merchant effect callback. Fault-injected registry commit failures
cannot authorize a charge; a consumed grant never permits automatic retry,
including when a quote validation fails. These are software fixture
guarantees, not an attested iOS approval.

Trusted Alice-only proposal cancellation now durably fences pending and
submitted steps. A step already claimed returns `inspection_required`,
never a falsely confirmed stop. The outbound model data is bounded and
heuristically redacted for synthetic URLs/emails/card strings/street phrases;
**this is NOT a comprehensive private-data filter** and curated product-only
inputs are required before deployment. The disposable HTTPS mailbox reuses
H02.1's bounded server, TLS handshake, header and body deadlines; it
remains loopback-only and is not a production OS or network isolation proof.

An independent reviewer reproduced a cancellation bypass across two
legitimate Hermes pairings for the same tenant/session/job. The new
durable job-level cancellation record now blocks every pairing, even a
fresh installation, while leaving any claimed effect pending inspection.
The negative test covers a second pairing after the cancellation and
another synthetic personal-data leak case with a street abbreviation
and nine-digit phone. These patches remain local until the next SHA.
After these additions the complete local repository suite ran **127 tests,
9 optional Chromium omitted, no failures**, and focused R02 plugin tests
ran **26 PASS**. The complete official Hermes suite and iOS build remain
separate GitHub CI requirements for the forthcoming SHA.

### Transversal fictional merchant recovery (subsequent local test)

The new
`test_h021_external_merchant.py::test_paired_hermes_proposals_device_consent_and_external_merchant_recovery`
drives five proposals over the disposable planner HTTPS channel into the
typed AliceRunner, obtains a fictional exact checkout and checks a P-256
**software** signature against a revocable public key. An independently
running fictional HTTPS merchant durably records one order, then the test
drops the HTTP reply, producing `UNKNOWN`. The runner and merchant both
restart; independent receipt lookup reconciles the exact checkout to
`confirmed_simulated` without a second merchant submission. Targeted
local test: **1 PASS**. It remains a fixture model and consent signature,
not proof of real Hermes installation, iOS human presence, PSP payment or
independent host administration. Its exact SHA CI has not yet run.

Local verification of the changed Python repository: **126 tests,
9 optional Chromium skipped, no failures**; mailbox **11 PASS**, device
registry **8 PASS**, focused R02 Hermes plugin **26 PASS**, whitespace
PASS. General Hermes tests run directly on this Mac lack official Hermes
modules and are not a validated regression or passing suite. New exact-SHA
Quality/iOS and official Hermes CI are still required before release claims.

### Shared SQLite merchant race (subsequent local fix)

The fictional `PersistentFictionalStore` now uses SQLite as the authoritative
cart and receipt source, even when separate store processes opened the
database before a cart or order was created. `BEGIN IMMEDIATE` serializes
competing checkout IDs; the first submission persists the immutable exact
receipt before replying. Another process returns that same persisted
receipt, cannot alter the recipient/amount using the same checkout ID,
and generates a unique fictional order ID for a different checkout.
The focused external-merchant suite **9/9 PASS** includes two concurrent
connections, a stale cart view, a changed-recipient denial, and the
independent process restart/UNKNOWN scenario. This is an R03 synthetic
merchant exercise, not a certified real merchant or PSP integration.
The latest local repository suite after this fix ran **129 tests, 9 optional
Chromium skipped, no failures**; a new SHA must be checked by GitHub.

### Native iOS exact-checkout contract (new local candidate)

Swift `SecureRunnerApprovalContract` strictly decodes the existing **fictional**
AliceRunner checkout snapshot and P-256 approval challenge with no additional
properties. It verifies tenant/session/job, precise checkout SHA-256 digest,
immutable merchant, quantity, currency, itemization and expiry, returning
canonical UTF-8 bytes only after all checks. A local Swift executable with a
Python independently computed SHA-256 golden fixture returned the exact same
challenge bytes. Malformed/tampered checkout, scope and expiry tests are
defined as iOS XCTest; actual XCTest execution awaits an isolated CI simulator.

The `SecureRunnerDeviceSigner` adapter separately provides a device-only
Secure Enclave P-256 public-key enrollment helper and a method that can sign
**only** a validated challenge. Its non-exportable key requests OS-level
`userPresence` with passcode-required, device-only Keychain protection;
there is no software-key fallback, payment submission, Hermès browser
connection or automatically trusted enrollment. Static Swift parsing and
typechecking against the installed **iOS device SDK** passed. No device
key was generated, no biometric/authentication event was invoked and no
proof of Face ID, presence, hardware attestation, remotely authenticated
Alice account or live user consent exists. These integrations remain P0
external gates. Existing SwiftUI cards still read-only with legacy `Pagar`
guarded; no new purchase action has been enabled.

An official-Hermes `PluginContext` registration smoke test has also been
added. It uses the real public `PluginContext` and a unique disposable
Hermes home to register both unprivileged planning tools, assert non-executing
handler denial and unload them. The bare Mac without official Hermes reports
**SKIPPED**, not PASS; the pinned-Hermes Quality CI must run this test for
valid installed-context evidence. It does not contact a configured model or
Hermes gateway or install anything into the person's home.

### Account-scoped device key possession (published in `3e0df06`)

The existing `RevocableP256DeviceConsent` registry now offers a trusted
administrator-only, SQLite-persisted, one-use, 180-second challenge for first
device enrollment and versioned key rotation. The challenge binds the exact
tenant, session, Alice account, named Hermes installation, proposed public
key digest, nonce and expected version; completing it requires an exact
P-256 signature by the **new key**. Stale, modified, replayed, wrongly
signed, and concurrent duplicate challenges are rejected, including across
independent SQLite connections. This proves possession of a software test
key, **not** that an Alice account or person was authenticated.

The parallel Swift `SecureRunnerEnrollmentContract` validates and canonically
serializes exactly this server challenge. The existing
`SecureRunnerDeviceSigner` now uses a session- and version-specific
Secure Enclave Keychain tag, refuses silent software fallback and exposes
only narrowly checked signatures of enrollment proofs and exact fictional
checkout challenges. The new code is **not connected to a public enrollment
API or UI**; no keys were generated on a personal device and biometric
presence remains unverified.

On the source with these local changes: repo Python **132 tests PASS (9
optional Chromium skipped)**; selected R02 plugin **27 tests (1 skipped,
0 failed)**; focused key registry **11 PASS**; Swift production models and
signer typecheck on this Mac, a standalone Swift contract executable checks
accepted/mutated synthetic enrollment, Swift XCTest files parse correctly.
**Local Swift XCTest was not executed** (no simulator/XCTest module in the
available standalone command), and the prior green GitHub iOS CI on
`d4c5d9b` does **not** cover this newer Swift code. A new exact-SHA CI
run is required after publication.

### Effect admission, exact enrollment lifetime, private backend redirects and R03 concurrency

The subsequent local security increment, prepared against `3e0df06`,
retains the existing runner, approval and independent fictional merchant
ledgers. It binds the exact proposed key expiry to the signed enrollment
challenge in both Python and Swift. It detects a previously committed
device-effect admission that has not reached the runner's dispatch ledger,
fencing the restored or immediately retried checkout as `UNKNOWN` instead
of risking a second merchant submission. The state is intentionally
conservative: this is not evidence that a charge actually reached a merchant.

The synthetic R03 merchant now rechecks the quoted cart within the same
SQLite `BEGIN IMMEDIATE` order transaction, preventing another merchant
process from mutating the cart between initial quote and durable receipt.
H02 gateway private-origin bearer and signed capability requests refuse
all HTTP 3xx responses; no redirect may carry them outside their destination.
The proposal mailbox declassifies only an exact, fixed fictional product
catalogue: arbitrary names, addresses, fragments of phone numbers and
goals remain redacted. The allowlist is a _test-fixture policy_, not a
general-purpose personal-data classification solution.

Focused local validation before committing this increment: **42 PASS**
across the device registry, durable external merchant, gateway redirect,
remote planner and H02.1 transport tests. Swift enrollment, approval and
Secure Enclave signer production files pass iPhoneOS 26.5 typecheck; this
does not prove XCTest execution, actual iOS secure-key generation or
authenticated Alice transport. Full-suite results, the published commit
SHA and its exact GitHub checks must be recorded separately after completion.

| Attempt                                                            | Expected result                                                                               |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Stolen gateway backend bearer without signed OWNER/COMMIT          | Denied by independent ASR verifier                                                            |
| Mutated Ed25519 role/path/job/body/tenant/session/replayed token   | Denied by both verifiers and durable replay                                                   |
| Forged/expired P-256 exact checkout consent                        | Denied by public-key device verifier and one-use job ledger                                   |
| Alter variant/tax/shipping/discount while keeping same final total | Denied before any merchant commit                                                             |
| Different recipient with reused merchant checkout ID               | Merchant rejects immutable receipt conflict                                                   |
| Lost merchant reply / both independent processes restarted         | `UNKNOWN` until exact durable merchant receipt read; no POST retry                            |
| Read-only Chromium credential tries merchant cart/receipt          | Denied; cannot access effect token through typed read endpoint                                |
| Legacy Hermes approval/resume while `ALICE_R02_ASR_ONLY=yes`       | Denied; no fallback to shared browser or saved card                                           |
| Legacy tools registered before cutover                             | Invocation-time quarantine includes login/cart/checkout/receipt paths                         |
| Lost Hermes `/v1/runs` reply after possible acceptance             | Durable uncertain marker prevents another run; remote status/stop needs manual reconciliation |
| Root Host A scans B private Docker bridge IP                       | Cannot assert firewall success from routing failure; independent evidence PENDING             |

## Cost, distribution and operations

### Additional local security remediation (pending exact-SHA CI)

The official Hermes plugin's advisory egress hook previously inspected shell
command text for known upload patterns; GET URLs, Python socket clients,
`git push`, or command-substitution/build hooks could bypass that heuristic.
The new plugin hook uses a tiny exact allowlist of purely local commands,
requires Hermes user approval for other known code/terminal executors even
when taint history is absent, and blocks if its guard raises an exception.
A scoped private SQLite ledger records the first network read before dispatch
and survives plugin reloads; further recognised web/browser network requests
require approval. Missing session identity or a corrupt ledger fails closed.
Its approval key binds the complete tool and argument object. This is
**defense in depth, not an OS-enforced network boundary**:
unknown Hermes tools, privileged extensions and independent processes may
still reach the network, and the first authorised-session web call is not
reviewed, so Host A must remain untrusted.

Installer changes are tested with a fake `hermes` CLI and a throwaway
`HERMES_HOME`, never against the owner's Hermes profile. Installation stages
an entire validated plugin before activating it, saves the previous copy and
configuration for rollback, rejects package/vendor symlinks, and orders
the gateway restart before the dashboard. Offline rollback/manifest tests
are not equivalent to verifying a clean deployment or upgraded official
Hermes running on a separately managed host. Neither rollout nor rollback
grants an authenticated R02 pairing or checkout capability.

Local outbound HTTPS callers now enforce a monotonic **response-body** time
budget (3 seconds for the synthetic merchant; 10 seconds for H02 private
ASR; 5 seconds for the proposal-only plugin) in addition to per-socket idle
timeouts. The Alice runner and H02 private gateway also bound response-header
parsing to 5 seconds and refuse unobservable transports. A trickle response
cannot occupy those reads indefinitely. The standalone Hermes plugin still
has no independently proven absolute response-header deadline, and no
production DDoS resistance or comprehensive whole-request budget is claimed.

For the published `abfc800` SHA, the H01/H02/H02.1/synthetic GitHub workflows
passed, while Quality's `verify` job rejected **this ledger's Markdown
formatting**; browser verification passed and the iOS job had not yet
completed at inspection time. The format is corrected with offline cached
Prettier and will be reverified at the next published SHA. Do not attribute
green CI to this candidate until checks refer to its exact commit.

No real account, keychain, Hermes installation, browser profile, service,
merchant or payment endpoint was accessed in these local hardening tests.
The final combined local Python/egress/installer suite for this increment
reported **165 PASS, 9 SKIPPED** (the skips require optional Chromium), with
`zsh -n`, `git diff --check` and offline Prettier check successful. Local
verification is not a substitute for the exact published SHA's GitHub CI.

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
