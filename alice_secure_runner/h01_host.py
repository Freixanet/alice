"""H01 container-only fictional ASR process: HTTPS broker + private Chromium.

The host must be launched in an isolated, non-privileged container on a
backend-only Docker network. Does not run on the Hermes user's computer.
NEVER use any real merchant, card, personal credential, or deployment key.
"""
from __future__ import annotations

import os
import secrets
import ssl
from http.server import ThreadingHTTPServer
from pathlib import Path

from .browser_fixture import BrowserFixtureReadAdapter
from .core import AliceRunner
from .fictional_shop import FictionalStore, FixtureHTTPS
from .http_service import FixturePrincipal, make_handler


def secret(name: str) -> str:
    path = Path('/run/h01-secrets') / name
    value = path.read_text(encoding='utf-8').strip()
    if len(value) < 40:
        raise ValueError('invalid ephemeral H01 secret')
    return value


def main() -> None:
    if os.environ.get('H01_SYNTHETIC_ONLY') != 'yes':
        raise SystemExit('H01 REFUSED: fictional-only lab')
    cert, key = '/run/h01-tls/asr.pem', '/run/h01-tls/asr.key'
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    store = FictionalStore(secret=secrets.token_urlsafe(45))
    store.commit_delay_seconds = min(max(int(os.environ.get('H01_FAULT_COMMIT_DELAY', '0')), 0), 30)
    with FixtureHTTPS(store, cert, key) as merchant:
        adapter = BrowserFixtureReadAdapter(
            origin=merchant.url, ca_file=cert, merchant_token=store.secret,
            browser_read_token=store.browser_read_secret,
            playwright_module='/opt/h01/node_modules/playwright')
        runner = AliceRunner(adapter, approval_key=bytes.fromhex(secret('device_hmac_hex')),
                             ledger_path='/var/lib/h01/state.sqlite3')
        principals = {}
        for name in ('a', 'b'):
            tenant, session = 'fixture-tenant-' + name, 'fixture-session-' + name
            principals[secret('backend_coordinator_' + name)] = FixturePrincipal('coordinator', tenant, session)
            principals[secret('backend_human_' + name)] = FixturePrincipal('human', tenant, session)
        server = ThreadingHTTPServer(('0.0.0.0', 8443), make_handler(runner, principals))
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        try:
            print('H01 synthetic ASR ready: private port 8443, browser-owned', flush=True)
            server.serve_forever()
        finally:
            server.server_close()
            runner.close()
            adapter.close()


if __name__ == '__main__':
    main()
