"""Alice's system prompt sections fit what Hermes keeps.

Hermes keeps each plugin section up to 4,000 characters and all of them together up to 8,000,
counting the "## Plugin Context: <id>" heading it adds; past either limit a section is dropped
from the prompt with only a log line. From 2026-09-27 Alice's sections added up to 15,924 and the
resolver, errands, cards and questions rules silently stopped reaching the model. This test
measures every section as the plugin registers it, at its largest (many goals, every detail kept),
so growing past the budget fails here instead of in a conversation.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_INIT = Path(__file__).resolve().parents[1] / "__init__.py"

try:  # Hermes' own limits when it is importable; the ones it shipped with otherwise.
    from hermes_cli.plugins_dispatch import (MAX_SYSTEM_PROMPT_SECTION_CHARS as SECTION_MAX,
                                             MAX_SYSTEM_PROMPT_SECTIONS_TOTAL_CHARS as TOTAL_MAX)
except Exception:  # noqa: BLE001
    SECTION_MAX, TOTAL_MAX = 4_000, 8_000
HEADING = "## Plugin Context: {}\n"
# Room left for other plugins' sections and for text that grows at run time.
HEADROOM = 800


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_plugin_alice_budget_test", PLUGIN_INIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PromptBudgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = load_plugin()

    def sections(self):
        found = []

        class Ctx:
            def register_system_prompt_section(self, section_id, fn, *args, **kwargs):
                found.append((section_id, fn))

            def __getattr__(self, name):
                return lambda *args, **kwargs: None

        self.plugin.register(Ctx())
        self.assertTrue(found, "the plugin registers its prompt sections")
        return found

    def rendered(self):
        home = Path(tempfile.mkdtemp())
        goals = self.plugin._goals_module()
        many = [{"id": f"g{i}", "title": f"Objetivo número {i} con un título largo de verdad",
                 "why": "Porque importa mucho y hay que explicarlo con detalle", "status": "active",
                 "steps": [{"id": f"s{i}{j}", "text": f"Paso {j} del objetivo {i}", "status": "todo"}
                           for j in range(5)]} for i in range(30)]
        details = {key: "x" * 40 for key in self.plugin._ask_person().FIELDS}
        store = types.SimpleNamespace(list=lambda include_done=False: many)
        with mock.patch.object(self.plugin, "_goals_store", return_value=store), \
                mock.patch.object(self.plugin._ask_person(), "load_details", return_value=details), \
                mock.patch.dict(sys.modules, {"hermes_constants": types.SimpleNamespace(get_hermes_home=lambda: home)}):
            out = {}
            for section_id, fn in self.sections():
                try:
                    out[section_id] = fn({}) or ""
                except Exception as exc:  # noqa: BLE001 — a section that raises is its own failure
                    self.fail(f"{section_id} raised {type(exc).__name__}: {exc}")
        self.assertTrue(goals, "goals module loads")
        return out

    def test_every_section_fits_its_limit(self):
        for section_id, text in self.rendered().items():
            size = len(HEADING.format(section_id)) + len(text)
            self.assertLessEqual(size, SECTION_MAX, f"{section_id} is {size} characters (limit {SECTION_MAX})")

    def test_all_sections_together_fit_with_room_to_spare(self):
        rendered = self.rendered()
        total = sum(len(HEADING.format(k)) + len(v) for k, v in rendered.items() if v)
        report = ", ".join(f"{k} {len(v)}" for k, v in sorted(rendered.items(), key=lambda kv: -len(kv[1])))
        self.assertLessEqual(total, TOTAL_MAX - HEADROOM,
                             f"Alice's sections total {total} of Hermes' {TOTAL_MAX} (keep {HEADROOM} free): {report}")


if __name__ == "__main__":
    unittest.main()
