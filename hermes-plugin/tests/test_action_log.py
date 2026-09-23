"""What agents did with consequences, and the receipts Alice opens from past chats.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "action_log.py"
spec = importlib.util.spec_from_file_location("alice_action_log_test", PATH)
log = importlib.util.module_from_spec(spec)
spec.loader.exec_module(log)

HOME = str(Path.home())


class ClassifyTests(unittest.TestCase):
    root = Path("/Users/someone/.hermes")

    def kind(self, tool, args=None, result=None):
        found = log.classify(tool, args or {}, result, self.root)
        return (found or {}).get("kind"), (found or {}).get("target")

    def test_reading_is_never_an_action(self):
        for tool in ("web_search", "web_extract", "read_file", "search_files", "session_search",
                     "skill_view", "browser_snapshot", "calendar_events"):
            self.assertIsNone(log.classify(tool, {"query": "x"}, None, self.root), tool)
        self.assertIsNone(log.classify("terminal", {"command": "ls -la ~/Documents && cat notes.md"}))
        self.assertIsNone(log.classify("cronjob", {"action": "list"}))
        self.assertIsNone(log.classify("send_message", {"action": "list"}))

    def test_messages_and_email(self):
        self.assertEqual(self.kind("send_message", {"target": "telegram:Ana", "message": "hola"}),
                         ("message.sent", "telegram:Ana"))
        self.assertEqual(self.kind("message_agent", {"target": "@inbox"}), ("agent.messaged", "@inbox"))
        command = 'python google_api.py gmail send --to ana@example.com --subject "Cena" --body "Nos vemos"'
        self.assertEqual(self.kind("terminal", {"command": command}), ("email.sent", "ana@example.com"))
        self.assertEqual(self.kind("mcp__gmail__send_email", {"to": "b@example.com"}), ("email.sent", "b@example.com"))

    def test_routines_memory_and_skills(self):
        self.assertEqual(self.kind("cronjob", {"action": "create", "name": "Chollos"}), ("routine.created", "Chollos"))
        self.assertEqual(self.kind("cronjob_manage", {"action": "pause", "job_id": "abc"}), ("routine.paused", "abc"))
        self.assertEqual(self.kind("memory", {"action": "add", "target": "user", "content": "secreto"}),
                         ("memory.saved", "user"))
        self.assertEqual(self.kind("skill_manage", {"action": "create", "name": "viajes"}), ("skill.created", "viajes"))

    def test_his_files_count_the_agent_desk_does_not(self):
        self.assertIsNone(log.classify("write_file", {"path": "/Users/someone/.hermes/profiles/x/workspace/a.md"},
                                       None, self.root))
        self.assertIsNone(log.classify("write_file", {"path": "report.md"}, None, self.root))
        self.assertIsNone(log.classify("patch", {"path": "/tmp/scratch.py"}, None, self.root))
        self.assertEqual(self.kind("write_file", {"path": HOME + "/Documents/plan.md"}),
                         ("file.written", "~/Documents/plan.md"))
        self.assertIsNone(log.classify("terminal", {"command": "rm -rf /tmp/build"}, None, self.root))
        self.assertEqual(self.kind("terminal", {"command": "rm ~/Desktop/viejo.pdf"}),
                         ("file.deleted", "~/Desktop/viejo.pdf"))

    def test_shell_actions(self):
        self.assertEqual(self.kind("terminal", {"command": "cd repo && git push origin main"}),
                         ("code.pushed", "origin main"))
        self.assertEqual(self.kind("terminal", {"command": "pip install requests"}),
                         ("package.installed", "requests"))
        self.assertEqual(self.kind("terminal", {"command": "curl -X POST https://api.example.com/v1 -d x=1"}),
                         ("web.sent", "api.example.com"))
        self.assertIsNone(log.classify("terminal", {"command": "curl -s https://example.com"}))
        self.assertIsNone(log.classify("terminal", {"command": "curl -X POST http://127.0.0.1:8644/x"}))

    def test_signing_in_names_the_site_never_the_secret(self):
        result = json.dumps({"success": True, "origin": "https://www.renfe.com", "filled_fields": 2})
        self.assertEqual(self.kind("browser_vault_fill", {"handle": "vault_1"}, result),
                         ("login.used", "www.renfe.com"))


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_keeps_the_kind_never_the_words(self):
        command = 'python google_api.py gmail send --to ana@example.com --body "texto privado"'
        log.observe(self.root, "default", tool_name="terminal", args={"command": command}, result="{}",
                    session_id="s1", status="ok")
        log.observe(self.root, "default", tool_name="memory",
                    args={"action": "add", "target": "user", "content": "le gusta el sushi"},
                    result="{}", session_id="s1", status="ok")
        stored = (self.root / ".alice" / "actions.jsonl").read_text()
        self.assertNotIn("texto privado", stored)
        self.assertNotIn("sushi", stored)
        self.assertNotIn("--body", stored)
        self.assertEqual([e["kind"] for e in log.recent(self.root)], ["memory.saved", "email.sent"])

    def test_reads_are_not_kept(self):
        self.assertIsNone(log.observe(self.root, "default", tool_name="web_search", args={"query": "x"},
                                      result="{}"))
        self.assertFalse((self.root / ".alice" / "actions.jsonl").exists())

    def test_a_failed_call_says_so(self):
        log.observe(self.root, "inbox", tool_name="send_message", args={"target": "x"}, result="{}",
                    status="error")
        self.assertFalse(log.recent(self.root)[0]["ok"])

    def test_a_refused_curator_patch_is_not_an_action(self):
        result = '{"success": false, "error": "Refusing background curator patch for bundled skill \'x\'."}'
        self.assertIsNone(log.observe(self.root, "default", tool_name="skill_manage",
                                      args={"action": "patch", "name": "x"}, result=result, status="error"))

    def test_since_and_profile_filter(self):
        log.record(self.root, profile="a", session="", tool="t", kind="note.saved", target="", ok=True, now=100)
        log.record(self.root, profile="b", session="", tool="t", kind="note.saved", target="", ok=True, now=200)
        log.record(self.root, profile="a", session="", tool="t", kind="note.saved", target="", ok=True, now=300)
        self.assertEqual([e["at"] for e in log.recent(self.root, since=150)], [300, 200])
        self.assertEqual([e["at"] for e in log.recent(self.root, profile="a")], [300, 100])

    def test_trimmed_when_it_grows(self):
        path = self.root / ".alice" / "actions.jsonl"
        path.parent.mkdir(parents=True)
        path.write_text("x\n" * (log.MAX_BYTES // 2 + 10))
        log.record(self.root, profile="a", session="", tool="t", kind="note.saved", target="", ok=True)
        self.assertLessEqual(len(path.read_text().splitlines()), log.KEEP_LINES)
        self.assertEqual(log.recent(self.root)[0]["kind"], "note.saved")


def make_db(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT, started_at REAL)")
    db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, "
               "content TEXT, timestamp REAL)")
    return db


class OriginAndReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        db = make_db(self.root / "state.db")
        db.execute("INSERT INTO sessions VALUES ('chat1', 'cli', 'Plan de viaje', 1)")
        db.execute("INSERT INTO sessions VALUES ('cron_cffca6f34c20_20260922_215139', 'cron', "
                   "'Cierre del día · Sep 22 21:52', 2)")
        db.execute("INSERT INTO sessions VALUES ('other', 'cli', 'Otro', 3)")
        turns = [("user", "¿Qué día volamos?"), ("assistant", "El viernes 3 a las 9:40."),
                 ("tool", '{"x":1}'), ("user", "Prefiero el sábado"),
                 ("assistant", "Hecho, lo miro.\n```alice-ui\n{\"type\":\"events\"}\n```"),
                 ("user", "Gracias"), ("assistant", "")]
        for role, text in turns:
            db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('chat1', ?, ?, 1)",
                       (role, text))
        db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('other', 'user', 'x', 1)")
        db.commit()
        db.close()

    def tearDown(self):
        self.temp.cleanup()

    def test_actions_say_where_they_happened(self):
        log.record(self.root, profile="default", session="chat1", tool="t", kind="note.saved", target="", ok=True)
        log.record(self.root, profile="default", session="cron_cffca6f34c20_20260922_215139", tool="t",
                   kind="email.sent", target="a", ok=True)
        routine, chat = log.recent(self.root)
        self.assertEqual(routine["origin"], {"place": "routine", "title": "Cierre del día",
                                             "routine": "default/cffca6f34c20"})
        self.assertEqual(chat["origin"], {"place": "chat", "title": "Plan de viaje"})

    def test_receipt_around_the_cited_message(self):
        found = log.receipt(self.root, "default", "chat1", around=4, window=1)
        self.assertEqual(found["title"], "Plan de viaje")
        texts = [m["text"] for m in found["messages"]]
        self.assertEqual(texts, ["El viernes 3 a las 9:40.", "Prefiero el sábado", "Hecho, lo miro."])
        self.assertEqual([m["anchor"] for m in found["messages"]], [False, True, False])

    def test_an_anchor_from_another_conversation_is_ignored(self):
        found = log.receipt(self.root, "default", "chat1", around=8, window=2)
        self.assertFalse(any(m["anchor"] for m in found["messages"]))
        self.assertEqual(found["messages"][-1]["text"], "Gracias")

    def test_an_action_opens_at_its_moment(self):
        db = sqlite3.connect(self.root / "state.db")
        db.execute("UPDATE messages SET timestamp = id * 10 WHERE session_id = 'chat1'")
        db.commit()
        db.close()
        found = log.receipt(self.root, "default", "chat1", window=1, at=45)
        anchored = [m["text"] for m in found["messages"] if m["anchor"]]
        self.assertEqual(anchored, ["Prefiero el sábado"])

    def test_unknown_session_or_profile(self):
        self.assertIsNone(log.receipt(self.root, "default", "nope"))
        self.assertIsNone(log.receipt(self.root, "../etc", "chat1"))


if __name__ == "__main__":
    unittest.main()
