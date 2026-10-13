"""Testable P-256 device-consent boundary, NOT iOS attestation.

Production must enroll the public key using an authenticated Alice account,
device binding, trusted timestamp/revocation and real iOS user-presence APIs.
The sample operator has an ephemeral SOFTWARE key solely to verify the
cryptographic contract. No device private key belongs in gateway or ASR.
"""
from __future__ import annotations

import base64
import binascii
import json
import re
import subprocess
import tempfile
import threading
from pathlib import Path


class InvalidDeviceConsent(ValueError):
    pass


_SLOTS = threading.BoundedSemaphore(4)
_NAME = re.compile(r"^[A-Za-z0-9_@.:-]{1,120}$")


class P256DeviceConsent:
    """Pinned public-key trust by exact (tenant, session) tuple."""

    def __init__(self, keypaths: dict[tuple[str, str], str]):
        if not keypaths:
            raise ValueError("no enrolled device public keys")
        for (tenant, session), path in keypaths.items():
            if not (_NAME.fullmatch(tenant) and _NAME.fullmatch(session)):
                raise ValueError("invalid trusted device identity")
            content = Path(path).read_text(encoding="ascii")
            if "PRIVATE KEY" in content:
                raise ValueError("private key cannot be used as verification key")
            if not content.startswith("-----BEGIN PUBLIC KEY-----"):
                raise ValueError("expected public P256 key")
            try:
                check = subprocess.run(
                    ["openssl", "pkey", "-pubin", "-in", path, "-text", "-noout"],
                    capture_output=True, timeout=5, check=False)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ValueError("device public key unavailable") from exc
            if check.returncode or b"prime256v1" not in check.stdout:
                raise ValueError("device signing key must be NIST P-256")
        self._keys = dict(keypaths)

    @classmethod
    def load(cls, manifest: str):
        folder = Path(manifest).parent.resolve()
        obj = json.loads(Path(manifest).read_text(encoding="utf-8"))
        if not isinstance(obj, dict) or set(obj) != {"devices"} or not isinstance(obj["devices"], list):
            raise ValueError("invalid pinned device registry")
        keys: dict[tuple[str, str], str] = {}
        for row in obj["devices"]:
            if (not isinstance(row, dict) or set(row) != {"tenant", "session", "file"}
                    or not isinstance(row["file"], str)
                    or not re.fullmatch(r"[A-Za-z0-9_.-]+", row["file"])):
                raise ValueError("invalid pinned device record")
            identity = (row["tenant"], row["session"])
            if identity in keys:
                raise ValueError("duplicate device enrollment")
            key = folder / row["file"]
            if not key.is_file() or key.is_symlink():
                raise ValueError("missing or symlink public device key")
            keys[identity] = str(key)
        return cls(keys)

    def verify(self, *, tenant: str, session: str, challenge: bytes, signature: str) -> bool:
        key = self._keys.get((tenant, session))
        if not key or not isinstance(signature, str) or len(signature) > 192:
            return False
        if not re.fullmatch(r"[A-Za-z0-9_-]+", signature):
            return False
        try:
            sig = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        except (ValueError, binascii.Error):
            return False
        if not 64 <= len(sig) <= 80:
            return False
        if not _SLOTS.acquire(blocking=False):
            return False
        try:
            with tempfile.TemporaryDirectory(prefix="h021-device-verify-") as directory:
                raw = Path(directory) / "challenge"
                signed = Path(directory) / "signature"
                raw.write_bytes(challenge)
                signed.write_bytes(sig)
                try:
                    process = subprocess.run(
                        ["openssl", "dgst", "-sha256", "-verify", key,
                         "-signature", str(signed), str(raw)],
                        capture_output=True, timeout=5, check=False)
                except (OSError, subprocess.TimeoutExpired):
                    return False
                return process.returncode == 0
        finally:
            _SLOTS.release()
