"""Alice-owned H02 HTTPS ingress with request-bound rotating capabilities.

Standalone synthetic experiment. This gateway and H01-compatible ASR backend
MUST both run only on an Alice-owned VM, not a Hermes-administered host.
"""
from __future__ import annotations

import json
import os
import ssl
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .h02_identity import InvalidCapability, Keyring, ReplayLedger, ROLE_PATHS
from .h021_crypto import PublicVerifier
from .h021_transport import HeaderDeadlineReader, LimitedHTTPServer, read_body_with_deadline

MAX_BODY = 16384
BACKEND_ORIGIN = "https://asr:8443"  # fixed Docker-internal origin; never user-controlled


class H02Gateway:
    def __init__(self, *, keyring: Keyring | PublicVerifier, ledger: ReplayLedger,
                 assignments: dict, backend: dict, ca_file: str):
        self.keyring = keyring
        self.verify_only = isinstance(keyring, PublicVerifier)
        self.ledger = ledger
        # Alice operator-provisioned subject -> actor mapping; neither model
        # nor caller JSON chooses which backend Alice identity is used.
        if not assignments or not all(
                isinstance(v, dict) and set(v) == {"actor", "tenant", "session"}
                and v["actor"] in backend
                and v["tenant"] == "fixture-tenant-" + v["actor"]
                and v["session"] == "fixture-session-" + v["actor"]
                for v in assignments.values()):
            raise ValueError("untrusted or non-fixture subject mapping")
        self.assignments = assignments
        self.backend = backend
        self.ca = ssl.create_default_context(cafile=ca_file)
        self.ca.minimum_version = ssl.TLSVersion.TLSv1_2
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=self.ca))

    def authorize(self, authorization: str, path: str, body: bytes):
        if not authorization.startswith("Alice-H02 "):
            raise InvalidCapability("missing scoped authorization")
        claims, obj = self.keyring.verify(authorization[len("Alice-H02 "):],
                                          path=path, body=body)
        principal = self.assignments.get(claims["sub"])
        if principal is None or (claims["tenant"], claims["session"]) != (
                principal["tenant"], principal["session"]):
            raise InvalidCapability("unregistered or mismatched identity")
        # Consume BEFORE forwarding; failure/timeout requires trusted Alice to
        # inspect durable job state, not replay the last operation.
        self.ledger.consume(claims)
        return principal["actor"], claims["role"], obj

    def forward(self, actor: str, role: str, path: str, obj: dict,
                *, raw_body: bytes | None = None, signed_token: str | None = None):
        scope = "human" if role == "human" else "coordinator"
        token = self.backend[actor][scope]
        data = dict(obj)
        data["tenant"] = "fixture-tenant-" + actor
        data["session"] = "fixture-session-" + actor
        if path == "/v1/proposals" and set(data) != {"tenant", "session", "job_id", "proposal"}:
            raise InvalidCapability("unexpected proposal shape")
        private_path = "/v1/propose" if path == "/v1/proposals" else path
        if self.verify_only:
            # Independent ASR guard verifies the EXACT original bytes and the
            # same signature again. Gateway cannot alter tenant, role, job or
            # body and cannot mint an OWNER/HUMAN signature when compromised.
            if raw_body is None or signed_token is None:
                raise InvalidCapability("H02.1 requires signed raw body")
            payload = raw_body
        else:
            payload = json.dumps(data, separators=(",", ":"), allow_nan=False).encode()
        req = urllib.request.Request(BACKEND_ORIGIN + private_path, data=payload,
                                     method="POST", headers={
                                         "Authorization": "Bearer " + token,
                                         **({"X-Alice-H021-Capability": signed_token}
                                            if self.verify_only else {}),
                                         "Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=10) as response:
                value = response.read(MAX_BODY + 1)
                if len(value) > MAX_BODY:
                    raise ValueError("private broker oversized response")
                return response.status, json.loads(value)
        except urllib.error.HTTPError as exc:
            return (exc.code if exc.code in (401, 403, 409) else 503,
                    {"error": ("denied" if exc.code in (401, 403)
                               else "unknown_outcome_do_not_retry" if exc.code == 409
                               else "unavailable")})


def make_handler(gateway: H02Gateway):
    admission = threading.BoundedSemaphore(12)
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            if gateway.verify_only:
                self.rfile = HeaderDeadlineReader(self.rfile, self.connection)

        def parse_request(self):
            accepted = super().parse_request()
            if gateway.verify_only:
                self.rfile.headers_complete()
            return accepted

        def log_message(self, *_):
            return

        def reply(self, status, obj):
            raw = json.dumps(obj, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if self.path == "/health":
                # No privileged endpoint or backend discovery exposed.
                self.reply(200, {"status": "h02_gateway_listening_fixture"})
            else:
                self.reply(404, {"error": "not_found"})

        def do_POST(self):
            if gateway.verify_only:
                if not admission.acquire(blocking=False):
                    self.reply(503, {"error": "verification_busy_no_effect"})
                    return
                try:
                    self._do_post_bounded()
                finally:
                    admission.release()
            else:
                self._do_post_bounded()

        def _do_post_bounded(self):
            if self.path not in set().union(*ROLE_PATHS.values()):
                self.reply(404, {"error": "not_found"})
                return
            try:
                if (self.headers.get("Transfer-Encoding")
                        or self.headers.get("Content-Type") != "application/json"):
                    raise InvalidCapability("ambiguous or wrong content encoding")
                length = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= length <= MAX_BODY:
                    raise InvalidCapability("body size outside limit")
                raw = (read_body_with_deadline(self, length) if gateway.verify_only
                       else self.rfile.read(length))
                if len(raw) != length:
                    raise InvalidCapability("truncated request")
                actor, role, obj = gateway.authorize(
                    self.headers.get("Authorization", ""), self.path, raw)
                status, result = gateway.forward(
                    actor, role, self.path, obj, raw_body=raw,
                    signed_token=(self.headers.get("Authorization", "")[len("Alice-H02 "):]
                                  if gateway.verify_only else None))
                self.reply(status, result)
            except (InvalidCapability, ValueError, KeyError, TypeError):
                self.reply(403, {"error": "denied"})
            except Exception as exc:
                if os.environ.get("H02_SYNTHETIC_ONLY") == "yes":
                    print("H02_BACKEND_FAILURE", type(exc).__name__, flush=True)
                self.reply(503, {"error": "unavailable_do_not_retry"})

    return Handler


def fixture_secret(name: str) -> str:
    value = (Path("/run/h01-secrets") / name).read_text().strip()
    if len(value) < 40:
        raise ValueError("invalid private backend capability")
    return value


def main():
    if os.environ.get("H02_SYNTHETIC_ONLY") != "yes":
        raise SystemExit("H02 REFUSED: synthetic independent-host proof only")
    keyring = (PublicVerifier.load("/run/h021-auth/public.json")
               if os.environ.get("H021_VERIFY_ONLY") == "yes" else
               Keyring.load("/run/h02-auth/keyring.json"))
    assignments = json.loads(Path("/run/h02-auth/subjects.json").read_text())
    backend = {name: {"coordinator": fixture_secret("backend_coordinator_" + name),
                      "human": fixture_secret("backend_human_" + name)}
               for name in ("a", "b")}
    ledger = ReplayLedger("/var/lib/h02/consumed.sqlite3")
    gateway = H02Gateway(keyring=keyring, ledger=ledger, assignments=assignments,
                         backend=backend, ca_file="/run/h01-ca/asr.pem")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain("/run/h01-tls/gateway.pem", "/run/h01-tls/gateway.key")
    server_type = LimitedHTTPServer if gateway.verify_only else ThreadingHTTPServer
    server = server_type(("0.0.0.0", 8443), make_handler(gateway))
    if gateway.verify_only:
        server.tls_context = tls
    else:
        server.socket = tls.wrap_socket(server.socket, server_side=True)
    print("H02 synthetic scoped gateway: HTTPS ingress", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        ledger.close()


if __name__ == "__main__":
    main()
