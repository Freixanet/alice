"""ASR cutover must never reinterpret old Hermes checkout approval as consent."""
from __future__ import annotations

import importlib.util
import os
import tempfile
import threading
import unittest
import urllib.error
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import Mock, patch


def load(name: str, filename: str):
    path = Path(__file__).resolve().parents[1] / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class R02NoLegacyPaymentFallback(unittest.TestCase):
    def test_missing_known_run_id_is_not_permission_to_restart_native_tools(self):
        errands = load("r02_404_run_status", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-lost-status-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional task", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="working", run_id="accepted-original-run", runs=1)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.side_effect = urllib.error.HTTPError(
                "https://localhost/v1/runs/accepted-original-run", 404, "missing", {}, None)
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    judge=lambda *_: self.fail("unknown must not be judged"),
                                    sleep=lambda _: None)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}):
                self.assertEqual(engine.run("please continue"), "stuck")
                self.assertEqual(engine.run(), "stuck")
            gateway.start.assert_not_called()
            saved = errands.get(home, entry["id"])
            self.assertTrue(saved["run_status_uncertain"])
            self.assertEqual(saved["status"], "stuck")

    def test_new_run_accepted_then_404_never_triggers_a_second_run(self):
        errands = load("r02_accepted_then_lost_run", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-after-accepted-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional only", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.durable_run_idempotency.return_value = False
            gateway.start.return_value = "accepted-fictional-run"
            gateway.status.side_effect = urllib.error.HTTPError(
                "https://localhost/v1/runs/accepted-fictional-run", 404, "missing", {}, None)
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    judge=lambda *_: {"should_continue": True},
                                    sleep=lambda _: None)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                 patch.object(errands, "prepare_browser", return_value=True):
                self.assertEqual(engine.run("start"), "stuck")
            gateway.start.assert_called_once()
            self.assertTrue(errands.get(home, entry["id"])["run_status_uncertain"])

    def test_failed_fsync_prevents_any_remote_start(self):
        errands = load("r02_fsync_blocks_dispatch", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-crash-before-run-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional only", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.durable_run_idempotency.return_value = True
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    judge=lambda *_: {"status": "done"}, sleep=lambda _: None)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                 patch.object(errands, "prepare_browser", return_value=True), \
                 patch.object(errands.os, "fsync", side_effect=OSError("fictional durability fault")):
                with self.assertRaises(OSError):
                    engine.run("start")
            gateway.start.assert_not_called()

    def test_stop_is_not_confirmed_when_hermes_still_reports_running(self):
        errands = load("r02_stop_verification", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-stop-verify-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional task", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="working", run_id="active-fictional-run")
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "running"}
            with patch.object(errands, "Gateway", return_value=gateway), \
                    patch.object(errands, "release_context"), \
                    patch.object(errands, "_goal_manager"):
                pending = errands.stop(home, entry["id"])
                self.assertEqual(pending["status"], "stuck")
                self.assertTrue(pending["cutover_stop_pending"])
                gateway.status.return_value = {"status": "cancelled"}
                verified = errands.stop(home, entry["id"])
                self.assertEqual(verified["status"], "stopped")
                self.assertFalse(verified["cutover_stop_pending"])

    def test_write_failure_before_rename_preserves_existing_fence(self):
        errands = load("r02_fsync_barrier", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-durable-fence-") as temporary:
            path = Path(temporary) / "errands.json"
            errands._write(path, [{"id": "before", "run_start_uncertain": True}])
            with patch.object(errands.os, "fsync", side_effect=OSError("synthetic durable write failure")):
                with self.assertRaises(OSError):
                    errands._write(path, [{"id": "after", "run_start_uncertain": False}])
            self.assertEqual(errands._read(path, strict=True),
                             [{"id": "before", "run_start_uncertain": True}])
            self.assertFalse(list(path.parent.glob(".errands.*")))

    def test_pinned_hermes_gateway_durable_idempotency_feature_gate(self):
        errands = load("r02_pinned_run_idempotency", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-idempotency-") as directory:
            gateway = errands.Gateway(Path(directory))
            with patch.object(gateway, "_call", return_value={
                    "features": {"runs_idempotency": {"supported": True, "durable": True}}}) as remote:
                self.assertTrue(gateway.durable_run_idempotency())
                remote.assert_called_once_with("GET", "/v1/capabilities")
            for flags in ({}, {"runs_idempotency": {"supported": True, "durable": False}},
                          {"runs_idempotency": {"supported": False, "durable": True}}):
                with patch.object(gateway, "_call", return_value={"features": flags}):
                    self.assertFalse(gateway.durable_run_idempotency())
            with patch.object(gateway, "_call", return_value={"run_id": "run_fixture"}) as remote:
                key = "A" * 43
                self.assertEqual(gateway.start(
                    "session", "fixture text", model="fixture-model", provider="fixture",
                    idempotency_key=key), "run_fixture")
                remote.assert_called_once_with(
                    "POST", "/v1/runs",
                    {"input": "fixture text", "session_id": "session",
                     "model": "fixture-model", "provider": "fixture"},
                    headers={"Idempotency-Key": key})
            with self.assertRaises(ValueError):
                gateway.start("session", "text", model="fixture-model",
                              provider="fixture", idempotency_key="bad header\r\n")

    def test_lost_response_persists_durable_request_identity_without_auto_replay(self):
        errands = load("r02_durable_lost_start", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-durable-start-") as directory:
            home = Path(directory)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            entry = errands._new_entry("Fictional only", now=1000, model_route={
                "model": "fictional-model", "provider": "fixture"})
            errands._write(archive, [entry])
            attempts = []

            class DurableFake:
                def durable_run_idempotency(self):
                    return True

                def start(self, session_id, text, *, model, provider, idempotency_key):
                    attempts.append((session_id, text, model, provider, idempotency_key))
                    raise TimeoutError("simulated accepted request with lost reply")

            engine = object.__new__(errands.Engine)
            engine.home, engine.errand_id = home, entry["id"]
            engine.gateway = DurableFake()
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "prepare_browser", return_value=True):
                self.assertEqual(engine.run("fictional first attempt"), "stuck")
                after = errands.get(home, entry["id"])
                self.assertTrue(after["run_start_uncertain"])
                self.assertRegex(after["run_start_key"], r"^[A-Za-z0-9_-]{32,128}$")
                self.assertEqual(after["run_start_key"], attempts[0][-1])
                self.assertEqual(after["run_start_payload"], {
                    "session_id": entry["session_id"], "text": "fictional first attempt",
                    "model": entry["model"], "provider": entry["provider"]})
                # This is a future *manual* recovery identifier, never an
                # authorization to relaunch a potentially payment-capable run.
                errands.update(home, entry["id"], status="working")
                self.assertEqual(engine.run("another"), "stuck")
                self.assertEqual(len(attempts), 1)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                self.assertTrue(errands.get(home, entry["id"])["cutover_stop_pending"])

    def test_cutover_created_between_initial_check_and_dispatch_cannot_start_run(self):
        errands = load("r02_admission_cutover_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-admission-") as directory:
            home = Path(directory)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            entry = errands._new_entry(
                "Fictional", now=1_000,
                model_route={"model": "fixture-model", "provider": "fixture"})
            errands._write(archive, [entry])
            gateway = __import__("unittest.mock", fromlist=["Mock"]).Mock()
            engine = object.__new__(errands.Engine)
            engine.home, engine.errand_id, engine.gateway = home, entry["id"], gateway
            real_barrier = errands._cutover_admission_lock

            @contextmanager
            def marker_arrives(path):
                with real_barrier(path):
                    (Path(path) / ".alice" / "r02-asr-only-v1").write_text("fixture cutover")
                    yield

            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "prepare_browser", return_value=True), \
                    patch.object(errands, "_cutover_admission_lock", marker_arrives), \
                    patch.object(errands, "arm_cutover_reaper"):
                self.assertEqual(engine.run("before marker"), "stuck")
            gateway.start.assert_not_called()
            self.assertEqual(errands.get(home, entry["id"])["status"], "stuck")

    def test_cutover_marker_writer_waits_for_inflight_run_admission_barrier(self):
        errands = load("r02_admission_serial_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-lock-") as directory:
            home = Path(directory)
            entered, finished = threading.Event(), threading.Event()

            def enable_marker():
                with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
                    entered.set()
                    errands.legacy_payment_blocked(home)
                    finished.set()

            with errands._cutover_admission_lock(home):
                worker = threading.Thread(target=enable_marker, daemon=True)
                worker.start()
                self.assertTrue(entered.wait(timeout=1))
                self.assertFalse(finished.wait(timeout=0.03))
            worker.join(timeout=1)
            self.assertTrue(finished.is_set())
            self.assertTrue((home / ".alice" / "r02-asr-only-v1").is_file())

    def test_lost_hermes_run_start_reply_is_fenced_across_restart_and_cutover(self):
        """A remote run may exist without a locally observed run_id."""
        errands = load("r02_uncertain_start_errands", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-lost-start-") as directory:
            home = Path(directory)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            entry = errands._new_entry(
                "Fictional task", now=1_000,
                model_route={"model": "fixture-model", "provider": "fixture"})
            errands._write(archive, [entry])
            accepted = []

            class AcceptedButReplyLost:
                def start(self, session_id, text, **_):
                    accepted.append((session_id, text))
                    raise TimeoutError("accepted by Hermes; reply dropped")

            engine = object.__new__(errands.Engine)
            engine.home, engine.errand_id = home, entry["id"]
            engine.gateway = AcceptedButReplyLost()
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "prepare_browser", return_value=True):
                self.assertEqual(engine.run("first run"), "stuck")
                uncertain = errands.get(home, entry["id"])
                self.assertTrue(uncertain["run_start_uncertain"])
                self.assertFalse(uncertain["run_id"])
                # Recreating an engine, even if a caller resets working, cannot
                # launch another native-tool run into the same Hermes session.
                errands.update(home, entry["id"], status="working")
                self.assertEqual(engine.run("restart attempt"), "stuck")
                self.assertEqual(len(accepted), 1)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}):
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                persisted = errands.get(home, entry["id"])
                self.assertTrue(persisted["cutover_stop_pending"])
                self.assertTrue(persisted["run_start_uncertain"])
                stopped = errands.stop(home, entry["id"])
                self.assertNotEqual(stopped["status"], "stopped")
                self.assertTrue(stopped["cutover_stop_pending"])

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
