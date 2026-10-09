"""No-agent cron entry point; serializes polling, execution and batch dispatch."""
from __future__ import annotations

import fcntl
import importlib.util
import json
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("alice_watcher_common", Path(__file__).with_name("watcher_common.py"))
_common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_common)
sibling = _common.sibling
JOB_NAME, JOB_SCRIPT = "Alice watchers", "alice-watchers.py"


def tick(home, *, store=None, sources=None, engine=None, delivery=None, force=False):
    owned = store is None
    store = store or sibling("watchers.py").Store(home)
    handle = (store.folder / "worker.lock").open("a")
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        sources = sources or sibling("watcher_sources.py").Sources(home)
        engine = engine or sibling("watchers.py").Engine(store)
        for row in store.db.execute("SELECT id FROM watchers").fetchall():
            ident = row[0]
            store.maintenance(ident)
            watcher = store.get(ident)
            if watcher["status"] != "active":
                continue
            for event in store.pending(ident):
                engine.run_event(ident, event["id"])
            if watcher["next_poll"] <= store.clock():
                try:
                    for item in sources.items(watcher, store.clock()):
                        store.ingest(ident, item)
                        engine.run_event(ident, item["id"])
                except Exception as exc:
                    with store.transaction():
                        current = store.get(ident)
                        current["state"]["source_error"] = {"kind": type(exc).__name__, "at": store.clock()}
                        store.save(current)
                with store.transaction():
                    current = store.get(ident)
                    current["next_poll"] = store.clock() + watcher["config"].get("every_minutes", 5) * 60
                    store.save(current)
        sibling("proactive.py").Service(store).morning()
        sibling("watcher_delivery.py").flush(store, delivery, force=force)
        return True
    finally:
        handle.close()
        if owned:
            store.close()


def ensure_schedule(home, jobs=None):
    if jobs is None:
        import cron.jobs as jobs
    module_path = str(Path(__file__).resolve())
    script = ("import importlib.util\nfrom pathlib import Path\n"
              f"spec = importlib.util.spec_from_file_location('alice_watcher_tick', {module_path!r})\n"
              "module = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n"
              f"module.tick(Path({str(Path(home).resolve())!r}))\n")
    scripts = Path(home) / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / JOB_SCRIPT).write_text(script)
    matches = [j for j in jobs.load_jobs() if j.get("name") == JOB_NAME and j.get("script") == JOB_SCRIPT]
    if matches:
        for duplicate in matches[1:]:
            jobs.remove_job(duplicate["id"])
        return matches[0]["id"]
    return jobs.create_job(None, "* * * * *", name=JOB_NAME, deliver="local", script=JOB_SCRIPT, no_agent=True)["id"]


def ensure_morning_schedule(home, jobs=None):
    if jobs is None:
        import cron.jobs as jobs
    ident = ensure_schedule(home, jobs)
    # Replace only Alice's known older template, retaining it for rollback.
    for job in jobs.load_jobs():
        if (job.get('name') == 'Buenos días' and job.get('script') == 'alice_buenos_dias.py'
                and job.get('enabled', True)):
            jobs.pause_job(job['id'], reason='Replaced by Settings → Watches morning briefing')
    return ident


if __name__ == "__main__":
    tick(Path(sys.argv[1]))
