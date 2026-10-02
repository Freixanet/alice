"""The QA system tests itself: with an old bug put back, the simulator's oracle must see it.

Each mutation re-introduces a defect fixed in an earlier round (docs/purchase-audit-2026-10-01.md)
and runs the scenario that exercises it. If any passes unnoticed, the oracle is blind there and
`scripts/qa.py` cannot be trusted. Skipped without jsdom (`npm ci`).
"""
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qa"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import shops  # noqa: E402

JSDOM = shops.jsdom_available()


def patching(target_of, name, value):
    """A mutation: replace ``name`` on the object ``target_of(sim)`` for this run only."""
    return lambda sim: sim.stack.enter_context(mock.patch.object(target_of(sim), name, value))


@unittest.skipUnless(JSDOM, "node with jsdom is needed")
class OracleSeesOldBugs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sim
        cls.sim = sim

    def found(self, faults, mutation):
        report = self.sim.run("tienda-tres.example", faults, mutate=mutation)
        return {f["invariant"] for f in report["findings"]}, report

    def test_the_unmutated_plugin_is_clean_in_the_same_scenarios(self):
        for faults in ((), ("pay_twice",), ("outcome_never_written",), ("total_changed_before_paying",),
                       ("agent_pays_without_approval",), ("chrome_crash_before_paying",)):
            with self.subTest(faults=faults):
                found, report = self.found(faults, None)
                self.assertEqual(found, set(), report["findings"])

    def test_a_second_press_of_pay_is_seen(self):
        # Before: a press was written once and a second one went through (pay_twice).
        found, _ = self.found(("pay_twice",), patching(lambda s: s.plugin, "_note_payment", lambda root, entry, session: None))
        self.assertIn("I2", found)

    def test_an_errand_ending_with_a_payment_in_the_air_is_seen(self):
        # Before: «done» was accepted, or a stop claimed nothing about the payment (no unknown receipt).
        found, _ = self.found(("outcome_never_written",), patching(lambda s: s.errands, "close_unknown", lambda *a, **k: False))
        self.assertIn("I5", found)

    def test_paying_a_total_other_than_the_approved_one_is_seen(self):
        # Before: the gate trusted the approval and did not read the page's total again.
        found, _ = self.found(("total_changed_before_paying",), patching(lambda s: s.prices, "payment_ready", lambda *a, **k: True))
        self.assertIn("I1", found)

    def test_paying_without_any_approval_is_seen(self):
        # Two gates stand there (the approval and the page's total read again); both are removed to
        # prove the oracle itself watches, not only the plugin.
        def mutation(sim):
            sim.stack.enter_context(mock.patch.object(sim.errands, "pay_gate", lambda *a, **k: None))
            sim.stack.enter_context(mock.patch.object(sim.prices, "payment_ready", lambda *a, **k: True))
        found, _ = self.found(("agent_pays_without_approval",), mutation)
        self.assertIn("I1", found)

    def test_one_gate_alone_still_stops_a_payment_without_approval(self):
        # Defence in depth: with the approval gate gone, re-reading the total still refuses to pay.
        found, report = self.found(("agent_pays_without_approval",), patching(lambda s: s.errands, "pay_gate", lambda *a, **k: None))
        self.assertNotIn("I1", found, report["findings"])

    def test_paying_on_a_basket_read_in_a_lost_browser_context_is_seen(self):
        def mutation(sim):
            sim.stack.enter_context(mock.patch.object(sim.prices, "fresh_cart", lambda *a, **k: True))
            sim.stack.enter_context(mock.patch.object(sim.prices, "payment_ready", lambda *a, **k: True))
            sim.stack.enter_context(mock.patch.object(sim.errands, "context_lost", lambda *a, **k: None))
        found, _ = self.found(("chrome_crash_before_paying",), mutation)
        self.assertIn("I7", found)

    def test_an_answer_that_never_reaches_the_errand_is_seen(self):
        # Before: an approval given while the run was still going was lost (resume_message).
        found, _ = self.found((), patching(lambda s: s.errands, "approved_message", lambda checkout: "Sigue."))
        self.assertIn("I4", found)


if __name__ == "__main__":
    unittest.main()
