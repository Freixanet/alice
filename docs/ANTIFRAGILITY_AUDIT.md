# Antifragility Audit

An adversarial stress test of the complete Alice system. This audit acts as
an adversarial principal engineer and tries to break Alice conceptually and
operationally.

**IMPORTANT:** This audit was run against `main` at
`2420a2f89a229ceb334d06e933e1c7a1881f9271`. The antifragility improvements
from PRs #41, #42, #44, #47 and #53 (Tasks 15-19) are **not yet merged**.
This audit evaluates the current state of `main` and notes where the
unmerged PRs would change the classification. It should be re-run after
the PRs the user chooses to merge are merged.

**No source code was modified.** This is a documentation-only audit.

---

## Classification

- **ROBUST** — Alice can detect the failure, fail safely, be diagnosed, be
  recovered, be rolled back, and the procedure is documented or learnable.
- **PARTIAL** — Some of the above are true but not all.
- **FRAGILE** — The failure would cause silent corruption, irreversible
  data loss, impossible UI state, corrupted agent/chat state, or
  unrecoverable startup.

For every PARTIAL or FRAGILE area, the smallest intervention that
materially improves resilience is proposed.

---

## Scenario 1: Original developer disappears

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A (not a runtime failure) |
| DOES ALICE FAIL SAFELY? | N/A |
| CAN IT BE DIAGNOSED? | Partial — AGENTS.md, architecture.md, verification.md exist. No START_HERE.md on main. |
| CAN IT BE RECOVERED? | Yes — the repository is on GitHub. A new engineer can clone it. |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Partial — PR #47 (START_HERE.md) would fix this. |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Partial — PR #53 (ADRs) would fix this. |

**Classification: PARTIAL**

