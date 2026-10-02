# QA protocol: how any agent finds and fixes what breaks a process

For Claude Code, Codex, Cursor or a person. One loop, one entry point, the same evidence.

## What exists

| Piece | Where | What it does |
| --- | --- | --- |
| Process maps | `qa/flows/*.yaml` | States, steps, invariants and faults of each process, and what proves each one (a test, a simulator scenario, or `gap: why`). |
| Simulator + oracle | `hermes-plugin/qa/sim.py`, `oracle.py` | The whole purchase with the real plugin, engine, routes and shop JavaScript; a scripted agent and person; every invariant checked after every event. |
| Fault catalogue + fuzz | `sim.FAULTS`, `hermes-plugin/qa/fuzz.py` | Each fault on each fixture shop; random combinations from replayable seeds, shrunk to the minimum, written as a regression test. |
| Static rules | `scripts/qa_static.py` | Fail-open guards, fixed ports, temp state, untested routes, undeclared tools, app↔plugin contract drift, false «nothing was paid», secrets in logs. |
| iOS contract | `hermes-plugin/tests/fixtures/errand_states.json` → `ios/AliceTests/ErrandContractTests.swift` | The errand states the simulator really produced, read by the app's tests. |
| iOS journey | `hermes-plugin/qa/serve.py` + `ios/AliceUITests/PurchaseJourneyTests.swift` | The app in the iOS simulator approves, accepts a new price and gets the order, against the simulator's dashboard. |
| Self-test | `hermes-plugin/tests/test_qa.py` | Old bugs put back must be caught; if not, the oracle is blind. |
| CI | `.github/workflows/qa.yml` | All of it on GitHub's free runners (public repo). Nothing heavy runs on the development Mac. |

## The loop

1. Work on a topic branch. Push it: `qa.yml` runs (or dispatch it with `seeds`, `fresh`, `ios`).
   Locally, only the fast parts: `npm ci`, then `python scripts/qa.py all`.
2. Read the report (`qa/reports/*.json`, or the `qa-reports` / `qa-ios` artifacts). Findings are
   ordered by severity: money (I1, I2) › secrets (I3) › lost state (I7) › a stop without a way out
   or a false sentence (I5) › a lost answer (I4) › no progress (P1) › cards (I6) › the rest.
3. For each finding, in that order:
   - reproduce it as a failing test (the fuzz already wrote one in `tests/test_qa_regressions.py`);
   - fix the **cause** — the gate, the state, the contract — never the symptom or the scenario;
   - decide whether the finding is the plugin's or the simulator's (a robot less careful or more
     careful than a real model, a fixture unlike a real shop). Fix the simulator too when it is
     wrong, and say so: a blind simulator is worse than none;
   - run `python scripts/qa.py all` again; it must be clean;
   - write one line in `qa/ledger.md`: finding, cause, fix, test.
4. Widen the map: a new state, fault or shop behaviour you met is work. Add it to the flow's
   YAML with what covers it, or `gap:` with why.
5. Stop when `qa.py all` is clean and two fuzz rounds from fresh seeds (`--fresh`) find nothing.
   Report as AGENTS.md says: checked (with evidence), not checkable here, remaining risk.

## Never

- weaken an assertion, delete a scenario, or add to `qa/known.yaml` to make a run green (an entry
  needs a reason, a date and who decided; closing the reason removes it);
- touch a person's real Hermes, their browser on port 9222, a real shop account or a payment;
- run levels 3 (a real model on fixture shops: `scripts/verify-purchase-complete.py --agent`) or
  4 (a real shop up to the pay step, never approving) without the person's explicit permission;
- run the iOS simulator on the development Mac (AGENTS.md); use the `qa-ios` job.

## Adding another process

Write `qa/flows/<process>.yaml` like `purchase.yaml`. `qa.py coverage` then checks every
reference in it exists and lists its gaps. A simulator is worth writing where a failure costs
money, a secret or the person's trust; elsewhere, map the existing tests and declare the gaps.
