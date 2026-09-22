"""The free-first web provider: Exa and Jina when they answer, Firecrawl only when not.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import asyncio
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "free_web.py"
spec = importlib.util.spec_from_file_location("alice_free_web_test", PATH)
free_web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(free_web)

LONG = "Title: Página\nURL Source: https://example.com\n\nMarkdown Content:\n" + "texto útil " * 40


class _Base:
    pass


class JinaTests(unittest.TestCase):
    def test_reads_a_public_page(self):
        with mock.patch.object(free_web, "_public_http", return_value=True):
            page = free_web.jina_read("https://example.com", fetch=lambda _r: (200, LONG.encode()))
        self.assertNotIn("error", page)
        self.assertEqual(page["title"], "Página")
        self.assertTrue(page["content"].startswith("texto útil"))

    def test_private_addresses_never_leave(self):
        page = free_web.jina_read("http://127.0.0.1/admin", fetch=lambda _r: self.fail("fetched"))
        self.assertIn("error", page)

    def test_a_nearly_empty_page_counts_as_failed(self):
        with mock.patch.object(free_web, "_public_http", return_value=True):
            page = free_web.jina_read("https://example.com", fetch=lambda _r: (200, b"Title: x\n\nMarkdown Content:\nLogin"))
        self.assertIn("error", page)


class ProviderTests(unittest.TestCase):
    def setUp(self):
        # Stand-ins for Hermes' modules, so the test runs without Hermes.
        base = types.ModuleType("agent.web_search_provider")

        class WebSearchProvider:
            pass

        base.WebSearchProvider = WebSearchProvider
        self.modules = mock.patch.dict(sys.modules, {
            "agent": types.ModuleType("agent"), "agent.web_search_provider": base,
        })
        self.modules.start()
        self.provider = free_web._build_provider_class()()

    def tearDown(self):
        self.modules.stop()

    def _keyless(self, result):
        module = types.ModuleType("plugins.web.keyless_mcp")
        module.exa_search_keyless = lambda query, limit: result
        return mock.patch.dict(sys.modules, {"plugins": types.ModuleType("plugins"),
                                             "plugins.web": types.ModuleType("plugins.web"),
                                             "plugins.web.keyless_mcp": module})

    def test_free_search_answers_without_the_paid_backend(self):
        hits = {"success": True, "data": {"web": [{"url": "https://a", "title": "A"}]}}
        paid = mock.Mock()
        with self._keyless(hits), mock.patch.object(free_web, "_paid_provider", return_value=paid):
            self.assertEqual(self.provider.search("q", 5), hits)
        paid.search.assert_not_called()

    def test_empty_free_search_falls_back_to_paid(self):
        paid = mock.Mock()
        paid.search.return_value = {"success": True, "data": {"web": [{"url": "https://b"}]}}
        with self._keyless({"success": True, "data": {"web": []}}), \
                mock.patch.object(free_web, "_paid_provider", return_value=paid):
            result = self.provider.search("q", 5)
        paid.search.assert_called_once_with("q", 5)
        self.assertEqual(result["data"]["web"][0]["url"], "https://b")

    def test_only_unread_pages_go_to_paid(self):
        good = {"url": "https://ok", "title": "t", "content": "c"}
        bad = {"url": "https://wall", "title": "", "content": "", "error": "Jina: HTTP 403"}
        paid = mock.Mock()

        async def paid_extract(urls, **_):
            return [{"url": u, "title": "p", "content": "paid"} for u in urls]

        paid.extract = paid_extract
        with mock.patch.object(free_web, "jina_read", side_effect=lambda u: good if u == "https://ok" else bad), \
                mock.patch.object(free_web, "_paid_provider", return_value=paid):
            pages = asyncio.run(self.provider.extract(["https://ok", "https://wall"]))
        self.assertEqual(pages[0], good)
        self.assertEqual(pages[1]["content"], "paid")


if __name__ == "__main__":
    unittest.main()
