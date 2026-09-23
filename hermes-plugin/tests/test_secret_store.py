"""Keys given in Alice's secure card land where Hermes reads them, and nowhere else.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "secret_store.py"
spec = importlib.util.spec_from_file_location("alice_secret_store_test", PATH)
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


class SecretStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_saved_to_the_main_env_and_every_profile_that_has_one(self):
        (self.root / "profiles" / "forja").mkdir(parents=True)
        (self.root / "profiles" / "forja" / ".env").write_text("OTHER=1\n", encoding="utf-8")
        (self.root / "profiles" / "sin-env").mkdir(parents=True)
        profiles = store.save(self.root, "EXA_API_KEY", " secret-1 ")
        self.assertEqual(profiles, ["default", "forja"])
        self.assertEqual((self.root / ".env").read_text(encoding="utf-8"), "EXA_API_KEY=secret-1\n")
        self.assertEqual((self.root / "profiles" / "forja" / ".env").read_text(encoding="utf-8"),
                         "OTHER=1\nEXA_API_KEY=secret-1\n")
        self.assertFalse((self.root / "profiles" / "sin-env" / ".env").exists())
        self.assertEqual(stat.S_IMODE((self.root / ".env").stat().st_mode), 0o600)
        self.assertTrue(store.is_set(self.root, "EXA_API_KEY"))

    def test_a_new_value_replaces_the_old_line_in_place(self):
        (self.root / ".env").write_text("A=1\nexport EXA_API_KEY=old\nB=2\n", encoding="utf-8")
        store.save(self.root, "EXA_API_KEY", "new")
        self.assertEqual((self.root / ".env").read_text(encoding="utf-8"), "A=1\nEXA_API_KEY=new\nB=2\n")

    def test_a_value_with_spaces_or_quotes_is_quoted(self):
        store.save(self.root, "TOKEN_X", 'a b"c')
        self.assertEqual((self.root / ".env").read_text(encoding="utf-8"), 'TOKEN_X="a b\\"c"\n')

    def test_hermes_own_settings_and_odd_names_are_refused(self):
        for name in ("HERMES_HOME", "API_SERVER_KEY", "PATH", "lower", "A", "X-Y", "ALICE_TOKEN"):
            with self.assertRaises(store.SecretError, msg=name):
                store.save(self.root, name, "v")
        self.assertFalse((self.root / ".env").exists())

    def test_a_value_that_would_add_lines_is_refused(self):
        for value in ("", "   ", "a\nEVIL=1", "a\rb", "x" * 5000):
            with self.assertRaises(store.SecretError):
                store.save(self.root, "EXA_API_KEY", value)
        self.assertFalse((self.root / ".env").exists())

    def test_unset_is_not_set(self):
        self.assertFalse(store.is_set(self.root, "EXA_API_KEY"))
        (self.root / ".env").write_text("EXA_API_KEY=\n", encoding="utf-8")
        self.assertFalse(store.is_set(self.root, "EXA_API_KEY"))


if __name__ == "__main__":
    unittest.main()
