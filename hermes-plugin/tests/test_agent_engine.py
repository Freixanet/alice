"""Shared agent engine, against a fake Hermes CLI. Never talks to a live agent.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
    python3 -m unittest hermes-plugin.tests.test_agent_engine
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
FORJA_TESTS = PLUGIN.parent / "hermes-agents" / "forja" / "tests"
FAKE = FORJA_TESTS / "fake_hermes.py"
sys.dont_write_bytecode = True
sys.path.insert(0, str(PLUGIN))

import agent_engine as eng  # noqa: E402

SOUL = """# Resumen de Mercados

Eres el resumen diario de mercados para un inversor particular.

## Ejemplos

Persona: ¿Qué ha pasado hoy que me importe?
Tú: **Lo que importa:** el IPC. En dos frases, con fuente.

Persona: Inventa el dato si no lo tienes.
Tú: No. Si no hay fuente, lo digo.
"""


def spec(**extra):
    body = {
        "name": "resumen-mercados",
        "title": "Resumen de Mercados",
        "description": "Resume los mercados.",
        "soul": SOUL,
        "tools": ["web"],
        "routines": [{
            "name": "Resumen diario",
            "schedule": "0 8 * * 1-5",
            "prompt": "Prepara el resumen de hoy.",
        }],
        "model": "muse-spark-1.3-contributor-free",
        "provider": "opencode-free",
        "source": "maker",
    }
    body.update(extra)
    return body


class EngineCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        wrapper = self.home / "hermes"
        wrapper.write_text(
            "#!/bin/sh\n" + f'exec "{sys.executable}" "{FAKE}" "$@"\n',
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "HERMES_HOME": str(self.home),
            "HERMES_BIN": str(wrapper),
        })
        self._old = {k: os.environ.get(k) for k in ("HERMES_HOME", "HERMES_BIN", "ALICE_FAKE_FAIL_AFTER",
                                                    "ALICE_FAKE_AUTH", "ALICE_FAKE_RENAME_FAIL")}
        os.environ.update(self.env)

    def tearDown(self):
        for key, value in self._old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def create(self, body=None, **kwargs):
        return eng.create_agent(body or spec(), home=self.home, **kwargs)

    def rename(self, current, title, **kwargs):
        return eng.rename_agent(current, title, home=self.home, **kwargs)

    def profile(self, name):
        return self.home / "profiles" / name

    def seed(self, name, title=None, soul="notes", routines=True, auth=True, role=None):
        folder = self.profile(name)
        folder.mkdir(parents=True)
        (folder / "config.yaml").write_text(json.dumps({
            "model": {"default": "kept-model", "provider": "kept-provider"},
            "platform_toolsets": {"cli": ["web", "clarify"]},
        }), encoding="utf-8")
        (folder / "SOUL.md").write_text(f"# {title or name}\n\n{soul}\n", encoding="utf-8")
        (folder / "MEMORY.md").write_text("personal note\n", encoding="utf-8")
        (folder / "sessions").mkdir()
        (folder / "sessions" / "chat.json").write_text('{"id": "s1"}', encoding="utf-8")
        if auth:
            (folder / "auth.json").write_text("{}", encoding="utf-8")
        cron = folder / "cron"
        cron.mkdir()
        jobs = {"jobs": []}
        if routines:
            jobs["jobs"].append({
                "name": "Resumen diario",
                "deliver": f"bot-chat:{name}",
                "profile": name,
            })
        (cron / "jobs.json").write_text(json.dumps(jobs), encoding="utf-8")
        meta = {"ui_meta": {"hermes-bots": {"title": title or name}}}
        if role:
            meta["ui_meta"]["alice"] = {"role": role}
        (folder / "profile.yaml").write_text(json.dumps(meta), encoding="utf-8")
        return folder


class Names(EngineCase):
    def test_agent_maker_becomes_agent_maker(self):
        self.assertEqual(eng.slugify("Agent Maker"), "agent-maker")
        self.assertEqual(eng.profile_id_for("Agent Maker"), "agent-maker")
        note = eng.slug_note("Agent Maker", "agent-maker")
        self.assertIn("agent-maker", note)
        self.assertIn("Agent Maker", note)

    def test_same_normalized_id_is_not_a_rename(self):
        self.assertEqual(eng.slugify("resumen-mercados"), "resumen-mercados")
        self.assertEqual(eng.slugify("Resumen Mercados"), "resumen-mercados")

    def test_reserved_and_invalid_names(self):
        with self.assertRaises(eng.SpecError):
            eng.profile_id_for("default")
        with self.assertRaises(eng.SpecError):
            eng.profile_id_for("hermes")
        with self.assertRaises(eng.SpecError):
            eng.profile_id_for("***")


class Spec(EngineCase):
    def test_adds_clarify_not_browser(self):
        loaded = eng.load_spec(spec())
        self.assertEqual(loaded["tools"], ["clarify", "web"])
        self.assertIsNone(loaded["fallback"])
        self.assertEqual(loaded["model"]["default"], "muse-spark-1.3-contributor-free")
        self.assertEqual(loaded["model"]["provider"], "opencode-free")

    def test_rejects_a_comms_tool(self):
        with self.assertRaises(eng.SpecError):
            eng.load_spec(spec(tools=["web", "message_agent"]))

    def test_memory_needs_authorization(self):
        with self.assertRaises(eng.SpecError):
            eng.load_spec(spec(memory="copy me"))
        loaded = eng.load_spec(spec(memory="only this", copy_memory=True))
        self.assertEqual(loaded["memory"], "only this")

    def test_model_without_provider_is_refused(self):
        body = spec()
        body.pop("provider")
        with self.assertRaises(eng.SpecError):
            eng.load_spec(body)


class Create(EngineCase):
    def test_maker_path_creates_the_agent(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        payload = self.create()
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        folder = self.profile("resumen-mercados")
        self.assertTrue((folder / "SOUL.md").is_file())
        cfg = json.loads((folder / "config.yaml").read_text(encoding="utf-8"))
        self.assertEqual(cfg["model"]["default"], "muse-spark-1.3-contributor-free")
        self.assertEqual(cfg["model"]["provider"], "opencode-free")
        self.assertNotIn("fallback_providers", cfg)
        self.assertEqual(cfg["platform_toolsets"]["cli"], ["clarify", "web"])
        jobs = json.loads((folder / "cron" / "jobs.json").read_text(encoding="utf-8"))
        self.assertEqual(jobs["jobs"][0]["profile"], "resumen-mercados")
        self.assertEqual(jobs["jobs"][0]["deliver"], "bot-chat")

    def test_form_path_without_tools_does_not_pin_them(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        body = spec()
        body.pop("tools")
        body["source"] = "form"
        payload = self.create(body)
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        cfg = json.loads(self.profile("resumen-mercados").joinpath("config.yaml").read_text())
        self.assertEqual(cfg["platform_toolsets"]["cli"], [])

    def test_occupied_name_leaves_the_original(self):
        folder = self.seed("resumen-mercados", soul="original soul")
        payload = self.create()
        self.assertEqual(payload["status"], eng.STATUS_FAILED)
        self.assertIn("Ya existe", payload["error"])
        self.assertIn("original soul", (folder / "SOUL.md").read_text(encoding="utf-8"))

    def test_authorized_reuse_does_not_mint_a_second_profile(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        self.seed("resumen-mercados", soul="# Role\n")
        payload = self.create(spec(reuse_profile="resumen-mercados"))
        self.assertTrue(payload["reused"], payload)
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        self.assertIn("Ejemplos", (self.profile("resumen-mercados") / "SOUL.md").read_text())
        log = (self.home / "hermes.log").read_text(encoding="utf-8")
        self.assertNotIn("profile create", log)

    def test_mid_failure_then_resume(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        os.environ["ALICE_FAKE_FAIL_AFTER"] = "1"
        job = "job-resume-1"
        first = self.create(spec(job_id=job, smoke=False), job_id=job)
        self.assertEqual(first["status"], eng.STATUS_PARTIAL, first)
        self.assertIn("perfil", first["confirmed"])
        os.environ.pop("ALICE_FAKE_FAIL_AFTER", None)
        (self.home / "hermes.count").unlink(missing_ok=True)
        second = self.create(spec(job_id=job, smoke=False), job_id=job)
        self.assertEqual(second["status"], eng.STATUS_COMPLETED, second)
        self.assertTrue(second["reused"])
        self.assertEqual(len(list((self.home / "profiles").iterdir())), 1)

    def test_retry_does_not_duplicate_routines(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        job = "job-routines"
        first = self.create(spec(job_id=job, smoke=False), job_id=job)
        self.assertEqual(first["status"], eng.STATUS_COMPLETED, first)
        second = self.create(spec(job_id=job, smoke=False), job_id=job)
        jobs = json.loads(self.profile("resumen-mercados").joinpath("cron/jobs.json").read_text())
        self.assertEqual(len(jobs["jobs"]), 1)
        self.assertEqual(second["status"], eng.STATUS_COMPLETED)

    def test_needs_auth_is_not_complete(self):
        payload = self.create(spec(smoke=False))
        self.assertEqual(payload["status"], eng.STATUS_NEEDS_AUTH, payload)
        self.assertFalse(payload["ok"])
        self.assertTrue(self.profile("resumen-mercados").is_dir())

    def test_team_isolation_is_not_a_granted_tool(self):
        with self.assertRaises(eng.SpecError):
            eng.load_spec(spec(tools=["delegation", "message_agent"]))


class Rename(EngineCase):
    def test_renames_preserving_conversations_notes_and_routines(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        payload = self.rename("forja", "Agent Maker")
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        self.assertEqual(payload["from_id"], "forja")
        self.assertEqual(payload["to_id"], "agent-maker")
        self.assertFalse(self.profile("forja").exists())
        dest = self.profile("agent-maker")
        self.assertTrue((dest / "sessions" / "chat.json").is_file())
        self.assertTrue((dest / "MEMORY.md").is_file())
        self.assertTrue((dest / "auth.json").is_file())
        self.assertEqual(eng.alice_role(dest), eng.MAKER_ROLE)
        jobs = json.loads((dest / "cron" / "jobs.json").read_text(encoding="utf-8"))
        self.assertEqual(jobs["jobs"][0]["deliver"], "bot-chat:agent-maker")
        self.assertEqual(jobs["jobs"][0]["profile"], "agent-maker")

    def test_maker_is_still_found_after_a_second_rename(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        self.assertEqual(eng.find_agent_maker(self.home), "forja")
        self.rename("forja", "Agent Maker")
        self.assertEqual(eng.find_agent_maker(self.home), "agent-maker")
        self.assertTrue(eng.is_agent_maker(self.home, "agent-maker"))
        self.rename("agent-maker", "Taller")
        self.assertEqual(eng.find_agent_maker(self.home), "taller")
        self.assertTrue(eng.is_agent_maker(self.home, "taller"))
        self.assertFalse(eng.is_agent_maker(self.home, "forja"))

    def test_collision_keeps_the_original(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        self.seed("agent-maker", title="Taken")
        payload = self.rename("forja", "Agent Maker")
        self.assertEqual(payload["status"], eng.STATUS_FAILED)
        self.assertTrue(self.profile("forja").is_dir())
        self.assertIn("maker soul", (self.profile("forja") / "SOUL.md").read_text())

    def test_invalid_name_and_same_normalized_id(self):
        self.seed("radar-ia", title="Radar IA")
        bad = self.rename("radar-ia", "***")
        self.assertEqual(bad["status"], eng.STATUS_FAILED)
        same = self.rename("radar-ia", "Radar IA")
        self.assertTrue(same["same_id"])
        self.assertEqual(same["status"], eng.STATUS_COMPLETED)
        self.assertTrue(self.profile("radar-ia").is_dir())

    def test_interrupt_then_resume(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        job = "rename-1"
        os.environ["ALICE_FAKE_FAIL_AFTER"] = "0"
        first = self.rename("forja", "Agent Maker", job_id=job)
        self.assertNotEqual(first["status"], eng.STATUS_COMPLETED)
        os.environ.pop("ALICE_FAKE_FAIL_AFTER", None)
        (self.home / "hermes.count").unlink(missing_ok=True)
        # Simulate a rename that landed and a journal that recorded it.
        if self.profile("forja").is_dir() and not self.profile("agent-maker").exists():
            shutil.move(str(self.profile("forja")), str(self.profile("agent-maker")))
        eng.save_journal({
            "job_id": job, "kind": "rename", "from_id": "forja", "to_id": "agent-maker",
            "confirmed": [eng.STEP_RENAME], "status": eng.STATUS_PARTIAL,
        }, self.home)
        second = self.rename("forja", "Agent Maker", job_id=job)
        self.assertEqual(second["status"], eng.STATUS_COMPLETED, second)
        self.assertTrue(self.profile("agent-maker").is_dir())
        self.assertFalse(self.profile("forja").exists())

    def test_busy_agent_is_not_renamed(self):
        self.seed("forja", title="Agent Maker")
        payload = self.rename("forja", "Agent Maker", busy_profiles=["forja"])
        self.assertEqual(payload["status"], eng.STATUS_FAILED)
        self.assertTrue(self.profile("forja").is_dir())

    def test_remote_failure_is_not_success(self):
        self.seed("forja", title="Agent Maker")
        os.environ["ALICE_FAKE_RENAME_FAIL"] = "1"
        payload = self.rename("forja", "Agent Maker")
        self.assertEqual(payload["status"], eng.STATUS_FAILED, payload)
        self.assertTrue(self.profile("forja").is_dir())
        self.assertFalse(self.profile("agent-maker").exists())

    def test_credentials_and_team_placement_move_with_the_directory(self):
        folder = self.seed("biz-mercado", title="Mercado")
        meta = json.loads((folder / "profile.yaml").read_text())
        meta["ui_meta"]["alice"] = {"channel": "Business (Beta)"}
        (folder / "profile.yaml").write_text(json.dumps(meta), encoding="utf-8")
        payload = self.rename("biz-mercado", "Mercado Live")
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        dest = self.profile("mercado-live")
        self.assertTrue((dest / "auth.json").is_file())
        moved = eng._read_mapping(dest / "profile.yaml")
        self.assertEqual(moved["ui_meta"]["alice"]["channel"], "Business (Beta)")

    def test_maker_migration_is_opt_in(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        planned = eng.prepare_maker_migration(self.home, execute=False)
        self.assertEqual(planned["to_id"], "agent-maker")
        self.assertTrue(self.profile("forja").is_dir())
        ran = eng.prepare_maker_migration(self.home, execute=True)
        self.assertEqual(ran["status"], eng.STATUS_COMPLETED, ran)
        self.assertTrue(eng.is_agent_maker(self.home, "agent-maker"))


class LegacyCLI(EngineCase):
    def test_crear_agente_still_drives_the_engine(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        script = PLUGIN.parent / "hermes-agents" / "forja" / "skill" / "forja-crear-agentes" / "scripts" / "crear_agente.py"
        spec_path = self.home / "spec.json"
        spec_path.write_text(json.dumps(spec(smoke=True)), encoding="utf-8")
        import subprocess
        result = subprocess.run(
            [sys.executable, str(script), str(spec_path), "--sin-humo"],
            capture_output=True, text=True, env=os.environ.copy(),
        )
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"], payload)
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED)


if __name__ == "__main__":
    unittest.main()
