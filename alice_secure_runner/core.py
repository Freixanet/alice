"""Typed Alice-owned effect broker for a single fictional HTTPS merchant.

Never pass the runner instance, TLS/private merchant token, approval key, or
checkout nonce into a Hermes tool or model prompt. The model is an UNTRUSTED
planner, and only an Alice coordinator is allowed to invoke this API.

This is a narrow protocol/one-shot demonstration. Python object separation is
NOT OS/process isolation. A production runner must live outside Hermes with
separate tenant credentials, sandboxed browser/egress, durable jobs and auth.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import sqlite3
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


class Denied(ValueError):
    """Invalid/unauthorized action; no merchant checkout submit attempted."""


class Indeterminate(RuntimeError):
    """Checkout dispatch might have reached the merchant; never retry blindly."""


ALLOWED = frozenset({"search", "read_product", "select_product", "add_to_cart", "prepare_checkout", "stop"})
ACTION_KEYS = {
    "search": frozenset({"action", "query", "epoch"}),
    "read_product": frozenset({"action", "sku", "epoch"}),
    "select_product": frozenset({"action", "sku", "epoch"}),
    "add_to_cart": frozenset({"action", "quantity", "epoch"}),
    "prepare_checkout": frozenset({"action", "epoch"}),
    "stop": frozenset({"action", "epoch"}),
}


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


@dataclass
class Job:
    id: str
    tenant: str
    owner_session: str
    recipient: str
    epoch: int = 0
    state: str = "researching"
    found: tuple[str, ...] = ()
    selected: str = ""
    quantity: int = 0
    cart_id: str = field(default_factory=lambda: secrets.token_urlsafe(20))
    checkout: dict[str, Any] | None = None
    challenge_nonce: str = ""
    challenge_expires: int = 0
    commit_expires: int = 0
    human_handle_digest: str = ""
    # Runner-only browser ownership marker, not a security boundary. A new
    # process must not claim it closed a previous process's browser.
    browser_opened: bool = False
    browser_generation: str = ""


class FictionalHTTPSAdapter:
    """One allowlisted endpoint, no caller-chosen URLs/HTTP/JavaScript/CDP."""

    def __init__(self, *, origin: str, ca_file: str, merchant_token: str):
        parsed = urllib.parse.urlsplit(origin)
        if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
            raise Denied("merchant endpoint must be a fixed HTTPS origin")
        if parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise Denied("prototype adapter can access only its fictional loopback merchant")
        self._base = origin.rstrip("/")
        self._ssl = ssl.create_default_context(cafile=ca_file)
        self._token = merchant_token  # NEVER included in any model-visible result
        class DenyRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                raise Denied("merchant redirect refused: no credential forwarding")
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),  # never inherit host HTTP proxy/credentials
            urllib.request.HTTPSHandler(context=self._ssl), DenyRedirect())

    def call(self, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        if not path.startswith("/") or path.startswith("//") or "#" in path:
            raise Denied("not a fixed adapter route")
        req = urllib.request.Request(
            self._base + path,
            data=_canonical(body) if body is not None else None,
            method=method,
            headers={"Authorization": "Bearer " + self._token, "Content-Type": "application/json"},
        )
        with self._opener.open(req, timeout=3) as response:
            # No implicit redirect to third-party endpoints, even on GET.
            if response.url.split("?", 1)[0].split("/", 3)[:3] != self._base.split("/", 3)[:3]:
                raise Denied("merchant redirected outside the pinned origin")
            data = response.read(16_385)
            if len(data) > 16_384:
                raise Denied("merchant response too large")
        result = json.loads(data)
        if not isinstance(result, dict):
            raise Denied("invalid merchant response")
        return result

    def search(self, query: str, *, browser_session: str | None = None) -> dict[str, Any]:
        return self.call("GET", "/search?q=" + urllib.parse.quote(query, safe=""))

    def read(self, sku: str, *, browser_session: str | None = None) -> dict[str, Any]:
        return self.call("GET", "/product/" + urllib.parse.quote(sku, safe=""))

    def cart(self, cart_id: str, sku: str, quantity: int) -> dict[str, Any]:
        return self.call("POST", "/cart", {"cart_id": cart_id, "sku": sku, "quantity": quantity})

    def quote(self, cart_id: str, recipient: str) -> dict[str, Any]:
        return self.call("POST", "/quote", {"cart_id": cart_id, "recipient": recipient})

    def commit(self, *, cart_id: str, recipient: str, snapshot: dict[str, Any], idempotency_key: str) -> dict[str, Any]:
        return self.call("POST", "/commit", {"cart_id": cart_id, "recipient": recipient,
                                             "snapshot": snapshot, "idempotency_key": idempotency_key})


class AliceRunner:
    """Prototype broker with a durable, at-most-one checkout attempt ledger."""

    def __init__(self, adapter: FictionalHTTPSAdapter, *, approval_key: bytes, ledger_path: str | Path = ":memory:"):
        if len(approval_key) < 32:
            raise ValueError("prototype device HMAC key must be >=32 bytes")
        ledger_path = ":memory:" if str(ledger_path) == ":memory:" else str(Path(ledger_path).expanduser().resolve())
        self.__adapter = adapter
        self.__approval_key = approval_key
        self.__jobs: dict[str, Job] = {}
        self.__lock = threading.RLock()
        self.__owner: sqlite3.Connection | None = None
        if str(ledger_path) != ":memory:":
            # A distinct SQLite lock database provides cross-process ownership
            # on Windows/macOS/Linux; sqlite3's main ledger remains autocommit.
            # Losing the owner process releases its transaction lock automatically.
            self.__owner = sqlite3.connect(str(ledger_path) + ".owner.sqlite3",
                                           timeout=0, isolation_level=None)
            try:
                self.__owner.execute("CREATE TABLE IF NOT EXISTS singleton (id INTEGER PRIMARY KEY)")
                self.__owner.execute("BEGIN IMMEDIATE")
            except sqlite3.OperationalError as exc:
                self.__owner.close()
                self.__owner = None
                raise Denied("another runner owns this persistent ledger") from exc
        try:
            self.__db = sqlite3.connect(str(ledger_path), check_same_thread=False, isolation_level=None)
            self.__db.execute("CREATE TABLE IF NOT EXISTS authorizations (checkout_id TEXT PRIMARY KEY, digest TEXT NOT NULL, status TEXT NOT NULL, order_id TEXT)")
            self.__db.execute("CREATE TABLE IF NOT EXISTS jobs (job_id TEXT PRIMARY KEY, state_json TEXT NOT NULL)")
            self._recover_jobs()
        except Exception:
            if hasattr(self, "_AliceRunner__db"):
                self.__db.close()
            if self.__owner is not None:
                self.__owner.close()
                self.__owner = None
            raise

    def _persist_job(self, job: Job) -> None:
        # Synthetic fixtures only: the durable record never stores raw human handles.
        self.__db.execute("INSERT OR REPLACE INTO jobs(job_id,state_json) VALUES(?,?)",
                          (job.id, _canonical(asdict(job)).decode("utf-8")))

    def _recover_jobs(self) -> None:
        """Reconcile crash windows with the authoritative payment-attempt ledger.

        A recorded dispatch is UNKNOWN after restart, never an invitation to
        resend. Inconsistent/missing authorization rows fail closed.
        """
        for job_id, serialized in self.__db.execute("SELECT job_id,state_json FROM jobs"):
            saved = json.loads(serialized)
            if not isinstance(saved, dict) or saved.get("id") != job_id:
                raise ValueError("invalid persisted job")
            if "browser_opened" not in saved:
                # Pre-migration jobs may have opened Chromium even though the
                # old ledger did not record ownership. Never infer no browser,
                # even if a different (API-only) adapter is active on restart.
                saved["browser_opened"] = True
                saved["browser_generation"] = "unknown-prior-generation"
            saved["found"] = tuple(saved.get("found", ()))
            job = Job(**saved)
            if job.checkout is not None:
                cid = job.checkout.get("checkout_id")
                row = self.__db.execute("SELECT digest,status FROM authorizations WHERE checkout_id=?", (cid,)).fetchone()
                if row is None or row[0] != _digest(job.checkout):
                    raise ValueError("job authorization state inconsistent; refusing startup")
                authorization_state = row[1]
                if authorization_state == "dispatching":
                    self.__db.execute("UPDATE authorizations SET status='unknown' WHERE checkout_id=? AND status='dispatching'", (cid,))
                    job.state = "unknown"
                elif authorization_state in ("approved", "unknown", "confirmed", "human_only",
                                             "handoff_pending_close"):
                    job.state = authorization_state
                elif authorization_state == "human_simulated":
                    job.state = "completed_by_human_simulated"
                elif authorization_state == "pending" and job.state == "awaiting_approval":
                    pass
                else:
                    raise ValueError("invalid persisted authorization transition")
                if job.state != "awaiting_approval":
                    job.challenge_nonce = ""
                    job.challenge_expires = 0
                if job.state == "completed_by_human_simulated":
                    job.human_handle_digest = ""
            self.__jobs[job.id] = job
            self._persist_job(job)

    def close(self) -> None:
        """Stop this synthetic runner after closing its test listener."""
        with self.__lock:
            self.__db.close()
            if self.__owner is not None:
                self.__owner.close()
                self.__owner = None

    def new_job(self, tenant: str, session: str, recipient: str) -> dict[str, Any]:
        if not all(isinstance(v, str) and 0 < len(v) <= 120 for v in (tenant, session, recipient)):
            raise Denied("invalid trusted identity/recipient")
        job = Job(secrets.token_urlsafe(16), tenant, session, recipient)
        with self.__lock:
            self.__jobs[job.id] = job
            self._persist_job(job)
        return {"job_id": job.id, "epoch": 0, "status": job.state}

    def _job(self, job_id: str, tenant: str, session: str) -> Job:
        job = self.__jobs.get(job_id)
        if job is None or job.tenant != tenant or job.owner_session != session:
            raise Denied("job does not belong to this session")
        return job

    def resume_job(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Resume a persisted job for trusted Alice without minting new authority.

        Returns a bounded coordinator observation; never leaks consent signing
        keys or the human handoff handle. A restored state cannot reset epoch.
        Terminal, human-only and uncertain states are observable, not writable.
        """
        with self.__lock:
            job = self._job(job_id, tenant, session)
            result: dict[str, Any] = {"job_id": job.id, "epoch": job.epoch, "status": job.state}
            if job.found:
                result["products"] = [{"sku": sku} for sku in job.found[:10]]
            if job.selected:
                result["sku"] = job.selected
            if job.quantity:
                result["quantity"] = job.quantity
                result["cart_ready"] = job.state == "cart_ready"
            if job.checkout is not None and job.state == "awaiting_approval":
                result["checkout"] = job.checkout.copy()
                result["approval_challenge"] = self._challenge(job)
            return result

    def _pending(self, job: Job) -> dict[str, Any]:
        if job.checkout is None:
            raise Denied("checkout has not been prepared")
        return job.checkout

    def _claim_browser(self, job: Job) -> None:
        generation = getattr(self.__adapter, "generation_id", None)
        if job.browser_opened and job.browser_generation != generation:
            raise Denied("old browser owner not isolated; cannot resume")
        if generation is None:
            return
        if not job.browser_opened:
            job.browser_opened = True
            job.browser_generation = generation
            self._persist_job(job)  # before the process could create a context

    def _cleanup_terminal_browser(self, job: Job) -> bool:
        """Best-effort read-session cleanup AFTER irreversibly recording state.

        Failure cannot undo a confirmed or uncertain merchant effect. Human
        handoff still uses a STRICT acknowledged close instead of this helper.
        """
        if not job.browser_opened:
            return True
        if (not hasattr(self.__adapter, "release_session")
                or job.browser_generation != getattr(self.__adapter, "generation_id", None)):
            return False
        prior_generation = job.browser_generation
        try:
            self.__adapter.release_session(job.id)
            job.browser_opened = False
            job.browser_generation = ""
            self._persist_job(job)
            return True
        except Exception:
            # Keep durable prior-owner marker if close or persistence fails.
            job.browser_opened = True
            job.browser_generation = prior_generation
            return False

    def propose(self, job_id: str, *, tenant: str, session: str, proposal: Any) -> dict[str, Any]:
        """Untrusted model proposals cannot commit an order or read secrets."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            # Fail closed for every future state unless explicitly authorized.
            if job.state not in ("researching", "selecting", "cart_ready"):
                raise Denied("agent's shopping write capability is revoked")
            if not isinstance(proposal, dict) or proposal.get("action") not in ALLOWED:
                raise Denied("unknown, privileged or malformed operation")
            action = proposal["action"]
            if set(proposal) != ACTION_KEYS[action]:
                raise Denied("unexpected/missing action parameters")
            if type(proposal["epoch"]) is not int or proposal["epoch"] != job.epoch:
                raise Denied("stale browser/document step")
            output: dict[str, Any]
            if action == "search":
                query = proposal["query"]
                if not isinstance(query, str) or not (1 <= len(query) <= 100):
                    raise Denied("invalid search")
                self._claim_browser(job)
                result = self.__adapter.search(query, browser_session=job.id)
                products = result.get("products")
                if not isinstance(products, list) or len(products) > 10:
                    raise Denied("bad merchant results")
                job.found = tuple(v["sku"] for v in products if isinstance(v, dict) and isinstance(v.get("sku"), str))
                output = {"products": [{"sku": v["sku"], "name": str(v.get("name", ""))[:100]}
                                       for v in products if isinstance(v, dict) and v.get("sku") in job.found]}
            elif action in ("read_product", "select_product"):
                sku = proposal["sku"]
                if not isinstance(sku, str) or sku not in job.found:
                    raise Denied("product not returned by this job's search")
                self._claim_browser(job)
                product = self.__adapter.read(sku, browser_session=job.id)
                if product.get("sku") != sku:
                    raise Denied("merchant product changed")
                output = {"sku": sku, "name": str(product.get("name", ""))[:100],
                          "description": str(product.get("description", ""))[:350],
                          "unit_minor": product.get("unit_minor"), "currency": product.get("currency")}
                if action == "select_product":
                    job.selected = sku
                    job.state = "selecting"
            elif action == "add_to_cart":
                quantity = proposal["quantity"]
                if not job.selected or type(quantity) is not int or not (1 <= quantity <= 5):
                    raise Denied("cart requires selected product and bounded quantity")
                result = self.__adapter.cart(job.cart_id, job.selected, quantity)
                if result.get("sku") != job.selected or result.get("quantity") != quantity:
                    raise Denied("merchant cart mismatch")
                job.quantity = quantity
                job.state = "cart_ready"
                output = {"sku": job.selected, "quantity": quantity, "cart_ready": True}
            elif action == "prepare_checkout":
                if not job.quantity or job.state != "cart_ready":
                    raise Denied("no independently prepared cart")
                quote = self.__adapter.quote(job.cart_id, job.recipient)
                self._validate_quote(job, quote)
                checkout_id = secrets.token_urlsafe(16)
                snapshot = {"merchant": "Alice Fictional HTTPS Merchant", "sku": job.selected,
                            "quantity": job.quantity, "recipient": job.recipient,
                            "amount_minor": quote["amount_minor"], "currency": quote["currency"],
                            "checkout_id": checkout_id}
                job.checkout = snapshot
                job.state = "awaiting_approval"
                job.challenge_nonce = secrets.token_urlsafe(20)
                job.challenge_expires = int(time.time()) + 180
                self.__db.execute("INSERT INTO authorizations(checkout_id,digest,status) VALUES(?,?,?)",
                                  (checkout_id, _digest(snapshot), "pending"))
                output = {"checkout": snapshot.copy(), "approval_challenge": self._challenge(job)}
            else:
                job.state = "stopped"
                output = {"stopped": True}
            job.epoch += 1
            self._persist_job(job)
            if job.state == "stopped":
                output["browser_cleanup_verified"] = self._cleanup_terminal_browser(job)
            return {"ok": True, "epoch": job.epoch, "status": job.state, **output}

    def _validate_quote(self, job: Job, quote: dict[str, Any]) -> None:
        if (quote.get("sku") != job.selected or quote.get("quantity") != job.quantity
                or quote.get("recipient") != job.recipient or quote.get("currency") != "EUR"
                or type(quote.get("amount_minor")) is not int
                or not 1 <= quote["amount_minor"] <= 100_000):
            raise Denied("checkout amount/items/recipient cannot be verified")

    def _challenge(self, job: Job) -> dict[str, Any]:
        return {"job_id": job.id, "tenant": job.tenant, "session": job.owner_session,
                "snapshot_digest": _digest(self._pending(job)), "nonce": job.challenge_nonce,
                "expires_at": job.challenge_expires}

    def challenge(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state != "awaiting_approval":
                raise Denied("not awaiting approval")
            return self._challenge(job)

    def approve(self, job_id: str, *, tenant: str, session: str, signature: str) -> dict[str, Any]:
        """HMAC proves this fictional test client, NOT real Secure Enclave attestation."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state != "awaiting_approval":
                raise Denied("not awaiting user approval")
            if time.time() >= job.challenge_expires:
                raise Denied("checkout consent expired")
            wanted = hmac.new(self.__approval_key, _canonical(self._challenge(job)), hashlib.sha256).hexdigest()
            if not isinstance(signature, str) or not hmac.compare_digest(signature, wanted):
                raise Denied("invalid or replayed user approval")
            cid = self._pending(job)["checkout_id"]
            rc = self.__db.execute("UPDATE authorizations SET status='approved' WHERE checkout_id=? AND status='pending'",
                                   (cid,)).rowcount
            if rc != 1:
                raise Denied("approval already consumed")
            job.challenge_nonce = ""
            job.challenge_expires = 0
            job.commit_expires = int(time.time()) + 300
            job.state = "approved"
            self._persist_job(job)
            return {"status": "approved", "checkout_id": cid}

    def commit(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Trusted Alice coordinator only. Never expose as a model tool."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state != "approved":
                raise Denied("not approved or checkout already attempted")
            if time.time() >= job.commit_expires:
                raise Denied("approved checkout execution window expired")
            snapshot = self._pending(job)
            # Recheck the real fictional merchant total before any submission.
            fresh = self.__adapter.quote(job.cart_id, job.recipient)
            self._validate_quote(job, fresh)
            if (fresh["amount_minor"], fresh["currency"]) != (snapshot["amount_minor"], snapshot["currency"]):
                raise Denied("amount changed after user approval")
            checkout_id = snapshot["checkout_id"]
            rc = self.__db.execute("UPDATE authorizations SET status='dispatching' WHERE checkout_id=? AND status='approved' AND digest=?",
                                   (checkout_id, _digest(snapshot))).rowcount
            if rc != 1:
                raise Denied("checkout attempt already consumed")
            job.state = "dispatching"
            self._persist_job(job)  # fail before sending if persistence fails
            try:
                response = self.__adapter.commit(cart_id=job.cart_id, recipient=job.recipient,
                                                 snapshot=snapshot, idempotency_key=checkout_id)
            except Exception as exc:
                self.__db.execute("UPDATE authorizations SET status='unknown' WHERE checkout_id=? AND status='dispatching'", (checkout_id,))
                job.state = "unknown"
                self._persist_job(job)
                self._cleanup_terminal_browser(job)
                raise Indeterminate("submission result unknown; do not retry automatically") from exc
            if (response.get("checkout_id") != checkout_id or response.get("amount_minor") != snapshot["amount_minor"]
                    or response.get("currency") != snapshot["currency"]
                    or not isinstance(response.get("order_id"), str)
                    or not 1 <= len(response["order_id"].strip()) <= 120):
                self.__db.execute("UPDATE authorizations SET status='unknown' WHERE checkout_id=? AND status='dispatching'", (checkout_id,))
                job.state = "unknown"
                self._persist_job(job)
                self._cleanup_terminal_browser(job)
                raise Indeterminate("merchant order receipt cannot be verified")
            confirmed = self.__db.execute("UPDATE authorizations SET status='confirmed',order_id=? WHERE checkout_id=? AND status='dispatching'",
                                          (response["order_id"], checkout_id)).rowcount
            if confirmed != 1:
                job.state = "unknown"
                self._persist_job(job)
                self._cleanup_terminal_browser(job)
                raise Indeterminate("order received but durable authorization changed; reconcile manually")
            job.state = "confirmed"
            self._persist_job(job)
            self._cleanup_terminal_browser(job)
            return {"status": "confirmed_simulated", "order_id": response["order_id"],
                    "checkout_id": checkout_id, "amount_minor": snapshot["amount_minor"], "currency": snapshot["currency"]}

    def human_handoff(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Revoke agent; verify browser closure BEFORE issuing human authority.

        If closure fails, a durable pending state blocks BOTH the agent and
        human reissue. Trusted Alice can retry closure without reopening writes.
        """
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state in ("dispatching", "unknown", "confirmed", "stopped", "human_only",
                             "completed_by_human_simulated"):
                raise Denied("cannot repeat a handoff or hand off a terminal checkout")
            if job.state != "handoff_pending_close":
                if job.checkout is not None:
                    transitioned = self.__db.execute(
                        "UPDATE authorizations SET status='handoff_pending_close' "
                        "WHERE checkout_id=? AND status IN ('pending','approved')",
                        (job.checkout["checkout_id"],)).rowcount
                    if transitioned != 1:
                        raise Denied("cannot hand off while checkout submission may be in flight")
                job.epoch += 1
                job.state = "handoff_pending_close"
                job.challenge_nonce = ""
                job.challenge_expires = 0
                job.commit_expires = 0
                job.human_handle_digest = ""
                self._persist_job(job)
            if job.browser_opened:
                if (not hasattr(self.__adapter, "release_session")
                        or job.browser_generation != getattr(self.__adapter, "generation_id", None)):
                    raise Denied("previous browser process not fenced; human handoff unavailable")
                try:
                    self.__adapter.release_session(job.id)
                except Exception as exc:
                    # Browser closure has NOT been attested: no human
                    # handle, no planner writes, no reissue until retry.
                    raise Denied("Alice browser session could not be closed") from exc
                job.browser_opened = False
                job.browser_generation = ""
            if job.checkout is not None:
                transitioned = self.__db.execute(
                    "UPDATE authorizations SET status='human_only' "
                    "WHERE checkout_id=? AND status='handoff_pending_close'",
                    (job.checkout["checkout_id"],)).rowcount
                if transitioned != 1:
                    raise Denied("human handoff state cannot be made exclusive")
            job.state = "human_only"
            human_handle = secrets.token_urlsafe(32)
            job.human_handle_digest = _digest(human_handle)
            self._persist_job(job)
            # Only the trusted caller/UI receives this; never feed it to Hermes.
            return {"status": "awaiting_human_finalization", "human_handle": human_handle}

    def reissue_human_handle(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Explicit human-side recovery, never an automatic backend retry.

        The HTTPS service exposes this only with its distinct human capability.
        A duplicate coordinator handoff request must not invalidate a live
        human session; an authenticated human may explicitly request a new
        handle if the original delivery failed. No real PSP is implemented.
        """
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state != "human_only":
                raise Denied("human recovery is not available for this state")
            if job.checkout is not None:
                transitioned = self.__db.execute(
                    "UPDATE authorizations SET status='human_only' WHERE checkout_id=? AND status='human_only'",
                    (job.checkout["checkout_id"],)).rowcount
                if transitioned != 1:
                    raise Denied("human recovery is no longer exclusive")
            job.epoch += 1
            human_handle = secrets.token_urlsafe(32)
            job.human_handle_digest = _digest(human_handle)
            self._persist_job(job)
            return {"status": "awaiting_human_finalization", "human_handle": human_handle}

    def human_finalize(self, job_id: str, *, tenant: str, human_handle: str) -> dict[str, Any]:
        """Simulated explicit human finalization, not an agent action."""
        with self.__lock:
            job = self.__jobs.get(job_id)
            if (job is None or job.tenant != tenant or job.state != "human_only"
                    or not isinstance(human_handle, str) or not hmac.compare_digest(
                        job.human_handle_digest, _digest(human_handle))):
                raise Denied("not an authorized human session")
            if job.checkout is not None:
                transitioned = self.__db.execute(
                    "UPDATE authorizations SET status='human_simulated' WHERE checkout_id=? AND status='human_only'",
                    (job.checkout["checkout_id"],)).rowcount
                if transitioned != 1:
                    raise Denied("human completion is no longer exclusive")
            job.human_handle_digest = ""
            job.state = "completed_by_human_simulated"
            self._persist_job(job)
            return {"status": job.state, "payment_claim": "NOT_VERIFIED"}
