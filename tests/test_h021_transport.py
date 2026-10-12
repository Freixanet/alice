"""Disposable transport regressions; no personal browser, network or keys."""
from __future__ import annotations

import io
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from alice_secure_runner.h021_transport import (
    HeaderDeadlineReader, LimitedHTTPServer, handshake_with_deadline,
    read_body_with_deadline,
)


class H021TransportTests(unittest.TestCase):
    def test_absolute_tls_deadline_even_if_peer_drips_records(self):
        fake = mock.Mock()
        fake.do_handshake.side_effect = ssl.SSLWantReadError()
        with mock.patch("alice_secure_runner.h021_transport.time.monotonic",
                        side_effect=[0.0, 0.2, 0.5, 1.01]), \
             mock.patch("alice_secure_runner.h021_transport.select.select",
                        return_value=([fake], [], [])) as ready:
            with self.assertRaises(TimeoutError):
                handshake_with_deadline(fake, seconds=1.0)
            ready.assert_called_once()
        fake.setblocking.assert_any_call(False)
        fake.setblocking.assert_any_call(True)
        fake.settimeout.assert_called_with(5.0)

    def test_absolute_header_deadline_rejects_drip(self):
        connection = mock.Mock()
        with mock.patch("alice_secure_runner.h021_transport.time.monotonic",
                        side_effect=[0.0, 0.2, 0.6, 1.2]):
            reader = HeaderDeadlineReader(io.BytesIO(b"abcd\n"), connection, seconds=1.0)
            with self.assertRaises(socket.timeout):
                reader.readline(40)
        self.assertGreater(connection.settimeout.call_count, 0)

    def test_absolute_body_deadline_rejects_drip(self):
        handler = SimpleNamespace(connection=mock.Mock(), rfile=io.BytesIO(b"abc"))
        with mock.patch("alice_secure_runner.h021_transport.time.monotonic",
                        side_effect=[0.0, 0.3, 1.2]):
            with self.assertRaises(TimeoutError):
                read_body_with_deadline(handler, 3, seconds=1.0)

    def test_idle_tcp_handshake_does_not_block_legitimate_tls_client(self):
        with tempfile.TemporaryDirectory(prefix="h021-socket-only-") as folder:
            cert = str(Path(folder) / "localhost.pem")
            key = str(Path(folder) / "localhost.key")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-nodes", "-sha256", "-days", "1", "-keyout", key, "-out", cert,
                "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                check=True, capture_output=True)

            class Healthy(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    return

                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Length", "2")
                    self.end_headers()
                    self.wfile.write(b"OK")

            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            server = LimitedHTTPServer(("127.0.0.1", 0), Healthy,
                                        max_connections=3)
            server.tls_context = tls
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            idle = None
            try:
                idle = socket.create_connection(("127.0.0.1", server.server_port), timeout=2)
                time.sleep(0.15)  # ensure one other TCP connection holds an SSL slot
                context = ssl.create_default_context(cafile=cert)
                opener = urllib.request.build_opener(
                    urllib.request.ProxyHandler({}),
                    urllib.request.HTTPSHandler(context=context))
                began = time.monotonic()
                with opener.open(f"https://localhost:{server.server_port}/", timeout=3) as reply:
                    self.assertEqual(reply.status, 200)
                    self.assertEqual(reply.read(), b"OK")
                self.assertLess(time.monotonic() - began, 3.0)
            finally:
                if idle is not None:
                    idle.close()
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())

    def test_idle_tls_slot_limit_releases_slots_after_handshake_deadline(self):
        with tempfile.TemporaryDirectory(prefix="h021-limited-tls-") as folder:
            cert, key = str(Path(folder) / "tls.pem"), str(Path(folder) / "tls.key")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                            "-nodes", "-sha256", "-days", "1", "-keyout", key,
                            "-out", cert, "-subj", "/CN=localhost",
                            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                           check=True, capture_output=True)

            class Healthy(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    return

                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Length", "2")
                    self.end_headers()
                    self.wfile.write(b"OK")

            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            server = LimitedHTTPServer(("127.0.0.1", 0), Healthy, max_connections=2)
            server.tls_context = tls
            from alice_secure_runner import h021_transport
            real_handshake = h021_transport.handshake_with_deadline
            with mock.patch.object(h021_transport, "handshake_with_deadline",
                                   side_effect=lambda sock: real_handshake(sock, seconds=0.25)):
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                socks = []
                try:
                    for _ in range(2):
                        socks.append(socket.create_connection(
                            ("127.0.0.1", server.server_port), timeout=1))
                    time.sleep(0.7)  # both idle TLS slots must expire
                    opener = urllib.request.build_opener(
                        urllib.request.ProxyHandler({}),
                        urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=cert)))
                    with opener.open(f"https://localhost:{server.server_port}/", timeout=2) as reply:
                        self.assertEqual(reply.status, 200)
                        self.assertEqual(reply.read(), b"OK")
                finally:
                    for sock in socks:
                        sock.close()
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=2)
                    self.assertFalse(thread.is_alive())


if __name__ == "__main__":
    unittest.main()
