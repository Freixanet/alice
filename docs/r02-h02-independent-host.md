# R02 — H02 Independent Host Isolation (synthetic, draft)

**Decision: P0 / NO-GO for autonomous real shopping.** H02 is an independently
deployable **configuration and adversarial-test candidate**, not a claim that
two independently administered live hosts have been tested. **H01 is unchanged**
in its original PR #78 and remains the verified same-host Docker baseline.

## Trust and machines

```text
HOST A — untrusted Hermes operator (may have root/Docker)
  Official Hermes, unchanged: typed proposal-only output
  Receives only a short-lived one-request PROPOSAL capability if needed.
       │ HTTPS to ONE authenticated gateway, never backend secret
       ▼
HOST B — ALICE administrative owner (independent OS/admin credentials)
  Public endpoint: H02 TLS gateway ── private authenticated HTTP/TLS ┐
  Alice-only Compose bridge ("internal: true")                       │
      ┌──────────────────────────────────────────────────────────────┘
      ▼
  Private ASR runner + own Chromium, cookie contexts, secret mounts,
  one-owner SQLite ledger, fake merchant at local loopback.
  No host-published ASR port, browser CDP or Docker API.
```

The independent-host premise requires Host A **not** to administer Host B,
its cloud account/IAM, hypervisor, Docker socket, backup volumes, issuer
keys, or Alice's signing/owner credentials. Both services on B are still in
one B administrative domain; a gateway compromise may reach the backend.
It is NOT separate control-plane isolation between gateway and ASR.

## Implemented code and synthetic verification

- `alice_secure_runner/h02_identity.py`: locally provisioned HMAC-SHA256
  keyring, active `kid` and old verification keys (remove and **recreate the
  gateway** to revoke; live reload is not implemented); strict
  issuer, fixed audience, registered subject, stable tenant/paired-session,
  role, job, HTTP method/path, exact request bytes digest, `nbf/iat/exp`
  (maximum five minutes) and one-time `jti`. Noncanonical/duplicate JSON,
  mistaken role, endpoint/body/job identity and expired tokens are refused.
- `ReplayLedger`: SQLite unique one-time request IDs consumed with
  `BEGIN IMMEDIATE` **before** forwarding. Multiple concurrent attempts
  and restarts do not restore a consumed request; unknown payment effects
  must be reconciled by Alice, not automatically retried. For this proof,
  an issued capability is **one-use**, not a reusable login/access token.
  This is not sender-constrained DPoP or hardware/device attestation.
- **Security qualification:** the public H02 gateway holds the HMAC **signing**
  key and coordinator/human backend secrets for both synthetic actors. A
  compromised gateway can impersonate privileged Alice roles. This is a
  **P0 production blocker**, not independent signed approval. Before real
  integration, use an independently operated signer/device authorization,
  public-key-only gateway verification and independently enforced ASR consent.
- `h02_gateway.py`: fixed-route HTTPS gateway. Trusted Alice operator
  maps provisioned `sub` to actor and stable tenant/session; role and job
  checks are before privileged forwarding. Model JSON cannot override identity,
  specify a URL, or call CDP/commit using a proposal capability.
- `deploy/h02/compose.yaml`: independently deployable Alice Host B
  **synthetic** stack. ASR attached only to private internal bridge; gateway
  sole published port, separate nonroot IDs, read-only filesystems, reduced
  capabilities, browser and SQLite only inside ASR, replay volume inside
  Alice B. Runner source reused unchanged from H01; H01 recovery semantics
  and `UNKNOWN` fail-closed behavior are preserved.
- `scripts/h02_remote_probe.py` can be copied to **Host A** and run with
  only one expiring proposal token and synthetic test CA. It attempts valid
  proposal, replay, body mutation, direct privileged action, and optional
  private ASR/CDP TCP. **A same-host container run is not a two-VM test.**

### Local / hosted CI synthetic test

```bash
bash scripts/verify-r02-h02-docker.sh
```

This test only operates with throwaway certs, actors, items, merchant and
random secrets. It sets `H02_PUBLIC_BIND=127.0.0.1`, creates disposable Docker
images, starts H02 gateway/ASR, uses a separate unprivileged attacker container,
tests one-use signed proposals and real private-IP denial, then tears down
containers, fixture files and volumes. It runs on **one Docker host**, so
it is **not independent-host isolation evidence**, irrespective of green CI.
No access to personal Hermes, browsers, cloud accounts or real shops.

