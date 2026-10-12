"""Alice-administered, durable public-only P-256 enrollment and revocation.

This is a local trust contract, NOT an identity provider, an iOS attestation
service or a substitute for a hardware-backed, user-present device approval.
Only a trusted Alice administrator may call enroll/rotate/revoke. Hermes has
neither a reference to this object nor permission to write its SQLite file.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import secrets
import sqlite3
import subprocess
import tempfile
import threading
import time
from pathlib import Path


_IDENTITY = re.compile(r"^[A-Za-z0-9_@.:-]{1,120}$")
_SIGNATURE = re.compile(r"^[A-Za-z0-9_-]{1,192}$")


class EnrollmentDenied(ValueError):
    pass


def _identity(value: str) -> str:
    if not isinstance(value, str) or _IDENTITY.fullmatch(value) is None:
        raise EnrollmentDenied("invalid identity")
    return value


def _validated_public_key(pem: str) -> str:
    if (not isinstance(pem, str) or not 100 <= len(pem) <= 4096
            or not pem.startswith("-----BEGIN PUBLIC KEY-----")
            or "-----END PUBLIC KEY-----" not in pem
            or "PRIVATE KEY" in pem or "\x00" in pem):
        raise EnrollmentDenied("only a P-256 public key is permitted")
    try:
        with tempfile.TemporaryDirectory(prefix="alice-enroll-key-") as folder:
            key = Path(folder) / "device.pem"
            key.write_text(pem, encoding="ascii")
            result = subprocess.run(
                ["openssl", "pkey", "-pubin", "-in", str(key), "-text", "-noout"],
                capture_output=True, timeout=5, check=False)
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
        raise EnrollmentDenied("public key could not be validated") from exc
    if result.returncode or b"prime256v1" not in result.stdout:
        raise EnrollmentDenied("device key must be NIST P-256")
    return pem


def _proof_signature_valid(pem: str, challenge: bytes, signature: str) -> bool:
    if (not isinstance(challenge, bytes) or not 1 <= len(challenge) <= 8192
            or not isinstance(signature, str) or _SIGNATURE.fullmatch(signature) is None):
        return False
    try:
        decoded = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
    except (ValueError, binascii.Error):
        return False
    if not 64 <= len(decoded) <= 80:
        return False
    try:
        with tempfile.TemporaryDirectory(prefix="alice-device-proof-") as folder:
            key, payload, signed = (
                Path(folder) / "public.pem", Path(folder) / "challenge", Path(folder) / "signature")
            key.write_text(pem, encoding="ascii")
            payload.write_bytes(challenge)
            signed.write_bytes(decoded)
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(key),
                 "-signature", str(signed), str(payload)],
                capture_output=True, timeout=5, check=False)
        return result.returncode == 0
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return False


class RevocableP256DeviceConsent:
    """Public-key verifier with single-active-key-per-(tenant, session) policy.

    Account and installation identity are set by the trusted Alice enrollment
    authority, never taken from a model's request. Rotation invalidates the old
    key; revocation and expiration fail closed across database reopen/restart.
    """

    def __init__(self, path: str | Path, *, clock=None):
        self._db = sqlite3.connect(str(path), timeout=5, isolation_level=None,
                                   check_same_thread=False)
        self._db.execute("PRAGMA busy_timeout=5000")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS device_keys ("
            "tenant TEXT NOT NULL, session TEXT NOT NULL, account TEXT NOT NULL, "
            "installation TEXT NOT NULL, public_pem TEXT NOT NULL, "
            "version INTEGER NOT NULL, expires_at INTEGER NOT NULL, "
            "revoked INTEGER NOT NULL DEFAULT 0, "
            "PRIMARY KEY(tenant,session))")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS device_approval_grants ("
            "tenant TEXT NOT NULL, session TEXT NOT NULL, "
            "challenge_digest TEXT NOT NULL, device_version INTEGER NOT NULL, "
            "state TEXT NOT NULL, PRIMARY KEY(tenant,session,challenge_digest))")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS device_enrollment_challenges ("
            "nonce TEXT PRIMARY KEY, tenant TEXT NOT NULL, session TEXT NOT NULL, "
            "account TEXT NOT NULL, installation TEXT NOT NULL, "
            "public_pem TEXT NOT NULL, operation TEXT NOT NULL, "
            "expected_version INTEGER NOT NULL, key_expires_at INTEGER NOT NULL, "
            "expires_at INTEGER NOT NULL, state TEXT NOT NULL)")
        self._lock = threading.RLock()
        self._clock = clock or time.time

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @staticmethod
    def _enrollment_payload(row: tuple) -> dict:
        nonce, tenant, session, account, installation, pem, operation, version, key_expires, expires, _ = row
        return {
            "purpose": "alice-r02-device-enroll-v1",
            "tenant": tenant, "session": session, "account": account,
            "installation": installation,
            "public_key_sha256": hashlib.sha256(pem.encode("ascii")).hexdigest(),
            "operation": operation, "expected_version": version,
            "key_expires_at": key_expires,
            "nonce": nonce, "expires_at": expires,
        }

    def begin_proven_enrollment(self, *, tenant: str, session: str,
                                account: str, installation: str, public_pem: str,
                                key_expires_at: int, operation: str = "enroll",
                                expected_version: int = 0) -> dict:
        """Trusted Alice administrator issues a short-lived exact-key challenge.

        Neither Hermes nor a model may initiate this; external Alice account
        authentication is a separate, still-unimplemented release gate.
        No private signing material is copied to Alice.
        """
        identities = tuple(map(_identity, (tenant, session, account, installation)))
        pem = _validated_public_key(public_pem)
        now = int(self._clock())
        if (operation not in ("enroll", "rotate")
                or type(expected_version) is not int
                or (operation == "enroll" and expected_version != 0)
                or (operation == "rotate" and expected_version < 1)
                or type(key_expires_at) is not int
                or not now < key_expires_at <= now + 31_536_000):
            raise EnrollmentDenied("invalid enrollment scope, operation or key lifetime")
        nonce = secrets.token_urlsafe(24)
        with self._lock:
            self._db.execute(
                "INSERT INTO device_enrollment_challenges VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (nonce, *identities, pem, operation, expected_version,
                 key_expires_at, now + 180, "pending"))
            row = self._db.execute(
                "SELECT * FROM device_enrollment_challenges WHERE nonce=?",
                (nonce,)).fetchone()
        return self._enrollment_payload(row)

    def complete_proven_enrollment(self, challenge: dict, signature: str) -> int:
        """Verify exact key-possession proof and atomically enroll/rotate once."""
        if (not isinstance(challenge, dict) or set(challenge) != {
                "purpose", "tenant", "session", "account", "installation",
                "public_key_sha256", "operation", "expected_version", "key_expires_at",
                "nonce", "expires_at"}):
            raise EnrollmentDenied("invalid enrollment response")
        nonce = challenge.get("nonce")
        if not isinstance(nonce, str) or not _SIGNATURE.fullmatch(nonce):
            raise EnrollmentDenied("invalid enrollment nonce")
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute(
                    "SELECT * FROM device_enrollment_challenges WHERE nonce=?",
                    (nonce,)).fetchone()
                if (row is None or row[-1] != "pending"
                        or row[-2] <= int(self._clock())
                        or self._enrollment_payload(row) != challenge):
                    raise EnrollmentDenied("unknown, stale or modified enrollment challenge")
                message = json.dumps(
                    challenge, sort_keys=True, separators=(",", ":"),
                    ensure_ascii=False).encode("utf-8")
                if not _proof_signature_valid(row[5], message, signature):
                    raise EnrollmentDenied("device does not control the proposed public key")
                scope = dict(tenant=row[1], session=row[2], account=row[3],
                             installation=row[4], public_pem=row[5],
                             expires_at=row[8])
                if row[6] == "enroll":
                    version = self.enroll(**scope)
                else:
                    version = self.rotate(expected_version=row[7], **scope)
                changed = self._db.execute(
                    "UPDATE device_enrollment_challenges SET state='consumed' "
                    "WHERE nonce=? AND state='pending'", (nonce,)).rowcount
                if changed != 1:
                    raise EnrollmentDenied("enrollment proof replay")
                self._db.execute("COMMIT")
                return version
            except BaseException:
                try:
                    self._db.execute("ROLLBACK")
                except sqlite3.Error:
                    pass
                raise

    def enroll(self, *, tenant: str, session: str, account: str, installation: str,
               public_pem: str, expires_at: int) -> int:
        identities = tuple(map(_identity, (tenant, session, account, installation)))
        pem = _validated_public_key(public_pem)
        if type(expires_at) is not int or not int(self._clock()) < expires_at <= int(self._clock()) + 31_536_000:
            raise EnrollmentDenied("invalid key expiry")
        with self._lock:
            try:
                self._db.execute(
                    "INSERT INTO device_keys(tenant,session,account,installation,public_pem,version,expires_at) "
                    "VALUES(?,?,?,?,?,1,?)", (*identities, pem, expires_at))
            except sqlite3.IntegrityError as exc:
                raise EnrollmentDenied("session already enrolled; use an authenticated rotation") from exc
        return 1

    def rotate(self, *, tenant: str, session: str, account: str, installation: str,
               expected_version: int, public_pem: str, expires_at: int) -> int:
        identities = tuple(map(_identity, (tenant, session, account, installation)))
        pem = _validated_public_key(public_pem)
        if (type(expected_version) is not int or expected_version < 1
                or type(expires_at) is not int
                or not int(self._clock()) < expires_at <= int(self._clock()) + 31_536_000):
            raise EnrollmentDenied("invalid key version or expiry")
        with self._lock:
            updated = self._db.execute(
                "UPDATE device_keys SET public_pem=?,version=version+1,expires_at=? "
                "WHERE tenant=? AND session=? AND account=? AND installation=? "
                "AND version=? AND revoked=0",
                (pem, expires_at, *identities, expected_version)).rowcount
            if updated != 1:
                raise EnrollmentDenied("unrecognized, revoked or stale device identity")
        return expected_version + 1

    def revoke(self, *, tenant: str, session: str, account: str,
               expected_version: int) -> None:
        tenant, session, account = map(_identity, (tenant, session, account))
        if type(expected_version) is not int or expected_version < 1:
            raise EnrollmentDenied("invalid device version")
        with self._lock:
            changed = self._db.execute(
                "UPDATE device_keys SET revoked=1 WHERE tenant=? AND session=? "
                "AND account=? AND version=? AND revoked=0",
                (tenant, session, account, expected_version)).rowcount
            if changed != 1:
                raise EnrollmentDenied("unknown or already-revoked enrollment")

    def verify(self, *, tenant: str, session: str, challenge: bytes, signature: str) -> bool:
        with self._lock:
            return self._verify_locked(tenant=tenant, session=session,
                                       challenge=challenge, signature=signature)

    def authorize(self, *, tenant: str, session: str, challenge: bytes,
                  signature: str, on_valid):
        """Commit the verified grant BEFORE persisting the runner approval.

        Separate SQLite stores cannot provide one atomic transaction. If grant
        durability fails, the runner callback NEVER executes. If the callback
        fails after grant commits, the orphaned grant has no checkout authority:
        the runner still requires a durable approved job and an exact digest.
        """
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                if not self._verify_locked(tenant=tenant, session=session,
                                           challenge=challenge, signature=signature):
                    raise EnrollmentDenied("device approval invalid, expired or revoked")
                key_version = self._db.execute(
                    "SELECT version FROM device_keys WHERE tenant=? AND session=?",
                    (tenant, session)).fetchone()[0]
                challenge_digest = hashlib.sha256(challenge).hexdigest()
                prior = self._db.execute(
                    "SELECT device_version,state FROM device_approval_grants "
                    "WHERE tenant=? AND session=? AND challenge_digest=?",
                    (tenant, session, challenge_digest)).fetchone()
                if prior is not None:
                    if prior != (key_version, "granted"):
                        raise EnrollmentDenied("consent grant already consumed")
                else:
                    self._db.execute(
                        "INSERT INTO device_approval_grants"
                        "(tenant,session,challenge_digest,device_version,state) "
                        "VALUES(?,?,?,?,'granted')",
                        (tenant, session, challenge_digest, key_version))
                self._db.execute("COMMIT")
            except BaseException:
                try:
                    self._db.execute("ROLLBACK")
                except sqlite3.Error:
                    pass
                raise
            return on_valid(key_version, challenge_digest)

    def guard_effect(self, *, tenant: str, session: str, expected_version: int,
                     challenge_digest: str, on_valid):
        """Commit ONE effect admission BEFORE the irreversible merchant call.

        Revocation after admission cannot undo a merchant effect. Even a crash
        before the merchant sees anything consumes this grant: fail closed
        rather than launch a possibly duplicated operation.
        """
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute(
                    "SELECT expires_at,revoked,version FROM device_keys "
                    "WHERE tenant=? AND session=?",
                    (tenant, session)).fetchone()
                if (type(expected_version) is not int or expected_version < 1
                        or row is None or row[1] or row[0] <= int(self._clock())
                        or row[2] != expected_version):
                    raise EnrollmentDenied("device approval key rotated, revoked or expired")
                if (not isinstance(challenge_digest, str)
                        or re.fullmatch(r"[a-f0-9]{64}", challenge_digest) is None):
                    raise EnrollmentDenied("missing durable device consent grant")
                updated = self._db.execute(
                    "UPDATE device_approval_grants SET state='effect_admitted' "
                    "WHERE tenant=? AND session=? AND challenge_digest=? "
                    "AND device_version=? AND state='granted'",
                    (tenant, session, challenge_digest, expected_version)).rowcount
                if updated != 1:
                    raise EnrollmentDenied("already consumed or absent device consent grant")
                self._db.execute("COMMIT")
            except BaseException:
                try:
                    self._db.execute("ROLLBACK")
                except sqlite3.Error:
                    pass
                raise
            return on_valid()

    def effect_admission_state(self, *, tenant: str, session: str,
                               challenge_digest: str) -> str | None:
        """Trusted Alice-only reconciliation; never exposed to the planner.

        A durable 'effect_admitted' may precede the runner's own dispatch
        record if either process fails between independent SQLite commits.
        It is *not* proof that the merchant was called or that it was not.
        """
        tenant, session = _identity(tenant), _identity(session)
        if (not isinstance(challenge_digest, str)
                or re.fullmatch(r"[a-f0-9]{64}", challenge_digest) is None):
            return None
        with self._lock:
            row = self._db.execute(
                "SELECT state FROM device_approval_grants WHERE tenant=? "
                "AND session=? AND challenge_digest=?",
                (tenant, session, challenge_digest)).fetchone()
            return row[0] if row is not None else None

    def _verify_locked(self, *, tenant: str, session: str, challenge: bytes,
                       signature: str) -> bool:
        if (not isinstance(tenant, str) or not isinstance(session, str)
                or not isinstance(challenge, bytes) or len(challenge) > 8192
                or not isinstance(signature, str) or not _SIGNATURE.fullmatch(signature)):
            return False
        # Serialization against enrollment/rotation/revocation in this process.
        # External administrative calls must use the same SQLite trusted domain.
        row = self._db.execute(
            "SELECT public_pem,expires_at,revoked FROM device_keys "
            "WHERE tenant=? AND session=?", (tenant, session)).fetchone()
        if row is None or row[2] or row[1] <= int(self._clock()):
            return False
        return _proof_signature_valid(row[0], challenge, signature)
