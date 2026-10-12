"""ASR cutover must never reinterpret old Hermes checkout approval as consent."""
from __future__ import annotations

import importlib.util
import os
import tempfile
import threading
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
        with tempfile.TemporaryDirectory(prefix="alice-r02-cutover-") as temporary, \
                patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
            home = Path(temporary)
            self.assertTrue(errands.legacy_payment_blocked())
            self.assertFalse(errands.request_checkout(home, "old-job", {})["ok"])
            self.assertIsNone(errands.decide_checkout(
                home, "old-job", True, checkout_id="old-approved-checkout"))
            self.assertIsNone(errands.approved_checkout({"checkout": {
                "id": "old-approved-checkout", "status": "approved"}}))
            self.assertFalse(errands.request_card(home, "old-job", "https://shop.example")["ok"])
            decision = errands.pay_gate(home, "old-session",
                                        card_fill_site="https://shop.example")
            self.assertEqual(decision["action"], "block")
            self.assertFalse(errands.resume(
                home, "old-job",
                errands.APPROVED_PREFIX + " injected old checkout"))
            self.assertIsNone(purchases.open_payment(home, "old-session"))
            self.assertTrue((home / ".alice" / "r02-asr-only-v1").exists())

    def test_asr_flag_is_explicit_not_inferred_from_an_untrusted_checkout(self):
        errands = load("r02_default_errands", "errands.py")
        with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}):
            self.assertFalse(errands.legacy_payment_blocked())

    def test_persistent_cutover_prevents_legacy_purchase_restart_even_without_flag(self):
        errands = load("r02_recovery_guarded_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-restart-") as directory:
            home = Path(directory)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
                self.assertTrue(errands.legacy_payment_blocked(home))
            # Simulate deploy/restart where an operator forgot to set the env.
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}):
                self.assertTrue(errands.legacy_payment_blocked(home))
                pending = {"id": "buy-1", "status": "working",
                           "offer": {"option_id": "sku-1"}, "request": "Comprar zapatillas",
                           "run_id": "still-running-1"}
                unrelated = {"id": "study-1", "status": "working",
                             "request": "Leer un documento"}
                with patch.object(errands, "listing", return_value=[pending, unrelated]), \
                        patch.object(errands, "launch", return_value=True) as launch, \
                        patch.object(errands, "Gateway") as gateway, \
                        patch.object(errands, "update") as update:
                    gateway.return_value.status.return_value = {"status": "cancelled"}
                    self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                    launch.assert_not_called()
                    gateway.return_value.stop.assert_called_once_with("still-running-1")
                    self.assertEqual(update.call_count, 2)
                    self.assertFalse(update.call_args_list[0].kwargs["cutover_stop_pending"])
                with patch.object(errands, "get", return_value=pending):
                    self.assertFalse(errands.launch(home, "buy-1"))
                blocked = errands.start(home, {"task": "Comprar zapatillas"}, offer={"option_id": "sku-1"})
                self.assertFalse(blocked["ok"])
                # Synonyms/no purchase metadata cannot evade the fence.
                self.assertFalse(errands.start(
                    home, {"task": "Encárgame dos bolsas de pienso"})["ok"])
                self.assertFalse(errands.start(
                    home, {"task": "Leer un documento"})["ok"])
                self.assertIsNone(errands.approved_checkout({"checkout": {
                    "status": "approved", "decided_at": 9999999999}}, home=home))

    def test_inflight_legacy_hermes_run_is_stopped_on_cutover_without_restarting(self):
        errands = load("r02_inflight_guarded_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-inflight-") as directory:
            home = Path(directory)
            entry = {"id": "old-job", "status": "working", "run_id": "running-legacy-1",
                     "request": "Consígueme el teclado", "model": "mock", "provider": "mock"}
            stopped, updates = [], []
            engine = object.__new__(errands.Engine)
            engine.home, engine.errand_id = home, "old-job"
            engine.gateway = __import__("types").SimpleNamespace(
                stop=lambda run_id: stopped.append(run_id),
                status=lambda _run_id: self.fail("no Hermes status after cutover"))
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "get", return_value=entry), \
                    patch.object(errands, "update", side_effect=lambda *_a, **kw:
                                 updates.append(kw)), \
                    patch.object(errands, "arm_cutover_reaper"):
                self.assertEqual(engine.run(), "stuck")
            self.assertEqual(stopped, ["running-legacy-1"])
            self.assertEqual(updates[0]["status"], "stuck")
            self.assertIn("desconocido", updates[0]["reason"])

    def test_cutover_during_existing_hermes_run_stops_without_any_payment_approval(self):
        errands = load("r02_poll_guarded_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-midflight-") as directory:
            home = Path(directory)
            entry = {"id": "old-job", "status": "working", "run_id": "running-legacy-1",
                     "request": "Consígueme el teclado",
                     "model": "mock", "provider": "mock"}
            stopped, approved, statuses, updates = [], [], [], []
            engine = object.__new__(errands.Engine)
            engine.home, engine.errand_id = home, "old-job"
            engine.gateway = __import__("types").SimpleNamespace(
                stop=lambda run_id: stopped.append(run_id),
                status=lambda run_id: statuses.append(run_id) or {"status": "running"},
                approve=lambda *a: approved.append(a))
            engine.sleep = lambda _: os.environ.__setitem__("ALICE_R02_ASR_ONLY", "yes")
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "get", return_value=entry), \
                    patch.object(errands, "update", side_effect=lambda *_a, **kw:
                                 updates.append(kw)), \
                    patch.object(errands, "arm_cutover_reaper"):
                self.assertEqual(engine._wait_run("running-legacy-1")["status"], "cancelled")
            self.assertEqual(statuses, ["running-legacy-1"])
            self.assertEqual(stopped, ["running-legacy-1"])
            self.assertEqual(approved, [])
            self.assertEqual(updates[0]["status"], "stuck")

    def test_persisted_remote_stop_is_retried_until_terminal_status_is_attested(self):
        errands = load("r02_remote_reaper_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-unverified-stop-") as directory:
            home = Path(directory)
            entry = {"id": "old-job", "status": "working",
                     "run_id": "persistent-old-run", "request": "Encárgame pienso"}
            updates = []
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "listing", return_value=[entry]) as listing, \
                    patch.object(errands, "Gateway") as gateway, \
                    patch.object(errands, "update", side_effect=lambda *_a, **kw:
                                 updates.append(kw)), \
                    patch.object(errands.time, "time", return_value=1_000):
                gateway.return_value.stop.return_value = None
                gateway.return_value.status.return_value = {"status": "running"}
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                self.assertTrue(updates[-1]["cutover_stop_pending"])
                self.assertEqual(updates[-1]["status"], "stuck")
                gateway.return_value.stop.assert_called_once_with("persistent-old-run")
            # A gateway timeout/unconfirmed stop is NOT a terminal receipt.
            entry = {**entry, "status": "stuck", "cutover_stop_pending": True,
                     "cutover_stop_attempt_at": 1_000}
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "listing", return_value=[entry]), \
                    patch.object(errands, "Gateway") as gateway, \
                    patch.object(errands, "update", side_effect=lambda *_a, **kw:
                                 updates.append(kw)), \
                    patch.object(errands.time, "time", return_value=1_031):
                gateway.return_value.status.return_value = {"status": "cancelled"}
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                gateway.return_value.stop.assert_called_once_with("persistent-old-run")
                self.assertFalse(updates[-1]["cutover_stop_pending"])

    def test_live_cutover_reaper_retries_without_process_restart(self):
        errands = load("r02_scheduler_guarded_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-periodic-stop-") as directory:
            home = Path(directory)
            ticks = []
            observed = threading.Event()

            def scheduled(path, *, arm_reaper=True):
                self.assertEqual(path.resolve(), home.resolve())
                self.assertFalse(arm_reaper)
                ticks.append(1)
                if len(ticks) >= 2:
                    observed.set()
                return []

            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "ensure_running", side_effect=scheduled):
                try:
                    self.assertTrue(errands.arm_cutover_reaper(home, interval=0.02))
                    self.assertFalse(errands.arm_cutover_reaper(home, interval=0.02))
                    self.assertTrue(observed.wait(timeout=1.0))
                finally:
                    errands.stop_cutover_reaper(home)
            self.assertGreaterEqual(len(ticks), 2)


if __name__ == "__main__":
    unittest.main()
