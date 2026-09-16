#!/usr/bin/env python3
"""Pruebas de aplicar_estilo.py y de with_style contra un HERMES_HOME temporal:
nunca tocan el Hermes real.

    python3 prueba_estilo.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "forja" / "skill" / "forja-crear-agentes" / "scripts"))

import aplicar_estilo  # noqa: E402
from crear_agente import with_style  # noqa: E402

BLOCK = aplicar_estilo.STYLE.read_text(encoding="utf-8").strip()


class Estilo(unittest.TestCase):
    def test_la_guia_va_justo_despues_del_titulo(self):
        soul = "# Radar\n\nEres Radar.\n\n## Reglas\n- Una.\n"
        out = aplicar_estilo.styled(soul, BLOCK)
        lines = out.splitlines()
        self.assertEqual(lines[0], "# Radar")
        self.assertEqual(lines[2], aplicar_estilo.START)
        self.assertLess(out.index("Cómo se ven tus mensajes"), out.index("Eres Radar."))
        self.assertIn("## Reglas\n- Una.", out)

    def test_una_guia_vieja_al_final_se_mueve_arriba_y_se_sustituye(self):
        soul = ("# Radar\n\nEres Radar.\n\n" + aplicar_estilo.START + "\nVIEJO\n"
                + aplicar_estilo.END + "\n")
        out = aplicar_estilo.styled(soul, BLOCK)
        self.assertNotIn("VIEJO", out)
        self.assertEqual(out.count(aplicar_estilo.START), 1)
        self.assertLess(out.index(aplicar_estilo.START), out.index("Eres Radar."))
        self.assertTrue(out.rstrip().endswith("Eres Radar."))

    def test_es_idempotente(self):
        soul = "# Radar\n\nEres Radar.\n"
        once = aplicar_estilo.styled(soul, BLOCK)
        self.assertEqual(aplicar_estilo.styled(once, BLOCK), once)

    def test_sin_titulo_va_al_principio(self):
        out = aplicar_estilo.styled("Eres Radar.\n", BLOCK)
        self.assertTrue(out.startswith(aplicar_estilo.START))
        self.assertTrue(out.rstrip().endswith("Eres Radar."))

    def test_forja_pone_la_guia_igual_y_no_la_duplica(self):
        soul = "# Nuevo\n\nHaces cosas.\n"
        out = with_style(soul)
        self.assertEqual(out.rstrip("\n"), aplicar_estilo.styled(soul, BLOCK).rstrip("\n"))
        self.assertEqual(with_style(out), out)

    def test_el_programa_respeta_hermes_home_y_comprobar_no_escribe(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "SOUL.md").write_text("# Alice\n\nHola.\n", encoding="utf-8")
            (home / "profiles" / "radar").mkdir(parents=True)
            (home / "profiles" / "radar" / "SOUL.md").write_text("# Radar\n\nEres Radar.\n", encoding="utf-8")
            env = {**os.environ, "HERMES_HOME": tmp}
            check = subprocess.run([sys.executable, str(HERE / "aplicar_estilo.py"), "--comprobar"],
                                   capture_output=True, text=True, env=env, check=True)
            self.assertEqual(json.loads(check.stdout)["cambian"], ["alice", "radar"])
            self.assertNotIn(aplicar_estilo.START, (home / "SOUL.md").read_text(encoding="utf-8"))
            apply = subprocess.run([sys.executable, str(HERE / "aplicar_estilo.py")],
                                   capture_output=True, text=True, env=env, check=True)
            self.assertEqual(json.loads(apply.stdout)["cambian"], ["alice", "radar"])
            again = subprocess.run([sys.executable, str(HERE / "aplicar_estilo.py"), "--comprobar"],
                                   capture_output=True, text=True, env=env, check=True)
            self.assertEqual(json.loads(again.stdout)["cambian"], [])
            self.assertIn("trompicones", (home / "profiles" / "radar" / "SOUL.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
