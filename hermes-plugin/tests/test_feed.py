"""The editorial feed: provenance closed in code, one run at a time, events idempotent.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "feed.py"
spec = importlib.util.spec_from_file_location("alice_feed_test", PATH)
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)

NOW = 1_800_000_000.0
SEARCH = json.dumps({"data": {"web": [
    {"title": "Apple unveils new Siri model", "url": "https://www.apple.com/newsroom/siri/?utm_source=x"},
    {"title": "Reuters on Siri", "url": "https://www.reuters.com/tech/siri"},
]}})


def post(sources, body=None, **extra):
    marks = "".join(f" Claim {i + 1}.[{i + 1}]" for i in range(len(sources)))
    return {"kicker": "IA", "category": "tecnología", "headline": "Siri cambia de modelo",
            "body": body if body is not None else "Apple ha anunciado un nuevo modelo." + marks,
            "sources": sources, "language": "es", **extra}


class FakeGateway:
    def __init__(self, statuses=None, on_start=None):
        self.statuses = list(statuses or ["completed"])
        self.started = []
        self.stopped = []
        self.on_start = on_start

    def start(self, session_id, text):
        self.started.append((session_id, text))
        if self.on_start:
            self.on_start(session_id)
        return f"run-{len(self.started)}"

    def status(self, run_id):
        return {"status": self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]}

    def stop(self, run_id):
        self.stopped.append(run_id)


class Base(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.clock = [NOW]

    def worker(self, gateway):
        return feed.Worker(self.home, gateway=gateway, sleep=lambda s: self.clock.__setitem__(0, self.clock[0] + s),
                           clock=lambda: self.clock[0])

    def running(self, session="feed-1-abc"):
        feed.request(self.home, "refresh", NOW)
        feed._mutate(self.home, lambda d: d["generation"].update(state="running", sessionID=session, startedAt=NOW))
        return session


class URLs(Base):
    def test_normalized_variants_are_one_source(self):
        a = feed.normalize_url("http://WWW.Example.com/path/?utm_source=x&b=2&a=1#frag")
        b = feed.normalize_url("https://example.com/path?a=1&b=2")
        self.assertEqual(a, b)

    def test_registry_keeps_the_url_as_research_surfaced_it(self):
        registry = feed.Registry()
        first = registry.add("https://www.apple.com/newsroom/siri/?utm_source=x", "Apple")
        again = registry.add("https://apple.com/newsroom/siri", "")
        self.assertEqual(first, again)
        self.assertEqual(registry.sources[first]["url"], "https://www.apple.com/newsroom/siri/?utm_source=x")

    def test_annotate_names_each_source_in_feed_runs_only(self):
        out = feed.annotate("feed-1-abc", "web_search", SEARCH)
        self.assertIn("[alice_source: src_01] Apple unveils new Siri model", out)
        self.assertIn("[alice_source: src_02]", out)
        self.assertIsNone(feed.annotate("chat-session", "web_search", SEARCH))
        self.assertIsNone(feed.annotate("feed-1-abc", "terminal", SEARCH))
        self.assertIsNotNone(feed.annotate("feed-1-abc", "browser_navigate", "Opened https://example.org/a"))

    def test_registry_is_dropped_when_another_run_starts(self):
        feed.annotate("feed-1-abc", "web_search", SEARCH)
        feed.registry_for("feed-2-def")
        self.assertNotIn("feed-1-abc", feed._registries)


class Publishing(Base):
    def setUp(self):
        super().setUp()
        self.session = self.running()
        feed.annotate(self.session, "web_search", SEARCH)

    def test_publishes_verified_posts(self):
        result = feed.publish(self.home, self.session, [post(["src_01", "src_02"])], now=NOW)
        self.assertEqual(result["published"], 1)
        stored = feed.listing(self.home)["posts"][0]
        self.assertEqual(stored["sources"][0]["url"], "https://www.apple.com/newsroom/siri/?utm_source=x")
        self.assertEqual(stored["viewerState"], {"loved": False, "lovedAt": None, "discussCount": 0})

    def test_invented_and_raw_sources_are_rejected(self):
        with self.assertRaisesRegex(feed.FeedError, "not a source your research surfaced"):
            feed.publish(self.home, self.session, [post(["src_09"])])
        with self.assertRaisesRegex(feed.FeedError, "never a raw URL"):
            feed.publish(self.home, self.session, [post(["https://made.up/story"])])

    def test_citation_markers_must_match_sources(self):
        with self.assertRaisesRegex(feed.FeedError, "do not match"):
            feed.publish(self.home, self.session, [post(["src_01"], body="A claim.[2]")])
        with self.assertRaisesRegex(feed.FeedError, "never cited"):
            feed.publish(self.home, self.session, [post(["src_01", "src_02"], body="Only one.[1]")])
        with self.assertRaisesRegex(feed.FeedError, "inline"):
            feed.publish(self.home, self.session, [post(["src_01"], body="No markers.")])

    def test_empty_publication_is_valid_and_only_once(self):
        self.assertEqual(feed.publish(self.home, self.session, [])["published"], 0)
        with self.assertRaisesRegex(feed.FeedError, "already published"):
            feed.publish(self.home, self.session, [])

    def test_only_the_active_run_can_publish(self):
        other = "feed-9-zzz"
        feed.annotate(other, "web_search", SEARCH)
        with self.assertRaisesRegex(feed.FeedError, "inside the feed run under way"):
            feed.publish(self.home, other, [post(["src_01"])])
        refused = feed.run_publish(self.home, "a-chat", {"posts": []})
        self.assertFalse(refused["ok"])

    def test_at_most_six(self):
        with self.assertRaisesRegex(feed.FeedError, "At most 6"):
            feed.publish(self.home, self.session, [post(["src_01"])] * 7)


class Requests(Base):
    def test_one_in_flight_and_one_pending_after_a_run(self):
        feed.request(self.home, "refresh", NOW)
        feed.request(self.home, "schedule", NOW)
        gen = feed.load(self.home)["generation"]
        self.assertEqual((gen["state"], gen["reasons"]), ("queued", ["refresh", "schedule"]))
        feed._mutate(self.home, lambda d: d["generation"].update(state="running"))
        feed.set_brief(self.home, "Más F1", NOW)
        out = feed.set_brief(self.home, "Más F1, menos cripto", NOW)
        self.assertTrue(out["pending"])
        self.assertIn("next run", out["note"])
        gen = feed.load(self.home)["generation"]
        self.assertTrue(gen["pendingAfterRun"])
        self.assertEqual(gen["pendingReasons"], ["brief"])

    def test_unchanged_brief_queues_nothing(self):
        feed.set_brief(self.home, "F1", NOW)
        feed._mutate(self.home, lambda d: d.update(generation=feed._idle_generation()))
        self.assertEqual(feed.set_brief(self.home, "F1", NOW), {"changed": False, "queued": False})
        self.assertEqual(feed.load(self.home)["generation"]["state"], "idle")

    def test_steering_is_bounded(self):
        for i in range(25):
            feed.add_steering(self.home, f"nota {i}", NOW + i)
        steering = feed.load(self.home)["steering"]
        self.assertEqual(len(steering), 20)
        self.assertEqual(steering[-1]["note"], "nota 24")

    def test_revision_bumps_on_every_change(self):
        before = feed.status(self.home)["revision"]
        feed.request(self.home, "refresh", NOW)
        self.assertGreater(feed.status(self.home)["revision"], before)


class Events(Base):
    def setUp(self):
        super().setUp()
        session = self.running()
        feed.annotate(session, "web_search", SEARCH)
        feed.publish(self.home, session, [post(["src_01"])], now=NOW)
        self.post_id = feed.listing(self.home)["posts"][0]["id"]

    def event(self, kind, on=None, at=NOW):
        body = {"id": str(uuid.uuid4()), "kind": kind, "createdAt": at}
        if on is not None:
            body["on"] = on
        return body

    def test_same_uuid_applies_once(self):
        love = self.event("love", True)
        self.assertTrue(feed.add_event(self.home, self.post_id, love)["applied"])
        self.assertTrue(feed.add_event(self.home, self.post_id, love)["duplicate"])
        self.assertEqual(len(feed.load(self.home)["events"]), 1)

    def test_love_and_delete_follow_their_last_event(self):
        feed.add_event(self.home, self.post_id, self.event("love", True, NOW))
        feed.add_event(self.home, self.post_id, self.event("love", False, NOW + 1))
        feed.add_event(self.home, self.post_id, self.event("discuss", at=NOW + 2))
        feed.add_event(self.home, self.post_id, self.event("discuss", at=NOW + 3))
        state = feed.listing(self.home)["posts"][0]["viewerState"]
        self.assertEqual((state["loved"], state["discussCount"]), (False, 2))
        feed.add_event(self.home, self.post_id, self.event("delete", True, NOW + 4))
        self.assertEqual(feed.listing(self.home)["posts"], [])
        feed.add_event(self.home, self.post_id, self.event("delete", False, NOW + 5))
        self.assertEqual(len(feed.listing(self.home)["posts"]), 1)

    def test_schema_per_kind(self):
        with self.assertRaises(feed.FeedError):
            feed.add_event(self.home, self.post_id, self.event("love"))
        with self.assertRaises(feed.FeedError):
            feed.add_event(self.home, self.post_id, self.event("discuss", True))
        with self.assertRaises(feed.FeedError):
            feed.add_event(self.home, self.post_id, {"id": "not-a-uuid", "kind": "love", "on": True})

    def test_expired_post(self):
        with self.assertRaises(LookupError):
            feed.add_event(self.home, "gone", self.event("love", True))

    def test_signals_reach_the_prompt(self):
        feed.add_event(self.home, self.post_id, self.event("love", True))
        feed.add_steering(self.home, "menos cripto", NOW)
        text = feed.prompt(self.home, NOW + 60)
        self.assertIn("Loved: Siri cambia de modelo", text)
        self.assertIn("menos cripto", text)
        self.assertIn("Siri cambia de modelo", text.split("Recent posts")[1])
        self.assertIn("never infer a permanent dislike", text)


class Worker(Base):
    def test_published_run_is_a_success(self):
        feed.request(self.home, "refresh", NOW)

        def publish(session):
            feed.annotate(session, "web_search", SEARCH)
            feed.publish(self.home, session, [post(["src_01"])])

        gateway = FakeGateway(["running", "completed"], on_start=publish)
        self.worker(gateway).run()
        gen = feed.load(self.home)["generation"]
        self.assertEqual((gen["state"], gen["publishedCount"]), ("idle", 1))
        self.assertIn("feed_publish", gateway.started[0][1])

    def test_run_that_never_publishes_fails(self):
        feed.request(self.home, "refresh", NOW)
        self.worker(FakeGateway(["completed"])).run()
        gen = feed.load(self.home)["generation"]
        self.assertEqual((gen["state"], gen["error"]), ("failed", "generation completed without publication"))

    def test_pending_request_becomes_exactly_one_next_run(self):
        feed.request(self.home, "refresh", NOW)

        def during(session):
            feed.set_brief(self.home, f"brief {session}")
            feed.set_brief(self.home, f"brief {session} again")
            feed.publish(self.home, session, [])

        gateway = FakeGateway(["completed"], on_start=during)
        worker = self.worker(gateway)
        self.assertTrue(worker.run_once())
        self.assertEqual(feed.load(self.home)["generation"]["state"], "queued")
        gateway.on_start = lambda s: feed.publish(self.home, s, [])
        worker.run()
        self.assertEqual(len(gateway.started), 2)

    def test_timeout_stops_the_run(self):
        feed.request(self.home, "refresh", NOW)
        gateway = FakeGateway(["running"])
        self.worker(gateway).run()
        gen = feed.load(self.home)["generation"]
        self.assertEqual(gen["state"], "failed")
        self.assertIn("timed out", gen["error"])
        self.assertEqual(gateway.stopped, ["run-1"])

    def test_orphaned_run_is_settled_and_pending_promoted(self):
        feed.request(self.home, "refresh", NOW)
        feed._mutate(self.home, lambda d: d["generation"].update(
            state="running", sessionID="feed-x", startedAt=NOW, runId="", pendingAfterRun=True,
            pendingReasons=["brief"]))
        worker = self.worker(FakeGateway(["completed"], on_start=lambda s: feed.publish(self.home, s, [])))
        worker.run_once()
        gen = feed.load(self.home)["generation"]
        self.assertEqual((gen["state"], gen["reasons"]), ("queued", ["brief"]))

    def test_live_run_is_followed_after_a_restart(self):
        feed.request(self.home, "refresh", NOW)
        feed._mutate(self.home, lambda d: d["generation"].update(
            state="running", sessionID="feed-x", startedAt=NOW, runId="run-7", published=True))
        gateway = FakeGateway(["running", "running", "completed"])
        self.worker(gateway).run_once()
        self.assertEqual(feed.load(self.home)["generation"]["state"], "idle")
        self.assertEqual(gateway.started, [])


class Schedule(unittest.TestCase):
    def test_cron_expression(self):
        self.assertEqual(feed.cron_expression(["08:00", "19:00"]), "0 8,19 * * *")
        self.assertEqual(feed.cron_expression(["nonsense"]), "0 8,19 * * *")


if __name__ == "__main__":
    unittest.main()
