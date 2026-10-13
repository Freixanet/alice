"""Bounded HTTP accept/read for the H02.1 synthetic TLS trust boundary.

This is not a substitute for a production TLS reverse proxy with connection,
header, body, and per-source rate limits.
"""
from __future__ import annotations

import socket
import ssl
import select
import http.client
import threading
import time
import urllib.request
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


def read_https_response_with_deadline(response, limit: int, *, seconds: float = 5.0) -> bytes:
    """Bound TOTAL HTTPS response-body time, not just idle socket time.

    urllib's HTTPResponse.read1 reads at most one buffered/socket chunk. In
    contrast read(limit) can spend unbounded wall time on tiny periodic TLS
    records. We reset the socket timeout to the REMAINING absolute budget
    before each read1. Refuse an unsupported response transport rather than
    silently dropping this guarantee around a privileged capability.

    ``limit`` includes the extra byte used to detect an oversized response.
    """
    if type(limit) is not int or not 1 <= limit <= 65536 or seconds <= 0:
        raise ValueError("invalid bounded HTTPS response")
    socket_obj = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
    if socket_obj is None or not callable(getattr(response, "read1", None)):
        raise TimeoutError("cannot enforce HTTPS response deadline")
    deadline = time.monotonic() + seconds
    chunks = []
    received = 0
    while received < limit:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("absolute HTTPS response deadline exceeded")
        socket_obj.settimeout(min(5.0, remaining))
        fragment = response.read1(min(4096, limit - received))
        if not fragment:
            break
        received += len(fragment)
        chunks.append(fragment)
    return b"".join(chunks)


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

    def read1(self, size=-1):
        return self._source.read1(size)

    def flush(self):
        return self._source.flush()

    @property
    def raw(self):
        # Keep the HTTPS socket accessible for the subsequent BODY deadline.
        return self._source.raw

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


class _ResponseWithHeaderDeadline(http.client.HTTPResponse):
    def begin(self):
        # urllib's ordinary socket timeout is an IDLE timeout. A hostile HTTPS
        # peer can otherwise deliver one status/header byte per idle period
        # forever, before the caller even receives the response object.
        if self.fp is None:
            return super().begin()
        socket_obj = getattr(getattr(self.fp, "raw", None), "_sock", None)
        if socket_obj is None:
            raise TimeoutError("cannot enforce HTTPS header deadline")
        reader = HeaderDeadlineReader(self.fp, socket_obj, seconds=5)
        self.fp = reader
        try:
            return super().begin()
        finally:
            reader.headers_complete()


class _ConnectionWithHeaderDeadline(http.client.HTTPSConnection):
    response_class = _ResponseWithHeaderDeadline


class HeaderBoundHTTPSHandler(urllib.request.HTTPSHandler):
    """stdlib pinned-CA HTTPS handler with absolute response-header deadline."""

    def https_open(self, req):
        # CPython 3.12 removed HTTPSHandler._check_hostname; the pinned
        # SSLContext already enforces hostname verification on both runtimes.
        return self.do_open(_ConnectionWithHeaderDeadline, req,
                            context=self._context)
