# R02 — H02.1 Independent Host Isolation: verification record

**Status: PENDING for the two-administrator, two-host acceptance criterion.
R02 remains P0 / NO-GO for real purchases.** The H02.1 CI is a **single
ephemeral Docker VM**. It cannot demonstrate that an operator with root on
Host A is unable to administer Host B.

## Intended security boundary

```text
   HOST A — hostile, root/Docker controlled by Hermes operator
   Official Nous Hermes (UNCHANGED) → typed proposals only
       ONLY one-use job-scoped proposal capability
            │  TLS, pinned test CA, :38444 (approved A source IP only)
            ▼
 ╔══════════ HOST B: independently administered ALICE VM ══════════════╗
 ║  Gateway HTTPS (untrusted ingress, public VERIFY KEY ONLY)          ║
 ║   ├─ signed user/session/tenant/job/body/path/role/time verification ║
 ║   ├─ one-use gateway replay SQLite (persists across gateway restart) ║
 ║   └─ forwards exact bytes + original signed proof over pinned TLS    ║
 ║                          │ private Docker internal bridge          ║
 ║   ASR PRIVATE (public VERIFY KEY ONLY; independent replay SQLite)   ║
 ║    ├─ requires signature + backend bearer + matching role/tenant     ║
 ║    ├─ separate trusted signing issuer NOT mounted into services      ║
 ║    ├─ atomic idempotent creation map + jobs + UNKNOWN SQLite ledger  ║
 ║    └─ private Chromium, cookies, synthetic shop, device-test secret  ║
 ║  No published ASR:8443, CDP:9222, Docker socket, secrets, database.  ║
 ╚══════════════════════════════════════════════════════════════════════╝
```

The single synthetic Host B is still one trust domain. If Host A can log
into B, control B's Docker, cloud IAM, SSH keys, hypervisor or gateway's
signer, the diagram does **not** express an effective boundary. Two virtual
machines in **one Hermes-administrated account do not qualify**.

## Implemented, with limitations

1. `h021_crypto.py`: offline Ed25519 operator private issuer, RSA-free
   verification using OpenSSL 3 `pkeyutl` and immutable, local pinned public
   PEM files in gateway and ASR. Fixed issuer/audience/kid, stable user,
   tenant, pairing session, role, job, method, exact raw-body SHA-256 and
   expiry. No `alg` negotiation, remote JWKS, identity from JSON or
   signing key inside either internet-facing or executor container. OpenSSL
   subprocess verification is a **fixture** (performance, HSM, key management
   and revocation policies require production-grade crypto integration).
2. H02.1 gateway forwards **unaltered signed JSON bytes**; ASR validates
   the signature itself, requires matching role + identity + a backend bearer
   and consumes a separate durable request replay ID **before** doing work.
   Compromise of the public gateway and theft of its static backend bearer
   alone can no longer mint OWNER/HUMAN/COMMIT operations. Actual device
   attestation and trusted consent-signing UX are still **not implemented**.
3. `AliceRunner.new_job(..., create_request_id=...)` atomically records the
   job + identity-scoped creation key + recipient digest in **one SQLite
   transaction**. A new signed request with the same create key returns the
   same job after a lost HTTP success; different recipient is denied. H01
   callers without the optional field preserve their original behavior.
   No automatic checkout retry has been introduced; `dispatching→unknown`
   remains unchanged.
4. `deploy/h021/compose.yaml` builds the H02.1 gateway and ASR from clean
   wheels in nonroot, capability-dropped, read-only containers; ASR has one
   Docker-internal bridge with no published port. A separate hostile
   container is **only a synthetic regression**, not a separate host.
5. Real outbound socket samples from the runner reject specified public
   IPv4/IPv6 and cloud metadata destinations. This is **not** a universal
   HTTP/DNS/UDP/WebRTC/redirect/rebinding/IPv6 egress policy. A future browser
   with approved Internet access needs a separate locked-down egress
   proxy, DNS resolution policy and network firewall.
6. `h021_transport.py`: bounded 24-connection HTTP admission **before**
   spawning handler threads, TLS handshakes in admitted workers rather than
   blocking the only accept loop, and absolute five-second request-header and
   request-body deadlines. A test with an idle TCP client and a concurrent
   verified TLS request passes locally. These fixture-level protections
   limit, but do **not** eliminate, denial-of-service; production requires
   an independently configured reverse proxy with connection and per-source
   rate limits, request budgets and load-tested cloud firewall behavior.

**H01/H02 preservation:** the #76/#77/#78/#79 commits are not modified. H02.1
is a separate draft PR stacked on #79. Because H02.1 extends the shared
runner's `core.py`, its H01 recovery and checkout regression tests **must**
run again against the final SHA.

