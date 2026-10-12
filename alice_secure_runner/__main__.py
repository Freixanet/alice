"""Launch the isolated *fictional-only* service for development.

No production network listener or real payment support. Bind to loopback only.
The application and service keys are provided by the trusted Alice backend,
never a Hermes model, tool, prompt or plugin configuration.
"""

from __future__ import annotations

import os
import sys

from .core import AliceRunner, FictionalHTTPSAdapter
from .http_service import make_handler


def main() -> int:
    if os.environ.get("ALICE_RUNNER_FIXTURE_ONLY") != "yes":
        print("Refusing to start: R02 runner prototype only supports the fictional merchant.", file=sys.stderr)
        return 2
    required = ("ALICE_FIXTURE_ORIGIN", "ALICE_FIXTURE_CA_FILE", "ALICE_FIXTURE_MERCHANT_TOKEN",
                "ALICE_RUNNER_APPROVAL_KEY_HEX", "ALICE_RUNNER_COORDINATOR_TOKEN",
                "ALICE_RUNNER_TLS_CERT_FILE", "ALICE_RUNNER_TLS_KEY_FILE", "ALICE_RUNNER_LEDGER_FILE")
    missing = [field for field in required if not os.environ.get(field)]
    if missing:
        print("Runner unavailable: required Alice-owned configuration is missing.", file=sys.stderr)
        return 2
    try:
        import ssl
        from http.server import ThreadingHTTPServer

        approval_key = bytes.fromhex(os.environ["ALICE_RUNNER_APPROVAL_KEY_HEX"])
        adapter = FictionalHTTPSAdapter(
            origin=os.environ["ALICE_FIXTURE_ORIGIN"],
            ca_file=os.environ["ALICE_FIXTURE_CA_FILE"],
            merchant_token=os.environ["ALICE_FIXTURE_MERCHANT_TOKEN"])
        runner = AliceRunner(adapter, approval_key=approval_key,
                             ledger_path=os.environ["ALICE_RUNNER_LEDGER_FILE"])
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(
            runner, os.environ["ALICE_RUNNER_COORDINATOR_TOKEN"]))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.environ["ALICE_RUNNER_TLS_CERT_FILE"],
                            os.environ["ALICE_RUNNER_TLS_KEY_FILE"])
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        print("Synthetic Alice runner HTTPS listening on loopback port", server.server_port, flush=True)
        server.serve_forever()
    except (ValueError, OSError, ssl.SSLError):
        print("Runner refused to launch due to invalid TLS or configuration.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
