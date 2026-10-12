# R02 — H01 Hosted Isolation Proof (fictional, security laboratory)

**Decision: P0 / NO-GO for real shopping.** This is executable isolation
evidence using Docker containers on an ephemeral CI-hosted Linux VM, not a
cloud production service, remote-host attestation or PCI/payment compliance.
Both original PRs **#76 and #77 stay untouched and DRAFT**; H01 uses a separate
stacked PR with an independent worktree, preserving their commits/evidence.

## Trust boundaries

````text
                       COMPUTER OF ANY HERMES USER
┌──────────────────────────────────────────────────────────────┐
│ Official Hermes + Alice optional public-interface plugin    │
│ Model can only produce {action, epoch, bounded parameters}    │
│ NO runner secret, browser, cookies, privileged API or Docker │
└─────────────────────────┬────────────────────────────────────┘
         HTTPS: untrusted proposal data + test scoped capability
                           │ (in H01 CI: unprivileged hostile container)
╔══════════════════════════▼═══════════════════════════════════╗
║ ALICE-OWNED INFRASTRUCTURE / DIFFERENT ADMINISTRATIVE HOST    ║
║ ┌──────────────────────────────────────────────────────────┐  ║
║ │ H01 gateway, own Docker container, hermes_front network   │  ║
║ │ Fixed endpoint paths, per-role/tenant/session synthetic   │  ║
║ │ credentials, STRICT schema; no arbitrary proxy/CDP/API    │  ║
║ └─────────────────────────────┬────────────────────────────┘  ║
║          Private TLS + separate backend capability            ║
║              ASR backend-only Docker bridge                   ║
║ ┌─────────────────────────────▼────────────────────────────┐  ║
║ │ ASR runner: typed AliceRunner + SQLite persistence        │  ║
║ │ Browser/Chromium per-job context, merchant/read secrets   │  ║
║ │ Approval HMAC mock and one-shot checkout ledger           │  ║
║ │ Localhost-only fictional HTTPS merchant and cart          │  ║
║ └──────────────────────────────────────────────────────────┘  ║
╚═══════════════════════════════════════════════════════════════╝

Topological trust separation applies **only** when the Alice-owned host is
actually distinct from the Hermes-controlled computer. In the test, the
Hermes stand-in is an unprivileged container on the *same CI VM* as the other
containers. Docker network/PID/mount policy can block that specific attacker,
but **root/Docker-socket access to the host defeats it**. VM/machine separation
from a privileged user's own Hermes host is an architectural requirement, not
something a same-host Docker test can prove by itself.

## What is executable in H01

1. A standalone installed **wheel** is built in a Docker build stage, installed
   outside the source directory; ASR runs Python plus real Playwright/Chromium
   in its own disposable container. The client never installs those packages.
2. Gateway and runner use separate TLS certs, different nonroot Linux UIDs,
   independent mount/PID/network namespaces, read-only root filesystems,
   `cap_drop: ALL`, no-new-privileges, PID/memory/CPU limits and no host,
   privileged, Docker-socket or shared browser mounts. ASR has **no public
   published port**. Both Docker networks are `internal: true`.
3. Gateway receives Hermes **proposal-only** bearer and an Alice **owner**
   synthetic bearer in separate roles; only Alice-owned owner role can request
   approve/commit. Synthetic identity is server-side, not user-supplied JSON.
   The gateway is a privileged deputy and has service secrets; it must stay
   inside Alice trust and undergo its own security audit.
4. A test human-consent HMAC signs the exact checkout nonce/digest, and the
   executor independently checks quote and `SQLite` compare-and-swap before
   sending *one* fictional `/commit`. `dispatching` recovered after SIGKILL
   becomes `unknown`: no automatic resubmission.
5. Browser cookies, profiles, Node IPC, CDP and merchant secrets reside only
   within ASR's container, never the untrusted Hermes container. No remote
   debugging port is published. Browser requests are scoped to synthetic
   read-only HTTPS routes; all redirects fail closed. Browser-level routing
   **is not an OS network firewall**, and the browser process currently shares
   an OS identity with the trusted runner *inside* ASR.

