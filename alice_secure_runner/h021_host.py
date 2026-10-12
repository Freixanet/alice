"""H02.1 Alice-owned synthetic ASR: independent signed request enforcement.

Gateway's backend bearer alone MUST NOT permit /v1/commit, owner or human
operations. Public-only verifier and a second persisted replay ledger belong
to ASR's private administrative domain. Preserve H01 merchant/UNKNOWN logic.
"""
from __future__ import annotations

import hmac
import io
import json
import os
import secrets
import ssl
import threading
from contextlib import nullcontext
from http.server import ThreadingHTTPServer

from .browser_fixture import BrowserFixtureReadAdapter
from .core import AliceRunner, Denied
from .fictional_shop import FictionalStore, FixtureHTTPS
from .h01_host import secret
from .h02_identity import InvalidCapability, ReplayLedger
from .h021_crypto import PublicVerifier
from .device_approval import P256DeviceConsent
from .h021_transport import HeaderDeadlineReader, LimitedHTTPServer, read_body_with_deadline
from .http_service import FixturePrincipal, make_handler


def protected_handler(runner, principals, verifier: PublicVerifier, replay: ReplayLedger,
                      subject_map: dict | None = None):
    original = make_handler(runner, principals)
    admission = threading.BoundedSemaphore(12)
    class H021Handler(original):
        def setup(self):
            super().setup()
            self.rfile = HeaderDeadlineReader(self.rfile, self.connection)

        def parse_request(self):
            accepted = super().parse_request()
            self.rfile.headers_complete()
            return accepted

        def do_POST(self):
            if not admission.acquire(blocking=False):
                self._write(503, {"error": "verification_busy_no_effect"})
                return
            try:
                self._do_post_guarded()
            finally:
                admission.release()

        def _do_post_guarded(self):
            try:
                if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Type") != "application/json":
                    raise InvalidCapability("content type denied")
                length = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= length <= 16384:
                    raise InvalidCapability("bad request size")
                raw = read_body_with_deadline(self, length)
                if len(raw) != length:
                    raise InvalidCapability("incomplete request")
                authorization = self.headers.get("Authorization", "")
                principal = None
                for secret_token, candidate in principals.items():
                    if hmac.compare_digest(authorization, "Bearer " + secret_token):
                        principal = candidate
                if principal is None:
                    raise InvalidCapability("unknown backend workload")
                signed = self.headers.get("X-Alice-H021-Capability", "")
                public_path = "/v1/proposals" if self.path == "/v1/propose" else self.path
                claims, body = verifier.verify(signed, path=public_path, body=raw)
                if subject_map is not None:
                    assigned = subject_map.get(claims["sub"])
                    if not isinstance(assigned, dict) or (
                            assigned.get("tenant"), assigned.get("session")) != (
                            claims["tenant"], claims["session"]):
                        raise InvalidCapability("subject not registered in ASR authority")
                expected_role = "human" if self.path in ("/v1/human-reissue", "/v1/human-finish") else "coordinator"
                if ((principal.role != expected_role) or
                        (claims["role"] == "human") != (principal.role == "human") or
                        (claims["role"] == "proposal") != (self.path == "/v1/propose") or
                        claims["tenant"] != principal.tenant or
                        claims["session"] != principal.session):
                    raise InvalidCapability("privileged role/session mismatch")
                # Consume at independent ASR boundary BEFORE performing action.
                replay.consume(claims)
                if self.path == "/v1/jobs":
                    if set(body) != {"recipient", "create_request_id"}:
                        raise InvalidCapability("idempotent creation request required")
                    out = runner.new_job(principal.tenant, principal.session,
                                         body["recipient"], create_request_id=body["create_request_id"])
                    self._write(200, out)
                    return
                # Reuse H01 handler only AFTER strong auth. No identity injected.
                self.rfile = io.BytesIO(raw)
                super().do_POST()
            except (InvalidCapability, Denied, ValueError, TypeError, KeyError):
                self._write(403, {"error": "denied"})
            except Exception as exc:
                print("H021_PRIVATE_HANDLER_FAILED", type(exc).__name__, flush=True)
                self._write(503, {"error": "unavailable"})
    return H021Handler


