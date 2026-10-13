"""Independent durable fictional merchant; runs ONLY on Alice's disposable lab.

Its persistent receipt ledger is distinct from ASR's ledger and survives ASR
container recreation. This is NOT a payment processor, or permission to pay.
"""
from __future__ import annotations

import os
import ssl

from .fictional_shop import PersistentFictionalStore, make_handler
from .h021_transport import HeaderDeadlineReader, LimitedHTTPServer
from .h01_host import secret


def main() -> None:
    if (os.environ.get("H021_MERCHANT_TEST_ONLY") != "yes"
            or os.environ.get("H021_SYNTHETIC_ONLY") != "yes"):
        raise SystemExit("independent fictional merchant requires lab-only flags")
    store = PersistentFictionalStore(
        secret=secret("merchant_effect_token"),
        browser_read_secret=secret("merchant_read_token"),
        ledger_path="/var/lib/h021-merchant/orders.sqlite3")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain("/run/h01-tls/merchant.pem", "/run/h01-tls/merchant.key")
    class BoundedMerchantHandler(make_handler(store)):
        _bounded_merchant_body = True

        def setup(self):
            super().setup()
            self.rfile = HeaderDeadlineReader(self.rfile, self.connection)

        def parse_request(self):
            valid = super().parse_request()
            self.rfile.headers_complete()
            return valid

    server = LimitedHTTPServer(("0.0.0.0", 8443), BoundedMerchantHandler)
    server.tls_context = ctx
    print("H021 fictional merchant: independent durable receipt ledger", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        store.close()


if __name__ == "__main__":
    main()
