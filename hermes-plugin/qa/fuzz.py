"""Combinations of faults nobody wrote a scenario for, from a seed anyone can replay.

Each seed draws a shop and two or three faults (`sim.FAULTS`), runs the whole purchase, and keeps
any invariant the oracle saw broken. A failing combination is shrunk to the fewest faults that
still break the same invariant, and written as a regression test (red until fixed) in
`hermes-plugin/tests/test_qa_regressions.py`.
"""
from __future__ import annotations

import random
from pathlib import Path
from typing import Any, Callable, Dict, List, Sequence, Tuple

import sim

REGRESSIONS = Path(__file__).resolve().parents[1] / "tests" / "test_qa_regressions.py"
HEADER = '''"""Combinations of faults the QA fuzz found breaking an invariant (hermes-plugin/qa/fuzz.py).

Written by `python scripts/qa.py fuzz`; each stays as a guard once fixed. Skipped without jsdom.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qa"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import shops  # noqa: E402

JSDOM = shops.jsdom_available()


@unittest.skipUnless(JSDOM, "node with jsdom is needed")
class FuzzRegressions(unittest.TestCase):
    def check(self, shop, faults):
        import sim
        report = sim.run(shop, faults)
        self.assertEqual(report["findings"], [], report["events"][-20:])
'''


def draw(seed: int) -> Tuple[str, Tuple[str, ...]]:
    rng = random.Random(seed)
    shop = rng.choice(sorted(sim.CASES))
    faults = tuple(sorted(rng.sample(sim.FAULTS, rng.choice((2, 2, 3)))))
    return shop, faults


def keys(findings: List[Dict[str, Any]]) -> set:
    return {f["invariant"] for f in findings}


def shrink(shop: str, faults: Sequence[str], broken: set, runner: Callable = sim.run) -> Tuple[str, ...]:
    """The fewest faults that still break one of the same invariants."""
    current = tuple(faults)
    changed = True
    while changed and len(current) > 1:
        changed = False
        for fault in current:
            smaller = tuple(f for f in current if f != fault)
            if keys(runner(shop, smaller)["findings"]) & broken:
                current, changed = smaller, True
                break
    return current


def write_regression(shop: str, faults: Sequence[str], seed: int, path: Path = REGRESSIONS) -> bool:
    """Adds one test for this combination; False if it is already there."""
    name = "test_" + shop.split(".")[0].replace("-", "_") + "__" + "__".join(faults)
    text = path.read_text(encoding="utf-8") if path.exists() else HEADER
    if f"def {name}(" in text:
        return False
    text = text.rstrip("\n") + f"\n\n    def {name}(self):\n        # seed {seed}\n        self.check({shop!r}, {tuple(faults)!r})\n"
    path.write_text(text, encoding="utf-8")
    return True


def fuzz(seeds: Sequence[int], write: bool = True, runner: Callable = sim.run, log: Callable = print) -> List[Dict[str, Any]]:
    found: List[Dict[str, Any]] = []
    for seed in seeds:
        shop, faults = draw(seed)
        report = runner(shop, faults)
        if not report["findings"]:
            log(f"  ok   seed {seed}: {shop} {'+'.join(faults)}")
            continue
        broken = keys(report["findings"])
        minimal = shrink(shop, faults, broken, runner)
        log(f"  FAIL seed {seed}: {shop} {'+'.join(faults)} → mínimo {'+'.join(minimal)} ({', '.join(sorted(broken))})")
        written = write_regression(shop, minimal, seed) if write else False
        found.append({"seed": seed, "shop": shop, "faults": list(faults), "minimal": list(minimal),
                      "findings": report["findings"], "regression_written": written})
    return found
