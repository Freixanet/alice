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
                if k in ("epoch", "status", "products", "name", "sku", "description", "currency", "unit_minor", "cart_ready", "quantity")}
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
