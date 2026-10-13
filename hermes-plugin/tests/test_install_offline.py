"""Installer integration tests: fake Hermes commands and isolated TEMP paths only."""

import json
import os
from pathlib import Path
import shutil
import site
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"


@unittest.skipUnless(shutil.which("zsh"), "Installer requires zsh")
class OfflineInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alice-install-offline-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.home = self.root / "fictional-user" / ".hermes"
        self.bin = self.root / "fake-bin"
        self.trace = self.root / "trace.log"
        self.source.mkdir()
        self.home.mkdir(parents=True)
        self.bin.mkdir()
        shutil.copy2(SCRIPT, self.source / "install.sh")
        self._put(self.source / "plugin.yaml", "name: alice\nversion: 1.0.0\nkind: standalone\nprovides_tools: [example_tool]\nprovides_hooks: [pre_tool_call]\n")
        self._put(self.source / "__init__.py", "# fictional plugin\n")
        self._put(self.source / "dashboard/dist/index.js", "// fictional dashboard\n")
        self._put(self.source / "dashboard/plugin_api.py", "# fictional API\n")
        self._put(self.source / "skills/comprar/SKILL.md", "fictional skill\n")
        self._put(
            self.source / "dashboard/manifest.json",
            json.dumps({
                "name": "alice", "version": "1.0.0", "entry": "dist/index.js",
                "api": "plugin_api.py",
            }),
        )
        self._put(
            self.bin / "hermes",
            "#!/bin/sh\n"
            "printf 'hermes %s\\n' \"$*\" >> \"$ALICE_FAKE_TRACE\"\n"
            "if [ \"$1\" = plugins ] && [ \"${FAKE_FAIL_ENABLE:-0}\" = 1 ]; then exit 4; fi\n"
            "printf 'fake_config_change: true\\n' >> \"$HERMES_HOME/config.yaml\"\n"
            "if [ \"$1\" = config ] && [ \"${FAKE_FAIL_CONFIG_SET:-0}\" = 1 ]; then exit 7; fi\n",
            executable=True,
        )
        self._put(
            self.bin / "launchctl",
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "print)\n"
            "  [ \"${FAKE_GATEWAY_NOT_READY:-0}\" = 1 ] && "
            "case \"$2\" in *gateway) echo 'state = waiting'; exit 0;; esac\n"
            "  echo 'state = running' ;;\n"
            "kickstart)\n"
            "  printf 'kickstart %s\\n' \"$3\" >> \"$ALICE_FAKE_TRACE\"\n"
            "  if [ \"${FAKE_FAIL_DASHBOARD:-0}\" = 1 ]; then\n"
            "    case \"$3\" in *dashboard) exit 5;; esac\n"
            "  fi ;;\n"
            "esac\n",
            executable=True,
        )
        interpreter = self.home / "hermes-agent/venv/bin/python"
        self._put(
            interpreter,
            "#!/bin/sh\n"
            "if [ \"$1\" = -m ] && [ \"$2\" = pip ]; then\n"
            "  printf 'pip %s\\n' \"$*\" >> \"$ALICE_FAKE_TRACE\"\n"
            "  prev=''\n"
            "  for arg in \"$@\"; do\n"
            "    if [ \"$prev\" = --target ]; then target=$arg; fi\n"
            "    prev=$arg\n"
            "  done\n"
            "  mkdir -p \"$target/pypdf\"\n"
            "  echo fictional > \"$target/pypdf/__init__.py\"\n"
            "  [ \"${FAKE_FAIL_PIP:-0}\" = 1 ] && exit 6\n"
            "  exit 0\n"
            "fi\n"
            "if [ \"$1\" = - ] && [ \"$#\" = 3 ] && [ \"${FAKE_FAIL_SWAP:-0}\" = 1 ]; then exit 9; fi\n"
            "if [ \"$1\" = - ] && [ \"$#\" = 3 ] && [ \"${FAKE_LOST_SWAP_RESULT:-0}\" = 1 ]; then\n"
            "  \"$ALICE_FAKE_PYTHON\" \"$@\" || exit $?\n"
            "  exit 9\n"
            "fi\n"
            "exec \"$ALICE_FAKE_PYTHON\" \"$@\"\n",
            executable=True,
        )

    @staticmethod
    def _put(path, value, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
        if executable:
            path.chmod(0o755)

    def _run(self, **extra):
        env = dict(os.environ)
        env.update({
            "HOME": str(self.home.parent),
            "HERMES_HOME": str(self.home),
            "ALICE_FAKE_TRACE": str(self.trace),
            "ALICE_FAKE_PYTHON": sys.executable,
            "PYTHONPATH": os.pathsep.join(filter(None, (
                site.getusersitepackages(), os.environ.get("PYTHONPATH", "")))),
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
        })
        env.update({key: str(value) for key, value in extra.items()})
        return subprocess.run(
            [shutil.which("zsh"), str(self.source / "install.sh")],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, check=False,
        )

    def _old_plugin(self):
        previous = self.home / "plugins/alice"
        self._put(previous / "old-marker.txt", "original installation\n")
        self._put(previous / "vendor/local.txt", "previous optional dependency\n")
        return previous

    def _trace(self):
        return self.trace.read_text(encoding="utf-8").splitlines() if self.trace.exists() else []

    def _backup_plugins(self):
        return list((self.home / "backups").glob("alice-*/alice"))

    def _assert_no_staging(self):
        self.assertEqual(list((self.home / "plugins").glob(".alice-install.*")), [])
        self.assertFalse((self.home / "plugins/.alice-install.lock").exists())

    def test_fresh_install_validates_and_restarts_gateway_first(self):
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("authenticated pairing/control plane remains NO-GO", result.stdout)
        self.assertIn("API health and authentication have not been verified", result.stdout)
        self.assertTrue((self.home / "plugins/alice/__init__.py").is_file())
        self.assertEqual((self.home / "plugins/alice/vendor/pypdf/__init__.py").read_text().strip(), "fictional")
        self.assertFalse((self.home / "plugins/alice/skills/comprar/SKILL.md").stat().st_mode & 0o222)
        trace = self._trace()
        self.assertIn("hermes plugins enable alice --no-allow-tool-override", trace)
        self.assertEqual([row.rsplit("/", 1)[-1] for row in trace if row.startswith("kickstart ")], ["ai.hermes.gateway", "ai.hermes.dashboard"])
        self.assertEqual(self._backup_plugins(), [])
        self._assert_no_staging()

    def test_update_creates_backup_and_does_not_retain_stale_files(self):
        old = self._old_plugin()
        self._put(self.home / "config.yaml", "skills: {external_dirs: [/tmp/other]}\n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((old / "old-marker.txt").exists())
        self.assertEqual((old / "vendor/local.txt").read_text(), "previous optional dependency\n")
        backups = self._backup_plugins()
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "old-marker.txt").read_text(), "original installation\n")
        self.assertIn(str(backups[0]), result.stdout)
        self._assert_no_staging()

    def test_failed_enable_rolls_back_old_plugin_and_exact_config(self):
        old = self._old_plugin()
        config = self.home / "config.yaml"
        original = "skills: {external_dirs: []}\noriginal: preserved\n"
        self._put(config, original)
        result = self._run(FAKE_FAIL_ENABLE=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((old / "old-marker.txt").read_text(), "original installation\n")
        self.assertFalse((old / "__init__.py").exists())
        self.assertEqual(config.read_text(), original)
        self.assertEqual(self._backup_plugins(), [])
        self.assertFalse(any(row.startswith("kickstart ") for row in self._trace()))
        self._assert_no_staging()

    def test_failed_atomic_exchange_keeps_original_before_activation(self):
        old = self._old_plugin()
        result = self._run(FAKE_FAIL_SWAP=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((old / "old-marker.txt").is_file())
        self.assertFalse((old / "__init__.py").exists())
        self.assertEqual(self._backup_plugins(), [])
        self.assertFalse(any(row.startswith("hermes ") for row in self._trace()))
        self.assertTrue((self.home / "plugins/.alice-install.lock/recovery").is_file())
        self.assertTrue(list((self.home / "plugins").glob(".alice-install.*/new/__init__.py")))

    def test_lost_swap_acknowledgement_preserves_original_and_recovery_lock(self):
        self._old_plugin()
        result = self._run(FAKE_LOST_SWAP_RESULT=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / "plugins/alice/__init__.py").is_file())
        self.assertTrue(list((self.home / "plugins").glob(".alice-install.*/new/old-marker.txt")))
        self.assertTrue((self.home / "plugins/.alice-install.lock/recovery").is_file())
        self.assertIn("outcome uncertain", result.stderr)

    def test_nondefault_home_must_not_restart_real_gui_service_labels(self):
        alternate = self.root / "alternate-hermes"
        alternate.mkdir()
        fake_python = alternate / "hermes-agent/venv/bin/python"
        self._put(fake_python,
                  (self.home / "hermes-agent/venv/bin/python").read_text(), executable=True)
        result = self._run(HERMES_HOME=alternate)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("services NOT restarted", result.stdout)
        self.assertFalse(any(row.startswith("kickstart ") for row in self._trace()))

    def test_symlinked_plugin_or_backup_parent_is_refused_before_mutation(self):
        for part in ("plugins", "backups"):
            with self.subTest(part=part):
                target = self.root / ("unrelated-" + part)
                self._put(target / "retain.txt", "outside contents\n")
                (self.home / part).symlink_to(target, target_is_directory=True)
                result = self._run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("symlink", result.stderr)
                self.assertEqual((target / "retain.txt").read_text(), "outside contents\n")
                (self.home / part).unlink()

    def test_failed_dashboard_restart_rolls_back_and_restarts_original_gateway(self):
        old = self._old_plugin()
        config = self.home / "config.yaml"
        original = "skills: {external_dirs: []}\n"
        self._put(config, original)
        result = self._run(FAKE_FAIL_DASHBOARD=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((old / "old-marker.txt").read_text(), "original installation\n")
        self.assertEqual(config.read_text(), original)
        restarts = [row.rsplit("/", 1)[-1] for row in self._trace() if row.startswith("kickstart ")]
        self.assertEqual(restarts[:2], ["ai.hermes.gateway", "ai.hermes.dashboard"])
        self.assertEqual(restarts[2:], ["ai.hermes.gateway", "ai.hermes.dashboard"])
        self._assert_no_staging()

    def test_invalid_manifest_fails_before_touching_existing_plugin(self):
        old = self._old_plugin()
        manifest = self.source / "dashboard/manifest.json"
        data = json.loads(manifest.read_text())
        data["entry"] = "../../private"
        manifest.write_text(json.dumps(data))
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid dashboard entry", result.stderr)
        self.assertTrue((old / "old-marker.txt").is_file())
        self.assertFalse(self.trace.exists())
        self._assert_no_staging()

    def test_optional_pip_failure_only_changes_staging(self):
        old = self._old_plugin()
        result = self._run(FAKE_FAIL_PIP=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not install pypdf", result.stderr)
        self.assertTrue((old / "vendor/local.txt").is_file())
        self.assertFalse((old / "vendor/pypdf/__init__.py").exists())
        self.assertTrue((self._backup_plugins()[0] / "old-marker.txt").is_file())

    def test_preexisting_lock_prevents_any_mutation(self):
        old = self._old_plugin()
        lock = self.home / "plugins/.alice-install.lock"
        lock.mkdir()
        self._put(lock / "recovery", "/fictional/previous/alice\n")
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install has a lock", result.stderr)
        self.assertTrue((old / "old-marker.txt").is_file())
        self.assertEqual((lock / "recovery").read_text(), "/fictional/previous/alice\n")
        self.assertFalse(self.trace.exists())

    def test_symlinked_vendor_is_rejected_without_modification(self):
        old = self._old_plugin()
        shutil.rmtree(old / "vendor")
        target = self.root / "unrelated-user-data"
        self._put(target / "keep.txt", "keep me\n")
        (old / "vendor").symlink_to(target, target_is_directory=True)
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertEqual((target / "keep.txt").read_text(), "keep me\n")
        self.assertFalse(self.trace.exists())
        self._assert_no_staging()

    def test_current_repository_distribution_manifests_agree(self):
        import yaml

        actual_root = SCRIPT.parent
        plugin = yaml.safe_load((actual_root / "plugin.yaml").read_text(encoding="utf-8"))
        manifest = json.loads((actual_root / "dashboard/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(plugin["name"], "alice")
        self.assertEqual(manifest["name"], "alice")
        self.assertEqual(plugin["version"], manifest["version"])
        for key in ("entry", "api"):
            self.assertTrue((actual_root / "dashboard" / manifest[key]).is_file())

    def test_failed_fresh_install_does_not_leave_partial_plugin_or_config(self):
        result = self._run(FAKE_FAIL_ENABLE=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "plugins/alice").exists())
        self.assertFalse((self.home / "config.yaml").exists())
        self._assert_no_staging()

    def test_failed_config_set_on_fresh_install_restores_absent_config(self):
        result = self._run(FAKE_FAIL_CONFIG_SET=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "plugins/alice").exists())
        self.assertFalse((self.home / "config.yaml").exists())
        self.assertEqual(self._backup_plugins(), [])
        self._assert_no_staging()

    def test_malformed_config_refused_without_changing_old_plugin(self):
        old = self._old_plugin()
        self._put(self.home / "config.yaml", "skills: [unfinished\n")
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((old / "old-marker.txt").is_file())
        self.assertEqual((self.home / "config.yaml").read_text(), "skills: [unfinished\n")
        self.assertFalse(any(row.startswith("hermes ") or row.startswith("kickstart ") for row in self._trace()))
        self.assertEqual(self._backup_plugins(), [])
        self._assert_no_staging()

    def test_symlink_installation_is_rejected_without_following_it(self):
        target = self.root / "user-files"
        self._put(target / "keep.txt", "keep me\n")
        (self.home / "plugins").mkdir()
        (self.home / "plugins/alice").symlink_to(target, target_is_directory=True)
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((target / "keep.txt").exists())
        self.assertFalse(self.trace.exists())


if __name__ == "__main__":
    unittest.main()
