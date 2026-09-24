"""An authenticator key given once is kept with the site's saved login; codes are then minted."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_vault_otp_test", Path(__file__).resolve().parents[1] / "vault_otp.py")
otp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(otp)

try:
    from agent.vault_store import VaultStore, totp_now
except ImportError:  # pragma: no cover
    VaultStore = None

SEED = "JBSWY3DPEHPK3PXP"


@unittest.skipIf(VaultStore is None, "Hermes is not on the path")
class OtpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = VaultStore(Path(self.tmp.name) / "vault")
        patcher = mock.patch.object(otp, "_store", return_value=self.store)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store.add_item("login", "shop", {"identifier_type": "email", "identifier": "a@b.c", "password": "pw"},
                            origin="https://www.shop.es")

    def test_the_key_joins_the_login_and_the_current_code_comes_back(self):
        result = otp.add("shop.es", f"otpauth://totp/Shop:a@b.c?secret={SEED}&issuer=Shop")
        self.assertEqual(result["sites"], ["https://www.shop.es"])
        self.assertEqual(result["code"], totp_now(SEED))
        [login] = [m for m in self.store.list_items() if m.kind == "login"]
        self.assertTrue(login.has_otp)
        self.assertEqual(self.store.resolve_secret(login.id)["password"], "pw")
        self.assertEqual(login.identifier, "a@b.c")
        self.assertEqual(otp.status("https://www.shop.es/login"), {"saved_login": True, "has_key": True})

    def test_nonsense_or_no_login_is_refused_without_echoing_the_key(self):
        with self.assertRaises(otp.OtpError) as bad:
            otp.add("shop.es", "not a key!!")
        self.assertNotIn("not a key", str(bad.exception))
        with self.assertRaises(otp.OtpError):
            otp.add("other.es", SEED)


if __name__ == "__main__":
    unittest.main()
