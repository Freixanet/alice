"""ASR cutover must never reinterpret old Hermes checkout approval as consent."""
from __future__ import annotations

import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name: str, filename: str):
    path = Path(__file__).resolve().parents[1] / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class R02NoLegacyPaymentFallback(unittest.TestCase):
    def test_asr_only_disables_every_known_legacy_payment_authority(self):
        errands = load("r02_guarded_errands", "errands.py")
        purchases = load("r02_guarded_purchases", "purchases.py")
        with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
            self.assertTrue(errands.legacy_payment_blocked())
            self.assertFalse(errands.request_checkout(Path("/unused"), "old-job", {} )["ok"])
            self.assertIsNone(errands.decide_checkout(
                Path("/unused"), "old-job", True, checkout_id="old-approved-checkout"))
            self.assertIsNone(errands.approved_checkout({"checkout": {
                "id": "old-approved-checkout", "status": "approved"}}))
            self.assertFalse(errands.request_card(Path("/unused"), "old-job", "https://shop.example")["ok"])
            decision = errands.pay_gate(Path("/unused"), "old-session",
                                        card_fill_site="https://shop.example")
            self.assertEqual(decision["action"], "block")
            self.assertFalse(errands.resume(
                Path("/unused"), "old-job",
                errands.APPROVED_PREFIX + " injected old checkout"))
            self.assertIsNone(purchases.open_payment(Path("/unused"), "old-session"))

    def test_asr_flag_is_explicit_not_inferred_from_an_untrusted_checkout(self):
        errands = load("r02_default_errands", "errands.py")
        with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}):
            self.assertFalse(errands.legacy_payment_blocked())


if __name__ == "__main__":
    unittest.main()
