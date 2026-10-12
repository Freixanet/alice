"""Prototype authenticated HTTPS JSON endpoint for an Alice-owned coordinator.

NOT a hosted deployment, identity provider, browser sandbox or payment API.
The bearer here represents the Alice backend, never Hermes/the plugin/model.
Use loopback synthetic shop and disposable TLS certs in tests. Do not run with
real merchant credentials. Production needs tenant-auth, quotas, key rotation,
process/container isolation, browser sandbox, persistent job recovery and audit.
"""

from __future__ import annotations

import hmac
import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .core import AliceRunner, Denied, Indeterminate


def make_handler(runner: AliceRunner, coordinator_token: str, human_token: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def _write(self, status, data):
            out = json.dumps(data, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_POST(self):
            bearer = self.headers.get("Authorization") or ""
            # A distinct Alice-owned human-facing capability is necessary even
            # for this mock endpoint; the planner and backend bearer cannot
            # claim human completion. This is NOT real user authentication.
            expected = (human_token if self.path in ("/v1/human-finish", "/v1/human-reissue")
                        else coordinator_token)
            if not hmac.compare_digest(bearer, "Bearer " + expected):
                self._write(401, {"error": "unauthorized"})
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= size <= 16384:
                    raise Denied("invalid request")
                obj = json.loads(self.rfile.read(size))
                if not isinstance(obj, dict):
                    raise Denied("invalid request")
                if self.path == "/v1/jobs":
                    out = runner.new_job(obj["tenant"], obj["session"], obj["recipient"])
                elif self.path == "/v1/resume":
                    out = runner.resume_job(obj["job_id"], tenant=obj["tenant"], session=obj["session"])
                elif self.path == "/v1/propose":
                    out = runner.propose(obj["job_id"], tenant=obj["tenant"],
                                         session=obj["session"], proposal=obj["proposal"])
                elif self.path == "/v1/challenge":
                    out = runner.challenge(obj["job_id"], tenant=obj["tenant"], session=obj["session"])
                elif self.path == "/v1/approve":
                    out = runner.approve(obj["job_id"], tenant=obj["tenant"],
                                         session=obj["session"], signature=obj["signature"])
                elif self.path == "/v1/commit":
                    out = runner.commit(obj["job_id"], tenant=obj["tenant"], session=obj["session"])
                elif self.path == "/v1/human-handoff":
                    out = runner.human_handoff(obj["job_id"], tenant=obj["tenant"], session=obj["session"])
                elif self.path == "/v1/human-reissue":
                    out = runner.reissue_human_handle(obj["job_id"], tenant=obj["tenant"], session=obj["session"])
                elif self.path == "/v1/human-finish":
                    out = runner.human_finalize(obj["job_id"], tenant=obj["tenant"],
                                                human_handle=obj["human_handle"])
                else:
                    self._write(404, {"error": "unknown endpoint"})
                    return
                self._write(200, out)
            except (Denied, KeyError, TypeError, ValueError):
                self._write(403, {"error": "denied"})
            except Indeterminate:
                self._write(409, {"error": "unknown_outcome_do_not_retry"})
            except Exception:
                self._write(503, {"error": "unavailable"})

    return Handler


class RunnerHTTPS:
    """One ephemeral HTTPS server. Do not expose to the public internet."""

    def __init__(self, runner: AliceRunner, *, coordinator_token: str, human_token: str,
                 cert_file: str, key_file: str):
        if (len(coordinator_token) < 32 or len(human_token) < 32
                or hmac.compare_digest(coordinator_token, human_token)):
            raise ValueError("invalid or shared Alice backend/human token")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(runner, coordinator_token, human_token))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert_file, key_file)
        self.server.socket = ctx.wrap_socket(self.server.socket, server_side=True)
        self.url = f"https://localhost:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
