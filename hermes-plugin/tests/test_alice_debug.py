"""alice_debug tools read the dump the iPhone uploaded.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_INIT = Path(__file__).resolve().parents[1] / "__init__.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_plugin_alice_debug_test", PLUGIN_INIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AliceDebugToolsTests(unittest.TestCase):
    def setUp(self):
        self.plugin = load_plugin()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        folder = self.home / ".alice" / "diagnostics"
        folder.mkdir(parents=True)
        (folder / "phone.json").write_text(json.dumps({
            "device_id": "phone",
            "captured_at": "2026-09-21T12:00:00Z",
            "version": "1.0",
            "build": "2",
            "wellbeing": "unreachable",
            "connected": False,
            "dashboard_ready": True,
            "gateway_configured": True,
            "unknown_events": [],
            "lines": [
                "2026-09-21T12:00:00Z turn.start",
                "2026-09-21T12:00:01Z turn.failed reply=r1 error=timeout",
            ],
        }), encoding="utf-8")
        constants = mock.MagicMock()
        constants.get_hermes_home.return_value = str(self.home)
        sys.modules["hermes_constants"] = constants
        self.addCleanup(lambda: sys.modules.pop("hermes_constants", None))

    def test_status_reads_the_latest_dump_without_log_lines(self):
        status = json.loads(self.plugin.alice_app_status())
        self.assertTrue(status["ok"])
        self.assertEqual(status["wellbeing"], "unreachable")
        self.assertEqual(status["line_count"], 2)
        self.assertNotIn("lines", status)

    def test_recent_errors_keep_only_failure_lines(self):
        errors = json.loads(self.plugin.alice_recent_errors())
        self.assertTrue(errors["ok"])
        self.assertEqual(errors["scanned"], 2)
        self.assertEqual(len(errors["errors"]), 1)
        self.assertIn("turn.failed", errors["errors"][0])

    def test_empty_folder_does_not_pretend_to_know(self):
        for path in (self.home / ".alice" / "diagnostics").glob("*.json"):
            path.unlink()
        status = json.loads(self.plugin.alice_app_status())
        self.assertEqual(status["reports"], 0)
        self.assertIn("no dump", status["note"])


if __name__ == "__main__":
    unittest.main()
