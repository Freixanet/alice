"""ASR cutover must never reinterpret old Hermes checkout approval as consent."""
from __future__ import annotations

import importlib.util
import os
import tempfile
import threading
import time
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
    def test_cutover_fence_preserves_pending_stop_without_known_run_id(self):
        errands = load("r02_cutover_missing_run_identity", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-cutover-unknown-run-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="stuck", run_id="", run_status_uncertain=True,
                         cutover_stop_pending=True)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            engine = errands.Engine(home, entry["id"], gateway=gateway)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "arm_cutover_reaper") as reaper:
                self.assertTrue(engine._cutover_fence())
                reaper.assert_called_once_with(home)
            saved = errands.get(home, entry["id"])
            self.assertEqual(saved["status"], "stuck")
            self.assertTrue(saved["run_status_uncertain"])
            self.assertTrue(saved["cutover_stop_pending"])
            gateway.stop.assert_not_called()
            gateway.start.assert_not_called()

    def test_cutover_without_argument_stops_archived_active_run_not_completed_one(self):
        errands = load("r02_cutover_archived_run_identity", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-cutover-known-run-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="working", run_id="known-legacy-run")
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            engine = errands.Engine(home, entry["id"], gateway=gateway)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "arm_cutover_reaper"):
                self.assertTrue(engine._cutover_fence())
                gateway.stop.assert_called_once_with("known-legacy-run")
                self.assertTrue(errands.get(home, entry["id"])["cutover_stop_pending"])
                errands.update(home, entry["id"], status="done", cutover_stop_pending=False)
                self.assertTrue(engine._cutover_fence())
            self.assertEqual(errands.get(home, entry["id"])["status"], "done")
            gateway.stop.assert_called_once()

    def test_cutover_fences_active_run_despite_recent_stop_attempt(self):
        errands = load("r02_recent_stop_cannot_delay_cutover", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-active-recent-stop-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="working", run_id="still-running-legacy",
                         cutover_stop_pending=False, cutover_stop_attempt_at=time.time())
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "running"}
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "Gateway", return_value=gateway):
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
            saved = errands.get(home, entry["id"])
            self.assertEqual(saved["status"], "stuck")
            self.assertTrue(saved["cutover_stop_pending"])
            gateway.stop.assert_called_once_with("still-running-legacy")
            gateway.start.assert_not_called()

    def test_pending_stop_reaper_cannot_exit_between_final_check_and_new_arm(self):
        errands = load("r02_stop_reaper_exit_race", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-reaper-exit-race-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="stuck", run_id="pending-stop-1",
                         cutover_stop_pending=True, cutover_stop_attempt_at=1.0)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            entered, release = threading.Event(), threading.Event()
            original = errands._reconcile_pending_stops
            gateway = Mock()
            gateway.status.return_value = {"status": "cancelled"}

            def delayed_check(_home):
                if not entered.is_set():
                    entered.set()
                    self.assertTrue(release.wait(3))
                    # Simulate an old reaper considering itself finished even
                    # though a concurrent STOP is still durable in the ledger.
                    return False
                return original(_home)

            try:
                with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                        patch.object(errands, "Gateway", return_value=gateway), \
                        patch.object(errands, "_reconcile_pending_stops", side_effect=delayed_check):
                    self.assertTrue(errands.arm_pending_stop_reaper(home, interval=0.02))
                    self.assertTrue(entered.wait(2))
                    self.assertFalse(errands.arm_pending_stop_reaper(home, interval=0.02))
                    release.set()
                    deadline = time.monotonic() + 2
                    while (errands.get(home, entry["id"])["cutover_stop_pending"]
                           and time.monotonic() < deadline):
                        time.sleep(0.01)
                self.assertFalse(errands.get(home, entry["id"])["cutover_stop_pending"])
                gateway.stop.assert_called_once_with("pending-stop-1")
                gateway.start.assert_not_called()
            finally:
                release.set()
                errands.stop_pending_stop_reaper(home)

    def test_cutover_ignores_stale_stop_ack_after_new_status_uncertainty(self):
        errands = load("r02_cutover_stale_stop_ack", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-cutover-stale-ack-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="working", run_id="old-known-run")
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.stop.side_effect = lambda _id: errands.update(
                home, entry["id"], run_status_uncertain=True)
            gateway.status.return_value = {"status": "cancelled"}
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "Gateway", return_value=gateway):
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
            saved = errands.get(home, entry["id"])
            self.assertEqual(saved["status"], "stuck")
            self.assertTrue(saved["run_status_uncertain"])
            self.assertTrue(saved["cutover_stop_pending"])
            gateway.stop.assert_called_once_with("old-known-run")
            gateway.start.assert_not_called()

    def test_cutover_also_stops_stuck_run_with_uncertain_gateway_status(self):
        errands = load("r02_uncertain_status_cutover", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-uncertain-cutover-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="stuck", run_id="prior-known-run", run_status_uncertain=True)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "cancelled"}
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "Gateway", return_value=gateway):
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
            gateway.stop.assert_called_once_with("prior-known-run")
            saved = errands.get(home, entry["id"])
            self.assertEqual(saved["status"], "stuck")
            self.assertTrue(saved["cutover_stop_pending"])
            self.assertTrue(saved["run_status_uncertain"])
            gateway.start.assert_not_called()

    def test_stop_reaper_gateway_delay_does_not_hold_admission_lock(self):
        errands = load("r02_nonblocking_gateway_stop", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-nonblocking-stop-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="stuck", run_id="prior-known-run", cutover_stop_pending=True,
                         cutover_stop_attempt_at=1.0)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            entered, resume = threading.Event(), threading.Event()
            gateway = Mock()
            def blocked_stop(_run):
                entered.set()
                self.assertTrue(resume.wait(3), "gateway STOP was blocked")
            gateway.stop.side_effect = blocked_stop
            gateway.status.return_value = {"status": "cancelled"}
            failures = []
            def reaper():
                try:
                    errands._reconcile_pending_stops(home)
                except Exception as exc:
                    failures.append(exc)
            try:
                with patch.object(errands, "Gateway", return_value=gateway):
                    thread = threading.Thread(target=reaper)
                    thread.start()
                    self.assertTrue(entered.wait(2), "retry did not reach Gateway")
                    # While stop() is blocked on the network, unrelated
                    # admission mutations must complete promptly. Persist a
                    # NEW uncertainty flag so stale terminal reply cannot
                    # clear this run's pending stop.
                    started = time.monotonic()
                    with errands._cutover_admission_lock(home):
                        errands.update(home, entry["id"], run_status_uncertain=True)
                    self.assertLess(time.monotonic() - started, 1)
            finally:
                resume.set()
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            saved = errands.get(home, entry["id"])
            self.assertTrue(saved["cutover_stop_pending"])
            self.assertTrue(saved["run_status_uncertain"])
            self.assertNotEqual(saved["status"], "stopped")

    def test_surviving_stalled_run_never_starts_a_replacement(self):
        errands = load("r02_stalled_survivor", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-surviving-run-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="working", run_id="unverified-prior", runs=1)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "running"}
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    sleep=lambda _: None)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(engine, "_wait_run", return_value={"status": "stalled"}), \
                    patch.object(errands, "arm_pending_stop_reaper") as reaper:
                self.assertEqual(engine.run(), "stuck")
                reaper.assert_called_once_with(home)
            gateway.start.assert_not_called()
            saved = errands.get(home, entry["id"])
            self.assertTrue(saved["cutover_stop_pending"])
            self.assertEqual(saved["status"], "stuck")

    def test_stalled_run_with_queued_resume_does_not_override_stop(self):
        errands = load("r02_stall_queued_resume", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-stalled-message-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="working", resume_message="queued user message")
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.durable_run_idempotency.return_value = False
            gateway.start.return_value = "run-first"
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    sleep=lambda _: None)
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "prepare_browser", return_value=True), \
                    patch.object(engine, "_wait_run", return_value={"status": "stalled"}), \
                    patch.object(errands, "arm_pending_stop_reaper") as reaper:
                self.assertEqual(engine.run("start"), "stuck")
                reaper.assert_called_once_with(home)
            gateway.start.assert_called_once()
            self.assertTrue(errands.get(home, entry["id"])["cutover_stop_pending"])

    def test_live_manual_stop_reaper_never_launches_a_new_run(self):
        errands = load("r02_manual_stop_reaper", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-manual-stop-reaper-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="stuck", run_id="run-original",
                         cutover_stop_pending=True, cutover_stop_attempt_at=1.0)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "cancelled"}
            try:
                with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                        patch.object(errands, "Gateway", return_value=gateway):
                    self.assertTrue(errands.arm_pending_stop_reaper(home, interval=0.02))
                    self.assertFalse(errands.arm_pending_stop_reaper(home, interval=0.02))
                    deadline = time.monotonic() + 2
                    while (errands.get(home, entry["id"])["cutover_stop_pending"]
                           and time.monotonic() < deadline):
                        time.sleep(0.01)
                saved = errands.get(home, entry["id"])
                self.assertEqual(saved["status"], "stopped")
                self.assertFalse(saved["cutover_stop_pending"])
                gateway.start.assert_not_called()
                gateway.stop.assert_called_once_with("run-original")
            finally:
                errands.stop_pending_stop_reaper(home)

    def test_manual_reaper_never_trusts_terminal_old_id_for_unknown_new_run(self):
        errands = load("r02_manual_reaper_unknown_new", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-manual-stop-uncertain-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="stuck", run_id="old-known-run", run_start_uncertain=True,
                         cutover_stop_pending=True, cutover_stop_attempt_at=1.0)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "cancelled"}
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "Gateway", return_value=gateway):
                self.assertTrue(errands._reconcile_pending_stops(home))
            saved = errands.get(home, entry["id"])
            self.assertEqual(saved["status"], "stuck")
            self.assertTrue(saved["cutover_stop_pending"])
            self.assertTrue(saved["run_start_uncertain"])
            gateway.start.assert_not_called()

    def test_dashboard_approval_refuses_stale_or_pending_stop(self):
        errands = load("r02_dashboard_stop_gate", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-dashboard-approval-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="needs_approval", run_id="original-run",
                         approval={"run_id": "original-run", "request_id": "req-1",
                                   "command": "Login to fictional store"})
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.approve.return_value = True
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "Gateway", return_value=gateway):
                self.assertIsNone(errands.approve_pending_run_request(home, entry["id"], "once", "wrong"))
                self.assertIsNone(errands.approve_pending_run_request(home, entry["id"], "once", ""))
                gateway.approve.assert_not_called()
                approved = errands.approve_pending_run_request(home, entry["id"], "once", "req-1")
                self.assertEqual(approved["status"], "working")
                gateway.approve.assert_called_once_with("original-run", "once", "req-1")
                self.assertIsNone(errands.approve_pending_run_request(home, entry["id"], "once", "req-1"))
                errands.update(home, entry["id"], status="stuck", cutover_stop_pending=True,
                               approval={"run_id": "original-run", "request_id": "req-2"})
                self.assertIsNone(errands.approve_pending_run_request(home, entry["id"], "once", "req-2"))
                gateway.approve.assert_called_once()

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

    def test_late_manual_stop_ack_cannot_clear_new_uncertain_remote_run(self):
        errands = load("r02_stop_stale_ack", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-stale-stop-ack-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("fictional", now=1_000,
                                       model_route={"model": "fixture", "provider": "fixture"})
            entry.update(status="working", run_id="old-known-run")
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.return_value = {"status": "cancelled"}
            gateway.stop.side_effect = lambda _run: errands.update(
                home, entry["id"], run_status_uncertain=True)
            with patch.object(errands, "Gateway", return_value=gateway), \
                    patch.object(errands, "release_context"), \
                    patch.object(errands, "_goal_manager"), \
                    patch.object(errands, "arm_pending_stop_reaper"):
                result = errands.stop(home, entry["id"])
            self.assertTrue(result["cutover_stop_pending"])
            self.assertEqual(errands.get(home, entry["id"])["status"], "stuck")
            self.assertTrue(errands.get(home, entry["id"])["run_status_uncertain"])
            gateway.stop.assert_called_once_with("old-known-run")

    def test_stop_pending_prevents_delayed_reply_and_payment_approval(self):
        errands = load("r02_pending_stop_approval", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-stop-before-approval-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional only", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="stuck", cutover_stop_pending=True,
                         run_id="previous-fictional-run", run_status_uncertain=False,
                         checkout={"id": "old", "status": "approved",
                                   "decided_at": time.time()})
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    judge=lambda *_: self.fail("stop pending"),
                                    sleep=lambda _: None)
            engine._answer_approval("previous-fictional-run", {
                "request_id": "approved-before-stop",
                "command": "Fill payment card on https://fixture.invalid"})
            gateway.approve.assert_not_called()
            self.assertEqual(engine._wait_run("previous-fictional-run")["status"], "cancelled")
            gateway.status.assert_not_called()
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                 patch.object(errands, "launch") as launch:
                self.assertFalse(errands.resume(home, entry["id"], "late address answer"))
                launch.assert_not_called()
            self.assertTrue(errands.get(home, entry["id"])["cutover_stop_pending"])

    def test_stop_while_browser_prepares_prevents_new_native_run(self):
        errands = load("r02_stop_during_prepare", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-stop-before-start-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional only", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            engine = errands.Engine(home, entry["id"], gateway=gateway,
                                    judge=lambda *_: self.fail("stopped before dispatch"),
                                    sleep=lambda _: None)
            def stop_during_prepare(_home):
                errands.update(home, entry["id"], status="stuck",
                               cutover_stop_pending=True)
                return True
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                 patch.object(errands, "prepare_browser", side_effect=stop_during_prepare):
                self.assertEqual(engine.run("start"), "stuck")
            gateway.start.assert_not_called()

    def test_restart_retries_unverified_stop_without_restarting_run(self):
        errands = load("r02_retry_pending_stop", "errands.py")
        with tempfile.TemporaryDirectory(prefix="alice-r02-restart-stop-") as temporary:
            home = Path(temporary)
            entry = errands._new_entry("Fictional only", now=1_000,
                                       model_route={"model": "fixture-model", "provider": "fixture"})
            entry.update(status="stuck", run_id="possibly-active-run",
                         cutover_stop_pending=True)
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True)
            errands._write(archive, [entry])
            gateway = Mock()
            gateway.status.side_effect = [{"status": "running"}, {"status": "cancelled"}]
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                 patch.object(errands, "Gateway", return_value=gateway), \
                 patch.object(errands, "launch") as launch:
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                pending = errands.get(home, entry["id"])
                self.assertEqual(pending["status"], "stuck")
                self.assertTrue(pending["cutover_stop_pending"])
                # The ordinary stop reaper is throttled, never a busy loop.
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                self.assertEqual(gateway.stop.call_count, 1)
                errands.update(home, entry["id"], cutover_stop_attempt_at=0)
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                finished = errands.get(home, entry["id"])
                self.assertEqual(finished["status"], "stopped")
                self.assertFalse(finished["cutover_stop_pending"])
                launch.assert_not_called()

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
                archive = home / ".alice" / "errands.json"
                archive.parent.mkdir(parents=True, exist_ok=True)
                errands._write(archive, [pending, unrelated])
                with patch.object(errands, "launch", return_value=True) as launch, \
                        patch.object(errands, "Gateway") as gateway:
                    gateway.return_value.status.return_value = {"status": "cancelled"}
                    self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                    launch.assert_not_called()
                    gateway.return_value.stop.assert_called_once_with("still-running-1")
                    self.assertFalse(errands.get(home, "buy-1")["cutover_stop_pending"])
                    self.assertFalse(errands.get(home, "study-1")["cutover_stop_pending"])
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
            archive = home / ".alice" / "errands.json"
            archive.parent.mkdir(parents=True, exist_ok=True)
            errands._write(archive, [entry])
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "yes"}), \
                    patch.object(errands, "Gateway") as gateway, \
                    patch.object(errands.time, "time", return_value=1_000):
                gateway.return_value.stop.return_value = None
                gateway.return_value.status.return_value = {"status": "running"}
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                self.assertTrue(errands.get(home, "old-job")["cutover_stop_pending"])
                self.assertEqual(errands.get(home, "old-job")["status"], "stuck")
                gateway.return_value.stop.assert_called_once_with("persistent-old-run")
            # A gateway timeout/unconfirmed stop is NOT a terminal receipt.
            with patch.dict(os.environ, {"ALICE_R02_ASR_ONLY": "no"}), \
                    patch.object(errands, "Gateway") as gateway, \
                    patch.object(errands.time, "time", return_value=1_031):
                gateway.return_value.status.return_value = {"status": "cancelled"}
                self.assertEqual(errands.ensure_running(home, arm_reaper=False), [])
                gateway.return_value.stop.assert_called_once_with("persistent-old-run")
                self.assertFalse(errands.get(home, "old-job")["cutover_stop_pending"])

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
