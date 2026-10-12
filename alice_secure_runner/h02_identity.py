"""H02 proof of request-scoped Alice authorization, NOT a production IdP.

HMAC issuers and their entire signing keyring stay with Alice's trusted
operator. An untrusted Hermes host may receive PROPOSAL tokens only. This
prototype does not attest an iPhone, sender hardware, or a live OIDC identity.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import threading
import time
from pathlib import Path
from typing import Mapping

AUDIENCE = "alice-asr-h02-gateway"
ISSUER = "alice-h02-fixture-issuer"
MAX_TTL = 300
ROLE_PATHS = {
    "proposal": frozenset(("/v1/proposals",)),
    "owner": frozenset(("/v1/jobs", "/v1/resume", "/v1/challenge", "/v1/approve",
                        "/v1/commit", "/v1/human-handoff")),
    "human": frozenset(("/v1/human-reissue", "/v1/human-finish")),
}
FIELDS = frozenset(("v", "iss", "aud", "kid", "sub", "tenant", "session",
                    "role", "job", "iat", "nbf", "exp", "jti", "method",
                    "path", "sha256"))
_B64 = re.compile(r"^[A-Za-z0-9_-]+$")
_IDENTITY = re.compile(r"^[A-Za-z0-9_@.:-]{1,120}$")
_HEX = re.compile(r"^[0-9a-f]{64}$")


class InvalidCapability(Exception):
    """Invalid, expired, revoked, mismatched or replayed request."""


def _json(raw: bytes):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise InvalidCapability("duplicate JSON field")
            obj[key] = value
        return obj
    try:
        return json.loads(raw, object_pairs_hook=unique)
    except (ValueError, UnicodeDecodeError) as exc:
        raise InvalidCapability("malformed JSON") from exc


def _encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode(value: str) -> bytes:
    if not value or len(value) > 4096 or not _B64.fullmatch(value):
        raise InvalidCapability("invalid token encoding")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except ValueError as exc:
        raise InvalidCapability("invalid token base64") from exc
    if _encode(raw) != value:
        raise InvalidCapability("noncanonical base64")
    return raw


def _canonical(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("ascii")


def _principal_fields(data: dict):
    if set(data) != FIELDS or data.get("v") != 1 or data.get("iss") != ISSUER or data.get("aud") != AUDIENCE:
        raise InvalidCapability("unsupported request capability")
    for name in ("kid", "sub", "tenant", "session", "jti"):
        if not isinstance(data[name], str) or not _IDENTITY.fullmatch(data[name]):
            raise InvalidCapability("invalid principal field")
    if data["role"] not in ROLE_PATHS or data["path"] not in ROLE_PATHS[data["role"]]:
        raise InvalidCapability("role/path mismatch")
    if data["method"] != "POST" or not isinstance(data["sha256"], str) or not _HEX.fullmatch(data["sha256"]):
        raise InvalidCapability("invalid request binding")
    if not isinstance(data["job"], str) or (data["job"] and not _IDENTITY.fullmatch(data["job"])):
        raise InvalidCapability("invalid job binding")
    if data["path"] == "/v1/jobs" and data["job"]:
        raise InvalidCapability("job creation must not claim an existing job")
    if data["path"] != "/v1/jobs" and not data["job"]:
        raise InvalidCapability("job binding required")
    if any(type(data[k]) is not int for k in ("iat", "nbf", "exp")):
        raise InvalidCapability("invalid temporal bounds")
    if not data["iat"] <= data["nbf"] < data["exp"] <= data["iat"] + MAX_TTL:
        raise InvalidCapability("invalid TTL")


class Keyring:
    """Explicit active signing kid and old verification keys.

    Rotation is an Alice operator action, never a caller request. Existing
    verifier instances use a snapshot: a trusted gateway restart is required
    before retired keys are revoked or newly active keys become effective.
    """

    def __init__(self, keys: Mapping[str, bytes], active: str):
        if not keys or active not in keys:
            raise ValueError("active signing key required")
        for kid, key in keys.items():
            if not _IDENTITY.fullmatch(kid) or not isinstance(key, bytes) or len(key) < 32:
                raise ValueError("invalid keyring")
        self.keys = dict(keys)
        self.active = active

    @classmethod
    def load(cls, path: str):
        data = _json(Path(path).read_bytes())
        if not isinstance(data, dict) or set(data) != {"active", "keys"} or not isinstance(data["keys"], dict):
            raise ValueError("invalid keyring file")
        try:
            keys = {key: bytes.fromhex(value) for key, value in data["keys"].items()}
        except (TypeError, ValueError) as exc:
            raise ValueError("invalid keyring secrets") from exc
        return cls(keys, data["active"])

    def mint(self, *, subject: str, tenant: str, session: str, role: str,
             job: str, path: str, body: bytes, now: int | None = None,
             ttl: int = 60, jti: str | None = None) -> str:
        if type(ttl) is not int or not 1 <= ttl <= MAX_TTL:
            raise ValueError("TTL outside cap")
        if now is None:
            now = int(time.time())
        claims = dict(v=1, iss=ISSUER, aud=AUDIENCE, kid=self.active,
                      sub=subject, tenant=tenant, session=session, role=role,
                      job=job, iat=now, nbf=now, exp=now + ttl,
                      jti=jti or secrets.token_hex(16), method="POST",
                      path=path, sha256=hashlib.sha256(body).hexdigest())
        _principal_fields(claims)
        raw = _canonical(claims)
        signature = hmac.new(self.keys[self.active], raw, hashlib.sha256).digest()
        return _encode(raw) + "." + _encode(signature)

    def verify(self, token: str, *, path: str, body: bytes, now: int | None = None):
        if not isinstance(token, str) or len(token) > 4096 or token.count(".") != 1:
            raise InvalidCapability("invalid bearer")
        payload, signature = token.split(".")
        raw = _decode(payload)
        claims = _json(raw)
        if not isinstance(claims, dict) or raw != _canonical(claims):
            raise InvalidCapability("noncanonical request claims")
        _principal_fields(claims)
        key = self.keys.get(claims["kid"])
        if key is None or not hmac.compare_digest(
                hmac.new(key, raw, hashlib.sha256).digest(), _decode(signature)):
            raise InvalidCapability("signature unknown or invalid")
        if now is None:
            now = int(time.time())
        if now < claims["nbf"] or now >= claims["exp"] or claims["iat"] > now + 5:
            raise InvalidCapability("expired or early capability")
        if claims["path"] != path or not hmac.compare_digest(
                claims["sha256"], hashlib.sha256(body).hexdigest()):
            raise InvalidCapability("wrong request or body")
        obj = _json(body)
        if not isinstance(obj, dict):
            raise InvalidCapability("request body must be an object")
        if claims["path"] != "/v1/jobs" or claims["job"]:
            if obj.get("job_id") != claims["job"]:
                raise InvalidCapability("wrong job")
        for name in ("tenant", "session"):
            if name in obj and obj[name] != claims[name]:
                raise InvalidCapability("body identity spoof")
        return claims, obj


class ReplayLedger:
    """Crash-safe one-time capability consumption in Alice's gateway domain."""

    def __init__(self, filename: str):
        self._lock = threading.Lock()
        self.db = sqlite3.connect(filename, timeout=8, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA busy_timeout=8000")
        self.db.execute("CREATE TABLE IF NOT EXISTS consumed (jti TEXT PRIMARY KEY, expires INTEGER NOT NULL)")

    def consume(self, claims: dict, now: int | None = None):
        if now is None:
            now = int(time.time())
        with self._lock:
            try:
                self.db.execute("BEGIN IMMEDIATE")
                # Cleanup never removes a token still valid at this instant.
                self.db.execute("DELETE FROM consumed WHERE expires<=?", (now,))
                self.db.execute("INSERT INTO consumed(jti,expires) VALUES (?,?)",
                                (claims["iss"] + ":" + claims["jti"], claims["exp"]))
                self.db.execute("COMMIT")
            except sqlite3.Error as exc:
                self.db.execute("ROLLBACK")
                raise InvalidCapability("already consumed or replay ledger unavailable") from exc

    def close(self):
        self.db.close()
