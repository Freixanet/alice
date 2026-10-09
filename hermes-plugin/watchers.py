"""Per-host watcher journal and reliable event pipeline; SQLite is the authority.

Notification intents enter the main agent's durable inbox before an ack is allowed.
The inbox dispatcher is separate from classify and coalesces a minute of events.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

_spec = importlib.util.spec_from_file_location("alice_watcher_common", Path(__file__).with_name("watcher_common.py"))
_common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_common)
WatcherError, bounded, sibling = _common.WatcherError, _common.bounded, _common.sibling


class RateLimit(WatcherError):
    pass


class Store:
    def __init__(self, home, clock=time.time):
        self.home, self.clock = Path(home), clock
        self.folder = self.home / ".alice/watchers"
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.folder / "journal.sqlite", timeout=15, isolation_level=None)
        os.chmod(self.folder / "journal.sqlite", 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS settings(owner TEXT PRIMARY KEY, route TEXT, feedback TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS watchers(id TEXT PRIMARY KEY, owner TEXT NOT NULL, record TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(watcher TEXT, id TEXT, payload TEXT, created REAL, status TEXT,
          classification TEXT, PRIMARY KEY(watcher,id));
        CREATE TABLE IF NOT EXISTS history(sequence INTEGER PRIMARY KEY, watcher TEXT, payload TEXT);
        CREATE TABLE IF NOT EXISTS inbox(id TEXT PRIMARY KEY, watcher TEXT, owner TEXT, created REAL,
          due REAL, status TEXT, content TEXT, error TEXT);
        CREATE TABLE IF NOT EXISTS dedup(watcher TEXT, key TEXT, inbox TEXT, PRIMARY KEY(watcher,key));
        CREATE TABLE IF NOT EXISTS notices(id TEXT PRIMARY KEY, owner TEXT, watcher TEXT, created REAL, message TEXT);
        ''')

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def settings(self, owner="local"):
        row = self.db.execute("SELECT * FROM settings WHERE owner=?", (owner,)).fetchone()
        return {"route": json.loads(row["route"]) if row and row["route"] else None,
                "feedback": json.loads(row["feedback"]) if row else {"muted_senders": [], "muted_topics": [], "less_categories": []}}

    def configure(self, owner, route):
        route = sibling("watcher_classify.py").validate_route(route)
        feedback = self.settings(owner)["feedback"]
        with self.transaction():
            self.db.execute("INSERT OR REPLACE INTO settings VALUES(?,?,?)", (owner, json.dumps(route), json.dumps(feedback)))
        return route

    def feedback(self, owner, kind, value, remove=False):
        if kind not in ("muted_senders", "muted_topics", "less_categories") or not isinstance(value, str) or not value.strip() or len(value) > 300:
            raise WatcherError("Choose a sender, topic or category to mute/reduce.")
        with self.transaction():
            settings = self.settings(owner)
            values = settings["feedback"][kind]
            value = value.strip().casefold()
            if remove:
                values[:] = [v for v in values if v != value]
            elif value not in values:
                if len(values) >= 100:
                    raise WatcherError("Feedback limit reached; remove a preference first.")
                values.append(value)
            self.db.execute("INSERT OR REPLACE INTO settings VALUES(?,?,?)", (owner, json.dumps(settings["route"]) if settings["route"] else None,
                                                                           json.dumps(settings["feedback"])))
        return settings["feedback"]

    def get(self, ident, owner=None):
        row = self.db.execute("SELECT record FROM watchers WHERE id=?", (ident,)).fetchone()
        if not row:
            raise WatcherError("Watcher not found.")
        record = json.loads(row[0])
        if owner is not None and owner != record["owner"]:
            raise WatcherError("Watcher not found.")
        return record

    def save(self, record):
        self.db.execute("UPDATE watchers SET record=? WHERE id=?", (json.dumps(record, allow_nan=False), record["id"]))

    def listing(self, owner="local"):
        rows = [json.loads(r[0]) for r in self.db.execute("SELECT record FROM watchers WHERE owner=?", (owner,))]
        for row in rows:
            row["pending"] = self.db.execute("SELECT count(*) FROM events WHERE watcher=? AND status='pending'", (row["id"],)).fetchone()[0]
            row.pop("webhook_hash", None)
        return rows

    def create(self, owner, name, source, config, code, created_by_request):
        sibling("watcher_sources.py").validate(source, config)
        if not isinstance(code, str) or not code.strip():
            raise WatcherError("Provide a non-empty watcher script that implements the user's notification rule.")
        sibling("watcher_runner.py").validate_code(code)
        if not isinstance(created_by_request, str) or not created_by_request.strip() or len(created_by_request) > 2000:
            raise WatcherError("Record the user's request that authorized this watcher.")
        if not isinstance(name, str) or not 1 <= len(name) <= 120:
            raise WatcherError("Give the watcher a short name.")
        config = bounded(config)
        ident = uuid.uuid4().hex
        scripts = self.folder / "code"
        scripts.mkdir(mode=0o700, exist_ok=True)
        path = scripts / (ident + ".py")
        with path.open("x") as handle:
            handle.write(code)
            handle.flush()
            os.fsync(handle.fileno())
        path.chmod(0o400)
        record = {"id": ident, "owner": owner, "name": name, "source": source, "config": config,
                  "code_path": str(path), "code_sha256": hashlib.sha256(code.encode()).hexdigest(),
                  "state": {}, "status": "paused", "reason": "user", "created_by_request": created_by_request,
                  "created_at": self.clock(), "status_version": 0, "crashes": [], "next_poll": 0,
                  "limited_since": None, "webhook_hash": None}
        with self.transaction():
            self.db.execute("INSERT INTO watchers VALUES(?,?,?)", (ident, owner, json.dumps(record)))
        return self.get(ident, owner)

    def terminal(self, record, status, reason, detail):
        if (record["status"], record["reason"]) == (status, reason):
            return
        record.update(status=status, reason=reason, status_version=record["status_version"] + 1)
        ident = f"{record['id']}:{record['status_version']}"
        self.db.execute("INSERT OR IGNORE INTO notices VALUES(?,?,?,?,?)", (ident, record["owner"], record["id"], self.clock(),
                        f"{record['name']}: {status} ({reason}). {detail} Retry to retain pending events, or discard them in Watchers."))
        self.save(record)

    def activate(self, ident, owner="local", runner=None):
        runner = runner or sibling("watcher_runner.py").Runner()
        with self.transaction():
            record = self.get(ident, owner)
            sibling("watcher_sources.py").validate(record["source"], record["config"])
            sibling("watcher_classify.py").validate_route(self.settings(owner)["route"])
            if not runner.available():
                raise WatcherError("Set up the macOS watcher sandbox before activating. Unconfined execution is disabled.")
            code = sibling("watcher_runner.py").load_code(record)
            if not code.strip():
                raise WatcherError("Provide a non-empty watcher script before activation.")
            runner.run("pass", {}, {}, lambda *_: None)
            if record["status"] != "active":
                active = sum(row["status"] == "active" for row in self.listing(owner))
                if active >= 20:
                    self.terminal(record, "paused", "quota", "Only 20 active watchers are allowed per user.")
                    return self.get(ident)
            record.update(status="active", reason=None, next_poll=0, limited_since=None)
            self.save(record)
        return record

    def pause(self, ident, owner="local"):
        with self.transaction():
            self.terminal(self.get(ident, owner), "paused", "user", "Paused by you.")

    def retry(self, ident, owner="local", runner=None):
        # User retry resets the deadline, never the crash-rate budget or dedup receipts.
        self.activate(ident, owner, runner)
        with self.transaction():
            record = self.get(ident, owner)
            record["state"].pop("error", None)
            self.save(record)
            self.db.execute("UPDATE events SET created=?,classification=NULL WHERE watcher=? AND status='pending'", (self.clock(), ident))

    def discard(self, ident, owner="local"):
        with self.transaction():
            self.get(ident, owner)
            self.db.execute("UPDATE events SET status='discarded' WHERE watcher=? AND status='pending'", (ident,))

    def rotate_webhook(self, ident, owner="local", revoke=False):
        secret = None if revoke else secrets.token_urlsafe(32)
        with self.transaction():
            record = self.get(ident, owner)
            record["webhook_hash"] = hashlib.sha256(secret.encode()).hexdigest() if secret else None
            self.save(record)
        return secret

    def webhook_owner(self, secret):
        if not isinstance(secret, str) or not 32 <= len(secret) <= 128:
            return None
        digest = hashlib.sha256(secret.encode()).hexdigest()
        for row in self.db.execute("SELECT record FROM watchers"):
            record = json.loads(row[0])
            if record.get("webhook_hash") and secrets.compare_digest(digest, record["webhook_hash"]):
                return record["id"]
        return None

    def ingest(self, ident, payload):
        payload = bounded(payload)
        if not isinstance(payload, dict) or not isinstance(payload.get("id"), str) or not 1 <= len(payload["id"]) <= 512:
            raise WatcherError("Every source event needs a bounded string ID.")
        with self.transaction():
            if self.get(ident)["status"] != "active":
                raise WatcherError("Watcher is not active.")
            if self.db.execute("SELECT 1 FROM events WHERE watcher=? AND id=?", (ident, payload["id"])).fetchone():
                return False
            count = self.db.execute("SELECT count(*) FROM events WHERE watcher=? AND status='pending'", (ident,)).fetchone()[0]
            if count >= 32:
                raise WatcherError("32 events pending; retry or discard before accepting more.")
            self.db.execute("INSERT INTO events VALUES(?,?,?,?,?,NULL)", (ident, payload["id"], json.dumps(payload), self.clock(), "pending"))
            self.db.execute("INSERT INTO history(watcher,payload) VALUES(?,?)", (ident, json.dumps(payload)))
            self.db.execute("DELETE FROM history WHERE watcher=? AND sequence NOT IN (SELECT sequence FROM history WHERE watcher=? ORDER BY sequence DESC LIMIT 20)", (ident, ident))
        return True

    def pending(self, ident):
        return [dict(r) for r in self.db.execute("SELECT * FROM events WHERE watcher=? AND status='pending' ORDER BY created,rowid", (ident,))]

    def maintenance(self, ident):
        with self.transaction():
            record = self.get(ident)
            if record["status"] != "active":
                return
            if any(self.clock() - row["created"] >= 900 for row in self.pending(ident)):
                self.terminal(record, "failed", "error", "An event has waited 15 minutes without acknowledgement.")
            elif record.get("limited_since") is not None and self.clock() - record["limited_since"] >= 3600:
                recent = self.db.execute("SELECT count(*) FROM inbox WHERE watcher=? AND created>?", (ident, self.clock() - 600)).fetchone()[0]
                if recent >= 6:
                    self.terminal(record, "paused", "budget", "Notification limit sustained for an hour.")
                else:
                    record["limited_since"] = None
                    self.save(record)

    def accepted_notify(self, record, event, message, key, classification):
        """Durably accept into the main inbox; requests in one minute share one slot.

        This journal is the main delivery adapter's inbox, not a transient buffer.
        The dispatcher never retries an ambiguous external acceptance as a new turn.
        """
        if not isinstance(message, str) or not 1 <= len(message) <= 2000 or not isinstance(key, str) or not 1 <= len(key) <= 300:
            raise WatcherError("Notify needs a bounded message and dedup key.")
        with self.transaction():
            fresh = self.get(record["id"])
            if fresh["status"] != "active":
                raise WatcherError("Watcher is no longer active.")
            duplicate = self.db.execute("SELECT inbox FROM dedup WHERE watcher=? AND key=?", (record["id"], key)).fetchone()
            if duplicate:
                return duplicate[0]
            row = self.db.execute("SELECT * FROM inbox WHERE watcher=? AND status='open' AND due>? ORDER BY created DESC LIMIT 1", (record["id"], self.clock())).fetchone()
            if row:
                content = json.loads(row["content"])
                ident = row["id"]
                if len(content) >= 200 or len(json.dumps(content).encode()) > 524288:
                    raise RateLimit("Batch capacity reached; event retained.")
            else:
                recent = self.db.execute("SELECT count(*) FROM inbox WHERE watcher=? AND created>?", (record["id"], self.clock() - 600)).fetchone()[0]
                if recent >= 6:
                    if fresh.get("limited_since") is None:
                        fresh["limited_since"] = self.clock()
                    self.save(fresh)
                    # Commit checkpoint before raising outside the transaction.
                    ident = None
                    content = None
                else:
                    ident, content = uuid.uuid4().hex, []
                    if recent + 1 < 6:
                        fresh["limited_since"] = None
                    elif fresh.get("limited_since") is None:
                        fresh["limited_since"] = self.clock()
                    self.save(fresh)
                    self.db.execute("INSERT INTO inbox VALUES(?,?,?,?,?,'open','[]',NULL)", (ident, record["id"], record["owner"], self.clock(), self.clock() + 60))
            if ident is not None:
                content.append({"message": message, "event": event, "classification": classification})
                self.db.execute("UPDATE inbox SET content=? WHERE id=?", (json.dumps(content), ident))
                self.db.execute("INSERT INTO dedup VALUES(?,?,?)", (record["id"], key, ident))
        if ident is None:
            raise RateLimit("Six notifications per 10 minutes; event retained.")
        return ident


def muted(event, feedback):
    from email.utils import parseaddr
    sender = parseaddr(str(event.get("sender", event.get("from", ""))))[1].casefold()
    topic = str(event.get("topic", event.get("subject", ""))).strip().casefold()
    reduced = str(event.get("category", "")).casefold() in feedback["less_categories"]
    sample = int(hashlib.sha256(str(event.get("id", "")).encode()).hexdigest()[:8], 16) % 4
    return sender in feedback["muted_senders"] or topic in feedback["muted_topics"] or (reduced and sample != 0)


class Engine:
    def __init__(self, store, classifier=None, runner=None):
        self.store = store
        self.classifier = classifier
        self.runner = runner or sibling("watcher_runner.py").Runner()

    def run_event(self, ident, event_id, *, dry=False, payload=None, checkpoint=None):
        store = self.store
        record = store.get(ident)
        rows = [row for row in store.pending(ident) if row["id"] == event_id]
        if not dry and (record["status"] != "active" or not rows):
            return {"notified": False}
        if not dry and record["state"].get("error", {}).get("kind") == "classifier_error" and record["state"]["error"].get("event_id") == event_id:
            return {"notified": False, "acked": False, "error": "classifier_error; retry explicitly"}
        event = payload if dry else json.loads(rows[0]["payload"])
        state = bounded(checkpoint if checkpoint is not None else record["state"])
        decision = None
        quiet = False
        notified, acked = False, False
        intents = []
        simulated = []
        settings = store.settings(record["owner"])
        feedback = settings["feedback"]
        route = sibling("watcher_classify.py").validate_route(settings["route"])
        classifier = self.classifier or sibling("watcher_classify.py").Classifier(store.home, route)
        try:
            if event.get("source_error") or not isinstance(event.get("body"), str):
                raise WatcherError("missing_body: source error; no model call.")
            code = sibling("watcher_runner.py").load_code(record)
            if muted(event, feedback):
                acked = True  # Deterministic quiet filter, before either model.
            else:
                def call(name, args):
                    nonlocal state, decision, quiet, notified, acked
                    arity = {"classify": 2, "notify": 2, "ack": 1, "state.get": 0, "state.put": 1, "source.read": 0, "http_get": 1, "log": 1}
                    if name not in arity or len(args) != arity[name]:
                        raise WatcherError("Invalid watcher capability arguments.")
                    if name == "state.get":
                        return bounded(state)
                    if name == "state.put":
                        state = bounded(args[0], 4096)
                        if not isinstance(state, dict):
                            raise WatcherError("Checkpoint must be a small JSON object.")
                        return True
                    if name == "source.read":
                        return bounded(event)
                    if name == "http_get":
                        return sibling("watcher_sources.py").http_get(record["source"], record["config"], args[0])
                    if name == "log":
                        if not isinstance(args[0], str) or len(args[0]) > 500:
                            raise WatcherError("Log limit exceeded.")
                        state["last_log"] = args[0]
                        return True
                    if name == "classify":
                        errors = 0
                        for attempt in range(2):
                            try:
                                decision = classifier.classify({"input": bounded(args[0]), "feedback": feedback}, args[1])
                                decision = sibling("watcher_classify.py").validate_answers(decision, args[1])
                                quiet = all(answer.get("quiet") is True or answer.get("key", answer.get("value")) in ("quiet", "none")
                                            for answer in decision.values())
                                return decision
                            except Exception:
                                errors += 1
                        state["error"] = {"kind": "classifier_error", "attempts": errors, "event_id": event_id}
                        raise sibling("watcher_classify.py").ClassifierError("classifier_error")
                    if name == "notify":
                        if decision is None or quiet or ("action" in decision and decision["action"].get("key") != "notify"):
                            raise WatcherError("Notify requires a successful non-quiet classification.")
                        if muted(event, store.settings(record["owner"])["feedback"]):
                            raise WatcherError("Candidate was muted before delivery.")
                        if dry:
                            bounded(args)
                            simulated.append({"message": args[0], "event": event, "classification": decision})
                            receipt = "dry-run"
                        else:
                            intents.append((args[0], args[1], bounded(decision)))
                            receipt = "staged-until-script-succeeds"
                        notified = True
                        return receipt
                    if name == "ack":
                        if args[0] != event_id or (decision is not None and not notified and
                                                  not quiet):
                            raise WatcherError("Ack only the current quiet event or a durably accepted notify.")
                        acked = True
                        return True
                self.runner.run(code, event, record["config"], call)
            if not dry:
                for message, key, result in intents:
                    store.accepted_notify(record, event, message, key, result)
                with store.transaction():
                    fresh = store.get(ident)
                    fresh["state"] = bounded(state, 4096)
                    store.save(fresh)
                    if acked:
                        store.db.execute("UPDATE events SET status='acked',classification=? WHERE watcher=? AND id=? AND status='pending'", (json.dumps(decision), ident, event_id))
            return {"notified": notified, "acked": acked, "would_notify": simulated, "checkpoint": state}
        except Exception as exc:
            if not dry:
                # Staged intents have no effect if any later capability fails.
                with store.transaction():
                    fresh = store.get(ident)
                    fresh["state"] = bounded(state, 4096)
                    fresh["state"]["error"] = state.get("error", {"kind": "source_error" if "missing_body" in str(exc) else "error", "event_id": event_id})
                    if isinstance(exc, sibling("watcher_runner.py").RunnerError):
                        if "hash" in str(exc) or "symlink" in str(exc):
                            store.terminal(fresh, "failed", "error", str(exc))
                        else:
                            fresh["crashes"] = [t for t in fresh["crashes"] if store.clock() - t < 3600]
                            fresh["crashes"].append(store.clock())
                            if len(fresh["crashes"]) > 3:
                                store.terminal(fresh, "failed", "exited", "Watcher exhausted three checkpoint reloads in one hour.")
                    store.save(fresh)
            return {"notified": False, "acked": False, "error": str(exc), "checkpoint": state}

    def dry_run(self, ident, owner="local", sources=None):
        record = self.store.get(ident, owner)
        checkpoint = record["state"]
        results = []
        rows = self.store.db.execute("SELECT payload FROM history WHERE watcher=? ORDER BY sequence DESC LIMIT 20", (ident,)).fetchall()[::-1]
        events = [json.loads(row[0]) for row in rows]
        if not events:
            sources = sources or sibling("watcher_sources.py").Sources(self.store.home)
            events = sources.items(record, self.store.clock())[:20][::-1]
        for event in events:
            result = self.run_event(ident, event["id"], dry=True, payload=event, checkpoint=checkpoint)
            checkpoint = result["checkpoint"]
            results.append({"event_id": event["id"], **result})
        return results
