"""P-256 consent contract with ephemeral SOFTWARE keys; not device attestation."""
from __future__ import annotations

import base64
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from alice_secure_runner.device_approval import P256DeviceConsent


class PublicOnlyDeviceApproval(unittest.TestCase):
    def test_exact_consent_cross_session_revocation_and_public_only(self):
        with tempfile.TemporaryDirectory(prefix="h021-device-test-") as directory:
            root = Path(directory)
            private = root / "private.pem"
            public = root / "device.pub.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC",
                            "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-out", str(private)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout",
                            "-out", str(public)], check=True, capture_output=True)
            manifest = root / "devices.json"
            manifest.write_text(json.dumps({"devices": [
                {"tenant": "a", "session": "pair-a", "file": "device.pub.pem"}]}))
            verifier = P256DeviceConsent.load(str(manifest))
            content = (b'{"amount_minor":4998,"checkout_id":"fictional",'
                       b'"recipient":"synthetic address","tax_minor":0}')
            signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private)],
                                    input=content, capture_output=True, check=True).stdout
            token = base64.urlsafe_b64encode(signed).decode().rstrip("=")
            self.assertTrue(verifier.verify(tenant="a", session="pair-a",
                                            challenge=content, signature=token))
            self.assertFalse(verifier.verify(tenant="a", session="pair-b",
                                             challenge=content, signature=token))
            self.assertFalse(verifier.verify(tenant="b", session="pair-a",
                                             challenge=content, signature=token))
            self.assertFalse(verifier.verify(tenant="a", session="pair-a",
                                             challenge=content + b" ", signature=token))
            self.assertFalse(verifier.verify(tenant="a", session="pair-a",
                                             challenge=content, signature="invalid"))
            with self.assertRaises(ValueError):
                P256DeviceConsent({("a", "pair-a"): str(private)})
            manifest.write_text(json.dumps({"devices": []}))
            with self.assertRaises(ValueError):
                P256DeviceConsent.load(str(manifest))


if __name__ == "__main__":
    unittest.main()
