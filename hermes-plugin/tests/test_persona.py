"""Alice's persona and routines are for whoever installs them: no one else's name, the
person's own name filled in at install time, and no rule that contradicts the purchase errands."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "hermes-agents"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PersonaTests(unittest.TestCase):
    def test_no_one_elses_name_is_left_and_the_persons_is_a_placeholder(self):
        for path in (ROOT / "alice" / "persona.md", ROOT / "proactiva" / "alice-proactiva.md", ROOT / "proactiva" / "instalar.py",
                     ROOT / "proactiva" / "cierre_dia.py", ROOT / "proactiva" / "antes_de_cita.py"):
            with self.subTest(path=path.name):
                self.assertNotIn("Marcos", path.read_text(encoding="utf-8"))
        self.assertIn("{{name}}", (ROOT / "alice" / "persona.md").read_text(encoding="utf-8"))

    def test_signing_in_inside_an_errand_follows_the_errands_own_tools(self):
        text = (ROOT / "alice" / "persona.md").read_text(encoding="utf-8")
        self.assertIn("login_fill", text)
        self.assertIn("login_request", text)
        self.assertIn("never create an account where a login is already saved", text)

    def test_the_installer_fills_the_name_from_the_argument_or_alices_details_or_refuses(self):
        installer = load(ROOT / "alice" / "instalar.py", "alice_persona_installer")
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            old = os.environ.get("HERMES_HOME")
            os.environ["HERMES_HOME"] = folder
            try:
                self.assertEqual(installer.main(["--comprobar"]), 2)
                (home / "alice").mkdir()
                (home / "alice" / "details.json").write_text(json.dumps({"name": "Lucía Pérez"}))
                self.assertEqual(installer.saved_name(home), "Lucía")
                self.assertEqual(installer.main([]), 0)
                soul = (home / "SOUL.md").read_text(encoding="utf-8")
                self.assertIn("Lucía", soul)
                self.assertNotIn("{{name}}", soul)
                self.assertEqual(installer.main(["--nombre", "Ana"]), 0)
                self.assertIn("Ana's", (home / "SOUL.md").read_text(encoding="utf-8"))
            finally:
                if old is None:
                    os.environ.pop("HERMES_HOME", None)
                else:
                    os.environ["HERMES_HOME"] = old


if __name__ == "__main__":
    unittest.main()
