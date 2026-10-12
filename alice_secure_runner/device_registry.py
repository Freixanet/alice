"""Alice-administered, durable public-only P-256 enrollment and revocation.

This is a local trust contract, NOT an identity provider, an iOS attestation
service or a substitute for a hardware-backed, user-present device approval.
Only a trusted Alice administrator may call enroll/rotate/revoke. Hermes has
neither a reference to this object nor permission to write its SQLite file.
"""

from __future__ import annotations

import base64
import binascii
import re
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
        self._lock = threading.RLock()
        self._clock = clock or time.time

    def close(self) -> None:
        with self._lock:
            self._db.close()

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
        """Fence trusted checkout-approval persistence against concurrent revoke.

        Holding a SQLite RESERVED writer lock serializes revocation/rotation by
        *other Alice processes* using this database. This is not proof of user
        presence or protection against a hostile database administrator.
        """
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                if not self._verify_locked(tenant=tenant, session=session,
                                           challenge=challenge, signature=signature):
                    raise EnrollmentDenied("device approval invalid, expired or revoked")
                outcome = on_valid()
                self._db.execute("COMMIT")
                return outcome
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    def guard_effect(self, *, tenant: str, session: str, on_valid):
        """Fence an already-approved dispatch against subsequent revocation.

        If revocation completed before this reservation, deny without sending.
        If dispatch began first, revocation waits behind the SQLite lock and
        cannot falsely claim the already-in-flight operation was prevented.
        Never imply this undoes a merchant effect already submitted.
        """
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute(
                    "SELECT expires_at,revoked FROM device_keys "
                    "WHERE tenant=? AND session=?",
                    (tenant, session)).fetchone()
                if row is None or row[1] or row[0] <= int(self._clock()):
                    raise EnrollmentDenied("device enrollment revoked or expired")
                outcome = on_valid()
                self._db.execute("COMMIT")
                return outcome
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    def _verify_locked(self, *, tenant: str, session: str, challenge: bytes,
                       signature: str) -> bool:
        if (not isinstance(tenant, str) or not isinstance(session, str)
                or not isinstance(challenge, bytes) or len(challenge) > 8192
                or not isinstance(signature, str) or not _SIGNATURE.fullmatch(signature)):
            return False
        try:
            sig = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        except (ValueError, binascii.Error):
            return False
        if not 64 <= len(sig) <= 80:
            return False
        # Serialization against enrollment/rotation/revocation in this process.
        # External administrative calls must use the same SQLite trusted domain.
        row = self._db.execute(
            "SELECT public_pem,expires_at,revoked FROM device_keys "
            "WHERE tenant=? AND session=?", (tenant, session)).fetchone()
        if row is None or row[2] or row[1] <= int(self._clock()):
            return False
        try:
            with tempfile.TemporaryDirectory(prefix="alice-verify-device-") as folder:
                key = Path(folder) / "public.pem"
                message = Path(folder) / "challenge"
                signed = Path(folder) / "signature"
                key.write_text(row[0], encoding="ascii")
                message.write_bytes(challenge)
                signed.write_bytes(sig)
                check = subprocess.run(
                    ["openssl", "dgst", "-sha256", "-verify", str(key),
                     "-signature", str(signed), str(message)],
                    capture_output=True, timeout=5, check=False)
        except (OSError, UnicodeError, subprocess.TimeoutExpired):
            return False
        return check.returncode == 0
