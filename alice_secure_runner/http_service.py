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
from http.server import BaseHTTPRequestHandler
from typing import Mapping

from .core import AliceRunner, Denied, Indeterminate
from .device_registry import RevocableP256DeviceConsent, EnrollmentDenied
from .h021_transport import HeaderDeadlineReader, LimitedHTTPServer, read_body_with_deadline


@dataclass(frozen=True)
class FixturePrincipal:
    """Test-issued role and identity, resolved from bearer, NEVER a JSON claim.

    Production must independently authenticate the Alice user and rotate/expire
    capabilities; these synthetic, server-provisioned bearer tokens are not it.
    """

    role: str
    tenant: str
    session: str
    # Optional trusted Alice fixture identity for synthetic device enrollment.
    # Never derive these values from Hermes or from an HTTP request body.
    account: str = ""
    installation: str = ""


def _validate_principals(principals: Mapping[str, FixturePrincipal]) -> dict[str, FixturePrincipal]:
    if not isinstance(principals, Mapping) or not principals:
        raise ValueError("explicit fixture principals are required")
    validated = {}
    for token, principal in principals.items():
        if (not isinstance(token, str) or len(token) < 32
                or not isinstance(principal, FixturePrincipal) or principal.role not in ("coordinator", "human")
                or not all(isinstance(x, str) and 0 < len(x) <= 120
                           for x in (principal.tenant, principal.session))
                or not all(isinstance(x, str) and len(x) <= 120
                           for x in (principal.account, principal.installation))
                or bool(principal.account) != bool(principal.installation)):
            raise ValueError("invalid fixture principal")
        validated[token] = principal
    actors: dict[tuple[str, str], set[str]] = {}
    for principal in validated.values():
        actors.setdefault((principal.tenant, principal.session), set()).add(principal.role)
    if any(roles != {"coordinator", "human"} for roles in actors.values()):
        raise ValueError("each synthetic tenant/session requires separate coordinator and human roles")
    return validated


