"""The free-first web provider: Exa and Jina when they answer, Firecrawl only when not.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import asyncio
import importlib.util
import json
import os
import sys
import tempfile
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


class ExaKeyedTests(unittest.TestCase):
    def test_results_come_back_in_hermes_shape(self):
        seen = {}

        def fetch(request):
            seen["key"] = request.get_header("X-api-key")
            seen["body"] = json.loads(request.data)
            reply = {"results": [{"url": "https://a", "title": "A", "text": "uno\n dos"}, {"title": "no url"}]}
            return 200, json.dumps(reply).encode()

        result = free_web.exa_search_keyed("q", 50, "secret", fetch=fetch)
        self.assertEqual(seen["key"], "secret")
        self.assertEqual(seen["body"]["numResults"], 10)
        self.assertEqual(result, {"success": True, "data": {"web": [{"url": "https://a", "title": "A", "description": "uno dos"}]}})

    def test_an_http_error_is_an_answer(self):
        result = free_web.exa_search_keyed("q", 5, "k", fetch=lambda _r: (429, b"{}"))
        self.assertEqual(result, {"success": False, "error": "Exa: HTTP 429"})


class ExaKeyTests(unittest.TestCase):
    def test_the_environment_wins(self):
        with mock.patch.dict(os.environ, {"EXA_API_KEY": " env "}):
            self.assertEqual(free_web.exa_key(), "env")

    def test_a_key_saved_to_the_env_file_is_read_without_a_restart(self):
        with tempfile.TemporaryDirectory() as profile, tempfile.TemporaryDirectory() as root:
            Path(root, ".env").write_text('OTHER=1\nexport EXA_API_KEY="from-main"\n', encoding="utf-8")
            constants = types.ModuleType("hermes_constants")
            constants.get_hermes_home = lambda: profile
            constants.get_default_hermes_root = lambda: root
            with mock.patch.dict(os.environ, {"EXA_API_KEY": ""}), mock.patch.dict(sys.modules, {"hermes_constants": constants}):
                self.assertEqual(free_web.exa_key(), "from-main")
                Path(profile, ".env").write_text("EXA_API_KEY=from-profile\n", encoding="utf-8")
                self.assertEqual(free_web.exa_key(), "from-profile")


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
        # No key unless a test sets one: the machine running this may have one.
        self.env = mock.patch.object(free_web, "exa_key", return_value="")
        self.env.start()
        self.provider = free_web._build_provider_class()()

    def tearDown(self):
        self.env.stop()
        self.modules.stop()

    def test_own_key_is_used_before_the_keyless_endpoint(self):
        hits = {"success": True, "data": {"web": [{"url": "https://k", "title": "K", "description": ""}]}}
        with mock.patch.object(free_web, "exa_key", return_value="k"), \
                self._keyless({"success": True, "data": {"web": [{"url": "https://free"}]}}), \
                mock.patch.object(free_web, "exa_search_keyed", return_value=hits) as keyed:
            self.assertEqual(self.provider.search("q", 5), hits)
        keyed.assert_called_once_with("q", 5, "k")

    def test_a_failing_key_still_tries_the_keyless_endpoint(self):
        free = {"success": True, "data": {"web": [{"url": "https://free"}]}}
        with mock.patch.object(free_web, "exa_key", return_value="k"), self._keyless(free), \
                mock.patch.object(free_web, "exa_search_keyed", return_value={"success": False, "error": "Exa: HTTP 401"}):
            self.assertEqual(self.provider.search("q", 5), free)

    def test_dead_search_says_how_to_fix_it(self):
        limited = {"success": False, "error": "You've hit Exa's free MCP rate limit."}
        with self._keyless(limited), mock.patch.object(free_web, "RETRY_PAUSE", 0), \
                mock.patch.object(free_web, "_paid_provider", return_value=None):
            result = self.provider.search("q", 5)
        self.assertFalse(result["success"])
        # The agent is sent to Alice's secure card, never to ask for the key in the chat.
        self.assertIn("alice://connect/search", result["error"])
        self.assertIn("Do not ask for the key in the chat", result["error"])

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
        with self._keyless({"success": True, "data": {"web": []}}), mock.patch.object(free_web, "RETRY_PAUSE", 0), \
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
        with mock.patch.object(free_web, "RETRY_PAUSE", 0), mock.patch.object(free_web, "jina_read", side_effect=lambda u: good if u == "https://ok" else bad), \
                mock.patch.object(free_web, "_paid_provider", return_value=paid):
            pages = asyncio.run(self.provider.extract(["https://ok", "https://wall"]))
        self.assertEqual(pages[0], good)
        self.assertEqual(pages[1]["content"], "paid")


if __name__ == "__main__":
    unittest.main()
