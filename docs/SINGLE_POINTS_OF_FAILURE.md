# Single Points of Failure

A systematic audit of single points of failure across the complete Alice
system. Alice is a personal project by one developer; mitigation complexity
itself is a risk.

**Audited at:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

## Classification

- **MUST REMOVE** — The failure would cause irreversible data loss or
  unrecoverable startup, and the mitigation is low-cost.
- **SHOULD REDUCE** — The failure would cause significant disruption, but
  the mitigation has a cost or the failure is recoverable.
- **ACCEPTABLE RISK** — The failure is unlikely, recoverable, or the
  mitigation would add more complexity than the risk justifies.

## SPOF register

### 1. Original developer disappears

| Field | Value |
| ----- | ----- |
| COMPONENT | Marc Freixanet — sole developer and director |
| FAILURE MODE | Developer becomes unavailable. No one else knows the system. |
| EVIDENCE | README: "Designed and directed by Marc Freixanet." AGENTS.md is the shared instruction file. docs/HANDOFF.md exists but is dated and partial. No START_HERE.md. |
| LIKELIHOOD | Low-medium (personal project, active development) |
| IMPACT | Critical — no one can continue the project |
| DETECTION | GitHub inactivity |
| RECOVERY DIFFICULTY | High — requires reading all code and docs |
| MITIGATION COST | Low — documentation |
| PROPOSED RESPONSE | **SHOULD REDUCE** — Create START_HERE.md (Task 18) and ADRs (Task 19). Move essential context into the repository. |

### 2. AI conversation history disappears

| Field | Value |
| ----- | ----- |
| COMPONENT | ChatGPT/Claude/Codex conversation context |
| FAILURE MODE | The AI agent that was working on Alice loses its conversation context. It cannot continue where it left off. |
| EVIDENCE | AGENTS.md says "This file is the shared source of instructions." CLAUDE.md points to AGENTS.md. But much architectural context exists only in conversation. |
| LIKELIHOOD | High — conversation context is ephemeral by design |
| IMPACT | Medium — work continues but with re-learning overhead |
| DETECTION | None — the agent does not know what it forgot |
| RECOVERY DIFFICULTY | Medium — requires re-reading the repo |
| MITIGATION COST | Low — documentation |
| PROPOSED RESPONSE | **SHOULD REDUCE** — START_HERE.md and ADRs make the repository the long-term memory. This is Task 18. |

### 3. Development Mac dies

| Field | Value |
| ----- | ----- |
| COMPONENT | Intel Mac (16 GB) — development machine |
| FAILURE MODE | The Mac fails. No Xcode, no Hermes, no development environment. |
| EVIDENCE | AGENTS.md: "This Mac (Intel, 16 GB) has no iOS simulators." README: "you build it with Xcode." The Mac is the only build and test machine. |
| LIKELIHOOD | Low-medium (hardware ages) |
| IMPACT | High — cannot build or test until replaced |
| DETECTION | Immediate |
| RECOVERY DIFFICULTY | Medium — need a new Mac with Xcode 26 |
| MITIGATION COST | None feasible (must have a Mac for iOS development) |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — GitHub Actions provides a hosted Mac for CI. A new Mac with Xcode installed restores development. The repo and CI are the backup. |

### 4. Runtime Mac/backend fails

| Field | Value |
| ----- | ----- |
| COMPONENT | The Mac running Hermes gateway + dashboard |
| FAILURE MODE | The Mac goes down, sleeps, or Hermes crashes. Alice cannot reach the agent. |
| EVIDENCE | architecture.md: "The iPhone talks to your Hermes over your network." No fallback or relay. |
| LIKELIHOOD | Medium (Mac sleeps, Hermes restarts, network changes) |
| IMPACT | High — Alice is non-functional until the Mac is back |
| DETECTION | iOS connection state, DiagnosticChecks |
| RECOVERY DIFFICULTY | Low — restart Hermes or wake the Mac |
| MITIGATION COST | High — a relay/APNs infrastructure is explicitly out of scope |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — This is a known, documented limitation. The README states "Not a hosted service." Adding infrastructure would increase complexity beyond what a personal project justifies. |

### 5. Hermes fails

| Field | Value |
| ----- | ----- |
| COMPONENT | Hermes agent runtime |
| FAILURE MODE | Hermes crashes, hangs, or produces no output. |
| EVIDENCE | Hermes is an external dependency. Alice cannot fix it. |
| LIKELIHOOD | Low (Hermes is stable in daily use) |
| IMPACT | High — no agent responses |
| DETECTION | iOS connection state, stall sampler, DiagnosticChecks |
| RECOVERY DIFFICULTY | Low — restart Hermes |
| MITIGATION COST | None — Hermes is external |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Alice detects the failure and shows it. Recovery is restarting Hermes. |

