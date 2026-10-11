# Evolving Alice without losing context

Alice has no fixed feature roadmap. It is an iOS-first, open-source-in-progress
personal agent companion, built in public as both a useful product and a
demonstration of strong engineering. Priorities may change with experiments,
users, competition, new AI models and industry standards. This document describes
**how to evolve well**, not **what to build next**.

## Where the truth lives

| Question                                        | Primary reference                                                                                                       |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| How should any coding agent work here?          | [AGENTS.md](../AGENTS.md)                                                                                               |
| How do components and identities interact?      | [Architecture](architecture.md)                                                                                         |
| What behavior is expected and how is it tested? | [Verification](verification.md), [compatibility](compatibility-matrix.md), tests; OpenSpec specs once present           |
| Why was an important design selected?           | [Decision records](decisions/README.md), linked PRs and evidence                                                        |
| What change is being considered or implemented? | A small PR; optionally `openspec/changes/<change>/` for significant behavioral work                                     |
| What is actually running?                       | Git commit, deployment status and **separately** the installation/runtime inventory; never infer the latter from GitHub |
| What happened during an agent session?          | Execution ledger if available to that agent, PR/CI records, evidence archives; this history is **not** a specification  |

The execution ledger may live outside this public repository and contain
private operational facts. Do not copy local paths, tokens, personal sessions,
private security reproductions, or installation inventories into public docs.
An unavailable ledger is a limitation to report, not a reason to invent its contents.

## Historical examples and evidence boundaries

- **Checkout approval recovery (U1):** [PR #69](https://github.com/Freixanet/alice/pull/69)
  ties a recovered approval to the checkout observed when the decision was
  captured. Recovery, retries and concurrent replacements must not transfer a
  payment decision to another checkout or replay a consumed decision. See
  `hermes-plugin/errands.py`, its tests and [purchases](purchases.md). The PR
  and tests establish the code change; they do not prove that a particular
  personal Hermes installation is running it or that payments are safe overall.
- **Browser action authorization (R02):** [PR #69](https://github.com/Freixanet/alice/pull/69)
  records an outstanding browser JavaScript authorization issue, separately
  from the checkout recovery addressed by U1. [PR #64](https://github.com/Freixanet/alice/pull/64)
  proposes additional safeguards but is not integrated into `main`. Neither
  proposal nor historical report proves complete coverage or current runtime
  status. Consult [architecture](architecture.md),
  [verification](verification.md) and the relevant browser/tool code before
  making a security claim. Detailed reproductions and current operational
  status may be private; an agent without access must say which facts it cannot
  verify. Green CI alone does not establish complete authorization coverage.

These are _examples of how to follow evidence_, not immutable design choices or
a standing task list. Replacements are welcome after affected guarantees and
their tests have been reconsidered.

## Scale process to the change

- **Small, local fix or UI polish:** inspect the relevant code and tests,
  implement, verify and report. No new spec or decision record unless a lasting
  contract/decision changes.
- **Feature or meaningful behavior change:** investigate existing flows and
  trade-offs, specify observable outcomes and important failure cases (OpenSpec
  where it adds value), implement and test. Specifications describe the **current
  intended behavior**, not a promised feature backlog.
- **Architectural, identity, security, persistence or migration change:** inspect
  dependencies, records and tests; compare real alternatives; write or supersede
  a short decision record; verify preserved and deliberately changed guarantees.
  This process still permits replacing the entire design when justified.
- **Experiment or competitive spike:** exploration is welcome without committing
  to ship. State what was learned and what remains uncertain; promote it to a
  spec only if we decide to build/keep it.

## Every coding agent's continuity loop

1. **Orient:** read [AGENTS.md](../AGENTS.md), find the affected modules and
   only the relevant architecture/decisions/specs. Check branch, base SHA,
   uncommitted and concurrent work; inspect installed/runtime differences if
   relevant and authorized.
2. **Explain:** identify the user outcome, current behavior, old rationale,
   contracts and relevant tests. Distinguish proven facts from assumptions.
3. **Change freely but deliberately:** improve, replace or retire designs if
   warranted. If an invariant must change, make that explicit rather than
   silently defeating the old tests or accepting a stale decision.
4. **Prove:** run appropriate focused and cross-surface tests; check data
   compatibility, security and recovery where affected. Never treat a passing
   unit test as proof of a live personal installation.
5. **Leave a usable trail:** update **only** specs/architecture/ADRs affected by
   the result, with PR/test evidence. Mark an old ADR `Superseded` rather than
   erasing its historical reasoning.
6. **Hand off in plain language:** what changed, why, what was verified, what
   remains unknown and whether it is only proposed, merged, deployed or
   personally installed.

The PR review should flag stale docs when changing a documented contract.
Documentation alone cannot prove compatibility; code/tests/CI enforce the
checks that can be automated. Agent-specific entry points such as
[CLAUDE.md](../CLAUDE.md) and Cursor rules defer to [AGENTS.md](../AGENTS.md).

## Optional OpenSpec workflow

[OpenSpec](https://openspec.dev/docs/quickstart) is available for meaningful
new capabilities or contract changes. This repo tracks project guidance in
[`openspec/config.yaml`](../openspec/config.yaml). That file **does not by
itself mean the OpenSpec CLI or agent skills are installed**.

When installed and initialized in an isolated checkout, use exploration before
committing to a direction, then proposal/spec/implementation as useful. After
shipping, sync/retire the completed change so today's specification stays
current. For trivial edits, use the existing PR+tests workflow without extra
artifacts. No global install, tool registration, or rewrite of existing history
is implied by adopting the configuration.

## What an excellent public portfolio should demonstrate

Keep useful engineering evidence visible: problem, reasoning, alternatives,
safety/compatibility constraints, relevant tests and measured outcomes. Do not
mistake a large feature count for product value, copy competitors blindly or
turn speculative ideas into mandatory milestones.

**Success condition:** a new agent with no chat history can locate the relevant
current contracts, understand why important decisions exist, improve them,
verify the result and leave the next agent with accurate context.
