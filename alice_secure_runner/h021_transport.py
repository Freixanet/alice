"""Bounded HTTP accept/read for the H02.1 synthetic TLS trust boundary.

This is not a substitute for a production TLS reverse proxy with connection,
header, body, and per-source rate limits.
"""
from __future__ import annotations

import socket
import ssl
import select
import threading
import time
from http.server import ThreadingHTTPServer


class LimitedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address, handler, *, max_connections=24):
        self._slots = threading.BoundedSemaphore(max_connections)
        self.tls_context = None
        super().__init__(address, handler)

    def get_request(self):
        # Never perform a blocking TLS handshake in the SINGLE accept loop:
        # Host A could otherwise hold the entire gateway with one idle TCP
        # connection before admission limits or handler timeouts were applied.
        raw, address = super().get_request()
        if self.tls_context is None:
            return raw, address
        try:
            wrapped = self.tls_context.wrap_socket(
                raw, server_side=True, do_handshake_on_connect=False)
            return wrapped, address
        except BaseException:
            raw.close()
            raise

    def process_request(self, request, client_address):
        # Refuse before creating another OS thread or file-backed TLS handler.
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            return super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(5.0)
            if isinstance(request, ssl.SSLSocket):
                try:
                    handshake_with_deadline(request)
                except (ssl.SSLError, OSError, TimeoutError):
                    self.shutdown_request(request)
                    return
            return super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def handshake_with_deadline(request: ssl.SSLSocket, *, seconds: float = 5.0) -> None:
    """Absolute monotonic deadline for TLS, even with trickled SSL records.

    A per-recv socket timeout alone is insufficient: a hostile peer can drip
    handshake bytes every few seconds and occupy every admitted TLS slot.
    """
    until = time.monotonic() + seconds
    request.setblocking(False)
    try:
        while True:
            if time.monotonic() >= until:
                raise TimeoutError("absolute TLS handshake deadline exceeded")
            try:
                request.do_handshake()
                return
            except ssl.SSLWantReadError:
                read, write = [request], []
            except ssl.SSLWantWriteError:
                read, write = [], [request]
            remaining = until - time.monotonic()
            if remaining <= 0 or not any(select.select(read, write, [], remaining)[:2]):
                raise TimeoutError("absolute TLS handshake deadline exceeded")
    finally:
        request.setblocking(True)
        request.settimeout(5.0)


def read_body_with_deadline(handler, size: int, *, seconds: float = 5.0) -> bytes:
    """Absolute request-body deadline, even for a slow one-byte-at-a-time send.

    rfile is buffered and may already contain body bytes after HTTP parsing:
    reading raw socket directly would accidentally skip such bytes. Reading
    one byte at a time ensures the total wall-clock deadline, rather than a
    TCP per-recv timeout reset by each attacker-supplied byte.
    """
    if not isinstance(size, int) or not 2 <= size <= 16384:
        raise ValueError("request size outside bounded fixture")
    until = time.monotonic() + seconds
    out = bytearray()
    while len(out) < size:
        remaining = until - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("request-body deadline exceeded")
        handler.connection.settimeout(min(5.0, remaining))
        try:
            byte = handler.rfile.read(1)
        except (OSError, socket.timeout) as exc:
            raise TimeoutError("request-body stalled") from exc
        if not byte:
            raise ValueError("request ended before declared content length")
        out.extend(byte)
    return bytes(out)


class HeaderDeadlineReader:
    """Limit total header/initial request-line wall time, not just idle gaps.

    Wraps the existing buffered rfile; never mixes raw socket reads that could
    discard bytes already buffered by BaseHTTPRequestHandler.
    """

    def __init__(self, buffered, connection, *, seconds=5.0):
        self._source = buffered
        self._connection = connection
        self._until = time.monotonic() + seconds

    def read(self, size=-1):
        return self._source.read(size)

    def readline(self, limit=-1):
        if self._until is None:
            return self._source.readline(limit)
        data = bytearray()
        # BaseHTTPRequestHandler already limits request/header line lengths,
        # but total wall time must also be bounded for a one-byte drip.
        maxbytes = min(65537, limit) if limit >= 0 else 65537
        while len(data) < maxbytes:
            remaining = self._until - time.monotonic()
            if remaining <= 0:
                raise socket.timeout("absolute HTTP header deadline")
            self._connection.settimeout(min(5.0, remaining))
            value = self._source.read(1)
            if not value:
                break
            data.extend(value)
            if value == b"\n":
                break
        return bytes(data)

    def headers_complete(self):
        self._until = None

    def close(self):
        self._source.close()
