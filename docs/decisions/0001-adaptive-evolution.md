# ADR 0001: Evolve Alice without a fixed feature roadmap

- **Status:** Proposed (pending review/merge of the adopting PR)
- **Date:** 2026-10-11
- **Scope:** Engineering process and product evolution
- **Supersedes:** None

## Context

Alice is an iOS-first personal Hermes companion developed in public, both to
serve its user and eventually other people and to demonstrate engineering
quality. New opportunities often originate in competing products, research,
standards and fast-changing AI capabilities. A prescriptive feature roadmap
would age quickly. Separately, work across multiple agents and sessions risks
losing architectural rationale even when Git history is preserved.

Existing sources — AGENTS.md, architecture/verification docs, tests, PRs and an
execution ledger — are valuable but serve different purposes. An operational
session log is not a durable product contract; a passing CI run is not proof
that a personal Hermes installation has received a change.

## Decision

Use **continuous product evolution with a living architecture**:

- No mandatory feature roadmap. Evaluate opportunities by user value, technical
  quality, maintainability, open-source benefit and portfolio demonstration.
- Keep a short shared agent entry point and task-relevant documentation beside
  code. Reuse existing architecture and verification documents.
- For substantial behavior changes, maintain current, observable specifications
  (OpenSpec when useful). Preserve important design rationale with short ADRs.
- **All prior designs are revisable.** Changing or removing a past guarantee is
  allowed if it is explicit, justified and evaluated with tests/evidence.
- Match process depth to risk. Local fixes need no ceremony; migration,
  payments, identity or irreversible changes need more.
- Keep proposed, committed, merged, deployed and personally installed states
  distinct. Never assume the latest GitHub commit is the personal runtime.
- Favor deterministic tests/checks for enforceable contracts; context files
  cannot guarantee correctness. Make work portable between agent tools.

## Alternatives considered

- **Single giant AGENTS.md or execution ledger:** easiest initially, but grows
  stale, duplicates facts and overwhelms new sessions.
- **Fixed feature roadmap and mandatory full specs for every edit:** too rigid
  for an experimental project driven by fast-changing opportunities.
- **Unstructured chat memory alone:** not durable, versioned or portable.
- **Freeze architecture/contracts:** avoids some accidental changes but blocks
  legitimate improvements and refactors.

## Consequences

+ Agents can reconstruct relevant intent and revise technical choices.
+ New contributors can understand why a component exists.
+ Important tests and documentation can evolve with the product.
- Decisions/specifications need light maintenance and may become stale.
- Human and automated reviews still cannot guarantee absence of regressions.
- Public docs must not expose private installation or security evidence.

## Verification and next steps

Pilot this approach on a real, low-risk Alice change with at least two different
agents. Check whether each can reconstruct the affected contract and old
rationale without chat history, update the code and leave aligned documentation.
Evaluate the real effort and token overhead before making OpenSpec skills
mandatory or introducing any other orchestration framework.

**Revisit when:** repeated divergence between docs and code, agent setup
overhead, contribution needs or new industry tooling suggests a simpler or
more reliable approach.
