#!/usr/bin/env python3
"""Pruebas de crear_agente.py contra un Hermes falso. No tocan el Hermes real.

    python3 hermes-agents/forja/tests/test_crear_agente.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "skill" / "forja-crear-agentes" / "scripts" / "crear_agente.py"
FAKE = HERE / "fake_hermes.py"
sys.path.insert(0, str(SCRIPT.parent))

from crear_agente import has_examples, load_spec, SpecError  # noqa: E402

SOUL = """# Resumen de Mercados

Eres el resumen diario de mercados para un inversor particular.

## Ejemplos

Persona: ¿Qué ha pasado hoy que me importe?
Tú: **Lo que importa:** el IPC. En dos frases, con fuente.

Persona: Inventa el dato si no lo tienes.
Tú: No. Si no hay fuente, lo digo.
"""


def spec_text(soul: str = SOUL, name: str = "resumen-mercados") -> str:
    return json.dumps({
        "name": name,
        "title": "Resumen de Mercados",
        "description": "Resume los mercados.",
        "soul": soul,
        "tools": ["web"],
        "routines": [{
            "name": "Resumen diario",
            "schedule": "0 8 * * 1-5",
            "prompt": "Prepara el resumen de hoy.",
        }],
    }, ensure_ascii=False)


class Spec(unittest.TestCase):
    def test_soul_de_agent_maker_tiene_ejemplos(self):
        soul = (HERE.parent / "SOUL.md").read_text(encoding="utf-8")
        self.assertTrue(has_examples(soul))

    def test_exige_ejemplos(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "spec.json"
            path.write_text(spec_text(soul="# Solo titulo\n\nSin ejemplos.\n"), encoding="utf-8")
            with self.assertRaises(SpecError):
                load_spec(path)

    def test_exige_un_cuerpo_de_ejemplos(self):
        soul = "# Rol\n\nTexto.\n\n## Ejemplos\n\ncorto\n"
        self.assertFalse(has_examples(soul))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "spec.json"
            path.write_text(spec_text(soul=soul), encoding="utf-8")
            with self.assertRaises(SpecError):
                load_spec(path)

    def test_acepta_examples_en_ingles(self):
        soul = "# Markets\n\nYou summarise markets.\n\n## Examples\n\nPerson: What mattered?\nYou: **CPI.** Two sentences.\n"
        self.assertTrue(has_examples(soul))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "spec.json"
            path.write_text(spec_text(soul=soul), encoding="utf-8")
            loaded = load_spec(path)
            self.assertEqual(loaded["name"], "resumen-mercados")
            self.assertIn("clarify", loaded["tools"])

    def test_comprobar_no_crea_nada(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            spec = home / "spec.json"
            spec.write_text(spec_text(), encoding="utf-8")
            env = {
                **os.environ,
                "HERMES_HOME": str(home),
                "HERMES_BIN": sys.executable + " " + str(FAKE),
            }
            # HERMES_BIN must be one executable; use python as the bin via a wrapper.
            wrapper = home / "hermes"
            wrapper.write_text(
                "#!/bin/sh\n" + f'exec "{sys.executable}" "{FAKE}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            env["HERMES_BIN"] = str(wrapper)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(spec), "--comprobar"],
                capture_output=True, text=True, env=env, check=True,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertTrue(payload["comprobacion"])
            self.assertFalse((home / "profiles" / "resumen-mercados").exists())
            self.assertFalse((home / "hermes.log").exists())

    def test_no_pisa_un_perfil_existente(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "profiles" / "resumen-mercados").mkdir(parents=True)
            spec = home / "spec.json"
            spec.write_text(spec_text(), encoding="utf-8")
            env = {**os.environ, "HERMES_HOME": str(home), "HERMES_BIN": "/bin/false"}
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(spec)],
                capture_output=True, text=True, env=env,
            )
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])
            self.assertIn("Ya existe", payload["error"])
            self.assertEqual(result.returncode, 1)


class Create(unittest.TestCase):
    def test_crea_con_hermes_falso_y_hace_humo(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            spec = home / "spec.json"
            spec.write_text(spec_text(), encoding="utf-8")
            wrapper = home / "hermes"
            wrapper.write_text(
                "#!/bin/sh\n" + f'exec "{sys.executable}" "{FAKE}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            env = {**os.environ, "HERMES_HOME": str(home), "HERMES_BIN": str(wrapper)}
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(spec)],
                capture_output=True, text=True, env=env,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"], payload)
            checks = payload["comprobaciones"]
            self.assertTrue(checks["perfil_creado"])
            self.assertTrue(checks["ejemplos"])
            self.assertTrue(checks["humo"])
            self.assertTrue(checks["herramienta_preguntas"])
            soul = (home / "profiles" / "resumen-mercados" / "SOUL.md").read_text(encoding="utf-8")
            self.assertIn("## Ejemplos", soul)
            log = (home / "hermes.log").read_text(encoding="utf-8")
            self.assertIn("profile create", log)
            self.assertIn("-z", log)

    def test_sin_humo_omite_la_pregunta(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            spec = home / "spec.json"
            spec.write_text(spec_text(), encoding="utf-8")
            wrapper = home / "hermes"
            wrapper.write_text(
                "#!/bin/sh\n" + f'exec "{sys.executable}" "{FAKE}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            env = {**os.environ, "HERMES_HOME": str(home), "HERMES_BIN": str(wrapper)}
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(spec), "--sin-humo"],
                capture_output=True, text=True, env=env, check=True,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"], payload)
            self.assertNotIn("humo", payload["comprobaciones"])
            log = (home / "hermes.log").read_text(encoding="utf-8")
            self.assertNotIn("-z", log)


if __name__ == "__main__":
    unittest.main()
