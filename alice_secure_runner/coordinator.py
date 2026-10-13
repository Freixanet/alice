"""Alice-owned multi-step coordinator. Hermes supplies proposals, not effects.

The planner MUST NOT receive the private merchant token, device approval key,
browser state, secrets or checkout signer. This prototype uses a fake planner.
"""

from __future__ import annotations

from typing import Any, Protocol

from .core import AliceRunner, Denied


class Planner(Protocol):
    def next_action(self, observation: dict[str, Any]) -> dict[str, Any]: ...


class Coordinator:
    def __init__(self, runner: AliceRunner, *, tenant: str, session: str, recipient: str, planner: Planner,
                 existing_job_id: str | None = None):
        self._runner = runner  # Alice-only credential-bearing process
        self._tenant = tenant
        self._session = session
        self._planner = planner
        self._job = (runner.resume_job(existing_job_id, tenant=tenant, session=session)
                     if existing_job_id is not None else runner.new_job(tenant, session, recipient))
        self._previous: dict[str, Any] = self._job.copy()
        self.events: list[dict[str, Any]] = []

    @property
    def job_id(self) -> str:
        return self._job["job_id"]

    def step(self) -> dict[str, Any]:
        # Copy *only* explicitly bounded, non-authorizing public observations.
        safe = {k: v for k, v in self._previous.items()
                if k in ("epoch", "status", "products", "name", "sku", "description", "currency",
                         "unit_minor", "variants", "variant", "cart_ready", "quantity")}
        proposed = self._planner.next_action(safe)
        # Planner output is not executed in Hermes: the runner independently
        # authorizes exact typed parameters against its own trusted job state.
        result = self._runner.propose(self.job_id, tenant=self._tenant, session=self._session, proposal=proposed)
        self.events.append({"proposed": proposed.copy(), "status": result["status"]})
        self._previous = result
        return result

    def run_to_approval(self, max_steps: int = 8) -> dict[str, Any]:
        # Restarting a coordinator must not create a new cart or replan an
        # already prepared/approved/terminal checkout.
        if self._previous["status"] == "awaiting_approval":
            return self._previous.copy()
        if self._previous["status"] in ("approved", "dispatching", "unknown", "confirmed", "human_only",
                                         "handoff_pending_close",
                                         "completed_by_human_simulated", "stopped"):
            raise Denied("cannot replan a non-writable resumed job")
        for _ in range(max_steps):
            out = self.step()
            if out["status"] == "awaiting_approval":
                return out
            if out["status"] == "stopped":
                raise Denied("planner stopped without preparing a checkout")
        raise Denied("planner did not prepare checkout within bounded steps")


class FictionalPlanner:
    """Deterministic stand-in. No real Hermes model is invoked in E2E tests."""

    def __init__(self):
        self._next = iter((
            {"action": "search", "query": "keyboard"},
            {"action": "read_product", "sku": "FAKE-ALICE-1"},
            {"action": "select_product", "sku": "FAKE-ALICE-1"},
            {"action": "add_to_cart", "quantity": 2},
            {"action": "prepare_checkout"},
        ))

    def next_action(self, observation: dict[str, Any]) -> dict[str, Any]:
        return {**next(self._next), "epoch": observation["epoch"]}


class PairedRemoteCoordinator:
    """Trusted Alice boundary for an externally supplied, proposal-only tool.

    The coordinator NEVER sends the runner, device signer or payment authority
    to Hermes. An Alice process explicitly stages each sanitized observation;
    a Hermes plugin independently proposes to a one-shot HTTPS mailbox. A
    claimed step is consumed only once, including after an uncertain crash.
    """

    def __init__(self, runner: AliceRunner, mailbox: Any, *, tenant: str,
                 session: str, pair_id: str, goal: str, recipient: str,
                 existing_job_id: str | None = None):
        self._runner = runner
        self._mailbox = mailbox
        self._tenant = tenant
        self._session = session
        self._pair_id = pair_id
        self._goal = goal
        self._job = (runner.resume_job(existing_job_id, tenant=tenant, session=session)
                     if existing_job_id is not None else runner.new_job(tenant, session, recipient))

    @property
    def job_id(self) -> str:
        return self._job["job_id"]

    def stage(self) -> str:
        state = self._runner.resume_job(
            self.job_id, tenant=self._tenant, session=self._session)
        if state["status"] not in ("researching", "selecting", "cart_ready"):
            raise Denied("remote planner writes revoked after checkout or handoff")
        # The mailbox applies an allowlist independently, avoiding accidental
        # exposure of recipient/checkout/payment values to the model.
        return self._mailbox.publish(
            self._pair_id, tenant=self._tenant, session=self._session,
            job_id=self.job_id, epoch=state["epoch"],
            goal=self._goal, observation=state)

    def consume(self, step_id: str) -> dict[str, Any]:
        # Claim is durably single-use BEFORE any external browser/cart action.
        # If this process crashes after claim, do NOT automatically reapply.
        claimed = self._mailbox.claim(
            self._pair_id, tenant=self._tenant, session=self._session,
            step_id=step_id)
        if claimed["job_id"] != self.job_id:
            raise Denied("planner step belongs to a different Alice job")
        result = self._runner.propose(
            self.job_id, tenant=self._tenant, session=self._session,
            proposal=claimed["proposal"])
        self._mailbox.acknowledge(
            self._pair_id, step_id=step_id, result_status=result["status"])
        return result

    def cancel(self) -> dict[str, Any]:
        """Trusted Alice cancellation. Never infer an in-flight step stopped."""
        outcome = self._mailbox.cancel(
            self._pair_id, tenant=self._tenant, session=self._session,
            job_id=self.job_id)
        if outcome["effect_may_be_in_flight"]:
            return outcome
        state = self._runner.resume_job(
            self.job_id, tenant=self._tenant, session=self._session)
        if state["status"] == "stopped":
            return {"status": "stopped", "effect_may_be_in_flight": False}
        if state["status"] not in ("researching", "selecting", "cart_ready"):
            return {"status": "inspection_required", "effect_may_be_in_flight": True}
        stopped = self._runner.propose(
            self.job_id, tenant=self._tenant, session=self._session,
            proposal={"action": "stop", "epoch": state["epoch"]})
        return {"status": stopped["status"], "effect_may_be_in_flight": False}
