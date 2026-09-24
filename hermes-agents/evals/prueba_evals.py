#!/usr/bin/env python3
"""Pruebas de evals.py contra un Hermes falso: nunca llama al Hermes real.

    ~/.hermes/hermes-agent/venv/bin/python prueba_evals.py
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
TOOL = HERE / "evals.py"

FAKE_HERMES = textwrap.dedent('''\
    #!{python}
    import json, os, sys
    from pathlib import Path
    import yaml
    args = sys.argv[1:]
    profile = "default"
    if args[:1] == ["-p"]:
        profile, args = args[1], args[2:]
    home = Path(os.environ["EVALS_HERMES_HOME"])
    log = home / "llamadas.jsonl"
    with log.open("a") as handle:
        handle.write(json.dumps({{"perfil": profile, "args": args}}) + "\\n")
    if args[:2] == ["config", "set"]:
        key, value = args[2], args[3]
        path = (home if profile == "default" else home / "profiles" / profile) / "config.yaml"
        cfg = yaml.safe_load(path.read_text()) or {{}}
        node = cfg
        parts = key.split(".")
        for part in parts[:-1]:
            node = node.setdefault(part, {{}})
        node[parts[-1]] = value
        path.write_text(yaml.safe_dump(cfg))
        sys.exit(0)
    if "-z" in args:
        prompt = args[args.index("-z") + 1]
        model = args[args.index("-m") + 1] if "-m" in args else "modelo-base"
        usage = args[args.index("--usage-file") + 1]
        Path(usage).write_text(json.dumps({{"estimated_cost_usd": 0.02, "input_tokens": 100,
                                            "output_tokens": 20, "model": model}}))
        if profile == "evals":
            print('Veredicto: {{"calidad": 8, "afirmaciones": 4, "alucinaciones": 1, "formato_ok": true, "escalado_ok": null, "comentario": "bien"}}')
        elif "quien" in prompt:
            import time
            soul = (home / "profiles" / profile / "SOUL.md").read_text()
            time.sleep(0.3)
            print(soul + "|" + (home / "profiles" / profile / "SOUL.md").read_text())
        elif "falla" in prompt:
            sys.exit(3)
        else:
            print("**Titular**\\nUna frase.\\nhttps://example.com")
        sys.exit(0)
    sys.exit(9)
''')


def run(env: dict, *args) -> dict:
    proc = subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, env=env)
    try:
        return json.loads(proc.stdout)
    except ValueError:
        raise AssertionError(f"Salida no JSON: {proc.stdout}\n{proc.stderr}")


def write_yaml(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data))


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        home, evals_dir = root / "hermes", root / "evals"
        fake = root / "hermes-falso"
        fake.write_text(FAKE_HERMES.format(python=sys.executable))
        fake.chmod(0o755)
        env = dict(os.environ, EVALS_HERMES_HOME=str(home), EVALS_DIR=str(evals_dir), EVALS_HERMES_BIN=str(fake))

        write_yaml(home / "config.yaml", {"model": {"default": "grok", "provider": "openrouter"}})
        (home / "SOUL.md").write_text("Alice")
        demo = home / "profiles" / "radar"
        write_yaml(demo / "config.yaml", {
            "model": {"default": "muse", "provider": "opencode-free", "base_url": ""},
            "fallback_providers": [{"provider": "openai-codex", "model": "luna", "base_url": "https://codex.example"}],
            "platform_toolsets": {"cli": ["web", "file"]},
        })
        (demo / "SOUL.md").write_text("Eres Radar.")
        (demo / "skills" / "noticias").mkdir(parents=True)
        (demo / "skills" / "noticias" / "SKILL.md").write_text("skill")
        (demo / "memories").mkdir()
        (demo / "memories" / "MEMORY.md").write_text("recuerdo")
        write_yaml(home / "profiles" / "evals" / "config.yaml", {"model": {"default": "luna", "provider": "openai-codex"}})
        sandbox = home / "profiles" / "evals-sandbox"
        write_yaml(sandbox / "config.yaml", {"model": {"default": "otro"}, "platform_toolsets": {"cli": ["web"]}})
        (home / "profiles" / ".deleted").mkdir()
        (home / "profiles" / "biz-director").mkdir()
        (home / "provider_models_cache.json").write_text(json.dumps({
            "openrouter": {"at": 1789500000, "models": ["a", "b"]},
            "opencode-free": {"at": 1789500000, "models": [{"id": "muse"}]},
        }))

        # Fingerprints: every agent is new. The sandbox, a leftover `.deleted`
        # folder and a half-removed profile without config.yaml are not agents.
        first = run(env, "huella", "--guardar")
        assert {c["agente"] for c in first["cambiados"]} == {"default", "radar", "evals"}, first
        assert run(env, "huella")["cambiados"] == []
        (demo / "SOUL.md").write_text("Eres Radar, mejor.")
        changed = run(env, "huella")["cambiados"]
        assert changed == [{"agente": "radar", "motivos": ["instrucciones"], "tiene_suite": False}], changed
        run(env, "huella", "--guardar")
        (demo / "memories" / "MEMORY.md").write_text("otro recuerdo")
        memory = run(env, "huella")
        assert memory["cambiados"] == [] and memory["memoria_pospuesta"] == ["radar"], memory

        # Models: the first review reports nothing new, the next one does.
        assert run(env, "modelos", "--nuevos", "--guardar")["primera_revision"] is True
        cache = json.loads((home / "provider_models_cache.json").read_text())
        cache["openrouter"]["models"].append("c")
        (home / "provider_models_cache.json").write_text(json.dumps(cache))
        assert run(env, "modelos", "--nuevos")["nuevos"] == [{"proveedor": "openrouter", "modelo": "c"}]

        # Running: without a suite it refuses; with one it runs in the sandbox only.
        assert run(env, "ejecutar", "radar")["ok"] is False
        suite = {"agente": "radar", "toolsets": ["web", "terminal", "file"], "rubrica": "Exacto y con fuente.",
                 "tareas": [
                     {"id": "normal", "prompt": "Noticias de hoy", "comprobaciones": {"regex": ["^\\*\\*"], "max_lineas": 3}},
                     {"id": "rota", "prompt": "Esto falla"},
                 ]}
        (evals_dir / "radar").mkdir(parents=True)
        (evals_dir / "radar" / "suite.json").write_text(json.dumps(suite))
        result = run(env, "ejecutar", "radar", "--repeticiones", "2")
        summary = result["resumen"]
        assert result["ok"] and summary["ejecuciones"] == 4 and summary["fiabilidad"] == 0.5, summary
        assert summary["comprobaciones"] == 1.0 and summary["toolsets"] == ["web"], summary
        assert summary["herramientas_descartadas"] == ["terminal", "file"], summary
        assert summary["modelo"] == "muse" and summary["coste_medio_usd"] == 0.02, summary
        assert (sandbox / "SOUL.md").read_text() == "Eres Radar, mejor."

        assert (sandbox / "memories" / "MEMORY.md").read_text() == "otro recuerdo"
        assert yaml.safe_load((sandbox / "config.yaml").read_text())["model"]["default"] == "muse"
        calls = [json.loads(l) for l in (home / "llamadas.jsonl").read_text().splitlines()]
        assert all(c["perfil"] == "evals-sandbox" for c in calls), calls
        assert all(c["args"][c["args"].index("-t") + 1] == "web" for c in calls)

        # Judging: another model judges; the same model is refused.
        results = result["resultados"]
        judged = run(env, "juzgar", results)
        assert judged["ok"] and judged["juzgadas"] == 2, judged
        assert judged["resumen"]["calidad_media"] == 8.0 and judged["resumen"]["alucinacion"] == 0.25, judged
        candidate = run(env, "ejecutar", "radar", "--modelo", "luna", "--proveedor", "openai-codex", "--tareas", "normal")
        refused = run(env, "juzgar", candidate["resultados"])
        assert refused["ok"] is False and "mismo modelo" in refused["error"], refused

        # Scoreboard: both models, the current one marked.
        board = run(env, "marcador", "radar")
        text = Path(board["marcador"]).read_text()
        assert board["modelos"] == 2 and "muse (opencode-free) · actual" in text and "8.0/10" in text, text

        # Routing: apply with a backup and the provider's known base URL, then revert.
        applied = run(env, "aplicar", "radar", "--modelo", "luna", "--proveedor", "openai-codex")
        cfg = yaml.safe_load((demo / "config.yaml").read_text())
        assert applied["ok"] and cfg["model"] == {"default": "luna", "provider": "openai-codex",
                                                 "base_url": "https://codex.example"}, cfg
        reverted = run(env, "revertir", "radar")
        cfg = yaml.safe_load((demo / "config.yaml").read_text())
        assert reverted["ok"] and cfg["model"]["default"] == "muse" and cfg["model"]["provider"] == "opencode-free", cfg
        assert "revertido" in (evals_dir / "radar" / "historial.md").read_text()

        # Two suites at once take turns: neither syncs the sandbox over the other mid-run.
        (evals_dir / "default").mkdir(exist_ok=True)
        for agent in ("radar", "default"):
            (evals_dir / agent / "suite.json").write_text(json.dumps(
                {"tareas": [{"id": f"quien-{n}", "prompt": "quien eres"} for n in range(3)]}))
        procs = [subprocess.Popen([sys.executable, str(TOOL), "ejecutar", agent], stdout=subprocess.PIPE,
                                  text=True, env=env) for agent in ("radar", "default")]
        for proc, soul in zip(procs, ("Eres Radar, mejor.", "Alice")):
            out = json.loads(proc.communicate()[0])
            assert out["ok"], out
            rows = [json.loads(line) for line in Path(out["resultados"]).read_text().splitlines()]
            assert [r["salida"] for r in rows] == [f"{soul}|{soul}"] * 3, rows

    print("ok: evals.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
