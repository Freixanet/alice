"""Connector logos come from the product's own site, are cached, and never from a
private host or an icon service.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "alice_connector_icons_test", Path(__file__).resolve().parents[1] / "connector_icons.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 200


class ConnectorIconTests(unittest.TestCase):
    def test_sites_prefer_the_product_and_skip_private_or_package_hosts(self):
        self.assertEqual(
            ci.sites(["notion.so"], ["https://mcp.notion.com/mcp", "https://developers.notion.com/docs/mcp"]),
            ["https://notion.so", "https://mcp.notion.com", "https://developers.notion.com", "https://notion.com"],
        )
        self.assertEqual(ci.sites([], ["http://127.0.0.1:8000/mcp", "https://github.com/x/y",
                                       "http://192.168.1.4/mcp", "https://box.local/mcp"]), [])
        # GitLab's own connector may wear gitlab.com's mark; a random bridge on it may not.
        self.assertEqual(ci.sites([], ["https://gitlab.com/api/v4/mcp"], "gitlab"), ["https://gitlab.com"])
        self.assertEqual(ci.sites([], ["https://gitlab.com/someone/bridge"], "notion"), [])

    def test_candidates_rank_touch_icons_first_and_drop_svg(self):
        page = ('<link rel="icon" href="/fav.svg"><link rel="icon" sizes="32x32" href="/f32.png">'
                '<link rel="apple-touch-icon" sizes="180x180" href="/touch.png">'
                '<link rel="icon" sizes="192x192" href="https://cdn.x.com/i192.png">')
        self.assertEqual(ci.candidates(page, "https://x.com"), [
            "https://x.com/touch.png", "https://cdn.x.com/i192.png", "https://x.com/f32.png",
            "https://x.com/apple-touch-icon.png", "https://x.com/favicon.ico",
        ])

    def test_resolve_takes_the_first_raster_and_skips_html_errors(self):
        calls = []

        def fetch(url, limit):
            calls.append(url)
            if url == "https://x.com/":
                return b'<link rel="apple-touch-icon" href="/t.png">', "text/html"
            if url == "https://x.com/t.png":
                return b"<html>not found</html>" * 10, "text/html"
            if url == "https://x.com/apple-touch-icon.png":
                return PNG, "application/octet-stream"
            raise OSError("nope")

        self.assertEqual(ci.resolve(["https://x.com"], fetch), (PNG, "image/png"))
        self.assertIn("https://x.com/t.png", calls)

    def test_cache_keeps_hits_a_month_and_misses_a_day(self):
        with tempfile.TemporaryDirectory() as home:
            clock = [1000.0]
            asked = []

            def fetch(url, limit):
                asked.append(url)
                if url.endswith("/favicon.ico"):
                    return PNG, "image/png"
                raise OSError("no")

            icons = ci.Icons(Path(home), now=lambda: clock[0], fetch=fetch)
            self.assertEqual(icons.get("linear", ["linear.app"], []), (PNG, "image/png"))
            count = len(asked)
            clock[0] += 86_400 * 10
            self.assertEqual(icons.get("linear", ["linear.app"], []), (PNG, "image/png"))
            self.assertEqual(len(asked), count)  # served from the cache

            none = ci.Icons(Path(home), now=lambda: clock[0], fetch=lambda u, l: (_ for _ in ()).throw(OSError()))
            self.assertIsNone(none.get("nothing", ["nothing.example"], []))
            self.assertIsNone(icons.get("nothing", ["nothing.example"], []))  # the miss is remembered
            self.assertIsNone(icons.get("../etc", ["x.com"], []))


if __name__ == "__main__":
    unittest.main()