**H01 regression:** review independent workflows under PR #78, especially
the Docker run for SHA `5e31764945cb631d9ae09dbc296107c9b06d5046`:
[`38269291679`](https://github.com/Freixanet/alice/actions/runs/38269291679).
H02 inherits it without changes. Running H01 again is unnecessary unless
H02 changes a shared contract or package source that can regress it.

## Two independent VM acceptance runbook (NOT EXECUTED)

No cloud instance, domain, certificate or remote SSH/IAM credential has been
provisioned by this project. Before using any independent VMs:

1. Have Alice's separate administrator approve a provider, region, usage
   quotas, time limit and cost. **Never place the Host B cloud administrator,
   SSH private key, Docker socket, signing keys or Alice owner token on A.**
   Use a separately managed account/identity and short-lived throwaway VMs.
2. On **B only**, install Docker/Compose, configure an independent outbound
   restriction and security-group firewall. Allow inbound TCP **only the
   intended TLS gateway port** from A's test IP; block 8443, 9222, Docker
   API, SSH and B management plane from A. Docker's published-port DNAT can
   bypass common host `ufw` rules: verify cloud security group **and**
   `DOCKER-USER`/nftables effective policy, IPv4 **and** IPv6. Never
   assume `internal: true` is a complete destination or browser firewall.
3. Configure a disposable, explicitly reviewed H02 gateway public binding,
   valid test certificate / pinned test CA, provision **Alice-only** keyring,
   subjects and backend credentials. H02 does not yet include hardened
   external onboarding: default scripts deliberately publish only loopback.
   Capture ASR container ID, PID, private networks and live listener _on B_.
4. From independently administered hostile **A**, with root access to A
   only, run `scripts/h02_remote_probe.py` against B's gateway. Provide a
   test proposal request token (no issuer signing key) and test CA using
   an outbound transfer from Alice's administrator. Record A's machine/VM
   identity, routing table, real destination IP, and actual HTTP/TCP outcome.
   On B record packet/firewall counters and denied packets. Use a controlled
   B-side private listener to distinguish firewall rejection from an
   **absent endpoint**; confirm it is actually listening before probing.
5. Attempt connections from A to B's ASR, metadata, browser/CDP and management
   ports; try gaining access to B processes, files, cookies and SQLite via
   any exposed protocol. An unrelated local A filesystem path being absent
   does **not** prove permission denial. Demand independent B-side evidence
   of actual resources and closed inbound routes.
6. Repeat with A root/Docker privileges, test key expiry/rotation and
   two-actor cross-job access, bring down B runner during a **fictional**
   irreversible step and verify durable `UNKNOWN` and zero blind retries.
   Confirm previous Chromium-owner PID/session destroyed before reusing it;
   a logical generation marker alone is not VM destruction attestation.
7. Tear down instances and verify cloud billing and deletion of VM disks,
   network resources and credentials. Preserve only redacted evidence,
   hashes, timestamps and the exact Git SHA/CI run IDs.

**Two-host GO condition:** authorized VM A and independently administered
Alice VM B exist at the same time; A can make an authorized proposal to
B's gateway; A with administrative rights cannot reach ASR's live private
listener or browser/secret/SQLite surfaces; gateway/runner independently
enforce role, audience, session/job, replay and network policy. Until this
is witnessed, report **H02 host boundary PENDING**, not GO.

## Adversarial matrix — honest proof types

| Attempt                                                                  | Current evidence                                                  | Independent-host status                                            |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------------ |
| Hermes sends permitted typed product proposal                            | Scoped signature + synthetic gateway and fixture runner           | **PARTIAL**: not real official Hermes live host                    |
| Request body substitution, expired/revoked key, wrong role/job, repeat   | Python isolated unit tests with SQLite durable replay             | **DEMONSTRATED in synthetic protocol**, no live OIDC               |
| Hermes reaches privileged `approve`, `commit` or human takeover          | Proposal-only role and signed method/path; synthetic HTTP tests   | **PARTIAL**: real iPhone owner/device authority not implemented    |
| Hermes connects ASR:8443, CDP:9222, cookies/SQLite/host PID              | H01 Docker network/PID/mount controls; H02 same-host fixture      | **PENDING** from remote independently managed A                    |
| Root on Hermes machine attacks Alice admin/VM/KVM/Docker                 | Not executable in same-host CI                                    | **PENDING**                                                        |
| ASR Chromium tries cloud metadata, internal services, redirected secrets | H01 selected internal network/TLS fixture probes                  | **PARTIAL**: DNS/IPv6/UDP/WebRTC and allowlist enforcement pending |
| SIGKILL while external merchant already charged but reply is lost        | H01 in-container fictional merchant only                          | **PENDING**: independent durable fake merchant/receipt             |
| Workload mTLS + independent signed backend assertions                    | Backend has Alice-private fixture TLS + static service capability | **PENDING**: H02 backend credential modernization                  |
| User authenticates with real OIDC/device-bound signature                 | Alice-operator issued fixture capability only                     | **PENDING**                                                        |

## Cost and operational limits

Public-repo standard GitHub-hosted `ubuntu-latest` jobs run on fresh VMs
and GitHub lists them as free, but independent jobs have no ready private
network or simultaneously reachable service. Running two jobs does NOT
automatically yield this proof:
<https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job>.

Oracle documentation currently describes up to **two AMD Always Free micro
VMs** or an Ampere A1 monthly allocation (capacity and home-region dependent):
<https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm>.
The AMD micro VM offers only about 1 GiB each: **insufficiently evidenced**
for the H01 ASR configuration capped at 2 GiB plus Chromium. An eligible
Arm instance may offer better capacity but requires verifying image/browser
architecture, quotas, networking and region **before use**. A zero-price
claim requires actual billing evidence. No cloud allocation was created.

**P0 / NO-GO remains mandatory** for real money: no independently hosted live
test yet, no OIDC/device attestation, no independent gateway->ASR workload
identity, no full DNS/IPv6/renderer egress policy, no external PSP receipt
verification, no independently attested browser reaper or certified payment
provider. Gateway key compromise permits privileged impersonation; lost
responses to `/v1/jobs` do not yet have an idempotent creation/recovery ID,
so additional unused jobs may be created. Keyring changes require recreating
the gateway with its durable replay volume, rather than hot-reloading keys.
The prototype contains only fictional shop credentials.

## Execution record

H02 started from PR #78 at SHA
`5e31764945cb631d9ae09dbc296107c9b06d5046`.
The original private Execution Ledger referenced in
`docs/continuity.md` may reside outside the repository; do not invent an
entry or expose private system inventories. Record final H02 commit, CI
verifications, security reviews and exclusions in the draft PR and here.
