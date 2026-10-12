"""H02 signed request and crash-safe anti-replay regression tests.

All identities, jobs and signatures are fictional and locally generated.
"""
from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from alice_secure_runner.h02_identity import (
    AUDIENCE, InvalidCapability, Keyring, ReplayLedger,
    _canonical, _decode, _encode,
)
from alice_secure_runner.h02_gateway import H02Gateway


class H02IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="alice-h02-fake-")
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / "replays.sqlite3")
        self.keyring = Keyring({"k1": b"A" * 32, "older": b"B" * 32}, "k1")
        self.ledger = ReplayLedger(self.path)
        self.addCleanup(self.ledger.close)
        self.body = b'{"job_id":"job-123","proposal":{"action":"search","epoch":0,"query":"fiction"}}'

    def mint(self, *, keyring=None, path="/v1/proposals", role="proposal",
             job="job-123", body=None, now=1000, ttl=60, **kwargs):
        return (keyring or self.keyring).mint(
            subject=kwargs.get("subject", "fictional-user"),
            tenant=kwargs.get("tenant", "fixture-tenant-a"),
            session=kwargs.get("session", "fixture-session-a"),
            path=path, role=role, job=job,
            body=self.body if body is None else body, now=now, ttl=ttl,
            jti=kwargs.get("jti"))

    def verify(self, token, *, body=None, path="/v1/proposals", now=1000):
        return self.keyring.verify(token, body=self.body if body is None else body,
                                   path=path, now=now)

    def test_one_time_request_survives_ledger_process_reopen(self):
        claims, obj = self.verify(self.mint())
        self.assertEqual(obj["job_id"], "job-123")
        self.ledger.consume(claims, now=1000)
        second = ReplayLedger(self.path)
        try:
            with self.assertRaises(InvalidCapability):
                second.consume(claims, now=1000)
        finally:
            second.close()

    def test_same_jti_two_threads_has_one_winner(self):
        claims, _ = self.verify(self.mint())
        results = []
        def call():
            try:
                self.ledger.consume(claims, now=1000)
                results.append("allowed")
            except InvalidCapability:
                results.append("denied")
        threads = [threading.Thread(target=call) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=3)
            self.assertFalse(t.is_alive())
        self.assertCountEqual(results, ["allowed", "denied"])

    def test_strict_body_and_endpoint_binding(self):
        token = self.mint()
        for path, body in (("/v1/commit", self.body),
                           ("/v1/proposals", self.body + b" "),
                           ("/v1/proposals", self.body.replace(b"job-123", b"job-456"))):
            with self.subTest(path=path, body=body), self.assertRaises(InvalidCapability):
                self.verify(token, path=path, body=body)

    def test_scope_never_allows_model_to_commit_or_read_owner_data(self):
        for endpoint in ("/v1/jobs", "/v1/resume", "/v1/approve",
                         "/v1/commit", "/v1/human-finish", "/v1/human-handoff"):
            with self.subTest(endpoint=endpoint), self.assertRaises(InvalidCapability):
                self.mint(path=endpoint, role="proposal")

    def test_expired_not_yet_valid_and_excess_ttl(self):
        token = self.mint(now=1000, ttl=2)
        for now in (999, 1002):
            with self.subTest(now=now), self.assertRaises(InvalidCapability):
                self.verify(token, now=now)
        with self.assertRaises(ValueError):
            self.mint(ttl=301)

    def test_key_rotation_old_valid_until_revoked(self):
        old = self.mint()
        next_keys = Keyring({"k1": b"A" * 32, "k2": b"C" * 32}, "k2")
        self.verify(old)
        new = self.mint(keyring=next_keys)
        self.assertEqual(next_keys.verify(new, path="/v1/proposals", body=self.body, now=1000)[0]["kid"], "k2")
        with self.assertRaises(InvalidCapability):
            Keyring({"k2": b"C" * 32}, "k2").verify(old, path="/v1/proposals",
                                                      body=self.body, now=1000)

    def test_signature_kid_audience_and_duplicate_claim_tampering(self):
        token = self.mint()
        payload, signature = token.split(".")
        claims = json.loads(_decode(payload))
        for field, value in (("aud", "untrusted"), ("tenant", "fixture-tenant-b"),
                             ("role", "owner"), ("kid", "other")):
            changed = dict(claims, **{field: value})
            with self.subTest(field=field), self.assertRaises(InvalidCapability):
                self.verify(_encode(_canonical(changed)) + "." + signature)
        dup = _decode(payload).replace(b'"aud":', b'"aud":"evil","aud":')
        with self.assertRaises(InvalidCapability):
            self.verify(_encode(dup) + "." + signature)

    def test_wrong_job_and_spoofed_tenant_in_json(self):
        changed = b'{"job_id":"job-456","proposal":{"action":"search"}}'
        with self.assertRaises(InvalidCapability):
            self.verify(self.mint(body=changed), body=changed)
        spoofed = b'{"job_id":"job-123","tenant":"fixture-tenant-b"}'
        with self.assertRaises(InvalidCapability):
            self.verify(self.mint(body=spoofed), body=spoofed)

    def test_bad_keyring_and_invalid_token_shape(self):
        with self.assertRaises(ValueError):
            Keyring({"k": b"x"}, "k")
        for token in ("", "a", "a.b.c", "bad_token.bad_token"):
            with self.subTest(token=token), self.assertRaises(InvalidCapability):
                self.verify(token)

    def test_gateway_consumes_before_backend_and_replay_stays_denied(self):
        with mock.patch("alice_secure_runner.h02_gateway.ssl.create_default_context"):
            gateway = H02Gateway(
                keyring=self.keyring, ledger=self.ledger,
                assignments={"fictional-user": {
                    "actor": "a", "tenant": "fixture-tenant-a",
                    "session": "fixture-session-a"}},
                backend={"a": {"coordinator": "fictional-opaque-coordinator",
                               "human": "fictional-opaque-human"}},
                ca_file="/not-read-in-unit-test")
        auth = "Alice-H02 " + self.mint(now=int(time.time()))
        actor, role, data = gateway.authorize(auth, "/v1/proposals", self.body)
        self.assertEqual((actor, role, data["job_id"]), ("a", "proposal", "job-123"))
        with self.assertRaises(InvalidCapability):
            gateway.authorize(auth, "/v1/proposals", self.body)
        # Failed application/backend requests are NOT retried with the same
        # issued capability after a restart or network failure.


if __name__ == "__main__":
    unittest.main()
