"""Required Phase 1 scenarios: fake sources/classifier/main, isolated temp journals."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("alice_watchers", ROOT / "watchers.py")
w = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = w
spec.loader.exec_module(w)
c = w.sibling("watcher_classify.py")
service = w.sibling("watcher_service.py")
delivery = w.sibling("watcher_delivery.py")
CODE = w.sibling("watcher_builtins.py").TRIAGE_CODE
ROUTE = {"provider": "user-cheap", "model": "cheap-test", "base_url": "https://cheap.invalid/v1"}


class Script:
    def available(self):
        return True

    def run(self, code, event, config, call):
        state = type("State", (), {"get": lambda _: call("state.get", []), "put": lambda _, v: call("state.put", [v])})()
        env = {"event": event, "config": config, "state": state}
        for cap in ("classify", "ack", "notify", "log"):
            env[cap] = lambda *args, name=cap: call(name, list(args))
        exec(code, env)


class Cheap:
    def __init__(self, error=None):
        self.calls, self.error = 0, error

    def classify(self, state, questions):
        self.calls += 1
        if self.error:
            raise self.error
        key = "notify" if state["input"]["event"]["body"] == "invoice overdue" else "quiet"
        return {"action": {"key": key, "confidence": 1, "probabilities": {"notify": int(key == "notify"), "quiet": int(key == "quiet"), "defer": 0}}}


class Main:
    def __init__(self):
        self.calls, self.messages, self.receipts = 0, [], {}

    def accept(self, ident, items):
        if ident not in self.receipts:
            self.calls += 1
            self.messages.append({"proactive": True, "items": items})
            self.receipts[ident] = {"id": ident, "status": "accepted"}
        return self.receipts[ident]


class Source:
    def __init__(self, items):
        self.rows = items

    def items(self, watcher, now):
        return self.rows


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = 100000.0
        self.store = w.Store(Path(self.temp.name), clock=lambda: self.now)
        self.addCleanup(self.store.close)
        self.store.configure("local", ROUTE)
        self.runner, self.cheap, self.main = Script(), Cheap(), Main()
        self.engine = w.Engine(self.store, self.cheap, self.runner)
        self.ident = self.create()

    def create(self, owner="local", active=True, code=CODE):
        row = self.store.create(owner, "Invoice", "feed", {"url": "https://feed.invalid/items", "every_minutes": 1}, code, "Tell me if the invoice needs attention")
        if active:
            self.store.activate(row["id"], owner, self.runner)
        return row["id"]

    def tick(self, rows, force=True):
        return service.tick(self.store.home, store=self.store, sources=Source(rows), engine=self.engine, delivery=self.main, force=force)

    def event(self, ident="e", body="invoice overdue"):
        return {"id": ident, "subject": "invoice", "body": body}

    def test_important(self):
        self.tick([self.event()])
        self.assertEqual((self.main.calls, len(self.main.messages)), (1, 1))
        self.assertTrue(self.main.messages[0]["proactive"])
        self.assertEqual(self.store.pending(self.ident), [])

    def test_quiet_opposite_body_same_subject(self):
        self.tick([self.event(body="invoice paid")])
        self.assertEqual(self.main.calls, 0)
        self.assertEqual(self.store.pending(self.ident), [])
        self.assertEqual(self.store.db.execute("SELECT status FROM events").fetchone()[0], "acked")

    def test_missing_body(self):
        self.tick([{"id": "e", "subject": "invoice", "source_error": "missing_body"}])
        self.assertEqual((self.cheap.calls, self.main.calls), (0, 0))
        self.assertEqual(len(self.store.pending(self.ident)), 1)

    def test_classifier_error_and_timeout_never_call_main_or_ack(self):
        for error in (RuntimeError("cheap down"), TimeoutError("cheap timeout")):
            with self.subTest(error=error):
                ident = self.create()
                self.store.ingest(ident, self.event())
                cheap = Cheap(error)
                engine = w.Engine(self.store, cheap, self.runner)
                # A fallback import or call would fail loudly, even with explicit routing.
                forbidden = mock.Mock(side_effect=AssertionError("main classifier fallback"))
                with mock.patch.dict(sys.modules, {"agent.auxiliary_client": type("Aux", (), {"call_llm": forbidden})()}):
                    result = engine.run_event(ident, "e")
                self.assertFalse(result["acked"])
                self.assertFalse(result["notified"])
                self.assertEqual(cheap.calls, 2)
                self.assertEqual(self.store.get(ident)["state"]["error"]["kind"], "classifier_error")
                self.assertEqual(len(self.store.pending(ident)), 1)
                self.assertEqual(self.store.db.execute("SELECT count(*) FROM inbox").fetchone()[0], 0)
                forbidden.assert_not_called()
                self.assertEqual(self.main.calls, 0)

    def test_fixed_classify_transport_errors_never_change_model(self):
        seen = []
        def error(route, payload, home):
            seen.append(payload["model"])
            raise TimeoutError()
        self.engine.classifier = c.Classifier(self.store.home, ROUTE, transport=error)
        self.tick([self.event()])
        self.assertEqual(seen, ["cheap-test", "cheap-test"])
        self.assertEqual(self.main.calls, 0)

    def test_duplicate_keeps_original(self):
        self.tick([self.event(), self.event(body="invoice paid")])
        self.assertEqual(self.main.calls, 1)
        self.assertEqual(self.main.messages[0]["items"][0]["event"]["body"], "invoice overdue")
        self.assertEqual(self.cheap.calls, 1)

    def test_flood_50_one_batched_message(self):
        self.tick([self.event(str(i)) for i in range(50)])
        self.assertEqual(self.main.calls, 1)
        self.assertEqual(len(self.main.messages[0]["items"]), 50)
        self.assertEqual(self.store.pending(self.ident), [])

    def test_activation_without_cheap_route_fails_with_setup_message(self):
        ident = self.create(owner="another-user", active=False)
        with self.assertRaisesRegex(c.ClassifierError, "Configure your cheap classifier"):
            self.store.activate(ident, "another-user", self.runner)
        self.assertEqual(self.store.get(ident)["status"], "paused")
        self.assertEqual(self.main.calls, 0)

    def test_32_pending_and_expiry_terminal_once(self):
        for i in range(32):
            self.store.ingest(self.ident, self.event(str(i)))
        with self.assertRaisesRegex(w.WatcherError, "32 events"):
            self.store.ingest(self.ident, self.event("33"))
        self.now += 900
        self.store.maintenance(self.ident)
        self.store.maintenance(self.ident)
        self.assertEqual(self.store.get(self.ident)["status"], "failed")
        self.assertEqual(len(self.store.pending(self.ident)), 32)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM notices").fetchone()[0], 1)

    def test_rate_limit_six_batches(self):
        for i in range(7):
            self.tick([self.event(str(i))])
            self.now += 61
        self.assertEqual(self.main.calls, 6)
        self.assertEqual(len(self.store.pending(self.ident)), 1)

    def test_user_quota_is_scoped(self):
        for _ in range(19):
            self.create()
        last = self.create(active=False)
        self.store.activate(last, runner=self.runner)
        self.assertEqual(self.store.get(last)["reason"], "quota")
        self.store.configure("other", ROUTE)
        self.assertEqual(self.store.get(self.create(owner="other"))["status"], "active")
        with self.assertRaises(w.WatcherError):
            self.store.get(self.ident, "other")

    def test_changed_hash_refused_and_events_retained(self):
        row = self.store.get(self.ident)
        Path(row["code_path"]).chmod(0o600)
        Path(row["code_path"]).write_text("ack(event['id'])")
        self.tick([self.event()])
        self.assertEqual(self.main.calls, 0)
        self.assertEqual(len(self.store.pending(self.ident)), 1)
        self.assertEqual(self.store.get(self.ident)["status"], "failed")

    def test_notify_failure_no_ack(self):
        with mock.patch.object(self.store, "accepted_notify", side_effect=RuntimeError("disk full")):
            self.tick([self.event()])
        self.assertEqual(self.main.calls, 0)
        self.assertEqual(len(self.store.pending(self.ident)), 1)

    def test_dry_run_no_durable_mutation_and_no_main(self):
        before = self.store.db.total_changes
        result = self.engine.dry_run(self.ident, sources=Source([self.event()]))
        self.assertTrue(result[0]["notified"])
        self.assertEqual(self.store.db.total_changes, before)
        self.assertEqual(self.main.calls, 0)

    def test_feedback_filters_before_models(self):
        self.store.feedback("local", "muted_topics", "invoice")
        self.tick([self.event()])
        self.assertEqual((self.cheap.calls, self.main.calls), (0, 0))
        self.assertEqual(self.store.pending(self.ident), [])

    def test_webhook_rotation_and_revocation(self):
        old = self.store.rotate_webhook(self.ident)
        self.assertEqual(self.store.webhook_owner(old), self.ident)
        new = self.store.rotate_webhook(self.ident)
        self.assertIsNone(self.store.webhook_owner(old))
        self.assertEqual(self.store.webhook_owner(new), self.ident)
        self.store.rotate_webhook(self.ident, revoke=True)
        self.assertIsNone(self.store.webhook_owner(new))

    def test_malformed_answer_fails_whole_call(self):
        for answer in ({}, {"action": {"key": "notify", "confidence": 1, "probabilities": {"notify": 1}}}):
            with self.assertRaises(c.ClassifierError):
                c.validate_answers(answer, {"action": {"type": "choice", "options": {"notify": "Notify", "quiet": "Quiet"}}})

    def test_checkpoint_crash_three_reloads_then_failed(self):
        crash = w.sibling("watcher_runner.py").RunnerError("exited")
        self.store.ingest(self.ident, self.event())
        with mock.patch.object(self.runner, "run", side_effect=crash):
            for _ in range(4):
                self.engine.run_event(self.ident, "e")
        self.assertEqual(self.store.get(self.ident)["reason"], "exited")
        self.assertEqual(len(self.store.pending(self.ident)), 1)

    def test_late_classifier_error_discards_staged_notify(self):
        code = CODE + '\nclassify({"event": event}, questions)\n'
        ident = self.create(code=code)
        self.store.ingest(ident, self.event())
        original = self.cheap.classify
        count = [0]
        def classify(state, questions):
            count[0] += 1
            if count[0] > 1:
                raise TimeoutError()
            return original(state, questions)
        with mock.patch.object(self.cheap, "classify", side_effect=classify):
            result = self.engine.run_event(ident, "e")
        delivery.flush(self.store, self.main, force=True)
        self.assertFalse(result["acked"])
        self.assertEqual(self.main.calls, 0)
        self.assertEqual(len(self.store.pending(ident)), 1)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM inbox").fetchone()[0], 0)

    def test_budget_pause_one_terminal_notice(self):
        record = self.store.get(self.ident)
        record["limited_since"] = self.now - 3600
        self.store.save(record)
        for i in range(6):
            self.store.db.execute("INSERT INTO inbox VALUES(?,?,?,?,?,'accepted','[]',NULL)",
                                  (str(i), self.ident, "local", self.now, self.now))
        self.store.maintenance(self.ident)
        self.store.maintenance(self.ident)
        self.assertEqual(self.store.get(self.ident)["reason"], "budget")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM notices").fetchone()[0], 1)

    def test_delivery_error_preserves_batch_and_reports_once(self):
        self.store.ingest(self.ident, self.event())
        self.engine.run_event(self.ident, "e")
        with mock.patch.object(self.main, "accept", side_effect=RuntimeError("unavailable")):
            delivery.flush(self.store, self.main, force=True)
            delivery.flush(self.store, self.main, force=True)
        self.assertEqual(self.store.get(self.ident)["status"], "failed")
        self.assertEqual(self.store.db.execute("SELECT status FROM inbox").fetchone()[0], "ready")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM notices").fetchone()[0], 1)

    def test_source_http_cannot_escape_repository_or_reach_private_address(self):
        sources = w.sibling("watcher_sources.py")
        for target in ("https://api.github.com/repos/a/b/../../user", "https://api.github.com/repos/a/b/%2e%2e/user", "https://evil.invalid/repos/a/b/issues"):
            with self.assertRaises(sources.SourceError):
                sources.allowed_url("github", {"repo": "a/b"}, target)
        with mock.patch.object(sources.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]):
            with self.assertRaises(sources.SourceError):
                sources.PinnedHTTPS("source.invalid").connect()

    def test_birthday_uses_this_year_and_calendar_accepts_iso_snapshot(self):
        builtins = w.sibling("watcher_builtins.py")
        from datetime import datetime, timezone
        now = datetime(2026, 10, 9, 12, tzinfo=timezone.utc).timestamp()
        rows = builtins.items(self.store.home, {"kind": "birthday", "birthdays": [{"name": "A", "date": "1990-10-10"}]}, now)
        self.assertIn("2026-10-10", rows[0]["id"])
        (self.store.home / ".alice/calendar.json").write_text(json.dumps({"connected": True, "updated_at": "2026-10-09T12:00:00Z", "events": [{"title": "Meeting", "start": "2026-10-09T12:20:00Z", "location": "123 Main St"}]}))
        self.assertEqual(len(builtins.items(self.store.home, {"kind": "leave_now", "travel_minutes": 15}, now)), 1)


if __name__ == "__main__":
    unittest.main()
