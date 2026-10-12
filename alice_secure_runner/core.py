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
from dataclasses import dataclass, field
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
    human_token: str = ""


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

    def search(self, query: str) -> dict[str, Any]:
        return self.call("GET", "/search?q=" + urllib.parse.quote(query, safe=""))

    def read(self, sku: str) -> dict[str, Any]:
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
        self.__adapter = adapter
        self.__approval_key = approval_key
        self.__jobs: dict[str, Job] = {}
        self.__lock = threading.RLock()
        self.__db = sqlite3.connect(str(ledger_path), check_same_thread=False, isolation_level=None)
        self.__db.execute("CREATE TABLE IF NOT EXISTS authorizations (checkout_id TEXT PRIMARY KEY, digest TEXT NOT NULL, status TEXT NOT NULL, order_id TEXT)")

    def new_job(self, tenant: str, session: str, recipient: str) -> dict[str, Any]:
        if not all(isinstance(v, str) and 0 < len(v) <= 120 for v in (tenant, session, recipient)):
            raise Denied("invalid trusted identity/recipient")
        job = Job(secrets.token_urlsafe(16), tenant, session, recipient)
        with self.__lock:
            self.__jobs[job.id] = job
        return {"job_id": job.id, "epoch": 0, "status": job.state}

    def _job(self, job_id: str, tenant: str, session: str) -> Job:
        job = self.__jobs.get(job_id)
        if job is None or job.tenant != tenant or job.owner_session != session:
            raise Denied("job does not belong to this session")
        return job

    def _pending(self, job: Job) -> dict[str, Any]:
        if job.checkout is None:
            raise Denied("checkout has not been prepared")
        return job.checkout

    def propose(self, job_id: str, *, tenant: str, session: str, proposal: Any) -> dict[str, Any]:
        """Untrusted model proposals cannot commit an order or read secrets."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state in ("awaiting_approval", "approved", "dispatching", "unknown", "confirmed", "human_only", "stopped"):
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
                result = self.__adapter.search(query)
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
                product = self.__adapter.read(sku)
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
            job.state = "approved"
            return {"status": "approved", "checkout_id": cid}

    def commit(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Trusted Alice coordinator only. Never expose as a model tool."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state != "approved":
                raise Denied("not approved or checkout already attempted")
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
            try:
                response = self.__adapter.commit(cart_id=job.cart_id, recipient=job.recipient,
                                                 snapshot=snapshot, idempotency_key=checkout_id)
            except Exception as exc:
                self.__db.execute("UPDATE authorizations SET status='unknown' WHERE checkout_id=? AND status='dispatching'", (checkout_id,))
                job.state = "unknown"
                raise Indeterminate("submission result unknown; do not retry automatically") from exc
            if (response.get("checkout_id") != checkout_id or response.get("amount_minor") != snapshot["amount_minor"]
                    or response.get("currency") != snapshot["currency"] or not isinstance(response.get("order_id"), str)):
                self.__db.execute("UPDATE authorizations SET status='unknown' WHERE checkout_id=? AND status='dispatching'", (checkout_id,))
                job.state = "unknown"
                raise Indeterminate("merchant order receipt cannot be verified")
            self.__db.execute("UPDATE authorizations SET status='confirmed',order_id=? WHERE checkout_id=? AND status='dispatching'",
                              (response["order_id"], checkout_id))
            job.state = "confirmed"
            return {"status": "confirmed_simulated", "order_id": response["order_id"],
                    "checkout_id": checkout_id, "amount_minor": snapshot["amount_minor"], "currency": snapshot["currency"]}

    def human_handoff(self, job_id: str, *, tenant: str, session: str) -> dict[str, Any]:
        """Revokes agent writes. Human token stays exclusively with Alice UI."""
        with self.__lock:
            job = self._job(job_id, tenant, session)
            if job.state in ("dispatching", "unknown", "confirmed", "stopped"):
                raise Denied("cannot hand off an already-sent or terminal checkout")
            job.epoch += 1
            job.state = "human_only"
            job.human_token = secrets.token_urlsafe(32)
            # Only the trusted caller/UI receives this; never feed it to Hermes.
            return {"status": "awaiting_human_finalization", "human_handle": job.human_token}

    def human_finalize(self, job_id: str, *, tenant: str, human_handle: str) -> dict[str, Any]:
        """Simulated explicit human finalization, not an agent action."""
        with self.__lock:
            job = self.__jobs.get(job_id)
            if (job is None or job.tenant != tenant or job.state != "human_only"
                    or not isinstance(human_handle, str) or not hmac.compare_digest(job.human_token, human_handle)):
                raise Denied("not an authorized human session")
            job.human_token = ""
            job.state = "completed_by_human_simulated"
            return {"status": job.state, "payment_claim": "NOT_VERIFIED"}
