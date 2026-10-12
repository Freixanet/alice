"""Prototype principal-scoped HTTPS JSON endpoint for Alice-owned actors.

NOT a hosted deployment, identity provider, browser sandbox or payment API.
The bearer here represents the Alice backend, never Hermes/the plugin/model.
Use loopback synthetic shop and disposable TLS certs in tests. Do not run with
real merchant credentials. Production needs tenant-auth, quotas, key rotation,
process/container isolation, browser sandbox, persistent job recovery and audit.
"""

from __future__ import annotations

import hmac
import json
import os
import ssl
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Mapping

from .core import AliceRunner, Denied, Indeterminate


@dataclass(frozen=True)
class FixturePrincipal:
    """Test-issued role and identity, resolved from bearer, NEVER a JSON claim.

    Production must independently authenticate the Alice user and rotate/expire
    capabilities; these synthetic, server-provisioned bearer tokens are not it.
    """

    role: str
    tenant: str
    session: str


def _validate_principals(principals: Mapping[str, FixturePrincipal]) -> dict[str, FixturePrincipal]:
    if not isinstance(principals, Mapping) or not principals:
        raise ValueError("explicit fixture principals are required")
    validated = {}
    for token, principal in principals.items():
        if (not isinstance(token, str) or len(token) < 32
                or not isinstance(principal, FixturePrincipal) or principal.role not in ("coordinator", "human")
                or not all(isinstance(x, str) and 0 < len(x) <= 120
                           for x in (principal.tenant, principal.session))):
            raise ValueError("invalid fixture principal")
        validated[token] = principal
    actors: dict[tuple[str, str], set[str]] = {}
    for principal in validated.values():
        actors.setdefault((principal.tenant, principal.session), set()).add(principal.role)
    if any(roles != {"coordinator", "human"} for roles in actors.values()):
        raise ValueError("each synthetic tenant/session requires separate coordinator and human roles")
    return validated


def make_handler(runner: AliceRunner, principals: Mapping[str, FixturePrincipal]):
    principals = _validate_principals(principals)

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
            # Resolve identity from the credential *before* parsing any claims.
            # A valid token for tenant B cannot impersonate tenant A by
            # submitting tenant A/session in JSON, even with a known job_id.
            principal = None
            for token, candidate in principals.items():
                if hmac.compare_digest(bearer, "Bearer " + token):
                    principal = candidate
            role = ("human" if self.path in ("/v1/human-finish", "/v1/human-reissue")
                    else "coordinator")
            if principal is None or principal.role != role:
                self._write(401, {"error": "unauthorized"})
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= size <= 16384:
                    raise Denied("invalid request")
                obj = json.loads(self.rfile.read(size))
                if not isinstance(obj, dict):
                    raise Denied("invalid request")
                # Refuse mismatched client claims instead of silently accepting
                # them; session is also required for human completion.
                if (("tenant" in obj and obj["tenant"] != principal.tenant)
                        or ("session" in obj and obj["session"] != principal.session)):
                    raise Denied("client identity cannot override bearer principal")
                tenant, session = principal.tenant, principal.session
                if self.path == "/v1/jobs":
                    out = runner.new_job(tenant, session, obj["recipient"])
                elif self.path == "/v1/resume":
                    out = runner.resume_job(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/propose":
                    out = runner.propose(obj["job_id"], tenant=tenant, session=session, proposal=obj["proposal"])
                elif self.path == "/v1/challenge":
                    out = runner.challenge(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/approve":
                    out = runner.approve(obj["job_id"], tenant=tenant, session=session, signature=obj["signature"])
                elif self.path == "/v1/commit":
                    out = runner.commit(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/reconcile":
                    out = runner.reconcile_unknown(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/human-handoff":
                    out = runner.human_handoff(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/human-reissue":
                    out = runner.reissue_human_handle(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/human-finish":
                    runner.resume_job(obj["job_id"], tenant=tenant, session=session)
                    out = runner.human_finalize(obj["job_id"], tenant=tenant, human_handle=obj["human_handle"])
                else:
                    self._write(404, {"error": "unknown endpoint"})
                    return
                self._write(200, out)
            except (Denied, KeyError, TypeError, ValueError):
                self._write(403, {"error": "denied"})
            except Indeterminate:
                self._write(409, {"error": "unknown_outcome_do_not_retry"})
            except Exception as exc:
                # Only the disposable H01 test-host logs the exception CLASS.
                # Never include request bodies, credentials or error strings.
                if os.environ.get('H01_SYNTHETIC_ONLY') == 'yes':
                    print('H01_ASR_HANDLER_FAILURE', self.path.split('?', 1)[0],
                          type(exc).__name__, flush=True)
                self._write(503, {"error": "unavailable"})

    return Handler


class RunnerHTTPS:
    """One ephemeral HTTPS server. Do not expose to the public internet."""

    def __init__(self, runner: AliceRunner, *, principals: Mapping[str, FixturePrincipal], cert_file: str,
                 key_file: str):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(runner, principals))
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