### 6. GitHub becomes unavailable

| Field | Value |
| ----- | ----- |
| COMPONENT | GitHub — source control, CI, issue tracking |
| FAILURE MODE | GitHub is down or the account is locked. No source, no CI, no issues. |
| EVIDENCE | The entire repository, CI workflows and issue templates are on GitHub. |
| LIKELIHOOD | Very low |
| IMPACT | Medium — local clones and builds still work; CI and collaboration do not |
| DETECTION | Immediate |
| RECOVERY DIFFICULTY | Low — GitHub outages are short |
| MITIGATION COST | None feasible |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Local clones preserve the code. CI resumes when GitHub is back. |

### 7. Critical dependency breaks

| Field | Value |
| ----- | ----- |
| COMPONENT | Hermes, Xcode, iOS 26, Neon, Vercel, npm packages, Python packages |
| FAILURE MODE | A dependency releases a breaking change or becomes unavailable. |
| EVIDENCE | CI pins specific versions (Node 24, npm 11.19.0, Python 3.11, Hermes commit b889e4e9). package-lock.json and npm audit exist. |
| LIKELIHOOD | Low (versions are pinned) |
| IMPACT | Varies — from build failure to runtime error |
| DETECTION | CI (npm audit, deps:check, build) |
| RECOVERY DIFFICULTY | Low — pin to the last working version |
| MITIGATION COST | Low — already done (pinning) |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Dependencies are pinned. CI catches breaks. Hermes is pinned to a specific commit. |

### 8. API provider disappears

| Field | Value |
| ----- | ----- |
| COMPONENT | Model provider (OpenAI, Anthropic, OpenRouter, etc.) |
| FAILURE MODE | The model provider Alice uses goes down or revokes access. |
| EVIDENCE | Alice supports multiple providers. Model selection is per-conversation and per-agent. |
| LIKELIHOOD | Low |
| IMPACT | Medium — the person can switch providers |
| DETECTION | Model list errors, connection errors |
| RECOVERY DIFFICULTY | Low — configure a different provider in Hermes |
| MITIGATION COST | None — already multi-provider |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Alice is provider-agnostic. The person configures providers in Hermes. |

### 9. Bad code reaches main

| Field | Value |
| ----- | ----- |
| COMPONENT | The main branch |
| FAILURE MODE | A merge introduces a regression, a data-destroying bug, or a security issue. |
| EVIDENCE | CI runs on every PR and push to main. But CI cannot catch every regression (no simulator on dev Mac, no live Hermes in CI). PRs can be merged directly. |
| LIKELIHOOD | Medium (AI coding agents can introduce subtle bugs) |
| IMPACT | Varies — from minor UI glitch to data loss |
| DETECTION | CI, manual testing on physical iPhone |
| RECOVERY DIFFICULTY | Low — git revert |
| MITIGATION COST | Low — CI already exists |
| PROPOSED RESPONSE | **SHOULD REDUCE** — CI catches static issues. The standing migration tests catch data-destroying Codable changes. But no automated test catches every regression. The mitigation is the PR review process and the physical-device testing requirement in AGENTS.md. |

### 10. Bad migration ships

