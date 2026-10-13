"""Disposable transport regressions; no personal browser, network or keys."""
from __future__ import annotations

import io
import errno
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
    HeaderBoundHTTPSHandler, HeaderDeadlineReader, LimitedHTTPServer,
    handshake_with_deadline,
    _ResponseWithHeaderDeadline, read_body_with_deadline,
    read_https_response_with_deadline,
)


class H021TransportTests(unittest.TestCase):
    def test_https_handler_works_without_removed_python312_attribute(self):
        context = ssl.create_default_context()
        handler = HeaderBoundHTTPSHandler(context=context)
        if hasattr(handler, "_check_hostname"):
            del handler._check_hostname
        with mock.patch.object(handler, "do_open", return_value="synthetic") as opened:
            self.assertEqual(handler.https_open("fictional-request"), "synthetic")
        self.assertEqual(opened.call_args.kwargs, {"context": context})

    def test_https_header_wrapper_parses_status_and_keeps_body_readable(self):
        connection = mock.Mock()

        class FakeStream(io.BytesIO):
            raw = SimpleNamespace(_sock=connection)

        source = FakeStream(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        sock = SimpleNamespace(makefile=lambda *_args, **_kwargs: source)
        response = _ResponseWithHeaderDeadline(sock)
        try:
            response.begin()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read1(2), b"OK")
            self.assertGreater(connection.settimeout.call_count, 0)
        finally:
            response.close()

    def test_https_header_wrapper_rejects_absolute_deadline(self):
        connection = mock.Mock()

        class FakeStream(io.BytesIO):
            raw = SimpleNamespace(_sock=connection)

        source = FakeStream(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        response = _ResponseWithHeaderDeadline(
            SimpleNamespace(makefile=lambda *_args, **_kwargs: source))
        try:
            with mock.patch("alice_secure_runner.h021_transport.time.monotonic",
                            side_effect=[0.0, 5.1]):
                with self.assertRaisesRegex(socket.timeout, "absolute HTTP header deadline"):
                    response.begin()
        finally:
            response.close()

    def test_https_body_absolute_deadline_blocks_trickle(self):
        connection = mock.Mock()
        response = SimpleNamespace(fp=SimpleNamespace(raw=SimpleNamespace(_sock=connection)))
        response.read1 = mock.Mock(side_effect=[b"a", b"b", b"c"])
        with mock.patch("alice_secure_runner.h021_transport.time.monotonic",
                        side_effect=[0.0, 0.2, 0.3, 0.7, 0.8, 1.1]):
            with self.assertRaisesRegex(TimeoutError, "absolute HTTPS response deadline"):
                read_https_response_with_deadline(response, 10, seconds=1)
        self.assertEqual(response.read1.call_count, 2)
        self.assertEqual(connection.settimeout.call_count, 2)

    def test_usable_buffered_response_survives_closed_connection_handle(self):
        connection = mock.Mock()
        connection.settimeout.side_effect = OSError(errno.EBADF, "closed connection")
        response = SimpleNamespace(fp=SimpleNamespace(raw=SimpleNamespace(_sock=connection)))
        response.read1 = mock.Mock(side_effect=[b"OK", b""])
        self.assertEqual(read_https_response_with_deadline(response, 50, seconds=3), b"OK")
        self.assertEqual(response.read1.call_count, 2)
        connection.settimeout.assert_called_once()

    def test_https_body_deadline_rejects_unobservable_socket(self):
        response = SimpleNamespace(fp=SimpleNamespace(raw=SimpleNamespace()),
                                   read1=lambda n: b"synthetic")
        with self.assertRaisesRegex(TimeoutError, "cannot enforce"):
            read_https_response_with_deadline(response, 100)

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
