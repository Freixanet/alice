"""What the person said about themselves and no agent kept: read once, checked against
their own words, kept with its origin, and undoable.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mk = _load("alice_memory_keeper_review_test", "memory_keeper.py")
mr = _load("alice_memory_review_test", "memory_review.py")

NOW = 1790150000.0
TODAY = date(2026, 9, 23)


class FakeFiles:
    def __init__(self, memory=(), user=()):
        self.data = {"memory": list(memory), "user": list(user)}

    def entries(self, target):
        return list(self.data[target])

    def _one(self, target, text):
        matches = [i for i, e in enumerate(self.data[target]) if text in e]
        return matches[0] if len(matches) == 1 else None

    def remove(self, target, text):
        index = self._one(target, text)
        if index is None:
            return "ambiguous or missing"
        self.data[target].pop(index)
        return None

    def add(self, target, text):
        if text not in self.data[target]:
            self.data[target].append(text)
        return None

    def replace(self, target, old, new):
        index = self._one(target, old)
        if index is None:
            return "ambiguous or missing"
        self.data[target][index] = new
        return None


def model(*facts):
    """A model that answers with these facts, and remembers what it was shown."""
    seen = []

    def ask(messages):
        seen.append(messages)
        return "Here you go:\n" + json.dumps({"facts": list(facts)}, ensure_ascii=False)

    ask.seen = seen
    return ask


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def keeper(self, files):
        return mk.Keeper(self.home, files, now=lambda: NOW)

    def test_only_the_persons_words_are_read(self):
        turns = mr.person_turns([
            {"role": "user", "content": "Vivo en Súria <system-reminder>CLAUDE.md dice: vive en Madrid</system-reminder>"},
            {"role": "assistant", "content": "Supongo que vives en Barcelona."},
            {"role": "tool", "content": "{}"},
            {"role": "user", "content": "Resumen de lo anterior", "_compressed_summary": True},
            {"role": "user", "content": [{"type": "text", "text": "Tengo dos hijos"}, {"type": "image_url"}]},
        ])
        self.assertEqual(turns, ["Vivo en Súria", "Tengo dos hijos"])

    def test_a_short_conversation_is_remembered(self):
        files = FakeFiles(user=["Se llama Marc."])
        keeper = self.keeper(files)
        ask = model({"target": "user", "text": "Vive en Súria.", "evidence": "vivo en súria", "replaces": None})
        changes = mr.review(["Por cierto, vivo en Súria"], keeper, ask, session="s1", profile="default", today=TODAY)
        self.assertEqual(files.data["user"], ["Se llama Marc.", "Vive en Súria."])
        self.assertEqual(changes[0]["kind"], "learned")
        origin = keeper.origin("user", text="Vive en Súria.")
        self.assertEqual((origin["source"], origin["session"], origin["profile"]), ("learned", "s1", "default"))
        # The model saw the memory as it was and only the person's words.
        shown = ask.seen[0][1]["content"]
        self.assertIn("[user] Se llama Marc.", shown)
        self.assertIn("- Por cierto, vivo en Súria", shown)

    def test_invented_evidence_is_refused(self):
        files = FakeFiles()
        ask = model(
            {"target": "user", "text": "Vive en Madrid.", "evidence": "vivo en Madrid"},
            {"target": "user", "text": "Tiene un perro.", "evidence": ""},
            {"target": "user", "text": "Trabaja de médico.", "evidence": "médico... soy"},
        )
        mr.review(["Soy médico en Manresa. Me encanta mi trabajo"], self.keeper(files), ask, today=TODAY)
        self.assertEqual(files.data["user"], [])
        # Fragments in order do count.
        ask = model({"target": "user", "text": "Trabaja de médico en Manresa.", "evidence": "soy médico… manresa"})
        mr.review(["Soy médico en Manresa. Me encanta mi trabajo"], self.keeper(files), ask, today=TODAY)
        self.assertEqual(files.data["user"], ["Trabaja de médico en Manresa."])

    def test_what_memory_holds_is_not_added_again(self):
        files = FakeFiles(user=["Vive en Súria."])
        ask = model({"target": "user", "text": "vive en  Súria", "evidence": "vivo en Súria"})
        self.assertEqual(mr.review(["vivo en Súria"], self.keeper(files), ask, today=TODAY), [])
        self.assertEqual(files.data["user"], ["Vive en Súria."])

    def test_an_update_replaces_the_old_entry_and_can_be_undone(self):
        files = FakeFiles(user=["Vive en Madrid con su pareja.", "Se llama Marc."])
        keeper = self.keeper(files)
        keeper.scan("user")  # both already there: legacy
        ask = model({"target": "user", "text": "Vive en Súria con su pareja.", "evidence": "ahora vivo en Súria",
                     "replaces": "Vive en Madrid con su pareja."})
        change = mr.review(["Ahora vivo en Súria"], keeper, ask, today=TODAY)[0]
        self.assertEqual(files.data["user"], ["Vive en Súria con su pareja.", "Se llama Marc."])
        self.assertEqual(change["removed"][0]["text"], "Vive en Madrid con su pareja.")
        keeper.revert(change["id"])
        self.assertEqual(sorted(files.data["user"]), ["Se llama Marc.", "Vive en Madrid con su pareja."])
        self.assertEqual(keeper.origin("user", text="Vive en Madrid con su pareja.")["source"], "legacy")

    def test_a_contradiction_without_a_change_is_asked_not_assumed(self):
        files = FakeFiles(user=["Vive en Madrid."])
        keeper = self.keeper(files)
        keeper.scan("user")
        ask = model({"target": "user", "text": "Vive en Manresa.", "evidence": "en Manresa, que es donde vivo",
                     "replaces": "Vive en Madrid."})
        self.assertEqual(mr.review(["en Manresa, que es donde vivo"], keeper, ask, today=TODAY), [])
        self.assertEqual(files.data["user"], ["Vive en Madrid."])  # not overwritten
        doubts = mr.open_doubts(keeper)
        self.assertEqual(doubts[0]["known"], "Vive en Madrid.")
        self.assertIn("pregúntaselo", mr.doubts_prompt(doubts))
        files.data["user"] = ["Vive en Manresa."]  # answered: memory updated
        self.assertEqual(mr.open_doubts(keeper), [])

    def test_the_persons_own_entries_are_never_replaced(self):
        files = FakeFiles(user=["Vive en Madrid."])
        keeper = self.keeper(files)
        keeper.record("user", "Vive en Madrid.", "person")
        ask = model({"target": "user", "text": "Vive en Súria.", "evidence": "vivo en Súria",
                     "replaces": "Vive en Madrid."})
        self.assertEqual(mr.review(["vivo en Súria"], keeper, ask, today=TODAY), [])
        self.assertEqual(files.data["user"], ["Vive en Madrid."])

    def test_a_replacement_it_cannot_point_to_is_skipped(self):
        files = FakeFiles(user=["Vive en Madrid."])
        ask = model({"target": "user", "text": "Vive en Súria.", "evidence": "vivo en Súria",
                     "replaces": "Vive en Valencia."})
        self.assertEqual(mr.review(["vivo en Súria"], self.keeper(files), ask, today=TODAY), [])
        self.assertEqual(files.data["user"], ["Vive en Madrid."])

    def test_bad_replies_and_bad_facts_change_nothing(self):
        files = FakeFiles()
        for reply in ("", "no JSON here", "{broken", json.dumps({"facts": "x"}), json.dumps([1, 2])):
            self.assertEqual(mr.review(["vivo en Súria"], self.keeper(files), lambda _m, r=reply: r,
                                       today=TODAY), [])
        ask = model(
            {"target": "system", "text": "Vive en Súria.", "evidence": "vivo en Súria"},
            {"target": "user", "text": "Corto", "evidence": "vivo en Súria"},
            {"target": "user", "text": "Vive en § Súria.", "evidence": "vivo en Súria"},
            {"target": "user", "text": "x" * 300, "evidence": "vivo en Súria"},
        )
        mr.review(["vivo en Súria"], self.keeper(files), ask, today=TODAY)
        self.assertEqual(files.data, {"memory": [], "user": []})

    def test_at_most_five_facts_a_look(self):
        files = FakeFiles()
        said = "a1 a2 a3 a4 a5 a6 a7"
        ask = model(*[{"target": "user", "text": f"Dato número {n}.", "evidence": f"a{n}"} for n in range(1, 8)])
        self.assertEqual(len(mr.review([said], self.keeper(files), ask, today=TODAY)), 0)  # evidence too short
        said = " ".join(f"tengo el dato {n}" for n in range(1, 8))
        ask = model(*[{"target": "user", "text": f"Tiene el dato {n}.", "evidence": f"tengo el dato {n}"}
                      for n in range(1, 8)])
        self.assertEqual(len(mr.review([said], self.keeper(files), ask, today=TODAY)), mr.MAX_FACTS)

    def test_learning_can_be_turned_off_and_defaults_on(self):
        keeper = self.keeper(FakeFiles())
        self.assertEqual(keeper.settings(), {"apply": False, "learn": True})
        keeper.set_apply(True)
        self.assertEqual(keeper.set_learn(False), {"apply": True, "learn": False})

    def test_no_turns_asks_nothing(self):
        ask = model()
        self.assertEqual(mr.review([], self.keeper(FakeFiles()), ask), [])
        self.assertEqual(ask.seen, [])


HERMES_TEST = r"""
import importlib.util, json, os, sys
from pathlib import Path
home = Path(os.environ["HERMES_HOME"])
spec = importlib.util.spec_from_file_location("alice_plugin_review_e2e", sys.argv[1])
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)
from hermes_state import SessionDB

