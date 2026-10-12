"""Typed browser-read fixture for Alice ASR; NOT security-grade OS isolation.

Requires Node and Playwright installed *in Alice's runner environment*, never
in the user's official Hermes installation. No browser tool is registered with
Hermes. A single subprocess owns one Chrome and per-job ephemeral contexts.
"""

from __future__ import annotations

import json
import os
import secrets
import selectors
import signal
import subprocess
import threading
import time
from pathlib import Path

from .core import Denied, FictionalHTTPSAdapter


class BrowserFixtureReadAdapter(FictionalHTTPSAdapter):
    """Use actual Chromium DOM for read-only fictional product discovery.

    Checkout and cart still require the strictly typed, pinned HTTPS merchant
    adapter and the authorization ledger. This is not a general browser agent.
    """

    def __init__(self, *, origin: str, ca_file: str, merchant_token: str, browser_read_token: str,
                 playwright_module: str, chrome_path: str | None = None):
        super().__init__(origin=origin, ca_file=ca_file, merchant_token=merchant_token)
        if not Path(playwright_module).is_dir():
            raise Denied("Alice runner test Playwright dependency missing")
        env = {"PATH": os.environ.get("PATH", ""),
               "ALICE_TEST_PLAYWRIGHT_MODULE": str(Path(playwright_module).resolve()),
               "ALICE_FIXTURE_ORIGIN": origin,
               "ALICE_FIXTURE_BROWSER_READ_TOKEN": browser_read_token}
        if os.environ.get("PLAYWRIGHT_BROWSERS_PATH"):
            env["PLAYWRIGHT_BROWSERS_PATH"] = os.environ["PLAYWRIGHT_BROWSERS_PATH"]
        if chrome_path:
            env["ALICE_TEST_CHROME_PATH"] = chrome_path
        self._lock = threading.RLock()
        self.generation_id = secrets.token_urlsafe(20)
        self._buffer = bytearray()
        self._next_id = 0
        self._child = subprocess.Popen(
            ["node", str(Path(__file__).with_name("browser_fixture.mjs"))],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=0, env=env, start_new_session=(os.name == "posix"))
        try:
            if self._receive(30) != {"ready": True}:
                raise Denied("Alice fixture browser failed to start")
        except Exception:
            self.close()
            raise

    def _receive(self, seconds: int) -> dict:
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as selector:
            selector.register(self._child.stdout, selectors.EVENT_READ)
            while b"\n" not in self._buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError("fixture browser channel timed out")
                fragment = os.read(self._child.stdout.fileno(), 4096)
                if not fragment:
                    raise Denied("fixture browser process exited")
                self._buffer.extend(fragment)
                if len(self._buffer) > 65536:
                    raise Denied("fixture browser response too large")
        index = self._buffer.index(10)
        line = bytes(self._buffer[:index])
        del self._buffer[:index + 1]
        data = json.loads(line.decode("utf-8"))
        if not isinstance(data, dict):
            raise Denied("invalid browser response")
        return data

    def _command(self, body: dict) -> dict:
        with self._lock:
            if self._child.poll() is not None:
                raise Denied("fixture browser unavailable")
            self._next_id += 1
            message = {**body, "id": self._next_id}
            try:
                self._child.stdin.write((json.dumps(message) + "\n").encode())
                self._child.stdin.flush()
                reply = self._receive(15)
            except (OSError, ValueError, TimeoutError):
                # In particular, a late response can never be confused with a
                # subsequent CLOSE acknowledgement. Terminate the entire
                # disposable Chrome/Node process group before returning.
                self._force_terminate()
                raise Denied("fixture browser channel lost; not safe to continue")
            if reply.get("id") != self._next_id or reply.get("op") != body["op"]:
                self._force_terminate()
                raise Denied("fixture browser protocol desynchronized")
            if "error" in reply:
                raise Denied("fixture browser rejected typed action")
            if not isinstance(reply.get("ok"), dict):
                self._force_terminate()
                raise Denied("invalid fixture browser response")
            return reply["ok"]

    def search(self, query: str, *, browser_session: str | None = None) -> dict:
        if not browser_session:
            raise Denied("runner job identity required for browser research")
        return self._command({"op": "search", "session": browser_session, "query": query})

    def read(self, sku: str, *, browser_session: str | None = None) -> dict:
        if not browser_session:
            raise Denied("runner job identity required for browser research")
        return self._command({"op": "read_product", "session": browser_session, "sku": sku})

    def release_session(self, browser_session: str) -> None:
        # An explicit unknown-session error is fail-closed for handoff, but is
        # not a reason to kill OTHER independent jobs in this Node process.
        # Transport timeout/desync still force-terminates within _command().
        reply = self._command({"op": "close", "session": browser_session})
        if reply != {"closed": True, "session": browser_session}:
            self._force_terminate()
            raise Denied("browser close not acknowledged")

    def fixture_stats(self) -> dict:
        """Test oracle inside Alice only; NEVER publish as a Hermes tool."""
        return self._command({"op": "stats"})

    def close(self) -> None:
        with self._lock:
            if self._child.poll() is None:
                try:
                    self._child.stdin.close()
                except OSError:
                    pass
                try:
                    self._child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._force_terminate()

    def _force_terminate(self) -> None:
        if self._child.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(self._child.pid, signal.SIGKILL)
                else:
                    self._child.kill()
            except ProcessLookupError:
                pass
            self._child.wait(timeout=5)