## Reproducible, free synthetic CI

```bash
bash scripts/verify-r02-h021-docker.sh
```

Produces new disposable keys, signed proposals, wheel-installed images,
an Alice gateway/ASR and hostile container. Verifies valid one-use proposal,
body substitution, replay, direct privileged endpoint denial, backend
bearer-only bypass rejection, idempotent job creation and owner-session
restoration after ASR recreation. It also drives a complete signed **fictional**
five-step search/product/cart/quote sequence, synthetic user challenge/consent,
one confirmed fictitious receipt and rejection of duplicate submission; this
cross-checks H02.1 authorization rather than assuming H01's older interface
still works. The synthetic shop remains _inside_ ASR and is not an independent
merchant receipt or PSP guarantee. Tears down dedicated containers and
volumes. **All on one Docker VM.**

The RSA TLS test certs are one-day self-signed with explicit SANs, checked
against an exact test CA. No TLS verification bypass or real payment exists.
Ed25519 fixture signing keys are generated each run; only the public PEM is
mounted into gateway and ASR. The issuer private PEM remains solely in the
trusted operator's temporary directory.

## Independent HOST A/B test: approval-gated procedure (NOT EXECUTED)

This runbook is deliberately executable **after** explicit approval to use
cloud VMs, network connections, test costs, region and credentials. It
does not provision, register or connect any external service itself.

**Prerequisites**

- Two ephemeral Linux VMs, with distinct OS administrative accounts and
  distinct provider control-plane/IAM authorities. B requires a supported
  Playwright image and a **measured** Chromium memory budget; 2 GiB/2 vCPU
  are container limits, not measured VM requirements. Confirm architecture
  with `uname -m` and Docker multiarch manifest **before** choosing Arm.
- A's operator has root/Docker on **A only**, not B. B's private cloud admin,
  signer private key, SSH key, backup volumes, issuer records and Docker API
  are unreachable from A.
- B security group/cloud firewall allows **only A's public test IP → B's
  gateway TCP 38444**; B SSH permitted only from a separately trusted admin
  IP, not A. Deny all other A→B inbound, IPv4 and IPv6. Check effective
  DOCKER-USER/nftables forwarding policies: host `ufw` alone can be bypassed
  by Docker-published-port DNAT. ASR private bridge must remain internal;
  metadata from the ASR net namespace must fail. If an infrastructure
  firewall or remote route is not verifiable, **STOP**.
- Official Hermes can run independently on A and emit only a typed proposal
  using unchanged public planner interfaces. The existing H02.1 shell
  acceptance script still uses a **synthetic Hermes stand-in**, so real
  official Hermes delivery/pairing remains a separate acceptance gate.

**On trusted B, once the above is reviewed and approved:**

```bash
export H021_EXTERNAL_APPROVED=yes
export H021_INDEPENDENT_ADMIN_CONFIRMED=yes
export H021_FIREWALL_REVIEWED=yes
export H021_B_BIND_IP=<actual-B-interface-IPv4>
export H021_B_PUBLIC_IP=<approved-B-reachable-IPv4>
bash scripts/verify-r02-h021-docker.sh
```

The script refuses this mode without all three explicit safeguards and
nonloopback IPv4 addresses. It builds disposable packages, generates
isolated secrets and SAN-pinned test TLS certs, starts **only the Alice
Host B** stack and checks local private listener presence. It writes an
operator-only `operator-session.env`, plus three transferable artifacts
`gateway.pem`, `untrusted_one_use_proposal` and
`remote_manifest.json` inside its **0700** temporary fixture directory.
Transfer **only those three files**, using an approved channel, to A.
Reissue the 5-minute proposal token securely if transfer takes too long.
Never transfer `issuer-private.pem`, backend credentials, device key,
SQLite, browser profiles or the B operator-session.env.

**On independent hostile Host A (root, authorized destination ONLY):**

```bash
sudo python3 scripts/h021_host_a_attack.py \
  --manifest remote_manifest.json \
  --ca gateway.pem \
  --proposal untrusted_one_use_proposal \
  --approved-target \
  --approved-private-target
```

This verifies a positive scoped proposal through B's TLS gateway, consumed
token and body alteration rejection, forbidden owner/human operations and
selected TCP exposures on B's public address **AND B's exact attested private
ASR IP:8443**. A route overlapping a local service on A is not conclusive:
independently verify that the private IP belongs to B before using the
second explicit approval flag. An unreachable TCP port is
classified **NOT REACHABLE OR ABSENT**, not a verified firewall block.
Confirm a **real live B-side ASR listener** at the same time with B's
operator output, Docker/OS inspection and (for firewall claims) denied
packet counters or ACL logs. Confirm B's private files, SQLite, Chrome
profile and secrets exist using trusted B-side evidence without copying
their contents to A.

