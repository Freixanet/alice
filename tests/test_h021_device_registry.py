"""Disposable device public-key lifecycle. No real Apple device or biometrics."""

from __future__ import annotations

import base64
import subprocess
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from alice_secure_runner.coordinator import Coordinator, FictionalPlanner
from alice_secure_runner.core import AliceRunner, Denied, FictionalHTTPSAdapter, _canonical
from alice_secure_runner.device_registry import EnrollmentDenied, RevocableP256DeviceConsent
import test_alice_secure_runner as shop_tests


def _keypair(folder: Path, name: str) -> tuple[Path, str]:
    private = folder / (name + ".key")
    public = folder / (name + ".pub")
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey",
                    "-noout", "-out", str(private)], check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                   check=True, capture_output=True)
    return private, public.read_text(encoding="ascii")


def _sign(private: Path, payload: bytes, folder: Path) -> str:
    raw = folder / "message"
    signed = folder / "signed"
    raw.write_bytes(payload)
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private),
                    "-out", str(signed), str(raw)], check=True, capture_output=True)
    return base64.urlsafe_b64encode(signed.read_bytes()).decode().rstrip("=")


class DeviceRegistryContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alice-device-registry-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.path = self.folder / "enrollment.sqlite3"
        self.now = int(time.time())
        self.first, self.first_public = _keypair(self.folder, "first")
        self.second, self.second_public = _keypair(self.folder, "second")
        self.registry = RevocableP256DeviceConsent(self.path, clock=lambda: self.now)
        self.addCleanup(self.registry.close)

    def enroll(self):
        return self.registry.enroll(
            tenant="tenant-a", session="session-a", account="owner-a",
            installation="installation-a", public_pem=self.first_public,
            expires_at=self.now + 3600)

    def test_identity_tenant_session_key_rotation_and_revoke(self):
        self.assertEqual(self.enroll(), 1)
        payload = b'{"fictional":"exact checkout consent"}'
        old_sig = _sign(self.first, payload, self.folder)
        self.assertTrue(self.registry.verify(tenant="tenant-a", session="session-a",
                                             challenge=payload, signature=old_sig))
        for tenant, session, message in (
            ("tenant-b", "session-a", payload),
            ("tenant-a", "session-b", payload),
            ("tenant-a", "session-a", payload + b"x"),
        ):
            self.assertFalse(self.registry.verify(tenant=tenant, session=session,
                                                  challenge=message, signature=old_sig))
        with self.assertRaises(EnrollmentDenied):
            self.enroll()
        with self.assertRaises(EnrollmentDenied):
            self.registry.rotate(
                tenant="tenant-a", session="session-a", account="wrong-account",
                installation="installation-a", expected_version=1,
                public_pem=self.second_public, expires_at=self.now + 3600)
        self.assertEqual(self.registry.rotate(
            tenant="tenant-a", session="session-a", account="owner-a",
            installation="installation-a", expected_version=1,
            public_pem=self.second_public, expires_at=self.now + 3600), 2)
        self.assertFalse(self.registry.verify(tenant="tenant-a", session="session-a",
                                              challenge=payload, signature=old_sig))
        new_sig = _sign(self.second, payload, self.folder)
        self.assertTrue(self.registry.verify(tenant="tenant-a", session="session-a",
                                             challenge=payload, signature=new_sig))
        with self.assertRaises(EnrollmentDenied):
            self.registry.rotate(
                tenant="tenant-a", session="session-a", account="owner-a",
                installation="installation-a", expected_version=1,
                public_pem=self.first_public, expires_at=self.now + 3600)
        self.registry.revoke(tenant="tenant-a", session="session-a",
                             account="owner-a", expected_version=2)
        self.assertFalse(self.registry.verify(tenant="tenant-a", session="session-a",
                                              challenge=payload, signature=new_sig))
        reopened = RevocableP256DeviceConsent(self.path, clock=lambda: self.now)
        try:
            self.assertFalse(reopened.verify(tenant="tenant-a", session="session-a",
                                             challenge=payload, signature=new_sig))
        finally:
            reopened.close()

    def test_expiry_invalid_public_key_and_session_collision(self):
        with self.assertRaises(EnrollmentDenied):
            self.registry.enroll(
                tenant="tenant-a", session="session-a", account="owner-a",
                installation="install-a", public_pem=self.first.read_text(),
                expires_at=self.now + 3600)
        self.enroll()
        payload = b"challenge"
        sig = _sign(self.first, payload, self.folder)
        self.now += 3600
        self.assertFalse(self.registry.verify(tenant="tenant-a", session="session-a",
                                              challenge=payload, signature=sig))
        self.assertFalse(self.registry.verify(tenant="tenant-a", session="session-a",
                                              challenge=payload, signature="not_base64!"))

    def test_revocation_during_runner_callback_blocks_future_effect(self):
        self.enroll()
        message = b"fictional approval"
        signed = _sign(self.first, message, self.folder)
        second_connection = RevocableP256DeviceConsent(self.path, clock=lambda: self.now)
        self.addCleanup(second_connection.close)
        inside_grant = threading.Event()
        allow_grant = threading.Event()
        revoked = threading.Event()
        failures = []

        def grant(version, digest):
            self.assertEqual(version, 1)
            self.assertEqual(digest, __import__("hashlib").sha256(message).hexdigest())
            inside_grant.set()
            if not allow_grant.wait(4):
                raise AssertionError("timed out waiting for grant release")
            return "granted"

        def authorize():
            try:
                self.assertEqual(self.registry.authorize(
                    tenant="tenant-a", session="session-a", challenge=message,
                    signature=signed, on_valid=grant), "granted")
            except BaseException as exc:
                failures.append(exc)

        def revoke():
            try:
                second_connection.revoke(tenant="tenant-a", session="session-a",
                                         account="owner-a", expected_version=1)
                revoked.set()
            except BaseException as exc:
                failures.append(exc)

        approval_thread = threading.Thread(target=authorize)
        approval_thread.start()
        self.assertTrue(inside_grant.wait(4))
        revocation_thread = threading.Thread(target=revoke)
        revocation_thread.start()
        # The grant is committed BEFORE the runner callback, so revocation can
        # complete during callback. A stale signed grant must never dispatch.
        self.assertTrue(revoked.wait(4))
        allow_grant.set()
        approval_thread.join(timeout=5)
        revocation_thread.join(timeout=5)
        self.assertFalse(approval_thread.is_alive() or revocation_thread.is_alive())
        self.assertEqual(failures, [])
        self.assertTrue(revoked.is_set())
        self.assertFalse(self.registry.verify(tenant="tenant-a", session="session-a",
                                              challenge=message, signature=signed))
        with self.assertRaises(EnrollmentDenied):
            self.registry.guard_effect(
                tenant="tenant-a", session="session-a", expected_version=1,
                challenge_digest=__import__("hashlib").sha256(message).hexdigest(),
                on_valid=lambda: self.fail("revoked device attempted a checkout effect"))

    def test_grant_commit_failure_cannot_publish_runner_approval(self):
        self.enroll()
        message = b"exact fictional challenge"
        signed = _sign(self.first, message, self.folder)
        invoked = []
        original = self.registry._db

        class FaultyConnection:
            def execute(self, command, *args):
                if command == "COMMIT":
                    raise sqlite3.OperationalError("injected registry commit failure")
                return original.execute(command, *args)

        self.registry._db = FaultyConnection()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                self.registry.authorize(
                    tenant="tenant-a", session="session-a", challenge=message,
                    signature=signed, on_valid=lambda *_: invoked.append(True))
        finally:
            self.registry._db = original
        self.assertEqual(invoked, [])
        self.assertIsNone(self.registry._db.execute(
            "SELECT state FROM device_approval_grants").fetchone())

    def test_effect_admission_commit_failure_cannot_call_merchant(self):
        self.enroll()
        message = b"exact fictional checkout"
        signed = _sign(self.first, message, self.folder)
        outcome = self.registry.authorize(
            tenant="tenant-a", session="session-a", challenge=message,
            signature=signed, on_valid=lambda version, digest: (version, digest))
        original = self.registry._db
        class FaultyConnection:
            def execute(self, command, *args):
                if command == "COMMIT":
                    raise sqlite3.OperationalError("injected effect-admission commit failure")
                return original.execute(command, *args)
        self.registry._db = FaultyConnection()
        invoked = []
        try:
            with self.assertRaises(sqlite3.OperationalError):
                self.registry.guard_effect(
                    tenant="tenant-a", session="session-a",
                    expected_version=outcome[0], challenge_digest=outcome[1],
                    on_valid=lambda: invoked.append(True))
        finally:
            self.registry._db = original
        self.assertEqual(invoked, [])
        self.assertEqual(self.registry._db.execute(
            "SELECT state FROM device_approval_grants").fetchone()[0], "granted")


class DeviceRegistryCheckoutContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shop_tests.RunnerHTTPSContractTests.setUpClass()
        cls.fixture = shop_tests.RunnerHTTPSContractTests

    @classmethod
    def tearDownClass(cls):
        cls.fixture.tearDownClass()

    def test_revoke_prevents_approval_of_exact_prepared_checkout(self):
        with tempfile.TemporaryDirectory(prefix="alice-device-checkout-") as tmp:
            folder = Path(tmp)
            private, public = _keypair(folder, "consent")
            registry = RevocableP256DeviceConsent(folder / "registry.sqlite3")
            self.addCleanup(registry.close)
            version = registry.enroll(
                tenant="tenant-a", session="session-a", account="owner-a",
                installation="device-a", public_pem=public,
                expires_at=int(time.time()) + 3600)
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.fixture.shop.url, ca_file=self.fixture.cert,
                merchant_token=self.fixture.shop_secret), approval_verifier=registry)
            self.addCleanup(runner.close)
            coord = Coordinator(runner, tenant="tenant-a", session="session-a",
                                recipient="Fictional addressee", planner=FictionalPlanner())
            prepared = coord.run_to_approval()
            approval = _sign(private, _canonical(prepared["approval_challenge"]), folder)
            registry.revoke(tenant="tenant-a", session="session-a",
                            account="owner-a", expected_version=version)
            with self.assertRaises(Denied):
                runner.approve(coord.job_id, tenant="tenant-a", session="session-a",
                               signature=approval)
            self.assertEqual(runner.resume_job(coord.job_id, tenant="tenant-a",
                                               session="session-a")["status"], "awaiting_approval")

    def test_revoking_after_signed_approval_blocks_unsubmitted_checkout(self):
        with tempfile.TemporaryDirectory(prefix="alice-device-after-approval-") as tmp:
            folder = Path(tmp)
            private, public = _keypair(folder, "approval")
            registry = RevocableP256DeviceConsent(folder / "registry.sqlite3")
            self.addCleanup(registry.close)
            version = registry.enroll(
                tenant="tenant-c", session="session-c", account="owner-c",
                installation="device-c", public_pem=public,
                expires_at=int(time.time()) + 3600)
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.fixture.shop.url, ca_file=self.fixture.cert,
                merchant_token=self.fixture.shop_secret), approval_verifier=registry)
            self.addCleanup(runner.close)
            coord = Coordinator(runner, tenant="tenant-c", session="session-c",
                                recipient="Fictional delivery", planner=FictionalPlanner())
            prepared = coord.run_to_approval()
            signature = _sign(private, _canonical(prepared["approval_challenge"]), folder)
            self.assertEqual(runner.approve(
                coord.job_id, tenant="tenant-c", session="session-c",
                signature=signature)["status"], "approved")
            with self.fixture.store._lock:
                before = self.fixture.store.submit_attempts
            registry.revoke(tenant="tenant-c", session="session-c",
                            account="owner-c", expected_version=version)
            with self.assertRaises(Denied):
                runner.commit(coord.job_id, tenant="tenant-c", session="session-c")
            with self.fixture.store._lock:
                self.assertEqual(self.fixture.store.submit_attempts, before)
            self.assertEqual(runner.resume_job(coord.job_id, tenant="tenant-c",
                                               session="session-c")["status"], "approved")

    def test_rotating_key_after_approval_invalidates_old_checkout_consent(self):
        with tempfile.TemporaryDirectory(prefix="alice-device-rotate-after-approval-") as tmp:
            folder = Path(tmp)
            private, old_public = _keypair(folder, "old")
            _, replacement_public = _keypair(folder, "replacement")
            registry = RevocableP256DeviceConsent(folder / "registry.sqlite3")
            self.addCleanup(registry.close)
            registry.enroll(
                tenant="tenant-d", session="session-d", account="owner-d",
                installation="device-d", public_pem=old_public,
                expires_at=int(time.time()) + 3600)
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.fixture.shop.url, ca_file=self.fixture.cert,
                merchant_token=self.fixture.shop_secret), approval_verifier=registry,
                ledger_path=folder / "runner.sqlite3")
            coord = Coordinator(runner, tenant="tenant-d", session="session-d",
                                recipient="Fictional delivery", planner=FictionalPlanner())
            prepared = coord.run_to_approval()
            signature = _sign(private, _canonical(prepared["approval_challenge"]), folder)
            runner.approve(coord.job_id, tenant="tenant-d", session="session-d",
                           signature=signature)
            # The version binding must survive a full Alice process restart;
            # losing it must never silently upgrade an old approval.
            runner.close()
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.fixture.shop.url, ca_file=self.fixture.cert,
                merchant_token=self.fixture.shop_secret), approval_verifier=registry,
                ledger_path=folder / "runner.sqlite3")
            self.addCleanup(runner.close)
            self.assertEqual(registry.rotate(
                tenant="tenant-d", session="session-d", account="owner-d",
                installation="device-d", expected_version=1,
                public_pem=replacement_public, expires_at=int(time.time()) + 3600), 2)
            with self.fixture.store._lock:
                before = self.fixture.store.submit_attempts
            with self.assertRaises(Denied):
                runner.commit(coord.job_id, tenant="tenant-d", session="session-d")
            with self.fixture.store._lock:
                self.assertEqual(self.fixture.store.submit_attempts, before)


if __name__ == "__main__":
    unittest.main()
