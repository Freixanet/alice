# START HERE

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

You are about to work on **Alice**, a native iPhone app for a self-hosted
Hermes agent. Before touching any code, read these files in order.

## 1. Read the AI Agent Guide

**[docs/AI_AGENT_GUIDE.md](docs/AI_AGENT_GUIDE.md)** — the strict,
project-specific engineering guide. It tells you:

- what to inspect before modifying code
- how to find existing implementations
- implementation rules (smallest correct change, no parallel
  implementations, no duplicate state, no speculative abstractions)
- validation rules (what to run for each change type)
- stop conditions (when to stop editing and investigate)
- regression rules (how to diagnose without layering patches)
- refactor rules (when justified and when prohibited)
- dependency rules (when new packages are acceptable)
- the output contract (what to report when done)

**Read it first. Read it fully.**

## 2. Read the shared project instructions

**[AGENTS.md](AGENTS.md)** — contracts that must survive changes,
verification steps, the task checklist, and Alice-specific rules.

## 3. Read the architecture

**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — what Alice is and is
not, complete system architecture, repository map, data flows, sources of
truth, state management, persistence, networking, streaming, background
execution, authentication, known fragile areas, and historical decisions.

## 4. Read the verification system

**[docs/verification.md](docs/verification.md)** — what each test suite
proves and does not prove. And **[docs/VALIDATION_TIERS.md](docs/VALIDATION_TIERS.md)**
— proportional validation so you run only the checks your change needs.

## 5. Read the architecture contracts

**[docs/ARCHITECTURE_CONTRACTS.md](docs/ARCHITECTURE_CONTRACTS.md)** —
the invariants that must remain true for the system to stay coherent.

## 6. Read the failure learnings

**[docs/FAILURE_LEARNINGS.md](docs/FAILURE_LEARNINGS.md)** — historical
failures and the permanent protections derived from them.

## Quick reference

| What you need | Where to look |
|---------------|---------------|
| What Alice is | [README.md](README.md) |
| How to work on Alice | [docs/AI_AGENT_GUIDE.md](docs/AI_AGENT_GUIDE.md) |
| Project instructions | [AGENTS.md](AGENTS.md) |
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| System map | [docs/SYSTEM_MAP.md](docs/SYSTEM_MAP.md) |
| Data flows | [docs/DATA_FLOW.md](docs/DATA_FLOW.md) |
| Verification | [docs/verification.md](docs/verification.md) |
| Validation tiers | [docs/VALIDATION_TIERS.md](docs/VALIDATION_TIERS.md) |
| Architecture contracts | [docs/ARCHITECTURE_CONTRACTS.md](docs/ARCHITECTURE_CONTRACTS.md) |
| Known failures | [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md) |
| Failure learnings | [docs/FAILURE_LEARNINGS.md](docs/FAILURE_LEARNINGS.md) |
| Debugging | [docs/DEBUGGING.md](docs/DEBUGGING.md) |
| Dependencies | [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) |
| Release process | [docs/RELEASE.md](docs/RELEASE.md) |
| Operations | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Security | [SECURITY.md](SECURITY.md) |
| Setup | [SETUP.md](SETUP.md) |
| Environment | [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) |
| Regression matrix | [docs/REGRESSION_MATRIX.md](docs/REGRESSION_MATRIX.md) |

## The one question that matters most

_What evidence shows this change does what was asked and keeps what
already worked?_