Capture separate A/B VM IDs, B root cloud principal, A root principal,
different provider IAM/admin capabilities, certificate fingerprint,
time-synchronized UTC timestamps, routing table, firewall/ACL snapshots,
positive B listener, blocked A connections, exact CI/commit SHA, selected
traffic captures with no tokens/secrets, process-destruction evidence,
and provider billing. Remote probes **cannot themselves prove** two
administrative principals are independent; cloud/IAM audit evidence must.

**Stop test B and remove only its recorded project and generated files:**

```bash
bash scripts/h021_host_b_stop.sh /path/from-B-output/operator-session.env
```

Then confirm **the cloud instances, volumes, public IPs and firewall rules**
have been destroyed in the provider console/API and check actual billing.
This repository does **not** delete cloud resources because it did not
provision them.

## Honest attack/proof matrix

| Attack / control                                                      | Synthetic evidence                              | Independent-host proof                                |
| --------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| Signed typed proposal delivered, no direct authority                  | Positive HTTPS request + limited search         | **PENDING** genuine official Hermes A→B               |
| Body/path/role/job/audience/time tampering                            | Ed25519 verifier negative tests                 | **DEMONSTRATED** fixture only                         |
| Gateway compromised: backend bearer used without signature            | Private ASR rejection from gateway container    | **DEMONSTRATED** fixture, not full compromise testing |
| Two actors and durable replay after ASR restart                       | SQLite and scope tests                          | **DEMONSTRATED** for selected Python fixtures         |
| Lost `/v1/jobs` response and changed create payload                   | Atomic recipient-scoped idempotency tests       | **DEMONSTRATED** synthetic core                       |
| Hermes root on A reaches B private ASR, CDP, Docker, files, processes | B non-exposure policy; A-side script prepared   | **PENDING** independent VM/IAM/firewall records       |
| Actual private Chromium profile/secret exists and A cannot reach it   | H01 same-host proof, H02.1 private inspection   | **PENDING** independently attested A/B run            |
| Metadata IPv4/IPv6 and external egress attempts                       | Selected ASR netns TCP checks                   | **PARTIAL**, full DNS/redirect/UDP policy pending     |
| Runner crash after durable checkout dispatch                          | H01 UNKNOWN regression                          | **PARTIAL**, external persistent merchant/PSP absent  |
| Hardware-backed user presence, real OIDC, mTLS to ASR                 | Not implemented                                 | **PENDING**                                           |
| Cryptographic key revocation/rotation                                 | Public key manifest replacement / restart tests | **PARTIAL** trusted operator workflow, no live IdP    |

## Cost/resource evidence

- **GitHub Actions standard public-repository runner:** published as free;
  each default Ubuntu runner is an ephemeral VM, but two Docker containers
  in one runner are **not** administratively independent.
  <https://docs.github.com/en/billing/concepts/product-billing/github-actions>
- **OCI Always Free:** documentation describes two AMD micro VMs and Arm
  Ampere A1 allowances amounting to 2 OCPU / 12 GiB with 1,500 OCPU
  hours + 9,000 GB hours per month; region/available capacity, image
  architecture, disk and quota apply. Even two free VMs under **the same
  Hermes-controlled administrator** fail the independent-admin test.
  <https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm>
- **Two isolated VM providers/accounts:** variable price; no instance type,
  network egress cost or final cost has been measured or incurred here.
  Select paid sizes only with explicit approval and bounded shutoff.
- **Observed CI resource limits:** H02 compose sets ASR 2 GiB/2 CPU;
  this is **a configured ceiling, not measured peak usage**. Real cold
  Chromium RSS, image-size/network, Arm64 feasibility and root attacker
  effects still require measurement on approved VMs.

## Evidence and execution ledger

H02.1 branches from PR #79 SHA
`62a3335d45652eb58747d8d75a42ad304741588e`. Cite final
H02.1 SHA and GitHub Actions run in the draft PR after verification.
The external/private execution ledger may not be accessible in this
worktree; do not invent its contents, private inventory or an update.

**Final acceptance is not a green same-host CI.** It requires proof that a
fully privileged Hermes administrator on real Host A cannot reach or
control B's existing privileged resources, **while a permitted proposal
still works** and ASR independently authorizes it. Until observed on
distinct administrative hosts, **H02.1 PENDING, R02 P0 / NO-GO**.
