"""H02.1 offline Ed25519 issuer and VERIFY-ONLY gateway/ASR contract.

Uses system OpenSSL 3's audited Ed25519 implementation. No remote JWKS URLs,
algorithm negotiation, dynamically fetched signing keys or HMAC signer secrets
in either gateway or runner. Synthetic fixtures, NOT device attestation.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .h02_identity import (AUDIENCE, ISSUER, FIELDS, MAX_TTL, ROLE_PATHS,
                           InvalidCapability, _IDENTITY, _canonical, _decode,
                           _encode, _json, _principal_fields)

# A bounded number of OpenSSL subprocesses per verifier process; fail closed
# on overload rather than spawning unbounded cryptographic workers.
_VERIFY_SLOTS = threading.BoundedSemaphore(4)


def _openssl(args: list[str], *, input_bytes: bytes | None = None) -> bytes:
    try:
        result = subprocess.run(["openssl", *args], input=input_bytes, timeout=5,
                                capture_output=True, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InvalidCapability("signature engine unavailable") from exc
    if result.returncode:
        raise InvalidCapability("signature rejected")
    return result.stdout


def _sign(private_path: str, raw: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="alice-h021-signer-") as folder:
        file = Path(folder) / "claims"
        file.write_bytes(raw)
        return _openssl(["pkeyutl", "-sign", "-rawin", "-inkey",
                         private_path, "-in", str(file)])


def _verify(public_path: str, raw: bytes, signature: bytes) -> None:
    if not _VERIFY_SLOTS.acquire(blocking=False):
        raise InvalidCapability("signature verifier capacity exhausted")
    try:
        _verify_locked(public_path, raw, signature)
    finally:
        _VERIFY_SLOTS.release()


def _verify_locked(public_path: str, raw: bytes, signature: bytes) -> None:
    with tempfile.TemporaryDirectory(prefix="alice-h021-verifier-") as folder:
        data = Path(folder) / "claims"
        sigfile = Path(folder) / "signature"
        data.write_bytes(raw)
        sigfile.write_bytes(signature)
        _openssl(["pkeyutl", "-verify", "-rawin", "-pubin", "-inkey",
                  public_path, "-in", str(data), "-sigfile", str(sigfile)])


class OfflineIssuer:
    """Trusted operator only: private Ed25519 key never mounted into services."""
    def __init__(self, private_path: str, kid: str):
        if not _IDENTITY.fullmatch(kid):
            raise ValueError("invalid issuer key identifier")
        self.private_path, self.kid = str(private_path), kid

    def mint(self, *, subject: str, tenant: str, session: str, role: str,
             job: str, path: str, body: bytes, now: int | None = None,
             ttl: int = 60, jti: str | None = None):
        from secrets import token_hex
        if type(ttl) is not int or not 1 <= ttl <= MAX_TTL:
            raise ValueError("out of range capability TTL")
        now = int(time.time()) if now is None else now
        claim = dict(v=1, iss=ISSUER, aud=AUDIENCE, kid=self.kid,
                     sub=subject, tenant=tenant, session=session, role=role,
                     job=job, iat=now, nbf=now, exp=now + ttl,
                     jti=jti or token_hex(16), method="POST", path=path,
                     sha256=hashlib.sha256(body).hexdigest())
        _principal_fields(claim)
        raw = _canonical(claim)
        return _encode(raw) + "." + _encode(_sign(self.private_path, raw))


class PublicVerifier:
    """Strict locally pinned Ed25519 public-key verifier (no signing capability)."""
    def __init__(self, public_keys: dict[str, str]):
        if not public_keys or any(not _IDENTITY.fullmatch(k) for k in public_keys):
            raise ValueError("missing public trust anchor")
        for public in public_keys.values():
            if "PRIVATE KEY" in public or not public.startswith("-----BEGIN PUBLIC KEY-----"):
                raise ValueError("only public verification keys permitted")
        self._files = {}
        # All paths live in the read-only *public verifier* config; an attacker
        # cannot choose paths/kids from an unsigned token or external URL.
        self._paths = dict(public_keys)

    @classmethod
    def load(cls, manifest_path: str):
        manifest = _json(Path(manifest_path).read_bytes())
        if not isinstance(manifest, dict) or set(manifest) != {"keys"} or not isinstance(manifest["keys"], dict):
            raise ValueError("invalid public key manifest")
        folder = Path(manifest_path).parent.resolve()
        keys = {}
        for kid, filename in manifest["keys"].items():
            if not isinstance(filename, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]+", filename):
                raise ValueError("invalid key file name")
            keyfile = folder / filename
            if not keyfile.is_file():
                raise ValueError("missing public key")
            keys[kid] = keyfile.read_text(encoding="ascii")
        obj = cls(keys)
        obj._paths = {kid: str(folder / manifest["keys"][kid]) for kid in keys}
        return obj

    def verify(self, token: str, *, path: str, body: bytes, now: int | None = None):
        if not isinstance(token, str) or len(token) > 4096 or token.count(".") != 1:
            raise InvalidCapability("invalid signed request")
        encoded, signature = token.split(".")
        raw = _decode(encoded)
        claims = _json(raw)
        if not isinstance(claims, dict) or _canonical(claims) != raw:
            raise InvalidCapability("noncanonical claims")
        _principal_fields(claims)
        keypath = self._paths.get(claims["kid"])
        if not keypath:
            raise InvalidCapability("unknown or revoked signing key")
        _verify(keypath, raw, _decode(signature))
        now = int(time.time()) if now is None else now
        if now < claims["nbf"] or now >= claims["exp"] or claims["iat"] > now + 5:
            raise InvalidCapability("expired or not-yet-valid request")
        if claims["path"] != path or not hmac.compare_digest(
                claims["sha256"], hashlib.sha256(body).hexdigest()):
            raise InvalidCapability("request changed")
        obj = _json(body)
        if not isinstance(obj, dict):
            raise InvalidCapability("object required")
        if claims["path"] != "/v1/jobs" and obj.get("job_id") != claims["job"]:
            raise InvalidCapability("different job")
        for identity in ("tenant", "session"):
            if identity in obj and obj[identity] != claims[identity]:
                raise InvalidCapability("forged identity")
        return claims, obj
