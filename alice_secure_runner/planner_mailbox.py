"""Least-authority, durable proposal mailbox for an untrusted Hermes planner.

Only Alice's trusted coordinator can create jobs, publish observations, claim
model proposals or execute runner effects. The bearer issued to Hermes allows
reading ONE explicitly published, bounded step and submitting ONE untrusted
typed proposal. There are deliberately no commit, approval, browser or payment
endpoints. Synthetic loopback HTTPS is NOT a deployed control plane.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

from .core import ACTION_KEYS, Denied
from .h021_transport import HeaderDeadlineReader, LimitedHTTPServer, read_body_with_deadline


_NAME = re.compile(r"^[a-zA-Z0-9_@.:-]{1,120}$")
_VISIBLE = frozenset({"epoch", "status", "products", "sku", "name", "description",
                      "currency", "unit_minor", "variants", "variant", "quantity",
                      "cart_ready", "selected"})
_REDACT = re.compile(r"(?i)(?:https?://[^\s]+|[\w.+-]+@[\w.-]+\.[a-z]{2,}|"
                     r"\b(?:\d[ -]?){13,19}\b|\b(?:password|secret|bearer|"
                     r"api.?key|access.?token|cvv|address|recipient)\b)")

# The laboratory exposes ONE known fictional catalogue, not arbitrary user
# prose. Regex alone cannot reliably detect names, phone fragments or street
# addresses hidden in product descriptions or prompts. Only trusted fixture
# values are declassified to the untrusted Hermes model; unknown strings
# remain redacted until a real Alice data-classification policy exists.
_PUBLIC_STRINGS = {
    "status": frozenset({"researching", "selecting", "cart_ready", "stopped"}),
    "sku": frozenset({"FAKE-ALICE-1"}),
    "selected": frozenset({"FAKE-ALICE-1"}),
    "name": frozenset({"Fictional ergonomic keyboard"}),
    "description": frozenset({"Quiet keys, compact ISO layout, fictional merchant stock."}),
    "currency": frozenset({"EUR"}),
    "variant": frozenset({"standard", "graphite"}),
    "variants": frozenset({"standard", "graphite"}),
}
_PUBLIC_GOALS = frozenset({"Research a fictional keyboard"})


def _name(value: str) -> str:
    if not isinstance(value, str) or not _NAME.fullmatch(value):
        raise Denied("invalid planner identity")
    return value


def _public_text(value: str) -> str:
    clipped = value[:350]
    if any(word in clipped.lower() for word in
           ("carrer ", "calle ", "street ", "avenida ", "avinguda ", "road ",
            " st,", " st.", " rd,", " rd.", " ship to ", " deliver to ",
            " apt ", " piso ", "domicilio", " address ", " recipient ")):
        return "[redacted]"
    digits = sum(ch.isdigit() for ch in clipped)
    if digits >= 9:
        return "[redacted]"
    return _REDACT.sub("[redacted]", clipped)


def _visible(value: Any, depth: int = 0, *, field: str = "") -> Any:
    if depth > 4:
        raise Denied("observation nesting exceeded")
    if isinstance(value, dict):
        return {k: _visible(v, depth + 1, field=k) for k, v in value.items()
                if isinstance(k, str) and k in _VISIBLE}
    if isinstance(value, list):
        return [_visible(v, depth + 1, field=field) for v in value[:10]]
    if isinstance(value, str):
        return value if value in _PUBLIC_STRINGS.get(field, ()) else "[redacted]"
    if value is None or type(value) in (bool, int):
        return value
    raise Denied("invalid model observation")


class PlannerMailbox:
    """SQLite ledger owned by Alice, never mounted inside the Hermes process."""

    def __init__(self, path: str | Path, *, clock=None):
        self._clock = clock or time.time
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(path), isolation_level=None, timeout=5,
                                   check_same_thread=False)
        self._db.execute("PRAGMA busy_timeout=5000")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS planner_pairs ("
            "id TEXT PRIMARY KEY, tenant TEXT NOT NULL, session TEXT NOT NULL, "
            "account TEXT NOT NULL, installation TEXT NOT NULL, "
            "token_digest TEXT NOT NULL UNIQUE, expires INTEGER NOT NULL, "
            "revoked INTEGER NOT NULL DEFAULT 0)")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS planner_steps ("
            "id TEXT PRIMARY KEY, pair_id TEXT NOT NULL, job_id TEXT NOT NULL, "
            "epoch INTEGER NOT NULL, nonce TEXT NOT NULL, goal TEXT NOT NULL, "
            "observation TEXT NOT NULL, proposal TEXT, state TEXT NOT NULL, "
            "result_status TEXT, UNIQUE(pair_id,job_id,epoch))")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS planner_cancellations ("
            "pair_id TEXT NOT NULL, job_id TEXT NOT NULL, "
            "PRIMARY KEY(pair_id,job_id))")
        # Cancellation has a job-wide authority boundary, independent of
        # WHICH Hermes installation originally obtained proposal access.
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS planner_job_cancellations ("
            "tenant TEXT NOT NULL, session TEXT NOT NULL, job_id TEXT NOT NULL, "
            "PRIMARY KEY(tenant,session,job_id))")

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    def create_pair(self, *, tenant: str, session: str, account: str,
                    installation: str, expires_in: int = 600) -> dict[str, str]:
        # All identity claims originate in trusted Alice, not over the planner
        # HTTP interface. Installation binding remains synthetic until attested.
        tenant, session, account, installation = map(
            _name, (tenant, session, account, installation))
        if type(expires_in) is not int or not 1 <= expires_in <= 86400:
            raise Denied("invalid proposal-only pairing lifetime")
        pair_id = secrets.token_urlsafe(18)
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._db.execute(
                "INSERT INTO planner_pairs(id,tenant,session,account,installation,token_digest,expires) "
                "VALUES(?,?,?,?,?,?,?)",
                (pair_id, tenant, session, account, installation,
                 self._digest(token), int(self._clock()) + expires_in))
        return {"pair_id": pair_id, "proposal_only_token": token}

    def rotate(self, pair_id: str, *, account: str) -> str:
        token = secrets.token_urlsafe(32)
        with self._lock:
            changed = self._db.execute(
                "UPDATE planner_pairs SET token_digest=? WHERE id=? AND account=? "
                "AND revoked=0 AND expires>?",
                (self._digest(token), _name(pair_id), _name(account), int(self._clock()))).rowcount
            if changed != 1:
                raise Denied("unknown or expired planner pairing")
        return token

    def revoke(self, pair_id: str, *, account: str) -> None:
        with self._lock:
            updated = self._db.execute(
                "UPDATE planner_pairs SET revoked=1 WHERE id=? AND account=? AND revoked=0",
                (_name(pair_id), _name(account))).rowcount
            if updated != 1:
                raise Denied("unrecognized or revoked planner pairing")

    def _pair(self, token: str) -> tuple[str, str, str]:
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
            raise Denied("unknown planner capability")
        row = self._db.execute(
            "SELECT id,tenant,session,expires,revoked FROM planner_pairs WHERE token_digest=?",
            (self._digest(token),)).fetchone()
        if not row or row[4] or row[3] <= int(self._clock()):
            raise Denied("expired or revoked planner capability")
        return row[0], row[1], row[2]

    def publish(self, pair_id: str, *, tenant: str, session: str, job_id: str,
                epoch: int, goal: str, observation: dict) -> str:
        """Trusted Alice publication; never callable from the Hermes HTTP API."""
        pair_id, tenant, session, job_id = map(_name, (pair_id, tenant, session, job_id))
        if type(epoch) is not int or epoch < 0 or not isinstance(goal, str) or not 1 <= len(goal) <= 800:
            raise Denied("invalid trusted planning step")
        safe = _visible(observation)
        if not isinstance(safe, dict) or safe.get("epoch") != epoch:
            raise Denied("observation epoch mismatch")
        encoded = json.dumps(safe, sort_keys=True, separators=(",", ":"), allow_nan=False)
        if len(encoded.encode()) > 4096:
            raise Denied("oversized model observation")
        safe_goal = goal if goal in _PUBLIC_GOALS else "Research the fictional catalogue"
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                pair = self._db.execute(
                    "SELECT tenant,session,expires,revoked FROM planner_pairs WHERE id=?",
                    (pair_id,)).fetchone()
                if (not pair or pair[0:2] != (tenant, session) or pair[3]
                        or pair[2] <= int(self._clock())):
                    raise Denied("untrusted or expired Alice pairing")
                if self._db.execute(
                        "SELECT 1 FROM planner_cancellations WHERE pair_id=? AND job_id=?",
                        (pair_id, job_id)).fetchone():
                    raise Denied("Alice has cancelled this planning job")
                if self._db.execute(
                        "SELECT 1 FROM planner_job_cancellations "
                        "WHERE tenant=? AND session=? AND job_id=?",
                        (tenant, session, job_id)).fetchone():
                    raise Denied("this Alice job was cancelled across all pairings")
                prior = self._db.execute(
                    "SELECT id,goal,observation FROM planner_steps "
                    "WHERE pair_id=? AND job_id=? AND epoch=?",
                    (pair_id, job_id, epoch)).fetchone()
                if prior:
                    if (prior[1], prior[2]) != (safe_goal, encoded):
                        raise Denied("conflicting planning step")
                    self._db.execute("COMMIT")
                    return prior[0]
                if self._db.execute(
                    "SELECT 1 FROM planner_steps WHERE pair_id=? "
                    "AND state IN ('pending','submitted','claimed') LIMIT 1",
                    (pair_id,)).fetchone():
                    raise Denied("a previous plan is still unsettled")
                step_id = secrets.token_urlsafe(18)
                self._db.execute(
                    "INSERT INTO planner_steps(id,pair_id,job_id,epoch,nonce,goal,observation,state) "
                    "VALUES(?,?,?,?,?,?,?,'pending')",
                    (step_id, pair_id, job_id, epoch, secrets.token_urlsafe(20), safe_goal, encoded))
                self._db.execute("COMMIT")
                return step_id
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    def pending(self, token: str) -> dict:
        """Hermes may read ONLY an already-published, redacted planning step."""
        with self._lock:
            pair_id, _, _ = self._pair(token)
            row = self._db.execute(
                "SELECT id,epoch,nonce,goal,observation FROM planner_steps "
                "WHERE pair_id=? AND state='pending' ORDER BY rowid LIMIT 1",
                (pair_id,)).fetchone()
        if row is None:
            return {"status": "idle", "execution_authority": False}
        return {"status": "pending", "step_id": row[0], "epoch": row[1],
                "nonce": row[2], "goal": row[3],
                "observation": json.loads(row[4]), "execution_authority": False}

    def submit(self, token: str, *, step_id: str, nonce: str, proposal: dict) -> dict:
        """Untrusted proposal submission. No runner is imported or called."""
        if not isinstance(proposal, dict) or not isinstance(proposal.get("action"), str) or proposal["action"] not in ACTION_KEYS:
            raise Denied("unrecognized planner proposal")
        action = proposal["action"]
        if set(proposal) != ACTION_KEYS[action] or type(proposal.get("epoch")) is not int:
            raise Denied("malformed planner proposal")
        try:
            encoded = json.dumps(proposal, sort_keys=True, separators=(",", ":"), allow_nan=False)
        except (ValueError, TypeError) as exc:
            raise Denied("malformed planner values") from exc
        if len(encoded.encode()) > 2048:
            raise Denied("oversized proposal")
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                pair_id, scope_tenant, scope_session = self._pair(token)
                row = self._db.execute(
                    "SELECT nonce,epoch,state,proposal,job_id FROM planner_steps WHERE id=? AND pair_id=?",
                    (_name(step_id), pair_id)).fetchone()
                if (not row or not isinstance(nonce, str)
                        or not hmac.compare_digest(row[0], nonce)
                        or row[1] != proposal["epoch"]):
                    raise Denied("wrong or stale planner step")
                if self._db.execute(
                        "SELECT 1 FROM planner_cancellations WHERE pair_id=? AND job_id=?",
                        (pair_id, row[4])).fetchone():
                    raise Denied("Alice cancelled the planning step")
                if self._db.execute(
                        "SELECT 1 FROM planner_job_cancellations "
                        "WHERE tenant=? AND session=? AND job_id=?",
                        (scope_tenant, scope_session, row[4])).fetchone():
                    raise Denied("Alice cancelled this job across all pairings")
                if row[2] == "pending":
                    updated = self._db.execute(
                        "UPDATE planner_steps SET state='submitted',proposal=? "
                        "WHERE id=? AND pair_id=? AND state='pending'",
                        (encoded, step_id, pair_id)).rowcount
                    if updated != 1:
                        raise Denied("planner step concurrently claimed or submitted")
                elif row[2] not in ("submitted", "claimed", "done") or row[3] != encoded:
                    raise Denied("proposal already consumed or changed")
                self._db.execute("COMMIT")
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
        return {"status": "accepted_untrusted", "execution_authority": False}

    def claim(self, pair_id: str, *, tenant: str, session: str, step_id: str) -> dict:
        """Trusted Alice one-time handoff. Crash after claim forbids auto replay."""
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                pair = self._db.execute(
                    "SELECT tenant,session,expires,revoked FROM planner_pairs WHERE id=?",
                    (_name(pair_id),)).fetchone()
                if (not pair or pair[0:2] != (_name(tenant), _name(session))
                        or pair[2] <= int(self._clock()) or pair[3]):
                    raise Denied("Alice coordinator has wrong tenant/session")
                if self._db.execute(
                        "SELECT 1 FROM planner_cancellations WHERE pair_id=? AND job_id=("
                        "SELECT job_id FROM planner_steps WHERE id=? AND pair_id=?)",
                        (pair_id, _name(step_id), pair_id)).fetchone():
                    raise Denied("Alice cancelled the planning job")
                if self._db.execute(
                        "SELECT 1 FROM planner_job_cancellations "
                        "WHERE tenant=? AND session=? AND job_id=("
                        "SELECT job_id FROM planner_steps WHERE id=? AND pair_id=?)",
                        (tenant, session, step_id, pair_id)).fetchone():
                    raise Denied("Alice cancelled this job across all pairings")
                changed = self._db.execute(
                    "UPDATE planner_steps SET state='claimed' WHERE id=? AND pair_id=? "
                    "AND state='submitted'", (_name(step_id), pair_id)).rowcount
                if changed != 1:
                    raise Denied("no new proposal; never repeat an uncertain effect")
                row = self._db.execute(
                    "SELECT job_id,epoch,proposal FROM planner_steps WHERE id=?",
                    (step_id,)).fetchone()
                self._db.execute("COMMIT")
                return {"job_id": row[0], "epoch": row[1], "proposal": json.loads(row[2])}
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    def cancel(self, pair_id: str, *, tenant: str, session: str, job_id: str) -> dict[str, Any]:
        """Trusted Alice-only fence; never expose this method over HTTP.

        A claimed step might already be performing an effect. It remains
        uncertain and cannot be declared cancelled without trusted inspection.
        """
        pair_id, tenant, session, job_id = map(_name, (pair_id, tenant, session, job_id))
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                pair = self._db.execute(
                    "SELECT tenant,session FROM planner_pairs WHERE id=?",
                    (pair_id,)).fetchone()
                if pair != (tenant, session):
                    raise Denied("wrong Alice cancellation authority")
                self._db.execute(
                    "INSERT OR IGNORE INTO planner_cancellations(pair_id,job_id) VALUES(?,?)",
                    (pair_id, job_id))
                self._db.execute(
                    "INSERT OR IGNORE INTO planner_job_cancellations "
                    "(tenant,session,job_id) VALUES(?,?,?)",
                    (tenant, session, job_id))
                claimed = self._db.execute(
                    "SELECT 1 FROM planner_steps AS step "
                    "JOIN planner_pairs AS pair ON step.pair_id=pair.id "
                    "WHERE pair.tenant=? AND pair.session=? AND step.job_id=? "
                    "AND step.state='claimed' LIMIT 1",
                    (tenant, session, job_id)).fetchone() is not None
                self._db.execute(
                    "UPDATE planner_steps SET state='cancelled' WHERE job_id=? "
                    "AND pair_id IN (SELECT id FROM planner_pairs "
                    "WHERE tenant=? AND session=?) "
                    "AND state IN ('pending','submitted')",
                    (job_id, tenant, session))
                self._db.execute("COMMIT")
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
        return {"status": "inspection_required" if claimed else "cancelled",
                "effect_may_be_in_flight": claimed}

    def acknowledge(self, pair_id: str, *, step_id: str, result_status: str) -> None:
        """Trusted Alice acknowledges only AFTER runner state is durable."""
        if _name(result_status) not in (
                "researching", "selecting", "cart_ready", "awaiting_approval", "stopped"):
            raise Denied("cannot acknowledge untrusted or privileged outcome")
        with self._lock:
            changed = self._db.execute(
                "UPDATE planner_steps SET state='done',result_status=? "
                "WHERE id=? AND pair_id=? AND state='claimed'",
                (result_status, _name(step_id), _name(pair_id))).rowcount
            if changed != 1:
                raise Denied("unverified or duplicate Alice outcome")


def make_handler(mailbox: PlannerMailbox):
    """Separate loopback-only synthetic HTTPS surface; no ASR runner reference."""
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.rfile = HeaderDeadlineReader(self.rfile, self.connection, seconds=3)

        def parse_request(self):
            accepted = super().parse_request()
            self.rfile.headers_complete()
            return accepted

        def log_message(self, *_):
            return

        def _reply(self, status, payload):
            raw = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _token(self):
            header = self.headers.get("Authorization", "")
            return header[7:] if header.startswith("Bearer ") else ""

        def do_GET(self):
            if self.path != "/v1/planner/next":
                return self._reply(404, {"error": "not_found"})
            try:
                self._reply(200, mailbox.pending(self._token()))
            except Denied:
                self._reply(401, {"error": "denied"})

        def do_POST(self):
            if self.path != "/v1/planner/proposal":
                return self._reply(404, {"error": "not_found"})
            try:
                if (self.headers.get("Content-Type") != "application/json"
                        or self.headers.get("Transfer-Encoding")):
                    raise Denied("invalid proposal request")
                size = int(self.headers.get("Content-Length", "-1"))
                if not 2 <= size <= 4096:
                    raise Denied("oversized proposal request")
                data = json.loads(read_body_with_deadline(self, size, seconds=3))
                if not isinstance(data, dict) or set(data) != {"step_id", "nonce", "proposal"}:
                    raise Denied("invalid proposal schema")
                self._reply(200, mailbox.submit(self._token(), **data))
            except (Denied, KeyError, ValueError, TypeError, TimeoutError, OSError):
                self._reply(403, {"error": "denied"})

    return Handler


class LoopbackPlannerHTTPS:
    """Disposable test transport, not a hosted multi-tenant deployment."""

    def __init__(self, mailbox: PlannerMailbox, cert_file: str, key_file: str):
        self.server = LimitedHTTPServer(
            ("127.0.0.1", 0), make_handler(mailbox), max_connections=8)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(cert_file, key_file)
        self.server.tls_context = tls
        self.url = f"https://localhost:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
