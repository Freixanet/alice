"""Shared agent engine, against a fake Hermes CLI. Never talks to a live agent.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
    python3 -m unittest hermes-plugin.tests.test_agent_engine
"""
from __future__ import annotations

import contextlib
import json
import os
import shutil
import sys
import tempfile
import unittest
import unittest.mock
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

    def assert_directory_identity_refused(self, payload, *, old="forja", new="agent-maker"):
        self.assertEqual(payload["status"], eng.STATUS_FAILED, payload)
        error = (payload.get("error") or "")
        lower = error.lower()
        self.assertIn("left unchanged", lower)
        self.assertIn("registry_home", lower)
        self.assertNotIn("then retry", lower)
        self.assertNotIn("remove the profile", lower)
        self.assertTrue(self.profile(old).is_dir())
        self.assertFalse(self.profile(new).exists())
        log = self.home / "hermes.log"
        if log.is_file():
            self.assertNotIn("profile rename", log.read_text())
        job_id = payload.get("job_id")
        if job_id:
            journal = eng.load_journal(job_id, self.home)
            self.assertEqual(journal.get("status"), eng.STATUS_FAILED, journal)
            self.assertNotEqual(journal.get("status"), eng.STATUS_COMPLETED)


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
        job = "job-alice-form-1"
        folder = self.seed("resumen-mercados", soul="# Role\n")
        meta = json.loads((folder / "profile.yaml").read_text(encoding="utf-8"))
        meta["ui_meta"]["alice"] = {"job_id": job, "source": "form"}
        (folder / "profile.yaml").write_text(json.dumps(meta), encoding="utf-8")
        payload = self.create(spec(reuse_profile="resumen-mercados", job_id=job, smoke=False), job_id=job)
        self.assertTrue(payload["reused"], payload)
        self.assertEqual(payload["status"], eng.STATUS_COMPLETED, payload)
        self.assertIn("Ejemplos", (self.profile("resumen-mercados") / "SOUL.md").read_text())
        log = (self.home / "hermes.log").read_text(encoding="utf-8")
        self.assertNotIn("profile create", log)

    def test_foreign_reuse_leaves_the_original_intact(self):
        folder = self.seed("resumen-mercados", soul="original soul")
        payload = self.create(spec(reuse_profile="resumen-mercados", job_id="job-other"))
        self.assertEqual(payload["status"], eng.STATUS_FAILED, payload)
        self.assertIn("not authorized", payload["error"])
        self.assertIn("original soul", (folder / "SOUL.md").read_text(encoding="utf-8"))
        self.assertFalse(payload["reused"])
        log = (self.home / "hermes.log")
        if log.is_file():
            self.assertNotIn("profile create", log.read_text(encoding="utf-8"))

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
    def test_directory_identity_change_is_refused_before_move(self):
        folder = self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        self.assertEqual(payload["from_id"], "forja")
        self.assertEqual(payload["to_id"], "agent-maker")
        self.assertTrue((folder / "sessions" / "chat.json").is_file())
        self.assertTrue((folder / "MEMORY.md").is_file())
        self.assertTrue((folder / "auth.json").is_file())
        self.assertEqual(eng.alice_role(folder), eng.MAKER_ROLE)
        jobs = json.loads((folder / "cron" / "jobs.json").read_text(encoding="utf-8"))
        self.assertEqual(jobs["jobs"][0]["deliver"], "bot-chat:forja")
        self.assertEqual(jobs["jobs"][0]["profile"], "forja")

    def test_maker_stays_on_the_legacy_id_when_rename_cannot_move(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        self.assertEqual(eng.find_agent_maker(self.home), "forja")
        self.assert_directory_identity_refused(self.rename("forja", "Agent Maker"))
        self.assertEqual(eng.find_agent_maker(self.home), "forja")
        self.assertTrue(eng.is_agent_maker(self.home, "forja"))
        self.assertFalse(self.profile("agent-maker").exists())

    def test_collision_keeps_the_original(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        self.seed("agent-maker", title="Taken")
        payload = self.rename("forja", "Agent Maker")
        self.assertEqual(payload["status"], eng.STATUS_FAILED)
        self.assertTrue(self.profile("forja").is_dir())
        self.assertIn("maker soul", (self.profile("forja") / "SOUL.md").read_text())
        self.assertTrue(self.profile("agent-maker").is_dir())

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
        first = self.rename("forja", "Agent Maker", job_id=job)
        self.assert_directory_identity_refused(first)
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
        seen = eng.profile_busy_reason("forja", self.home, extra=["forja"])
        self.assertIsNotNone(seen)
        payload = self.rename("forja", "Agent Maker", busy_profiles=["forja"])
        self.assert_directory_identity_refused(payload)

    def test_remote_failure_is_not_success(self):
        self.seed("forja", title="Agent Maker")
        os.environ["ALICE_FAKE_RENAME_FAIL"] = "1"
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_credentials_and_team_placement_stay_on_the_original(self):
        folder = self.seed("biz-mercado", title="Mercado")
        meta = json.loads((folder / "profile.yaml").read_text())
        meta["ui_meta"]["alice"] = {"channel": "Business (Beta)"}
        (folder / "profile.yaml").write_text(json.dumps(meta), encoding="utf-8")
        payload = self.rename("biz-mercado", "Mercado Live")
        self.assert_directory_identity_refused(payload, old="biz-mercado", new="mercado-live")
        stayed = eng._read_mapping(folder / "profile.yaml")
        self.assertEqual(stayed["ui_meta"]["alice"]["channel"], "Business (Beta)")
        self.assertTrue((folder / "auth.json").is_file())

    def test_maker_migration_is_opt_in(self):
        self.seed("forja", title="Agent Maker", role=eng.MAKER_ROLE)
        planned = eng.prepare_maker_migration(self.home, execute=False)
        self.assertEqual(planned["to_id"], "agent-maker")
        self.assertTrue(self.profile("forja").is_dir())
        self.assertNotEqual(planned.get("status"), eng.STATUS_COMPLETED)
        ran = eng.prepare_maker_migration(self.home, execute=True)
        self.assert_directory_identity_refused(ran)
        self.assertTrue(eng.is_agent_maker(self.home, "forja"))
        self.assertFalse(self.profile("agent-maker").exists())


class Safety(EngineCase):
    def test_job_id_rejects_absolute_paths_and_traversal(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        for bad in ("../etc/passwd", "/tmp/alice-job", "foo/bar", r"..\windows", "a" * 81):
            payload = self.create(spec(job_id=bad, smoke=False), job_id=bad)
            self.assertEqual(payload["status"], eng.STATUS_FAILED, payload)
            self.assertIn("job_id", (payload.get("error") or "").lower())
            self.assertFalse((self.home / "etc").exists())
            self.assertFalse((self.home / "tmp").exists())
            ops = self.home / ".alice" / "agent-ops"
            if ops.is_dir():
                self.assertFalse(any("passwd" in p.name for p in ops.rglob("*")))
        with self.assertRaises(eng.SpecError):
            eng.load_journal("../../etc/passwd", self.home)
        with self.assertRaises(eng.SpecError):
            eng.journal_path("/tmp/x", self.home)

    def test_job_id_stays_bound_to_its_destination(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        job = "job-bound-1"
        first = self.create(spec(job_id=job, smoke=False), job_id=job)
        self.assertEqual(first["status"], eng.STATUS_COMPLETED, first)
        diverted = self.create(
            spec(name="otro-agente", title="Otro", job_id=job, smoke=False), job_id=job,
        )
        self.assertEqual(diverted["status"], eng.STATUS_FAILED, diverted)
        self.assertIn("bound", diverted["error"])
        self.assertTrue(self.profile("resumen-mercados").is_dir())
        self.assertFalse(self.profile("otro-agente").exists())
        self.assertIn("Ejemplos", (self.profile("resumen-mercados") / "SOUL.md").read_text())

    def test_partial_result_keeps_error_and_job_for_recovery(self):
        os.environ["ALICE_FAKE_AUTH"] = "1"
        os.environ["ALICE_FAKE_FAIL_AFTER"] = "1"
        job = "job-partial-ui"
        first = self.create(spec(job_id=job, smoke=False), job_id=job)
        self.assertEqual(first["status"], eng.STATUS_PARTIAL, first)
        self.assertEqual(first["job_id"], job)
        self.assertTrue(first["error"])
        self.assertFalse(first["ok"])
        journal = eng.load_journal(job, self.home)
        self.assertEqual(journal["status"], eng.STATUS_PARTIAL)
        self.assertEqual(journal["profile_id"], "resumen-mercados")
        self.assertEqual(journal["job_id"], job)

    def test_server_busy_session_is_not_idle(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        runtime = self.home / "runtime"
        runtime.mkdir()
        (runtime / "active_sessions.json").write_text(json.dumps({
            "entries": [{
                "lease_id": "L1",
                "session_id": "s1",
                "pid": os.getpid(),
                "surface": "gateway",
                "metadata": {"profile": "forja"},
            }],
        }), encoding="utf-8")
        seen = eng.profile_busy_reason("forja", self.home)
        self.assertIsNotNone(seen)
        self.assertIn("session", seen.lower())
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        self.assertIn("maker soul", (self.profile("forja") / "SOUL.md").read_text())

    def test_dead_session_lease_still_does_not_allow_a_directory_move(self):
        self.seed("forja", title="Agent Maker")
        runtime = self.home / "runtime"
        runtime.mkdir()
        (runtime / "active_sessions.json").write_text(json.dumps({
            "entries": [{
                "lease_id": "L1",
                "session_id": "s1",
                "pid": 999_999_999,
                "surface": "gateway",
                "metadata": {"profile": "forja"},
            }],
        }), encoding="utf-8")
        self.assertIsNone(eng.profile_busy_reason("forja", self.home))
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_running_session_file_is_not_idle(self):
        folder = self.seed("forja", title="Agent Maker", soul="maker soul")
        (folder / "sessions" / "chat.json").write_text(
            '{"id": "s1", "running": true}', encoding="utf-8",
        )
        seen = eng.profile_busy_reason("forja", self.home)
        self.assertIsNotNone(seen)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_rename_lock_does_not_hide_identity_refusal(self):
        import subprocess

        self.seed("forja", title="Agent Maker", soul="maker soul")
        lock_path = eng._rename_lock_path(self.home, "forja")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl, sys, time\n"
             "handle = open(sys.argv[1], 'a+b')\n"
             "fcntl.flock(handle, fcntl.LOCK_EX)\n"
             "print('locked', flush=True)\n"
             "time.sleep(30)\n",
             str(lock_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(holder.kill)
        line = holder.stdout.readline()
        self.assertIn("locked", line)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        holder.kill()
        holder.wait()
        holder.stdout.close()
        holder.stderr.close()
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)


    def _write_leases(self, entries, *, root=None):
        runtime = (root or self.home) / "runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        (runtime / "active_sessions.json").write_text(
            json.dumps({"entries": entries}), encoding="utf-8",
        )

    def test_corrupt_session_registry_is_not_idle(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        runtime = self.home / "runtime"
        runtime.mkdir()
        (runtime / "active_sessions.json").write_text("{not-json", encoding="utf-8")
        seen = eng.profile_busy_reason("forja", self.home)
        self.assertIsNotNone(seen)
        self.assertIn("unreadable", seen.lower())
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        self.assertIn("maker soul", (self.profile("forja") / "SOUL.md").read_text())

    def test_invalid_registry_shape_is_not_idle(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        for body in ('{"entries": "nope"}', '{"entries": [1, 2]}'):
            with self.subTest(body=body):
                runtime = self.home / "runtime"
                runtime.mkdir(exist_ok=True)
                (runtime / "active_sessions.json").write_text(body, encoding="utf-8")
                seen = eng.profile_busy_reason("forja", self.home)
                self.assertIsNotNone(seen)
                self.assertIn("unreadable", seen.lower())
                payload = self.rename("forja", "Agent Maker")
                self.assert_directory_identity_refused(payload)

    def test_own_rename_lock_does_not_hide_live_sessions(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        self._write_leases([{
            "lease_id": "L1", "session_id": "s1", "pid": os.getpid(),
            "surface": "gateway", "metadata": {"profile": "forja"},
        }])
        with eng.coordinate_rename(self.home, "forja"):
            seen = eng.profile_busy_reason("forja", self.home, skip_rename_lock=True)
            self.assertIsNotNone(seen)
            self.assertIn("session", seen.lower())
            self.assertNotIn("already in progress", seen.lower())

    def test_rename_sees_a_session_started_after_the_alice_lock(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        original = eng.coordinate_rename

        @contextlib.contextmanager
        def inject(home, *names):
            with original(home, *names):
                self._write_leases([{
                    "lease_id": "L1", "session_id": "s1", "pid": os.getpid(),
                    "surface": "gateway", "metadata": {"profile": "forja"},
                }])
                yield

        with unittest.mock.patch.object(eng, "coordinate_rename", inject):
            payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_hermes_session_lock_is_not_used_as_move_permission(self):
        import subprocess

        self.seed("forja", title="Agent Maker", soul="maker soul")
        lock_path = eng.session_lock_path(self.home)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl, sys, time\n"
             "handle = open(sys.argv[1], 'a+b')\n"
             "fcntl.flock(handle, fcntl.LOCK_EX)\n"
             "print('locked', flush=True)\n"
             "time.sleep(30)\n",
             str(lock_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(holder.kill)
        line = holder.stdout.readline()
        self.assertIn("locked", line)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        holder.kill()
        holder.wait()
        holder.stdout.close()
        holder.stderr.close()
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_live_gateway_pid_is_not_idle(self):
        folder = self.seed("forja", title="Agent Maker", soul="maker soul")
        (folder / "gateway.pid").write_text(str(os.getpid()), encoding="utf-8")
        seen = eng.profile_busy_reason("forja", self.home)
        self.assertIsNotNone(seen)
        self.assertIn("gateway", seen.lower())
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)

    def test_identity_change_is_refused_before_move_without_runtime(self):
        folder = self.seed("forja", title="Agent Maker", soul="maker soul")
        self.assertFalse((folder / "runtime").exists())
        self.assertFalse(self.profile("agent-maker").exists())
        roots = eng._session_lock_roots(self.home, "forja", "agent-maker")
        self.assertEqual(roots, [self.home])
        self.assertNotIn(self.profile("agent-maker"), roots)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        self.assertFalse((folder / "runtime").exists())

    def test_empty_registry_file_and_incomplete_leases_are_not_idle(self):
        self.seed("forja", title="Agent Maker", soul="maker soul")
        runtime = self.home / "runtime"
        runtime.mkdir()
        registry = runtime / "active_sessions.json"
        registry.write_text("", encoding="utf-8")
        empty = eng.profile_busy_reason("forja", self.home)
        self.assertIsNotNone(empty)
        self.assertIn("unreadable", empty.lower())
        self.assert_directory_identity_refused(self.rename("forja", "Agent Maker"))
        for body in (
            {"entries": [{"session_id": "s1", "pid": os.getpid()}]},
            {"entries": [{"lease_id": "L1", "session_id": "s1"}]},
            {"entries": [{"lease_id": "L1", "session_id": "s1", "pid": 0}]},
            {"entries": [
                {"lease_id": "L1", "session_id": "s1", "pid": 1},
                {"lease_id": "L1", "session_id": "s2", "pid": 2},
            ]},
        ):
            with self.subTest(body=body):
                registry.write_text(json.dumps(body), encoding="utf-8")
                seen = eng.profile_busy_reason("forja", self.home)
                self.assertIsNotNone(seen)
                self.assertIn("unreadable", seen.lower())
                payload = self.rename("forja", "Agent Maker")
                self.assert_directory_identity_refused(payload)

    def test_delayed_hermes_session_is_refused_before_any_move(self):
        import subprocess

        folder = self.seed("forja", title="Agent Maker", soul="maker soul")
        self.assertFalse((folder / "runtime").exists())
        proc = subprocess.Popen(
            [sys.executable, "-c",
             "import os, sys, time\n"
             "os.environ['HERMES_HOME'] = sys.argv[2]\n"
             "time.sleep(0.8)\n"
             "from hermes_cli.active_sessions import try_acquire_active_session\n"
             "lease, message = try_acquire_active_session(\n"
             "    session_id='delayed-forja', surface='cli', config={},\n"
             "    registry_home=sys.argv[1],\n"
             ")\n"
             "print('acquired' if lease is not None else 'refused', flush=True)\n",
             str(folder), str(self.home)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
        self.addCleanup(proc.kill)
        payload = self.rename("forja", "Agent Maker")
        self.assert_directory_identity_refused(payload)
        proc.wait(timeout=5)
        out = (proc.stdout.read() if proc.stdout else "") or ""
        err = (proc.stderr.read() if proc.stderr else "") or ""
        if proc.stdout:
            proc.stdout.close()
        if proc.stderr:
            proc.stderr.close()
        self.assertEqual(proc.returncode, 0, err or out)
        self.assertTrue(folder.exists())

    def test_journal_is_not_left_completed_when_rename_returns_partial(self):
        folder = self.seed("forja", title="Agent Maker", soul="maker soul")
        shutil.move(str(folder), str(self.profile("agent-maker")))
        job = "rename-journal-partial"
        eng.save_journal({
            "job_id": job, "kind": "rename", "from_id": "forja", "to_id": "agent-maker",
            "confirmed": [eng.STEP_RENAME], "status": eng.STATUS_PARTIAL,
        }, self.home)

        def lie(**kwargs):
            self.profile("forja").mkdir()
            confirmed = list(kwargs["confirmed"]) + [eng.STEP_REBIND, eng.STEP_VERIFY]
            eng._persist_rename(
                kwargs["home"], kwargs["job_id"], kwargs["old_id"], kwargs["new_id"],
                kwargs["title"], confirmed, eng.STATUS_COMPLETED,
            )
            return eng.result(
                eng.STATUS_COMPLETED, profile_id=kwargs["new_id"], title=kwargs["title"],
                from_id=kwargs["old_id"], to_id=kwargs["new_id"],
                confirmed=confirmed, job_id=kwargs["job_id"],
            )

        with unittest.mock.patch.object(eng, "_execute_rename", lie):
            payload = self.rename("forja", "Agent Maker", job_id=job)
        self.assertEqual(payload["status"], eng.STATUS_PARTIAL, payload)
        journal = eng.load_journal(payload["job_id"], self.home)
        self.assertEqual(journal.get("status"), eng.STATUS_PARTIAL, journal)
        self.assertNotEqual(journal.get("status"), eng.STATUS_COMPLETED)
        self.assertTrue(self.profile("forja").exists())
        self.assertTrue(self.profile("agent-maker").is_dir())


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


class AgentToolset(EngineCase):
    """A profile only gets the native tools if its config lists the toolset."""

    def test_the_toolset_is_added_once_and_not_again(self):
        self.seed("agent-maker")
        self.assertTrue(eng.ensure_agent_toolset("agent-maker", home=self.home))
        self.assertIn(eng.AGENT_TOOLSET, eng._read_tools(self.profile("agent-maker")))
        # Running the installer twice must not list it twice.
        self.assertFalse(eng.ensure_agent_toolset("agent-maker", home=self.home))
        tools = eng._read_tools(self.profile("agent-maker"))
        self.assertEqual(tools.count(eng.AGENT_TOOLSET), 1)

    def test_the_toolsets_it_already_had_are_kept(self):
        self.seed("agent-maker")
        eng.hermes("-p", "agent-maker", "config", "set", "platform_toolsets.cli",
                   json.dumps(["terminal", "clarify"]), home=self.home)
        eng.ensure_agent_toolset("agent-maker", home=self.home)
        self.assertEqual(eng._read_tools(self.profile("agent-maker")),
                         ["terminal", "clarify", eng.AGENT_TOOLSET])

    def test_a_profile_that_is_not_there_is_left_alone(self):
        self.assertFalse(eng.ensure_agent_toolset("no-such-agent", home=self.home))


if __name__ == "__main__":
    unittest.main()
