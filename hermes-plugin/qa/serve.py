"""The purchase simulator as a dashboard the iPhone app can talk to (QA journey, level 1 + iOS).

    python hermes-plugin/qa/serve.py --port 8765 --report qa/reports/ios-journey.json

Serves, on 127.0.0.1 only:

* what the app needs of a Hermes dashboard to connect — `POST /auth/password-login` (any password)
  and `GET /api/memory` — and the plugin's real routes under `/api/plugins/alice` (errands, cards,
  checkout approvals, answers, «Seguir», stop), backed by the simulator's plugin;
* `POST /qa/start {"faults": [...]}` — the person asks for a purchase and taps the recommended card
  (done here, as the Linux simulator does); the errand then runs and waits for the app;
* `GET /qa/state` — the errands as the app sees them, and the oracle's findings so far.

The person is the app itself: approvals, answers and «Seguir» come from the iOS UI test through
the real routes. One thread drives the errand engine whenever an answer resumes it. On exit (SIGTERM
or SIGINT) the oracle's findings are written to --report; any finding fails the CI job.
"""
from __future__ import annotations

import argparse
import json
import queue
import signal
import sys
import threading
import time
import traceback
import warnings
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sim  # noqa: E402


class Journey:
    def __init__(self, shop: str):
        self.sim = sim.Sim(shop, ())
        self.jobs: "queue.Queue[tuple]" = queue.Queue()
        self.lock = threading.Lock()
        self.stopping = False

    def __enter__(self):
        self.sim.__enter__()
        s = self.sim
        # Nothing restarts errands behind the driver's back, and the app is the person.
        s.stack.enter_context(sim.mock.patch.object(s.errands, "ensure_running", lambda home: []))
        threading.Thread(target=self.drive, name="qa-driver", daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.stopping = True
        self.sim.__exit__(*exc)

    def start(self, faults, shop: str = "") -> dict:
        done: "queue.Queue[dict]" = queue.Queue()
        self.jobs.put(("start", tuple(faults), done, shop))
        return done.get(timeout=120)

    def drive(self) -> None:
        """The only thread that touches the browser pages: scenario starts and engine runs."""
        s = self.sim
        while not self.stopping:
            try:
                job = self.jobs.get(timeout=0.2)
            except queue.Empty:
                job = None
            try:
                if job and job[0] == "start":
                    _, faults, done, shop = job
                    unknown = [f for f in faults if f not in sim.FAULTS]
                    if unknown or (shop and shop not in sim.CASES):
                        done.put({"ok": False, "error": "faltas o tienda desconocidas: " + ", ".join(unknown or [shop])})
                        continue
                    if shop:
                        s.case = {**sim.CASES[shop], "host": shop}
                        s.cards = sim.Cards("https://" + shop, saved="no_saved_card" not in faults)
                        s.errand_js = None
                    s.faults, s.once = faults, set()
                    s.person.accepted_price = s.person.said_another_order = False
                    s.world = sim.World(s.case)
                    s.robot.shop_for()
                    option = s.person.cards()
                    if option and "price_changed" in faults:
                        s.world.price_delta = 500
                    if option:
                        qty = int(s.case.get("qty") or 1)
                        s.chat(f"[elección:{option['id']}] {option['title']} · {option['price']}" + (f" [cantidad:{qty}]" if qty > 1 else ""))
                    errand = s.errand()
                    done.put({"ok": bool(errand), "errand_id": (errand or {}).get("id"), "title": (errand or {}).get("title")})
                while s.launches:
                    errand_id, message = s.launches.pop(0)
                    pending = (s.errands.get(s.home, errand_id) or {}).get("resume_message")
                    if pending:
                        s.errands.update(s.home, errand_id, resume_message=None)
                    s.errands.Engine(s.home, errand_id, gateway=s.gateway, judge=s.robot.judge,
                                     sleep=lambda x: None).run(pending or message)
                    s.oracle.after("engine")
            except Exception as exc:  # noqa: BLE001 — said in the report, never a silent stall
                s.oracle.fail("SIM", "driver", "".join(traceback.format_exception(exc))[-800:])
                if job and job[0] == "start":
                    job[2].put({"ok": False, "error": type(exc).__name__})

    def state(self) -> dict:
        s = self.sim
        return {"errands": [s.errands.public(e) for e in s.errands.listing(s.home)],
                "findings": s.oracle.findings, "events": s.events[-60:]}


def app(journey: Journey):
    from fastapi import Body, FastAPI
    from fastapi.responses import JSONResponse

    api = FastAPI()
    s = journey.sim
    api.include_router(s.api.router, prefix=s.api.PLUGIN_PREFIX)

    @api.post("/auth/password-login")
    async def login():  # the fixture accepts any account
        return JSONResponse({"ok": True})

    @api.get("/api/memory")
    async def memory():
        return {"active": "builtin", "builtin_files": {"memory": 0, "user": 0},
                "providers": [{"name": "builtin", "status": "ok", "available": True, "configured": True}]}

    @api.post("/qa/start")
    def qa_start(body: dict = Body(default={})):  # sync: FastAPI runs it in a worker thread
        return journey.start((body or {}).get("faults") or [], str((body or {}).get("shop") or ""))

    @api.get("/qa/state")
    async def qa_state():
        return journey.state()

    @api.get("/health")
    async def health():
        return {"ok": True}

    return api


def main() -> int:
    warnings.filterwarnings("ignore")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--shop", default="tienda-tres.example")
    parser.add_argument("--report", default="qa/reports/ios-journey.json")
    args = parser.parse_args()
    import uvicorn

    with Journey(args.shop) as journey:
        server = uvicorn.Server(uvicorn.Config(app(journey), host="127.0.0.1", port=args.port, log_level="warning"))

        def finish(*_):
            server.should_exit = True

        signal.signal(signal.SIGTERM, finish)
        signal.signal(signal.SIGINT, finish)
        try:
            server.run()
        finally:
            state = journey.state()
            path = Path(args.report)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(state, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
            print(f"QA journey: {len(state['findings'])} hallazgo(s); informe en {path}", flush=True)
            return 1 if state["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