The repository contains substantial documentation, but it is scattered.
START_HERE.md (PR #47) and ADRs (PR #53) are the smallest interventions
that materially improve resilience. Without them, a new engineer or agent
must discover the architecture by reading code.

**Smallest intervention:** Merge PR #47 and PR #53.

---

## Scenario 2: All AI conversation history disappears

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | N/A |
| CAN IT BE DIAGNOSED? | Yes — the repository is the source of truth. AGENTS.md is the shared instruction file. |
| CAN IT BE RECOVERED? | Yes — a new AI session reads AGENTS.md and the docs. |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Partial — START_HERE.md (PR #47) makes the repository the long-term memory. |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — the repo does not depend on conversation context. |

**Classification: PARTIAL**

The repository does not depend on AI conversation context. AGENTS.md is
explicitly designed as the shared instruction file. START_HERE.md (PR #47)
would make this explicit. The gap is that some architectural rationale
exists only in conversation; ADRs (PR #53) would preserve it.

**Smallest intervention:** Merge PR #47 and PR #53.

---

## Scenario 3: Coding model/provider changes

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | N/A |
| CAN IT BE DIAGNOSED? | Yes — AGENTS.md is tool-agnostic. CLAUDE.md points to it. |
| CAN IT BE RECOVERED? | Yes — any coding tool reads AGENTS.md. |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — AGENTS.md says "This file is the shared source of instructions for Codex, Claude Code, Cursor and other tools." |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

AGENTS.md is explicitly designed to be tool-agnostic. Any coding agent can
read it and follow the same rules. The repository does not assume any
particular AI tool.

---

## Scenario 4: Development Mac dies

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | N/A |
| CAN IT BE DIAGNOSED? | Yes — GitHub Actions CI uses a hosted Mac. |
| CAN IT BE RECOVERED? | Yes — a new Mac with Xcode 26 and XcodeGen. |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — AGENTS.md documents the Mac's limitations. README documents setup. |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — the dev Mac's limitations are documented in AGENTS.md. |

**Classification: ROBUST**

The dev Mac is documented as having no simulator. CI uses a hosted Mac.
A new Mac with Xcode 26, XcodeGen and an Apple developer account restores
development. The signing identity would need to be set up on the new Mac.

---

## Scenario 5: Runtime Mac/backend fails

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — connection state, DiagnosticChecks |
| DOES ALICE FAIL SAFELY? | Yes — shows "Hermes: Disconnected" |
| CAN IT BE DIAGNOSED? | Yes — DiagnosticChecks, diagnostics.log |
| CAN IT BE RECOVERED? | Yes — restart Hermes or wake the Mac |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — README, getting-connected.md |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — the "phone never server" decision is documented |

**Classification: ROBUST**

Alice detects the failure, shows it, and recovers when the Mac is back.
The only risk is that background notifications are not delivered while the
Mac is down — this is documented as a known limitation.

---

## Scenario 6: Hermes fails

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — connection state, stall sampler |
| DOES ALICE FAIL SAFELY? | Yes — shows connection failure |
| CAN IT BE DIAGNOSED? | Yes — diagnostics.log, unknown events |
| CAN IT BE RECOVERED? | Yes — restart Hermes |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

Alice detects Hermes failures and preserves local state (conversations,
drafts). Recovery is restarting Hermes.

---

## Scenario 7: Network becomes unreliable

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — connection state, retry logic |
| DOES ALICE FAIL SAFELY? | Yes — shows "offline", keeps cached data |
| CAN IT BE DIAGNOSED? | Yes — diagnostics.log |
| CAN IT BE RECOVERED? | Yes — automatic reconnect |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — architecture.md, compatibility-matrix.md |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

Alice has a LaunchCache (stale-while-revalidate), FeedStore (offline cache),
EventResume (stream resumption), and connection retry logic. The phone
shows cached data while offline and refreshes when the network returns.

---

## Scenario 8: Critical dependency breaks

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — CI (npm audit, deps:check, build) |
| DOES ALICE FAIL SAFELY? | Partial — a broken dependency may cause runtime errors that are not caught |
| CAN IT BE DIAGNOSED? | Yes — diagnostics.log, build errors |
| CAN IT BE RECOVERED? | Yes — pin to the last working version |
| CAN IT BE ROLLED BACK? | Yes — package-lock.json, pinned Hermes commit |
| IS THE PROCEDURE DOCUMENTED? | Yes — verification.md, CI workflows |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — dependencies are pinned |

**Classification: ROBUST**

Dependencies are pinned (Node 24, npm 11.19.0, Python 3.11, Hermes
b889e4e9). CI catches breaking changes. The last known-good version is in
package-lock.json and the Hermes commit is pinned in CI.

---

## Scenario 9: API provider disappears

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — model list errors, connection errors |
| DOES ALICE FAIL SAFELY? | Yes — shows error, allows switching providers |
| CAN IT BE DIAGNOSED? | Yes — diagnostics.log |
| CAN IT BE RECOVERED? | Yes — configure a different provider in Hermes |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — README, compatibility-matrix.md |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — multi-provider is a design decision |

**Classification: ROBUST**

Alice is provider-agnostic. The person configures providers in Hermes.
The model picker shows all available providers. A failed provider shows
an error; the person can switch.

---

## Scenario 10: Bad code reaches main

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Partial — CI catches static issues. Some regressions require a physical iPhone. |
| DOES ALICE FAIL SAFELY? | Yes — standing tests guard against data-destroying Codable changes |
| CAN IT BE DIAGNOSED? | Yes — diagnostics.log, CI results |
| CAN IT BE RECOVERED? | Yes — `git revert` |
| CAN IT BE ROLLED BACK? | Yes — git revert, last known-good build on iPhone |
| IS THE PROCEDURE DOCUMENTED? | Yes — AGENTS.md, verification.md |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Partial — PRs are reviewed but can be merged directly |

**Classification: PARTIAL**

CI catches static issues (types, lint, build, secret scan, plugin tests,
e2e tests, iOS simulator tests). The standing migration tests guard against
the specific regression that erased conversations. But CI cannot catch
every regression — there is no live Hermes in CI, and the dev Mac has no
simulator. The mitigation is the PR review process and physical-device
testing.

**Smallest intervention:** Require PR review before merging to main.
Currently PRs can be merged directly by the owner.

---

## Scenario 11: Bad migration ships

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Partial — CI tests Codable migrations. SQL migrations are not tested against real data. |
| DOES ALICE FAIL SAFELY? | Yes — salvage path retains unreadable archives |
| CAN IT BE DIAGNOSED? | Yes — ConversationArchive.load reports unreadable bytes |
| CAN IT BE RECOVERED? | Partial — Codable: salvage path. SQL: additive migrations allow code rollback. |
| CAN IT BE ROLLED BACK? | Yes — for additive SQL. For Codable, the old build reads the new format. |
| IS THE PROCEDURE DOCUMENTED? | Partial — docs/MIGRATIONS.md (PR #41) would fix this. |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — the regression that erased conversations is a standing test |

**Classification: PARTIAL**

The standing migration tests guard against the specific Codable regression.
SQL migrations are additive and backward-compatible. But SQL migrations
are not tested against real production data, and there is no schema version
on conversation records to detect downgrade incompatibility.

**Smallest intervention:** Merge PR #41 (docs/MIGRATIONS.md and
ForwardCompatibilityTests). Add a schema version to conversation records
in a future change.

---

## Scenario 12: Operation interrupted midway

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — diagnostics.log |
| DOES ALICE FAIL SAFELY? | Yes — atomic writes, write-order recovery |
| CAN IT BE DIAGNOSED? | Yes |
| CAN IT BE RECOVERED? | Yes — the design handles this |
| CAN IT BE ROLLED BACK? | Yes — source is untouched until verified |
| IS THE PROCEDURE DOCUMENTED? | Partial — docs/MIGRATIONS.md (PR #41) documents this |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

All writes are atomic. The blob→split and UserDefaults→file migrations
verify every copy before removing the source. Agent task sessions have
recovery (session.resume). The feed cache survives offline. The sync
state saves the cursor with the corresponding state.

---

## Scenario 13: Local state becomes partially corrupted

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — decode failure, salvage path |
| DOES ALICE FAIL SAFELY? | Yes — unreadable bytes retained, never overwritten |
| CAN IT BE DIAGNOSED? | Yes — ConversationArchive.describe(error) gives a safe description |
| CAN IT BE RECOVERED? | Partial — conversations are salvageable. UserDefaults settings are not. |
| CAN IT BE ROLLED BACK? | Partial — conversations can be restored from salvage. Settings cannot. |
| IS THE PROCEDURE DOCUMENTED? | Partial — docs/DATA_INTEGRITY.md (PR #41) documents this |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: PARTIAL**

Conversations are well-protected (atomic writes, salvage, migration tests).
But UserDefaults settings have no backup or recovery path. If the
UserDefaults plist is corrupted, all settings (theme, accent, bot layout,
activity, notes) are lost. The Hermes key is in Keychain and survives.

**Smallest intervention:** Move the largest UserDefaults values to files
(the RetiredPreferences pattern already does this for the RSS archive).
Identify other large values and migrate them.

---

## Scenario 14: Deployment becomes partial/inconsistent

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — release verifier |
| DOES ALICE FAIL SAFELY? | Yes — immutable Vercel deployments |
| CAN IT BE DIAGNOSED? | Yes — X-Alice-Version header |
| CAN IT BE RECOVERED? | Yes — promote the last known-good deployment |
| CAN IT BE ROLLED BACK? | Yes — docs/release-operations.md documents the procedure |
| IS THE PROCEDURE DOCUMENTED? | Yes |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

Vercel deployments are immutable. The release verifier checks that the
endpoint is healthy and its version matches. Rollback is promoting the last
known-good deployment. Database changes are additive, so a code rollback
does not require a database rollback.

---

## Scenario 15: iPhone/Mac versions become incompatible

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — Hermes contract fixtures, capability detection |
| DOES ALICE FAIL SAFELY? | Yes — unknown events preserved, unsupported features degrade independently |
| CAN IT BE DIAGNOSED? | Yes — compatibility-matrix.md, hermes-contracts.md |
| CAN IT BE RECOVERED? | Yes — update Hermes or Alice to match |
| CAN IT BE ROLLED BACK? | Yes — pin to a compatible version |
| IS THE PROCEDURE DOCUMENTED? | Yes |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

Hermes contract fixtures are pinned to specific commits. Capability
detection distinguishes absence from failed detection. Unknown stream
events are preserved safely. The compatibility matrix documents what
works and what doesn't.

---

## Scenario 16: Credentials rotate or expire

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | Yes — connection state, DiagnosticChecks |
| DOES ALICE FAIL SAFELY? | Yes — shows connection failure |
| CAN IT BE DIAGNOSED? | Yes — DiagnosticChecks |
| CAN IT BE RECOVERED? | Yes — re-pair or re-enter credentials |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Yes — getting-connected.md, pairing.md |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes — KeyStore update-then-add preserves the old credential |

**Classification: ROBUST**

Alice detects credential failures and shows them. Re-pairing is a
documented process. The KeyStore update-then-add pattern ensures a failed
update never loses the old credential.

---

## Scenario 17: Six months pass with no development

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | Yes — the app and Hermes continue to run |
| CAN IT BE DIAGNOSED? | Partial — docs/HANDOFF.md is dated and partial |
| CAN IT BE RECOVERED? | Yes — the repository and CI are on GitHub |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Partial — START_HERE.md (PR #47) and ADRs (PR #53) would fix this |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Partial |

**Classification: PARTIAL**

After six months, dependencies may have security patches, Hermes may have
released new versions, and the development Mac may need OS/Xcode updates.
The repository is on GitHub and CI catches dependency issues. But the
context for why decisions were made may be lost. START_HERE.md and ADRs
are the smallest interventions.

**Smallest intervention:** Merge PR #47 and PR #53. Run `npm audit` and
`npm run deps:check` after the hiatus.

---

## Scenario 18: New engineer takes over tomorrow

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | N/A |
| CAN IT BE DIAGNOSED? | Partial — documentation exists but is scattered |
| CAN IT BE RECOVERED? | Yes — the repository is self-contained |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Partial — START_HERE.md (PR #47) is the fix |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Partial — ADRs (PR #53) are the fix |

**Classification: PARTIAL**

Same as Scenario 1. The repository contains substantial documentation but
no single entry point. START_HERE.md (PR #47) is the smallest intervention.

**Smallest intervention:** Merge PR #47.

---

## Scenario 19: GitHub temporarily becomes unavailable

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | N/A |
| DOES ALICE FAIL SAFELY? | Yes — local clones preserve the code |
| CAN IT BE DIAGNOSED? | Yes |
| CAN IT BE RECOVERED? | Yes — GitHub outages are short |
| CAN IT BE ROLLED BACK? | N/A |
| IS THE PROCEDURE DOCUMENTED? | Implicit |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Yes |

**Classification: ROBUST**

Local clones preserve the code. CI resumes when GitHub is back. No
runtime dependency on GitHub (the app talks to Hermes, not GitHub).

---

## Scenario 20: A future AI agent misunderstands the architecture

| Question | Answer |
| -------- | ------ |
| CAN ALICE DETECT IT? | No — there is no automated check for architectural understanding |
| DOES ALICE FAIL SAFELY? | Partial — AGENTS.md has contracts, but enforcement is manual |
| CAN IT BE DIAGNOSED? | Partial — PR review catches some misunderstandings |
| CAN IT BE RECOVERED? | Yes — git revert |
| CAN IT BE ROLLED BACK? | Yes |
| IS THE PROCEDURE DOCUMENTED? | Partial — AGENTS.md, START_HERE.md (PR #47), ADRs (PR #53) |
| IS THE FAILURE CLASS PERMANENTLY LEARNED FROM? | Partial |

**Classification: PARTIAL**

AGENTS.md has contracts that must survive changes. The task checklist
requires evidence. But there is no automated enforcement of architectural
contracts — a coding agent could introduce a change that violates a
contract and CI would not catch it (e.g., adding a non-optional Codable
field is caught by the standing test, but rerouting a conversation to
another profile is not).

**Smallest intervention:** Merge PR #47, #53. Add architectural
contract tests where feasible (e.g., a test that verifies the home chat
always uses the main profile).

---

## Summary

| Scenario | Classification |
| -------- | ------------- |
| 1. Developer disappears | PARTIAL |
| 2. AI history disappears | PARTIAL |
| 3. Model/provider changes | ROBUST |
| 4. Dev Mac dies | ROBUST |
| 5. Runtime Mac fails | ROBUST |
| 6. Hermes fails | ROBUST |
| 7. Network unreliable | ROBUST |
| 8. Dependency breaks | ROBUST |
| 9. API provider disappears | ROBUST |
| 10. Bad code on main | PARTIAL |
| 11. Bad migration ships | PARTIAL |
| 12. Operation interrupted | ROBUST |
| 13. State partially corrupted | PARTIAL |
| 14. Partial deployment | ROBUST |
| 15. iPhone/Mac incompatible | ROBUST |
| 16. Credentials rotate | ROBUST |
| 17. Six months pass | PARTIAL |
| 18. New engineer | PARTIAL |
| 19. GitHub unavailable | ROBUST |
| 20. AI misunderstands architecture | PARTIAL |

| Classification | Count |
| -------------- | ----- |
| ROBUST | 13 |
| PARTIAL | 7 |
| FRAGILE | 0 |

No scenario is FRAGILE. The 7 PARTIAL scenarios share root causes:

1. **Documentation scattered** (Scenarios 1, 2, 17, 18) — fixed by PR #47
   (START_HERE.md) and PR #53 (ADRs).
2. **No schema version on conversations** (Scenarios 11, 13) — documented
   in PR #41; a code change to add a version field is the next step.
3. **No automated architectural contract enforcement** (Scenarios 10, 20) —
   AGENTS.md has contracts but CI does not enforce all of them.
4. **UserDefaults has no backup** (Scenario 13) — the RetiredPreferences
   pattern partially mitigates this.

---

## Second-order review

Could any existing resilience mechanism itself create:

### Excessive complexity

**No.** The existing mechanisms (atomic writes, write-order recovery,
salvage path, migration tests) are simple and well-contained. Each is a
few lines of code in a focused module.

### False confidence

**Partial risk.** The standing migration tests could create false
confidence that any Codable change is safe. The tests cover specific
regressions, not all possible Codable changes. A new non-optional field
would be caught, but a removed field would not (documented in
ForwardCompatibilityTests, PR #41).

### Maintenance burden

**Low.** The migration tests are self-contained and do not require
maintenance beyond adding new test cases when the model changes. The
diagnostics log is bounded. The CI workflows are standard GitHub Actions.

### Test brittleness

**Low risk.** The migration tests use fixed JSON fixtures that represent
real old-format archives. They do not depend on live services or random
data. The only brittleness risk is if the `Conversation` or `Message`
struct changes in a way that makes the old fixtures invalid — but that
is exactly what the tests are designed to catch.

### Operational fragility

**None.** The resilience mechanisms do not introduce operational
dependencies. They are all local to the app or the repo.

---

## What we would deeply regret not creating

While powerful Perplexity Computer access is temporarily available:

1. **START_HERE.md (PR #47)** — Without this, every new engineer or agent
   must discover the architecture by reading code. This is the single
   highest-leverage documentation.

2. **Architecture Decision Records (PR #53)** — Without these, important
   decisions can be casually undone without understanding their
   consequences. The rationale for "phone never server", "Keychain
   update-then-add", "additive migrations" and "Codable backward
   compatibility" would be lost.

3. **Migration and data integrity documentation (PR #41)** — Without this,
   a future agent could introduce a non-optional Codable field and erase
   conversations again. The documentation and the forward-compatibility
   test are the guardrails.

4. **SPOF audit (PR #44)** — Without this, the human knowledge
   concentration is invisible. The audit makes it explicit and
   actionable.

5. **Observability documentation (PR #42)** — Without this, debugging a
   failure requires reproducing everything manually. The diagnostic
   bundle makes it possible to hand a coding agent the state it needs.

6. **Schema version on conversation records** — Not yet implemented. This
   is the next code change after the documentation PRs are merged. It
   would prevent downgrade data loss and enable explicit migration
   logic for breaking schema changes.

7. **Architectural contract tests** — Not yet implemented. Tests that
   verify the home chat always uses the main profile, that bot chats
   carry their own profile, and that conversations are never silently
   rerouted. These would catch architectural violations in CI.

The first five are already in draft PRs. The last two are the highest-
leverage code changes that would follow.
