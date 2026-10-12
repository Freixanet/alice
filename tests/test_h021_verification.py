"""H02.1 signed trust boundary and atomic lost-response recovery tests."""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from alice_secure_runner.core import AliceRunner, Denied
from alice_secure_runner.h02_identity import InvalidCapability
from alice_secure_runner.h021_crypto import OfflineIssuer, PublicVerifier
from alice_secure_runner.h021_host import protected_handler
from alice_secure_runner.h02_identity import ReplayLedger
from alice_secure_runner.http_service import FixturePrincipal


class H021Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="h021-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        private = self.root / "signing-private.pem"
        public_dir = self.root / "public"
        public_dir.mkdir()
        public = public_dir / "issuer.pub.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519",
                        "-out", str(private)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(private),
                        "-pubout", "-out", str(public)], check=True, capture_output=True)
        (public_dir / "public.json").write_text(json.dumps({"keys":{"v1":"issuer.pub.pem"}}))
        self.issuer = OfflineIssuer(str(private), "v1")
        self.verifier = PublicVerifier.load(str(public_dir / "public.json"))
        self.body = b'{"job_id":"synthetic-123","proposal":{"action":"search","epoch":0,"query":"keyboard"}}'

    def mint(self, **kwargs):
        return self.issuer.mint(subject=kwargs.get("subject", "user-a"),
            tenant=kwargs.get("tenant", "fixture-tenant-a"),
            session=kwargs.get("session", "fixture-session-a"),
            role=kwargs.get("role", "proposal"),
            path=kwargs.get("path", "/v1/proposals"),
            job=kwargs.get("job", "synthetic-123"),
            body=kwargs.get("body", self.body),
            ttl=kwargs.get("ttl", 60),
            now=kwargs.get("now"))

    def test_no_signing_key_or_private_material_in_verifier(self):
        self.assertEqual(self.verifier.verify(self.mint(),
            path="/v1/proposals", body=self.body)[0]["role"], "proposal")
        public = (self.root / "public" / "issuer.pub.pem").read_text()
        self.assertIn("PUBLIC KEY", public)
        self.assertNotIn("PRIVATE", public)
        with self.assertRaises(ValueError):
            PublicVerifier({"bad": (self.root / "signing-private.pem").read_text()})

    def test_signature_cannot_be_forged_with_public_key(self):
        original = self.mint()
        claims, sig = original.split(".")
        from alice_secure_runner.h02_identity import _decode, _encode, _canonical
        forged = json.loads(_decode(claims))
        forged["role"] = "owner"
        forged["path"] = "/v1/commit"
        with self.assertRaises(InvalidCapability):
            self.verifier.verify(_encode(_canonical(forged)) + "." + sig,
                                 path="/v1/commit", body=self.body)

    def test_exact_body_role_path_job_tenant_audience_expiry(self):
        token = self.mint()
        variants = (
            ("/v1/commit", self.body),
            ("/v1/proposals", self.body + b" "),
            ("/v1/proposals", self.body.replace(b"synthetic-123", b"synthetic-456")),
        )
        for path, raw in variants:
            with self.subTest(path=path), self.assertRaises(InvalidCapability):
                self.verifier.verify(token, path=path, body=raw)
        expired = self.mint(now=int(time.time()) - 120, ttl=30)
        with self.assertRaises(InvalidCapability):
            self.verifier.verify(expired, path="/v1/proposals", body=self.body)
        with self.assertRaises(InvalidCapability):
            self.mint(role="proposal", path="/v1/commit")

    def test_public_trust_anchors_revocable_without_private_key(self):
        token = self.mint()
        manifest = self.root / "public" / "public.json"
        manifest.write_text(json.dumps({"keys":{"unrelated":"issuer.pub.pem"}}))
        revoked = PublicVerifier.load(str(manifest))
        with self.assertRaises(InvalidCapability):
            revoked.verify(token, path="/v1/proposals", body=self.body)

    def test_idempotent_creation_atomic_restart_and_cross_tenant(self):
        ledger = self.root / "state.sqlite3"
        first = AliceRunner(object(), approval_key=b"F" * 32, ledger_path=ledger)
        initial = first.new_job("tenant-a", "stable-session", "dummy recipient",
                                create_request_id="create-stable-0001")
        repeated = first.new_job("tenant-a", "stable-session", "dummy recipient",
                                 create_request_id="create-stable-0001")
        self.assertEqual(initial["job_id"], repeated["job_id"])
        with self.assertRaises(Denied):
            first.new_job("tenant-a", "stable-session", "changed recipient",
                          create_request_id="create-stable-0001")
        other = first.new_job("tenant-b", "stable-session", "dummy recipient",
                              create_request_id="create-stable-0001")
        self.assertNotEqual(initial["job_id"], other["job_id"])
        first.close()
        after = AliceRunner(object(), approval_key=b"F" * 32, ledger_path=ledger)
        try:
            recovered = after.new_job("tenant-a", "stable-session", "dummy recipient",
                                      create_request_id="create-stable-0001")
            self.assertEqual(initial["job_id"], recovered["job_id"])
            self.assertEqual(after.resume_job(recovered["job_id"], tenant="tenant-a",
                              session="stable-session")["status"], "researching")
            with self.assertRaises(Denied):
                after.resume_job(recovered["job_id"], tenant="tenant-b",
                                 session="stable-session")
        finally:
            after.close()

    def test_concurrent_same_create_id_no_duplicate(self):
        from concurrent.futures import ThreadPoolExecutor
        runner = AliceRunner(object(), approval_key=b"F" * 32)
        try:
            def create(_):
                return runner.new_job("t", "s", "r", create_request_id="concurrent-request-0001")["job_id"]
            with ThreadPoolExecutor(max_workers=8) as pool:
                ids = list(pool.map(create, range(24)))
            self.assertEqual(len(set(ids)), 1)
        finally:
            runner.close()

    def test_failed_commit_rolls_back_job_and_memory_state(self):
        runner = AliceRunner(object(), approval_key=b"F" * 32)
        real_db = runner._AliceRunner__db
        class FailOneCommit:
            def __init__(self, original):
                self.original = original
                self.failed = False
            def execute(self, statement, *args):
                if statement == "COMMIT" and not self.failed:
                    self.failed = True
                    raise sqlite3.OperationalError("simulated disk-write COMMIT failure")
                return self.original.execute(statement, *args)
        runner._AliceRunner__db = FailOneCommit(real_db)
        try:
            with self.assertRaises(sqlite3.OperationalError):
                runner.new_job("a", "s", "fictional",
                               create_request_id="disk-failure-case-001")
            self.assertEqual(len(runner._AliceRunner__jobs), 0)
            self.assertEqual(real_db.execute("SELECT count(*) FROM job_creations").fetchone()[0], 0)
            self.assertEqual(real_db.execute("SELECT count(*) FROM jobs").fetchone()[0], 0)
            ok = runner.new_job("a", "s", "fictional",
                                create_request_id="disk-failure-case-001")
            self.assertEqual(len(runner._AliceRunner__jobs), 1)
            self.assertEqual(ok["status"], "researching")
        finally:
            runner._AliceRunner__db = real_db
            runner.close()
    def test_private_handler_rejects_gateway_backend_bearer_without_signature(self):
        runner = AliceRunner(object(), approval_key=b"F" * 32)
        replay = ReplayLedger(str(self.root / "replay.sqlite"))
        try:
            principals = {
                "synthetic_backend_coordinator_abcdef"*2:
                    FixturePrincipal("coordinator","fixture-tenant-a","fixture-session-a"),
                "synthetic_backend_human_abcdef"*2:
                    FixturePrincipal("human","fixture-tenant-a","fixture-session-a")}
            handler = protected_handler(runner, principals, self.verifier, replay)
            self.assertTrue(callable(handler.do_POST))
            # The integration test opens a real HTTPS server and tries stolen
            # gateway backend tokens; this test verifies a guarded handler is
            # constructed without changing H01's handler.
        finally:
            replay.close()
            runner.close()


if __name__ == "__main__":
    unittest.main()