asked = []
def ask(messages):
    asked.append(messages[1]["content"].split("The person's messages:")[1].strip())
    return json.dumps({"facts": [{"target": "user", "text": "Vive en Súria.", "evidence": "vivo en Súria"}]})
plugin._review_ask = ask

db = SessionDB()
db.create_session("chat", "tui")
db.append_message("chat", "user", "Por cierto, vivo en Súria")
db.append_message("chat", "assistant", "¡Anotado! Supongo que trabajas en Barcelona.")
db.create_session("routine", "cron")
db.append_message("routine", "user", "vivo en Súria")
db.close()

plugin._review_memory(home, "default", "routine")
plugin._review_memory(home, "default", "chat")
plugin._review_memory(home, "default", "chat")
db = SessionDB()
db.append_message("chat", "user", "Y mañana voy al médico")
db.close()
plugin._review_memory(home, "default", "chat")
print(json.dumps({"asked": asked, "user_md": (home / "memories" / "USER.md").read_text(encoding="utf-8")}))
"""


class HermesReviewTests(unittest.TestCase):
    """The hook against Hermes' own session database and memory files; only the model is fake."""

    def test_reads_each_message_once_and_writes_through_hermes(self):
        import os
        import subprocess

        hermes = Path.home() / ".hermes" / "hermes-agent"
        if not (hermes / "hermes_state.py").is_file():
            self.skipTest("Hermes is not installed here")
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HERMES_HOME=home, PYTHONPATH=str(hermes))
            proc = subprocess.run([sys.executable, "-c", HERMES_TEST, str(HERE / "__init__.py")],
                                  capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr[-2000:])
            result = json.loads(proc.stdout.strip().splitlines()[-1])
        # Never a routine; the chat once, then only what is new; never the agent's words.
        self.assertEqual(result["asked"], ["- Por cierto, vivo en Súria", "- Y mañana voy al médico"])
        self.assertIn("Vive en Súria.", result["user_md"])
        self.assertEqual(result["user_md"].count("Vive en Súria."), 1)


if __name__ == "__main__":
    unittest.main()
