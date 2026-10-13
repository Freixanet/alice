"""Real *installed official Hermes* PluginContext registration, disposable home.

No personal Hermes, LLM provider, gateway, network, browser or credentials.
Run in Quality after pinned NousResearch/hermes-agent has been installed.
On a bare machine without Hermes, skip rather than invent an official pass.
"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


PLUGIN_ROOT = Path(__file__).resolve().parents[1]


def load(filename: str):
    spec = importlib.util.spec_from_file_location(
        "alice_r02_official_" + filename.replace(".", "_"), PLUGIN_ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class OfficialDisposableContextSmoke(unittest.TestCase):
    def test_real_official_context_registers_both_nonexecuting_tools(self):
        if importlib.util.find_spec("hermes_cli") is None:
            self.skipTest("official Hermes not installed in isolated Python")
        with tempfile.TemporaryDirectory(prefix="alice-r02-official-context-") as root:
            # Scope overrides are installed BEFORE official imports. Never
            # read the user's ~/.hermes or use the user's configured LLM.
            with patch.dict(os.environ, {
                    "HERMES_HOME": root,
                    "ALICE_R02_PLANNER_ORIGIN": "",
                    "ALICE_R02_PLANNER_CA_FILE": "",
                    "ALICE_R02_PLANNER_BEARER_FILE": ""}):
                from hermes_constants import (
                    set_hermes_home_override, reset_hermes_home_override)
                token = set_hermes_home_override(Path(root))
                try:
                    from hermes_cli.plugins import PluginManager, PluginContext
                    from hermes_cli.plugins_manifest import parse_manifest_file
                    from tools.registry import registry

                    manifest = parse_manifest_file(
                        PLUGIN_ROOT / "plugin.yaml", PLUGIN_ROOT, "user", "")
                    self.assertIsNotNone(manifest)
                    manager = PluginManager(scope_key=root)
                    context = PluginContext(manifest, manager)
                    local = load("r02_planner.py")
                    remote = load("r02_remote.py")
                    try:
                        local.register(context)
                        remote.register(context, local)
                        for name in ("alice_secure_plan", "alice_secure_plan_remote"):
                            with self.subTest(name=name):
                                live = registry.get_entry(name, scope=manager.scope_key)
                                self.assertIsNotNone(live)
                                self.assertEqual(live.toolset, "alice_secure_planning")
                                self.assertIn("handler", dir(live))
                        # Even when Hermes has a real plugin context, it does
                        # not grant this optional tool ASR/payment authority.
                        entry = registry.get_entry(
                            "alice_secure_plan_remote", scope=manager.scope_key)
                        self.assertEqual(
                            json.loads(entry.handler({})),
                            {"status": "denied", "execution_authority": False})
                        self.assertEqual(
                            json.loads(entry.handler({"commit": True})),
                            {"status": "denied", "execution_authority": False})
                    finally:
                        manager.unload()
                    for name in ("alice_secure_plan", "alice_secure_plan_remote"):
                        self.assertIsNone(registry.snapshot_registration(
                            name, scope=manager.scope_key))
                finally:
                    reset_hermes_home_override(token)