| Field | Value |
| ----- | ----- |
| COMPONENT | SQL migrations, Codable changes |
| FAILURE MODE | A migration destroys data or makes the app crash on launch. |
| EVIDENCE | SQL migrations are additive and backward-compatible. Codable changes have standing regression tests. But a non-additive SQL migration or a removed Codable field could ship. |
| LIKELIHOOD | Low (rules are documented and tested) |
| IMPACT | Critical — data loss or unrecoverable startup |
| DETECTION | CI (unit tests), but CI does not test against a real database with real data |
| RECOVERY DIFFICULTY | High — migrated data cannot be un-migrated |
| MITIGATION COST | Low — documentation and tests |
| PROPOSED RESPONSE | **SHOULD REDUCE** — docs/MIGRATIONS.md codifies the rules. The forward-compatibility test (PR #41) guards against one regression. Database migrations should be tested against a copy of production data before deployment. |

### 11. Operation interrupted midway

| Field | Value |
| ----- | ----- |
| COMPONENT | Any long-running operation (migration, sync, agent task) |
| FAILURE MODE | The app is killed mid-operation. |
| EVIDENCE | All writes are atomic. Migrations verify before committing. Agent tasks have recovery (session.resume). |
| LIKELIHOOD | Medium (iOS kills background apps freely) |
| IMPACT | Low — the operation resumes or is retried |
| DETECTION | Diagnostics log |
| RECOVERY DIFFICULTY | Low — the design handles this |
| MITIGATION COST | None — already implemented |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Atomic writes, write-order recovery and session recovery handle this. |

### 12. Local state partially corrupted

| Field | Value |
| ----- | ----- |
| COMPONENT | iOS file system, UserDefaults, Keychain |
| FAILURE MODE | A file is partially written (disk error), UserDefaults plist is corrupted, Keychain entry is lost. |
| EVIDENCE | Atomic writes prevent partial files. ConversationArchive has a salvage path. KeyStore uses update-then-add. But UserDefaults corruption is not recoverable. |
| LIKELIHOOD | Very low |
| IMPACT | Varies — from a lost setting to lost conversations |
| DETECTION | Decode failure, salvage path |
| RECOVERY DIFFICULTY | Medium — conversations are salvageable; settings are not |
| MITIGATION COST | Low — already mostly mitigated |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — The existing protections (atomic writes, salvage, Keychain update-then-add) are sufficient. UserDefaults corruption is an iOS-level issue Alice cannot solve. |

### 13. Credentials rotate or expire

| Field | Value |
| ----- | ----- |
| COMPONENT | Hermes key, dashboard password, API tokens, OAuth tokens |
| FAILURE MODE | A credential expires or is rotated. Alice cannot connect. |
| EVIDENCE | KeyStore stores the Hermes key. Dashboard credentials are separate. API tokens are in Hermes' .env. OAuth tokens are in Hermes' config. |
| LIKELIHOOD | Low (credentials are long-lived) |
| IMPACT | Medium — Alice shows connection failure; the person re-pairs |
| DETECTION | Connection state, DiagnosticChecks |
| RECOVERY DIFFICULTY | Low — re-pair or re-enter credentials |
| MITIGATION COST | None — already handled |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — Alice detects the failure and shows it. Re-pairing is a documented process. |

### 14. Human knowledge concentrated in one person

| Field | Value |
| ----- | ----- |
| COMPONENT | Marc's understanding of the system |
| FAILURE MODE | Knowledge of why decisions were made, how components interact, and what not to change exists only in Marc's head (or in AI conversation context). |
| EVIDENCE | docs/HANDOFF.md is partial. No START_HERE.md. No ADRs. AGENTS.md has contracts but not rationale. |
| LIKELIHOOD | High (knowledge is not yet in the repo) |
| IMPACT | Critical — a new engineer or agent cannot make safe changes |
| DETECTION | None |
| RECOVERY DIFFICULTY | High — requires re-discovering decisions |
| MITIGATION COST | Low — documentation |
| PROPOSED RESPONSE | **MUST REMOVE** — START_HERE.md (Task 18) and ADRs (Task 19) are the mitigation. The repository must become the long-term engineering memory. |

### 15. Build process depends on one machine

| Field | Value |
| ----- | ----- |
| COMPONENT | The development Mac for device builds |
| FAILURE MODE | Only the dev Mac can build and install on the physical iPhone (specific device ID, signing identity). |
| EVIDENCE | AGENTS.md: device ID A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B. The signing identity is on this Mac. |
| LIKELIHOOD | Low (the Mac is working) |
| IMPACT | Medium — cannot install on the iPhone until a new signing identity is set up |
| DETECTION | Immediate |
| RECOVERY DIFFICULTY | Medium — need Xcode + signing on a new Mac |
| MITIGATION COST | None feasible |
| PROPOSED RESPONSE | **ACCEPTABLE RISK** — CI uses a hosted Mac. A new Mac with Xcode and a developer account can build. The device ID changes, but that is expected. |

## Summary

| Classification | Count | SPOFs |
| -------------- | ----- | ----- |
| MUST REMOVE | 1 | Human knowledge concentration (#14) |
| SHOULD REDUCE | 4 | Developer disappears (#1), AI context loss (#2), Bad code (#9), Bad migration (#10) |
| ACCEPTABLE RISK | 10 | All others |

The single MUST REMOVE is addressed by Tasks 18 (START_HERE.md) and 19
(ADRs), which move essential context into the repository.

No redundancy is recommended where redundancy is only theoretically safer.
Alice is a personal project; adding a second Mac, a relay service or a
monitoring platform would increase complexity beyond what the project
justifies.