### Test from a clean Linux Docker-enabled host

```sh
bash scripts/verify-r02-h01-docker.sh
````

The script requires Docker Compose and OpenSSL **only on Alice's test host**;
it synthesizes credentials and two short-lived certificates, builds three
standalone images (runner, gateway, hostile Hermes), runs independent HTTPS
connections and adversarial probes, checks an approved fictitious checkout,
then forces runner SIGKILL in a delayed fake payment and verifies durable
`unknown` without retry. All containers, ledger and fixture files are removed
on normal script exit. A crash of the test operator could leave temporary
containers/files; in that case manually `docker compose -f
deploy/h01/compose.yaml --profile attack down -v` from the lab host.
Do **not** invoke this script with real accounts, personal Hermes configuration,
or on a computer controlled by a potentially malicious Hermes process.

## Adversarial evidence matrix and scope

`BLOCKED (TECH)` = a genuine TCP/socket/namespace/file access was attempted
and refused by configured technical policy. `DENIED (AUTH)` = gateway/runner
rejected a delivered request after verifying its scoped credential/state.
`UNAVAILABLE` = the API/port was never implemented; do **not** present this as
independent isolation. `PENDING` = not executed against an independently
operated cloud VM, real official Hermes host or real PSP.

| Attack/action from Hermes stand-in                              | Expected / evidence kind                               | Limits                                                                 |
| --------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- |
| Valid structured product-search proposal                        | **ALLOWED** via gateway                                | Read/search changes no irreversible charge                             |
| Read ASR backend bearer, device key, SQLite file                | **BLOCKED (TECH)** separate container mounts           | Host admin/Docker operator not hostile in this test                    |
| Read ASR `/proc/<real_host_pid>/environ` or memory              | **BLOCKED (TECH)** PID/mount namespaces                | Same-host kernel escape not tested                                     |
| Connect to ASR's actual private IP:8443 or :9222                | **BLOCKED (TECH)** Docker network separation           | Host routing, custom NAT/iptables outside fixture unknown              |
| Connect to public internet from Hermes container                | **BLOCKED (TECH)** internal-only frontend bridge       | No general internet permission in adversarial lab                      |
| Visit gateway's unused `/v1/browser/cdp`                        | **UNAVAILABLE**, 404                                   | Absence of implemented route is not a sandbox                          |
| Use proposal token for approval, payment or human takeover      | **DENIED (AUTH)** role separation                      | Static test bearer is not real device identity                         |
| Force `browser_exec`, arbitrary HTTP, raw JS or checkout_commit | **DENIED (AUTH/schema)** typed action validator        | Hermes can still act independently using its own tools outside Alice   |
| Spoof other tenant/session or another job ID                    | **DENIED (AUTH)** scoped gateway + runner              | User enrolment, real key issuer/revocation pending                     |
| Replay same epoch or approval/submit                            | **DENIED (STATE)** epoch/CAS and signed mock consent   | Live expiration/revocation/OIDC not proven hosted                      |
| Replace ASR container with prior browser job pending            | **DENIED (STATE)** stale browser generation            | Doesn't attest old OS process killed across unrelated hosts            |
| SIGKILL while fictitious submission in progress                 | **UNKNOWN, NO RETRY** durable ledger                   | Fake merchant is in same container; no external receipt reconciliation |
| Browser native JS to network/WS/redirect or CDP bypass          | **PARTIAL** separate Chromium unit CI and typed filter | OS egress firewall, WebRTC/beacons/SSRF not universally covered        |
| Hermes host with root/Docker-socket privileges on Alice host    | **PENDING / NOT A SAFE DEPLOYMENT**                    | Must host on independently controlled machine/VM                       |
| Human viewer and real payment-provider receipts                 | **PENDING**                                            | Do not transfer real cards/cookies or buy anything                     |

The CI workflow `.github/workflows/r02-h01-hosted-isolation.yml` must be
checked on the **exact final H01 commit**. Local Python tests and a previous
PR77 Chromium 9/9 PASS are **not evidence of Docker network isolation**.

## Continuity and current architectural gaps

- The backend SQLite ledger is a named Docker volume, persisted across
  `restart`/`--force-recreate`; its cross-process singleton DB prevents two
  owners of the same ledger. This is not replicated DB/HA. Synthetic merchant
  memory/cart is **not** persistent; a crash during irreversible work is
  intentionally marked UNKNOWN and must not be re-sent. Verify actual PSP
  charge state and idempotency independently before any production retry.
- Browser generation is a **logical fail-closed marker**. Without trusted
  container/VM destruction attestation and a cleanup/reaper protocol, an
  orphaned session cannot be safely resumed or handed to a human.
- Static fixture tokens have no expiry or real OIDC identity; no independent
  iPhone hardware-backed consent, user/tenant key lifecycle, per-job routing
  signatures, quotas/rate limits, encryption-at-rest, resource abuse test,
  network allowlist by resolved IP, WebRTC policy, mTLS workload identity,
  secrets manager, audit log, browser separate-UID sandbox or external PSP.
- Gateway is dual-homed by design and can contact both networks. Compromising
  it can defeat scope isolation; no agent tool should expose it as a raw proxy.
- Hermes official compatibility stays at public `ctx.llm.complete_structured`
  and optional `alice_secure_plan` plugin. H01 exercises **untrusted proposal
  payloads in a hostile container**, not a live official Hermes model/host
  running without personal credentials. Universal plugin provisioning or a
  verified no-plugin planner and cloud account onboarding remain unfinished.
- ADR 0002's general checkout action taxonomy is _proposed_, not the live H01
  contract. The runnable broker accepts only `search`, `read_product`,
  `select_product`, `add_to_cart`, `prepare_checkout`, and `stop`; never a
  model-callable `commit` or raw browser/CDP action.

## Costs: measurements vs estimates

**Measured in source configuration**: H01 ASR has Docker resource caps of
**2 vCPU and 2 GiB memory**, gateway **256 MiB**, hostile fixture **128 MiB**.
These are _configured maxima_, not observed demand or cloud reservations.
Actual CPU seconds, peak memory, build/minutes and account charges must be
collected from the final CI logs/hosting billing; **$0 measured cloud spend**
is not claimed unless an account invoice is available. No paid cloud was
deployed for H01.

**Illustrative assumption only**: Google Cloud Run Tier 1 consumption CPU
`$0.000024/vCPU-s` and memory `$0.0000025/GiB-s` (as listed on the official
pricing page when researched in October 2026). If an eligible service actually
ran 2 vCPU + 2 GiB for **600 billed active seconds**, arithmetic would be
`2 × 600 × $0.000024 + 2 × 600 × $0.0000025 = ~$0.032 per 10-minute session`,
or **~$32 per 1,000 such sessions** _before_ free tier, concurrency, minimum
instance, gateway, storage, VPC/NAT egress, observability, TLS, images,
third-party browser infrastructure, security, model inference, PSP, support
and taxes. This is **NOT** a verified quote for H01 Docker/Chrome deployment,
especially because Cloud Run networking and browser runtime constraints differ.
Reference: https://cloud.google.com/run/pricing . GitHub says public repos on
standard GitHub-hosted Linux runners may run within its free policy:
https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions . Do not assume private repositories are free.

## Release gates

**H01 can report GO-for-conditional-lab** only after an independent Linux CI
VM runs the actual hostile container against ASR, with successful positive
controls and explicit network/PID/mount deny probes. Even then, report exact
limits and **NO-GO for production / real autonomous purchases**. Real user
identity, a separately controlled cloud host, PSP verification, human viewer,
universal official-Hermes installation, cloud IAM/network egress, per-tenant
host isolation, and independent security review remain necessary.
