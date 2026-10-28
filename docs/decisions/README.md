# Engineering decisions

Short Architecture Decision Records (ADRs) explain important choices that a
future agent may need to reconsider. They are **history and rationale**, not
immutable instructions or a roadmap.

- [0001 — Adaptable development without a fixed feature roadmap](0001-adaptive-evolution.md)
- [0002 — Proposed R02 distributable Alice Secure Runner, without Hermes core changes (blocked)](0002-r02-executor-authority.md)

For a meaningful new decision, capture:

1. **Status** — Proposed, Accepted, Superseded (with replacement link) or Rejected.
2. **Context** — What problem and constraints existed? Cite code, issue or PR
   rather than duplicating large logs.
3. **Decision and alternatives** — What is chosen, what else was considered?
4. **Consequences and verification** — What improves, what it costs and which
   behaviors/tests/operational boundaries matter?
5. **Revisit when** — What new evidence would justify changing the decision?

Record only durable decisions. Minor fixes, experiments and routine UI polish
usually do not need an ADR. Supersede outdated records: never silently rewrite
their historical rationale. Keep private runtime details outside public Git.

When reviewing a PR that adopts or replaces a decision, check that the affected
ADR's status matches what actually happened; link the adopting PR or successor.
