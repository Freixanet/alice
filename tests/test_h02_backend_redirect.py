"""H02 internal bearer must never follow backend redirects (loopback only)."""

from __future__ import annotations

import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from alice_secure_runner import h02_gateway


class PrivateBackendRedirectTests(unittest.TestCase):
    def test_h02_internal_capabilities_are_not_forwarded_to_redirect_target(self):
        target_hits = []

        class Target(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                target_hits.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()

            do_POST = do_GET

        target = ThreadingHTTPServer(("127.0.0.1", 0), Target)
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        target_thread.start()
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)
        self.addCleanup(lambda: target_thread.join(timeout=3))
        redirect_code = [301]

        class PrivateBackend(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.send_response(redirect_code[0])
                self.send_header("Location", f"http://127.0.0.1:{target.server_port}/stolen")
                self.end_headers()

        private = ThreadingHTTPServer(("127.0.0.1", 0), PrivateBackend)
        private_thread = threading.Thread(target=private.serve_forever, daemon=True)
        private_thread.start()
        self.addCleanup(private.server_close)
        self.addCleanup(private.shutdown)
        self.addCleanup(lambda: private_thread.join(timeout=3))

        gateway = object.__new__(h02_gateway.H02Gateway)
        gateway.verify_only = False
        gateway.backend = {"a": {"coordinator": "fictional-private-bearer",
                                 "human": "fictional-private-human"}}
        gateway.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            h02_gateway._DenyPrivateBackendRedirect())
        with patch.object(h02_gateway, "BACKEND_ORIGIN",
                          f"http://127.0.0.1:{private.server_port}"):
            for code in (301, 302, 303, 307, 308):
                with self.subTest(code=code):
                    redirect_code[0] = code
                    status, result = gateway.forward(
                        "a", "coordinator", "/v1/resume", {"job_id": "fictional"})
                    self.assertEqual(status, 503)
                    self.assertEqual(result["error"], "unavailable")
                    self.assertEqual(target_hits, [],
                                     "private bearer followed a redirect to another origin")


if __name__ == "__main__":
    unittest.main()