def make_handler(runner: AliceRunner, principals: Mapping[str, FixturePrincipal], *,
                 device_registry: RevocableP256DeviceConsent | None = None):
    principals = _validate_principals(principals)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.rfile = HeaderDeadlineReader(self.rfile, self.connection)

        def parse_request(self):
            valid = super().parse_request()
            self.rfile.headers_complete()
            return valid

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
            role = ("human" if self.path in ("/v1/human-finish", "/v1/human-reissue",
                                             "/v1/human-cancel",
                                             "/v1/human-enrollment-begin",
                                             "/v1/human-enrollment-complete",
                                             "/v1/human-enrollment-revoke",
                                             "/v1/human-status", "/v1/human-approve")
                    else "coordinator")
            if principal is None or principal.role != role:
                self._write(401, {"error": "unauthorized"})
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= size <= 16384:
                    raise Denied("invalid request")
                # An idle socket timeout alone permits indefinitely trickled
                # bytes. Bound the total body wall-clock time before parsing
                # any command or touching a durable checkout.
                obj = json.loads(read_body_with_deadline(self, size))
                if not isinstance(obj, dict):
                    raise Denied("invalid request")
                # Refuse mismatched client claims instead of silently accepting
                # them; session is also required for human completion.
                if (("tenant" in obj and obj["tenant"] != principal.tenant)
                        or ("session" in obj and obj["session"] != principal.session)):
                    raise Denied("client identity cannot override bearer principal")
                tenant, session = principal.tenant, principal.session
                if self.path == "/v1/jobs":
                    # One caller-generated request identity survives a lost
                    # HTTP reply without minting a second shopping job. The
                    # runner commits this binding with its job in one SQLite
                    # transaction and scopes it to authenticated principal.
                    out = runner.new_job(tenant, session, obj["recipient"],
                                         create_request_id=obj.get("create_request_id"))
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
                elif self.path == "/v1/human-status":
                    out = runner.human_status(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/human-cancel":
                    out = runner.human_cancel(obj["job_id"], tenant=tenant, session=session)
                    out = {**out, "tenant": tenant, "session": session}
                elif self.path.startswith("/v1/human-enrollment-"):
                    # Enrollment is only possible with an explicitly configured
                    # trusted, account-bound Alice fixture principal and the
                    # same public-key registry the runner uses for approvals.
                    # This is NOT a real Alice login, IdP, attestation or
                    # entitlement to any production merchant/payment account.
                    if (device_registry is None or not principal.account
                            or not principal.installation):
                        raise Denied("trusted Alice device identity unavailable")
                    scope = {"tenant": tenant, "session": session,
                             "account": principal.account,
                             "installation": principal.installation}
                    if self.path == "/v1/human-enrollment-begin":
                        if set(obj) - {"tenant", "session", "public_pem", "key_expires_at",
                                        "operation", "expected_version"}:
                            raise Denied("unexpected enrollment data")
                        out = device_registry.begin_proven_enrollment(
                            **scope, public_pem=obj["public_pem"],
                            key_expires_at=obj["key_expires_at"],
                            operation=obj.get("operation", "enroll"),
                            expected_version=obj.get("expected_version", 0))
                    elif self.path == "/v1/human-enrollment-complete":
                        if set(obj) - {"tenant", "session", "challenge", "signature"}:
                            raise Denied("unexpected enrollment data")
                        challenge = obj["challenge"]
                        if (not isinstance(challenge, dict)
                                or any(challenge.get(k) != v for k, v in scope.items())):
                            raise Denied("enrollment principal mismatch")
                        version = device_registry.complete_proven_enrollment(
                            challenge, obj["signature"])
                        out = {**scope, "version": version, "status": "enrolled_fixture_only"}
                    elif self.path == "/v1/human-enrollment-revoke":
                        if set(obj) - {"tenant", "session", "expected_version"}:
                            raise Denied("unexpected enrollment data")
                        device_registry.revoke(tenant=tenant, session=session,
                                               account=principal.account,
                                               expected_version=obj["expected_version"])
                        out = {**scope, "status": "revoked_fixture_only"}
                    else:
                        raise Denied("unknown enrollment operation")
                elif self.path == "/v1/human-approve":
                    # The human role supplies a detached exact-checkout
                    # signature only; no checkout dispatch capability is
                    # granted to this HTTPS route. ASR verifies the signature.
                    out = runner.approve(obj["job_id"], tenant=tenant,
                                         session=session, signature=obj["signature"])
                    out = {**out, "job_id": obj["job_id"], "tenant": tenant,
                           "session": session}
                elif self.path == "/v1/human-reissue":
                    out = runner.reissue_human_handle(obj["job_id"], tenant=tenant, session=session)
                elif self.path == "/v1/human-finish":
                    runner.resume_job(obj["job_id"], tenant=tenant, session=session)
                    out = runner.human_finalize(obj["job_id"], tenant=tenant, human_handle=obj["human_handle"])
                else:
                    self._write(404, {"error": "unknown endpoint"})
                    return
                self._write(200, out)
            except (Denied, EnrollmentDenied, KeyError, TypeError, ValueError):
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
                 key_file: str, device_registry: RevocableP256DeviceConsent | None = None):
        if (device_registry is not None and
                device_registry is not getattr(runner, "_AliceRunner__approval_verifier", None)):
            raise ValueError("enrollment registry must be the runner's public-key verifier")
        self.server = LimitedHTTPServer(("127.0.0.1", 0),
                                        make_handler(runner, principals,
                                                     device_registry=device_registry),
                                        max_connections=8)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert_file, key_file)
        # TLS handshake happens in one of eight bounded worker threads with
        # an absolute deadline, never on the sole accept loop. This is still
        # only a loopback fixture, not a production-facing reverse proxy.
        self.server.tls_context = ctx
        self.url = f"https://localhost:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
