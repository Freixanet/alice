#!/usr/bin/env python3
"""Pruebas de reach.py sin red. Un proceso real solo comprueba el timeout.

    python3 hermes-agents/internet/tests/test_reach.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from reach import (  # noqa: E402
    ReachError,
    _opencli,
    default_spawn,
    execute,
    public_http_url,
    redact,
)


def _which(found):
    def which(name):
        return found.get(name)

    return which


class ReachTests(unittest.TestCase):
    def test_rejects_private_and_credential_urls(self):
        for url in (
            "http://127.0.0.1/",
            "http://169.254.169.254/latest/meta-data",
            "http://localhost/admin",
            "file:///etc/passwd",
            "https://user:secret@example.com/",
            "https://10.1.2.3/",
        ):
            with self.assertRaises(ReachError):
                public_http_url(url)

    def test_search_query_is_one_argument(self):
        seen = []

        def spawn(argv, timeout, env=None):
            seen.append(argv)
            return 0, json.dumps([{"title": "Uno", "url": "https://example.com", "text": "cuerpo"}]), "", False

        result = execute(
            {"capability": "web.search", "query": "grok; rm -rf /"},
            spawn=spawn,
            which=_which({"mcporter": "mcporter"}),
        )
        self.assertTrue(result["ok"])
        self.assertEqual(seen[0][3], "query=grok; rm -rf /")
        self.assertEqual(result["sources"][0]["url"], "https://example.com")
        self.assertEqual(result["backend"], "exa")

    def test_timeout_and_malformed_and_secret(self):
        def timeout_spawn(argv, timeout, env=None):
            return 1, "", "", True

        timed = execute(
            {"capability": "web.search", "query": "hola"},
            spawn=timeout_spawn,
            which=_which({"mcporter": "mcporter"}),
        )
        self.assertEqual(timed["error"]["code"], "timeout")

        def bad_spawn(argv, timeout, env=None):
            return 0, "{", "", False

        bad = execute(
            {"capability": "web.search", "query": "hola"},
            spawn=bad_spawn,
            which=_which({"mcporter": "mcporter"}),
        )
        self.assertEqual(bad["error"]["code"], "malformed")

        token = "super-secret-token-value"
        os.environ["TWITTER_AUTH_TOKEN"] = token
        try:
            self.assertNotIn(token, redact(f"fallo auth_token={token}"))
            self.assertIn("[redacted]", redact(f"visto {token}"))
        finally:
            del os.environ["TWITTER_AUTH_TOKEN"]

    def test_missing_backend_and_write_command(self):
        missing = execute(
            {"capability": "web.search", "query": "hola"},
            spawn=lambda *args: (_ for _ in ()).throw(AssertionError("no debe ejecutar")),
            which=_which({}),
        )
        self.assertEqual(missing["error"]["code"], "unavailable")

        with self.assertRaises(ReachError) as caught:
            _opencli(lambda *args: (0, "", "", False), _which({"opencli": "opencli"}), "facebook", "add-friend", "zuck", 5)
        self.assertEqual(caught.exception.code, "rejected")

    def test_transcript_falls_back_when_subtitles_are_empty(self):
        calls = []

        def spawn(argv, timeout, env=None):
            calls.append(argv[0])
            if "opencli" in argv[0]:
                return 0, "title: demo\ntexto del vídeo", "", False
            return 0, "", "", False

        result = execute(
            {"capability": "video.transcript", "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw"},
            spawn=spawn,
            which=_which({"yt-dlp": "/usr/bin/yt-dlp", "opencli": "/usr/bin/opencli"}),
            opencli_ready=lambda: True,
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["backend"], "opencli")
        self.assertIn("yt-dlp:empty", result["fallback"])
        self.assertEqual(calls, ["/usr/bin/yt-dlp", "/usr/bin/opencli"])

    def test_rss_normalization_and_private_feed(self):
        xml = b"""<?xml version="1.0"?>
        <rss><channel><item>
          <title>Novedad</title>
          <link>https://example.com/post</link>
          <pubDate>Mon, 22 Sep 2026 10:00:00 GMT</pubDate>
          <description>Resumen</description>
        </item></channel></rss>"""

        def fetch(url, timeout, headers, limit):
            return 200, xml

        result = execute({"capability": "rss.read", "url": "https://example.com/feed.xml"}, fetch=fetch)
        self.assertTrue(result["ok"])
        self.assertEqual(result["sources"][0]["title"], "Novedad")
        self.assertEqual(result["sources"][0]["url"], "https://example.com/post")
        self.assertEqual(result["sources"][0]["platform"], "rss")

        blocked = execute({"capability": "rss.read", "url": "http://192.168.1.2/feed"}, fetch=fetch)
        self.assertEqual(blocked["error"]["code"], "rejected")

    def test_health_cache_skips_doctor(self):
        calls = []

        def spawn(argv, timeout, env=None):
            calls.append(argv)
            return 0, json.dumps({"web": {"status": "ok", "message": "jina", "active_backend": "Jina Reader"}}), "", False

        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / "health.json"
            first = execute(
                {"capability": "health"},
                spawn=spawn,
                which=_which({"agent-reach": "agent-reach"}),
                health_cache=cache,
                now=1_000_000,
            )
            second = execute(
                {"capability": "health"},
                spawn=spawn,
                which=_which({"agent-reach": "agent-reach"}),
                health_cache=cache,
                now=1_000_100,
            )
        self.assertEqual(len(calls), 1)
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(second["channels"][0]["id"], "web")

    def test_batch_keeps_going_when_one_job_fails(self):
        def spawn(argv, timeout, env=None):
            if "roto" in argv[3]:
                return 1, "", "429 demasiado", False
            return 0, json.dumps([{"title": "Bien", "url": "https://example.com/a"}]), "", False

        raw_jobs = [
            {"capability": "web.search", "query": "roto"},
            {"capability": "web.search", "query": "bien"},
        ]

        def fetch(*args):
            raise AssertionError("no")

        # El lote entra por execute de cada job, no por la CLI.
        from concurrent.futures import ThreadPoolExecutor

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(
                pool.map(
                    lambda job: execute(job, spawn=spawn, fetch=fetch, which=_which({"mcporter": "mcporter"})),
                    raw_jobs,
                )
            )
        self.assertEqual(results[0]["error"]["code"], "rate_limit")
        self.assertTrue(results[1]["ok"])

    def test_exa_text_cards_and_disconnected_opencli(self):
        card = (
            "Title: Agent Reach\nURL: https://github.com/Panniantong/Agent-Reach\n"
            "Published: N/A\nAuthor: N/A\nHighlights:\nUn CLI de internet.\n\n"
            "Title: Docs\nURL: https://github.com/Panniantong/Agent-Reach/blob/main/docs/install.md\n"
            "Highlights:\nInstalación.\n"
        )

        def spawn(argv, timeout, env=None):
            return 0, json.dumps({"content": [{"type": "text", "text": card}]}), "", False

        found = execute(
            {"capability": "web.search", "query": "agent reach"},
            spawn=spawn,
            which=_which({"mcporter": "mcporter"}),
        )
        self.assertTrue(found["ok"])
        self.assertEqual(found["results"], 2)
        self.assertEqual(found["sources"][0]["url"], "https://github.com/Panniantong/Agent-Reach")

        calls = []

        def social_spawn(argv, timeout, env=None):
            calls.append(argv)
            return 0, "", "", False

        saved = {key: os.environ.pop(key, None) for key in ("TWITTER_AUTH_TOKEN", "TWITTER_CT0")}
        try:
            blocked = execute(
                {"capability": "social.search", "platform": "x", "query": "grok"},
                spawn=social_spawn,
                which=_which({"twitter": "twitter", "opencli": "opencli"}),
                config_path=Path("/tmp/alice-reach-no-config.yaml"),
                opencli_ready=lambda: False,
            )
        finally:
            for key, value in saved.items():
                if value is not None:
                    os.environ[key] = value
        self.assertEqual(blocked["error"]["code"], "unauthorized")
        self.assertEqual(calls, [])

    def test_upstream_timeout_kills_the_process(self):
        code, _out, _err, timed_out = default_spawn(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            0.4,
        )
        self.assertTrue(timed_out)
        self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
