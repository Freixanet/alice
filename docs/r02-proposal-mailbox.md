# R02 — Proposal-only Hermes ↔ Alice lab

**Synthetic loopback HTTPS integration only. R02 remains P0 / NO-GO.**
No personal Hermes, bank account, real merchant, iOS device or external
infrastructure was used.

## Trust boundaries

The official Hermes plugin registers two non-executing tools: the existing
single-step planner and an optional remote proposal transport. The latter
can GET exactly one Alice-published, sanitized observation and POST exactly
one typed proposal. It never has access to AliceRunner, private browser,
payment authority, merchant tokens, checkout approval, recipient or CDP.

The disposable TLS transport has only /v1/planner/next (GET) and
/v1/planner/proposal (POST). There is no payment/commit, privileged browser,
job creation or human-approval endpoint. Unconfigured tools fail closed.
Redirects and ambient proxy inheritance are disabled; a disposable CA is
explicitly pinned. The demonstration permits only localhost HTTPS, not a
public service. Its short-lived bearer file must have private file permissions.
No operator is instructed to modify their personal Hermes installation.

## Protocol

1. Trusted Alice enrollment issues a time-limited proposal-only token bound
   to tenant, session, Alice account and named Hermes installation.
2. Trusted Alice PairedRemoteCoordinator creates a fictional job or resumes
   a known job ID. It stages a filtered observation at an exact epoch.
3. Hermes uses its official LLM planning method to propose a typed action,
   supplying the nonce of the Alice-published planning step.
4. Alice stores that **untrusted proposal**, then its trusted coordinator
   claims it durably before independently validating and executing the
   reversible typed runner step. Hermes receives no privileged handle.
5. Alice acknowledges the result only after the runner returns. A crash
   after claiming leaves the step non-replayable and requires inspection;
   no automatic duplicate cart action or checkout is issued.
6. Rotate, expiry or revocation of proposal credentials deny further access
   or claims. SQLite transactions serialize relevant writes across processes.

## Evidence and explicit limitations

The disposable Python tests cover exact HTTPS calls, fake official LLM
interface and tool registration, five-step fictitious shopping to approval,
zero merchant checkout attempts, malformed/forged proposals, wrong tenants,
wrong/non-private bearer, expiry, rotation/revocation, durable crash fence and
resuming the same Alice job. This is not evidence of a live Hermes + real LLM
pairing: neither the installed official runtime nor a hardware-backed iOS
approval was exercised.

**Still PENDING:** production Alice identity provider and authenticated
enrollment, independently administered host, TLS/rate-limit/OS egress policy,
real Hermes device pairing and network deployment, iOS hardware signing,
multi-host attacks, real merchant certification, distribution, and recovery
operations. The synthetic loopback HTTP server lacks production deadlines,
quotas, and process-level tenant separation; do not expose it publicly.
