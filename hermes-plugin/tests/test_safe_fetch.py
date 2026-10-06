"""Icons and pictures are fetched from public https addresses only, redirects included."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_safe_fetch_test", Path(__file__).resolve().parents[1] / "safe_fetch.py")
safe_fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe_fetch)


def resolves(*addresses):
    return mock.patch.object(safe_fetch.socket, "getaddrinfo",
                             return_value=[(2, 1, 6, "", (a, 443)) for a in addresses])


class SafeTests(unittest.TestCase):
    def test_inside_addresses_are_refused(self):
        for address in ("127.0.0.1", "192.168.1.10", "10.0.0.2", "100.101.5.7", "169.254.169.254", "::1"):
            with resolves(address):
                self.assertFalse(safe_fetch.safe("https://looks-public.example/icon.png"), address)

    def test_a_public_https_address_passes(self):
        with resolves("93.184.216.34"):
            self.assertTrue(safe_fetch.safe("https://example.com/icon.png"))

    def test_plain_http_and_odd_schemes_are_refused(self):
        with resolves("93.184.216.34"):
            for url in ("http://example.com/a.png", "file:///etc/passwd", "ftp://example.com/x", ""):
                self.assertFalse(safe_fetch.safe(url), url)

    def test_a_redirect_inside_is_refused(self):
        handler = safe_fetch._Checked()
        with resolves("127.0.0.1"):
            with self.assertRaises(ValueError):
                handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example/json/version")


if __name__ == "__main__":
    unittest.main()
