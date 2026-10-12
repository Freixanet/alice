"""Alice-owned H01 HTTPS gateway. Hermes bearer is PROPOSAL-ONLY.

No arbitrary HTTP proxy, no browser API, no CDP forwarding. Synthetic static
principals only; real identity/OIDC, HSM and device approval remain NO-GO.
"""
from __future__ import annotations

import hmac
import json
import os
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def secret(name: str) -> str:
    token = (Path('/run/h01-secrets') / name).read_text(encoding='utf-8').strip()
    if len(token) < 40:
        raise ValueError('invalid ephemeral secret')
    return token


class Gateway:
    """Issue capabilities from ALICE trusted identity, never JSON tenant claim."""

    OWNER = {'/v1/jobs', '/v1/resume', '/v1/challenge', '/v1/approve',
             '/v1/commit', '/v1/human-handoff'}
    HUMAN = {'/v1/human-reissue', '/v1/human-finish'}
    PROPOSAL = {'/v1/proposals'}

    def __init__(self):
        self.tokens = {}
        self.backend = {}
        for actor in ('a', 'b'):
            for role in ('owner', 'proposal', 'human'):
                self.tokens[secret(role + '_' + actor)] = (role, actor)
            self.backend[actor] = {
                'coordinator': secret('backend_coordinator_' + actor),
                'human': secret('backend_human_' + actor),
            }
        self.ca = ssl.create_default_context(cafile='/run/h01-ca/asr.pem')
        self.ca.minimum_version = ssl.TLSVersion.TLSv1_2
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                 urllib.request.HTTPSHandler(context=self.ca))

    def authenticate(self, header: str, path: str):
        if path in self.PROPOSAL:
            role = 'proposal'
        elif path in self.HUMAN:
            role = 'human'
        elif path in self.OWNER:
            role = 'owner'
        else:
            raise LookupError('not a public Alice H01 operation')
        match = None
        for token, principal in self.tokens.items():
            if hmac.compare_digest(header, 'Bearer ' + token):
                match = principal
        if match is None or match[0] != role:
            raise PermissionError('no Alice actor authority')
        return match[1], role

    def forward(self, actor: str, path: str, data: dict, *, human: bool):
        role = 'human' if human else 'coordinator'
        token = self.backend[actor][role]
        # Explicit route map. Never use a user-provided URL, method or host.
        api_path = '/v1/propose' if path == '/v1/proposals' else path
        data = dict(data)
        data['tenant'] = 'fixture-tenant-' + actor
        data['session'] = 'fixture-session-' + actor
        if path == '/v1/proposals':
            if set(data) != {'tenant', 'session', 'job_id', 'proposal'}:
                raise ValueError('unexpected proposal payload')
        body = json.dumps(data, separators=(',', ':'), allow_nan=False).encode()
        req = urllib.request.Request('https://asr:8443' + api_path, data=body, method='POST',
                                     headers={'Authorization': 'Bearer ' + token,
                                              'Content-Type': 'application/json'})
        try:
            with self.opener.open(req, timeout=10) as response:
                payload = response.read(16385)
                if len(payload) > 16384:
                    raise ValueError('private broker response exceeds cap')
                return response.status, json.loads(payload)
        except urllib.error.HTTPError as exc:
            # Preserve precise synthetic deny/unknown semantics without
            # exposing backend exception text, cookies or environment.
            return (exc.code if exc.code in (401, 403, 409) else 503,
                    {'error': 'denied' if exc.code in (401, 403) else
                     'unknown_outcome_do_not_retry' if exc.code == 409 else 'unavailable'})


def make_handler(gateway: Gateway):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def reply(self, status, obj):
            body = json.dumps(obj, separators=(',', ':')).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == '/health':
                self.reply(200, {'status': 'ready_synthetic'})
            else:
                self.reply(404, {'error': 'not_found'})

        def do_POST(self):
            try:
                actor, role = gateway.authenticate(self.headers.get('Authorization', ''), self.path)
            except LookupError:
                self.reply(404, {'error': 'not_found'})
                return
            except PermissionError:
                self.reply(401, {'error': 'unauthorized'})
                return
            try:
                size = int(self.headers.get('Content-Length', '-1'))
                if not 2 <= size <= 16384:
                    raise ValueError('bad length')
                obj = json.loads(self.rfile.read(size))
                if not isinstance(obj, dict):
                    raise ValueError('bad body')
                # Do not silently fix an attempted identity spoof: reject it.
                for claim in ('tenant', 'session'):
                    expected = ('fixture-tenant-' if claim == 'tenant' else 'fixture-session-') + actor
                    if claim in obj and obj[claim] != expected:
                        raise ValueError('identity mismatch')
                status, result = gateway.forward(actor, self.path, obj, human=(role == 'human'))
                self.reply(status, result)
            except (ValueError, KeyError, TypeError):
                self.reply(403, {'error': 'denied'})
            except Exception:
                self.reply(503, {'error': 'unavailable'})

    return Handler


def main():
    if os.environ.get('H01_SYNTHETIC_ONLY') != 'yes':
        raise SystemExit('H01 REFUSED: fictional-only lab')
    gateway = Gateway()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain('/run/h01-tls/gateway.pem', '/run/h01-tls/gateway.key')
    server = ThreadingHTTPServer(('0.0.0.0', 8443), make_handler(gateway))
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    print('H01 Alice gateway ready: typed HTTPS ingress only', flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
