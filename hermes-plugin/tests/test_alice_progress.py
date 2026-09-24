"""Alice's weekly progress: counts only, this week against the last."""
import importlib.util
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_progress_test", Path(__file__).resolve().parents[1] / "alice_progress.py")
progress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(progress)


class ProgressTests(unittest.TestCase):
    def test_tasks_corrections_and_lessons(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, now = Path(tmp), time.time()
            with closing(sqlite3.connect(home / "state.db")) as db, db:
                db.execute("CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT)")
                db.execute("CREATE TABLE sessions (id TEXT, source TEXT)")
                db.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
                goals = [("done", 3, 12), ("paused", 2, 12), ("paused", 12, 12)]
                for i, (status, used, most) in enumerate(goals):
                    db.execute("INSERT INTO state_meta VALUES (?, ?)", (f"goal:s{i}", json.dumps(
                        {"status": status, "turns_used": used, "max_turns": most, "created_at": now - 3600})))
                db.execute("INSERT INTO sessions VALUES ('a', 'tui'), ('c', 'cron')")
                for i in range(12):
                    db.execute("INSERT INTO messages VALUES ('a', 'user', ?, ?)",
                               ("no, te pedí otra cosa" if i < 3 else "gracias", now - 60))
                db.execute("INSERT INTO messages VALUES ('c', 'user', 'no, eso no', ?)", (now - 60,))
            (home / ".alice").mkdir()
            (home / ".alice" / "learned.jsonl").write_text(json.dumps({"at": now - 10, "learned": "x"}) + "\n")
            lines = progress.week_lines(home, lambda t: t.startswith("no,"), now)
            self.assertEqual(lines[0], "- Tareas de varios pasos: 1 terminadas de 3 (1 pararon para preguntarte, 1 se quedaron sin intentos)")
            self.assertEqual(lines[1], "- Correcciones tuyas: 3 de 12 mensajes (25 %)")
            self.assertEqual(lines[2], "- Aprendizajes guardados esta semana: 1")


if __name__ == "__main__":
    unittest.main()