def main():
    if os.environ.get("H021_SYNTHETIC_ONLY") != "yes":
        raise SystemExit("H021 REFUSED: fixture only, no real payments")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain("/run/h01-tls/asr.pem", "/run/h01-tls/asr.key")
    external_merchant = os.environ.get("H021_EXTERNAL_MERCHANT_FIXTURE_ONLY") == "yes"
    store = None
    if external_merchant:
        merchant_context = nullcontext(None)
        origin = "https://merchant:8443"
        merchant_ca = "/run/h01-ca/merchant.pem"
        effect_token = secret("merchant_effect_token")
        read_token = secret("merchant_read_token")
    else:
        store = FictionalStore(secret=secrets.token_urlsafe(45))
        store.commit_delay_seconds = min(max(int(os.environ.get("H01_FAULT_COMMIT_DELAY", "0")), 0), 30)
        merchant_context = FixtureHTTPS(store, "/run/h01-tls/asr.pem", "/run/h01-tls/asr.key")
        effect_token = store.secret
        read_token = store.browser_read_secret
    with merchant_context as merchant:
        if merchant is not None:
            origin = merchant.url
            merchant_ca = "/run/h01-tls/asr.pem"
        adapter = BrowserFixtureReadAdapter(
            origin=origin, ca_file=merchant_ca,
            merchant_token=effect_token, browser_read_token=read_token,
            playwright_module="/opt/h01/node_modules/playwright")
        if os.environ.get("H021_DEVICE_CONSENT_P256_FIXTURE_ONLY") == "yes":
            runner = AliceRunner(adapter,
                approval_verifier=P256DeviceConsent.load("/run/h021-auth/devices.json"),
                ledger_path="/var/lib/h01/state.sqlite3")
        else:
            runner = AliceRunner(adapter, approval_key=bytes.fromhex(secret("device_hmac_hex")),
                                 ledger_path="/var/lib/h01/state.sqlite3")
        principals = {}
        for actor in ("a", "b"):
            tenant, session = "fixture-tenant-" + actor, "fixture-session-" + actor
            principals[secret("backend_coordinator_" + actor)] = FixturePrincipal("coordinator", tenant, session)
            principals[secret("backend_human_" + actor)] = FixturePrincipal("human", tenant, session)
        verifier = PublicVerifier.load("/run/h021-auth/public.json")
        with open("/run/h021-auth/subjects.json", encoding="utf-8") as subject_file:
            subject_map = json.load(subject_file)
        replay = ReplayLedger("/var/lib/h01/h021_requests.sqlite3")
        server = LimitedHTTPServer(("0.0.0.0", 8443),
                                   protected_handler(runner, principals, verifier, replay, subject_map))
        server.tls_context = tls
        janitor_stop = threading.Event()

        def reap_terminal_browsers():
            # A failed terminal close must not retain a live Chromium context
            # indefinitely within this executor process. NEVER infer closure
            # of a prior generation or retry a merchant/payment operation.
            while not janitor_stop.is_set():
                try:
                    runner.reap_terminal_browser_sessions()
                except Exception:
                    # Retain durable browser ownership markers on failure.
                    pass
                if janitor_stop.wait(10):
                    return

        janitor = threading.Thread(target=reap_terminal_browsers,
                                  name="h021-terminal-browser-reaper", daemon=True)
        janitor.start()
        print("H021 private ASR: independent public-key scope and durable replay", flush=True)
        try:
            server.serve_forever()
        finally:
            janitor_stop.set()
            janitor.join(timeout=3)
            server.server_close()
            replay.close()
            runner.close()
            adapter.close()


if __name__ == "__main__":
    main()
