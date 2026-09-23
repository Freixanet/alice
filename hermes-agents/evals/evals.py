#!/usr/bin/env python3
"""Evals: benchmarks propios para saber si cada agente hace bien su trabajo.

Con el Python de Hermes:

    python evals.py huella [--guardar]
    python evals.py modelos [--nuevos] [--guardar]
    python evals.py ejecutar AGENTE [--modelo M --proveedor P] [--repeticiones N] [--limite K]
                                    [--tareas id,id] [--timeout S]
    python evals.py juzgar RESULTADOS.jsonl [--modelo M --proveedor P] [--permitir-mismo-modelo]
    python evals.py marcador AGENTE
    python evals.py aplicar AGENTE --modelo M --proveedor P
    python evals.py revertir AGENTE

Cada agente tiene su carpeta en ~/hermes-workspaces/evals/<agente>/: suite.json,
resultados/, marcador.md, copias/ e historial.md. Las tareas se ejecutan siempre
en el perfil de pruebas `evals-sandbox`, sincronizado antes con las instrucciones,
el modelo, las skills y la memoria del agente, y solo con herramientas que no
escriben archivos, usan el terminal ni programan rutinas: una evaluación nunca
toca el agente real. El juez es el perfil `evals`, con un modelo distinto al
evaluado. Todo comando imprime un JSON.

Variables para pruebas: EVALS_HERMES_HOME, EVALS_DIR, EVALS_HERMES_BIN y
EVALS_EUR_POR_USD (el coste que da Hermes es en dólares; el cambio es aproximado).
"""
import fcntl
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

import yaml

HOME = Path(os.environ.get("EVALS_HERMES_HOME") or Path.home() / ".hermes")
EVALS_DIR = Path(os.environ.get("EVALS_DIR") or Path.home() / "hermes-workspaces" / "evals")
HERMES_BIN = os.environ.get("EVALS_HERMES_BIN") or str(HOME / "hermes-agent" / "venv" / "bin" / "hermes")
EUR_PER_USD = float(os.environ.get("EVALS_EUR_POR_USD") or 0.92)

SANDBOX = "evals-sandbox"
JUDGE = "evals"
# Hermes profile names, the same shape Forja accepts. Leftovers such as
# `.deleted` or a half-removed folder without config.yaml are not agents.
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
# What an evaluation may use: nothing that writes files, runs commands, schedules
# work, remembers or talks to other agents.
SAFE_TOOLSETS = {"web", "browser", "skills", "todo", "vision", "session_search"}
DEFAULT_TOOLSETS = ["web", "browser", "skills", "todo"]
MEMORY_MIN_DAYS = 7
SYNCED_CONFIG_KEYS = ("model", "fallback_providers", "agent")


class Fallo(Exception):
    pass


# ---------------------------------------------------------------- basics

def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def profile_dir(name: str) -> Path:
    return HOME if name == "default" else HOME / "profiles" / name


def profile_args(name: str) -> list:
    return [] if name == "default" else ["-p", name]


def agents() -> list:
    profiles = HOME / "profiles"
    named = []
    if profiles.is_dir():
        for path in sorted(profiles.iterdir()):
            if not path.is_dir() or path.name == SANDBOX:
                continue
            if not PROFILE_NAME.fullmatch(path.name):
                continue
            if not (path / "config.yaml").is_file():
                continue
            named.append(path.name)
    return ["default"] + named


def load_yaml(path: Path) -> dict:
    if not path.is_file():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else {}


def write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        handle.write(text)
        tmp = handle.name
    os.replace(tmp, path)


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (text or "actual").lower()).strip("-") or "actual"


def agent_dir(agent: str) -> Path:
    return EVALS_DIR / agent


def current_model(agent: str) -> dict:
    model = load_yaml(profile_dir(agent) / "config.yaml").get("model") or {}
    if isinstance(model, str):
        return {"modelo": model, "proveedor": ""}
    return {"modelo": model.get("default") or "", "proveedor": model.get("provider") or ""}


# ---------------------------------------------------------------- fingerprints

def _hash_tree(root: Path) -> str:
    digest = hashlib.sha256()
    if root.is_dir():
        for path in sorted(root.rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts and path.stat().st_size <= 2_000_000:
                digest.update(str(path.relative_to(root)).encode())
                digest.update(path.read_bytes())
    return digest.hexdigest()[:16]


def _hash_value(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()[:16]


def fingerprint(agent: str) -> dict:
    base = profile_dir(agent)
    cfg = load_yaml(base / "config.yaml")
    soul = base / "SOUL.md"
    return {
        "instrucciones": _hash_value(soul.read_text(encoding="utf-8") if soul.is_file() else ""),
        "modelo": _hash_value([cfg.get("model"), cfg.get("fallback_providers")]),
        "herramientas": _hash_value(cfg.get("platform_toolsets")),
        "skills": _hash_tree(base / "skills"),
        "memoria": _hash_tree(base / "memories"),
    }


def cmd_huella(args: dict) -> dict:
    store_path = EVALS_DIR / "huellas.json"
    stored = load_json(store_path, {})
    changed, postponed, current = [], [], {}
    for agent in agents():
        fp = fingerprint(agent)
        current[agent] = fp
        before = stored.get(agent)
        suite = (agent_dir(agent) / "suite.json").is_file()
        if before is None:
            changed.append({"agente": agent, "motivos": ["nuevo"], "tiene_suite": suite})
            continue
        reasons = [key for key, value in fp.items() if before.get(key) != value]
        if reasons == ["memoria"]:
            last = before.get("memoria_evaluada")
            if last and datetime.fromisoformat(last) > datetime.now() - timedelta(days=MEMORY_MIN_DAYS):
                postponed.append(agent)
                continue
        if reasons:
            changed.append({"agente": agent, "motivos": reasons, "tiene_suite": suite})

    if args.get("guardar"):
        postponed_set = set(postponed)
        saved = {}
        for agent, fp in current.items():
            before = stored.get(agent) or {}
            record = dict(fp)
            record["memoria_evaluada"] = before.get("memoria_evaluada")
            if agent in postponed_set:
                record["memoria"] = before.get("memoria")
            elif before.get("memoria") != fp["memoria"] or not before:
                record["memoria_evaluada"] = now()
            saved[agent] = record
        write_text_atomic(store_path, json.dumps(saved, ensure_ascii=False, indent=2))
    return {"ok": True, "cambiados": changed, "memoria_pospuesta": postponed, "guardado": bool(args.get("guardar"))}


# ---------------------------------------------------------------- models

def cmd_modelos(args: dict) -> dict:
    cache = load_json(HOME / "provider_models_cache.json", {})
    if not cache:
        raise Fallo("No hay lista de modelos en caché. Abre `hermes model` una vez para que Hermes la descargue.")
    available, oldest = [], None
    for provider, entry in sorted(cache.items()):
        if not isinstance(entry, dict):
            continue
        at = entry.get("at")
        if isinstance(at, (int, float)):
            oldest = at if oldest is None else min(oldest, at)
        for model in entry.get("models") or []:
            model_id = model.get("id") if isinstance(model, dict) else model
            if isinstance(model_id, str) and model_id:
                available.append({"proveedor": provider, "modelo": model_id})
    seen_path = EVALS_DIR / "modelos-vistos.json"
    seen = {(m["proveedor"], m["modelo"]) for m in load_json(seen_path, [])}
    result = {"ok": True, "total": len(available),
              "cache_horas": round((time.time() - oldest) / 3600, 1) if oldest else None}
    if args.get("nuevos"):
        result["nuevos"] = [m for m in available if (m["proveedor"], m["modelo"]) not in seen] if seen else []
        result["primera_revision"] = not seen
    else:
        result["modelos"] = available
    if args.get("guardar"):
        write_text_atomic(seen_path, json.dumps(available, ensure_ascii=False, indent=2))
        result["guardado"] = True
    return result


# ---------------------------------------------------------------- sandbox

def _replace_tree(source: Path, target: Path) -> None:
    fresh = target.parent / f".{target.name}.nuevo"
    stale = target.parent / f".{target.name}.viejo"
    for leftover in (fresh, stale):
        if leftover.exists():
            shutil.rmtree(leftover)
    if source.is_dir():
        shutil.copytree(source, fresh, ignore=shutil.ignore_patterns("__pycache__"))
    else:
        fresh.mkdir(parents=True)
    if target.exists():
        target.rename(stale)
    fresh.rename(target)
    if stale.exists():
        shutil.rmtree(stale)


def sync_sandbox(agent: str) -> None:
    """The sandbox takes the agent's instructions, model, skills and memory, so
    what is measured is that agent; nothing flows back."""
    source, sandbox = profile_dir(agent), profile_dir(SANDBOX)
    if not sandbox.is_dir():
        raise Fallo(f"No existe el perfil de pruebas `{SANDBOX}`. Ejecuta el instalador del equipo.")
    if not source.is_dir():
        raise Fallo(f"No existe el agente `{agent}`.")
    soul = source / "SOUL.md"
    write_text_atomic(sandbox / "SOUL.md", soul.read_text(encoding="utf-8") if soul.is_file() else "")
    source_cfg, sandbox_cfg = load_yaml(source / "config.yaml"), load_yaml(sandbox / "config.yaml")
    for key in SYNCED_CONFIG_KEYS:
        if key in source_cfg:
            sandbox_cfg[key] = source_cfg[key]
        else:
            sandbox_cfg.pop(key, None)
    write_text_atomic(sandbox / "config.yaml", yaml.safe_dump(sandbox_cfg, sort_keys=False, allow_unicode=True))
    for folder in ("skills", "memories"):
        _replace_tree(source / folder, sandbox / folder)


# ---------------------------------------------------------------- running

def run_hermes(profile: str, prompt: str, toolsets: list, model: str, provider: str, timeout: int) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        usage_path = Path(tmp) / "uso.json"
        command = [HERMES_BIN, *profile_args(profile), "-z", prompt, "--usage-file", str(usage_path),
                   "-t", ",".join(toolsets)]
        if model:
            command += ["-m", model]
        if provider:
            command += ["--provider", provider]
        started = time.monotonic()
        try:
            proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
            code, out, err = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            code, out, err = None, "", f"Sin respuesta en {timeout} s"
        latency = round(time.monotonic() - started, 2)
        usage = load_json(usage_path, {})
    return {"codigo": code, "salida": out.strip(), "error": err.strip()[-500:] if code != 0 else "",
            "latencia_s": latency, "uso": usage}


def run_checks(output: str, checks: dict) -> list:
    results = []
    lines = [line for line in output.splitlines() if line.strip()]
    for text in checks.get("contiene") or []:
        results.append({"comprobacion": f"contiene «{text}»", "ok": text in output})
    for text in checks.get("no_contiene") or []:
        results.append({"comprobacion": f"no contiene «{text}»", "ok": text not in output})
    for pattern in checks.get("regex") or []:
        try:
            ok = re.search(pattern, output, re.MULTILINE) is not None
        except re.error:
            ok = False
        results.append({"comprobacion": f"regex {pattern}", "ok": ok})
    if "min_lineas" in checks:
        results.append({"comprobacion": f"al menos {checks['min_lineas']} líneas", "ok": len(lines) >= checks["min_lineas"]})
    if "max_lineas" in checks:
        results.append({"comprobacion": f"como mucho {checks['max_lineas']} líneas", "ok": len(lines) <= checks["max_lineas"]})
    if "max_caracteres" in checks:
        results.append({"comprobacion": f"como mucho {checks['max_caracteres']} caracteres",
                        "ok": len(output) <= checks["max_caracteres"]})
    if "silencio" in checks:
        silent = output.strip() == "[SILENT]"
        results.append({"comprobacion": "responde [SILENT]" if checks["silencio"] else "no responde [SILENT]",
                        "ok": silent if checks["silencio"] else not silent})
    return results


def load_suite(agent: str) -> dict:
    path = agent_dir(agent) / "suite.json"
    suite = load_json(path, None)
    if not isinstance(suite, dict) or not isinstance(suite.get("tareas"), list) or not suite["tareas"]:
        raise Fallo(f"`{path}` no existe o no tiene tareas.")
    for task in suite["tareas"]:
        if not isinstance(task, dict) or not str(task.get("id") or "").strip() or not str(task.get("prompt") or "").strip():
            raise Fallo("Cada tarea necesita `id` y `prompt`.")
    return suite


@contextmanager
def sandbox_turn():
    """One suite at a time: the sandbox holds a single agent's instructions, so a
    second run waits here instead of syncing over the first one mid-suite."""
    EVALS_DIR.mkdir(parents=True, exist_ok=True)
    with open(EVALS_DIR / ".sandbox.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def cmd_ejecutar(args: dict) -> dict:
    with sandbox_turn():
        return run_suite(args)


def run_suite(args: dict) -> dict:
    agent = args["posicional"]
    suite = load_suite(agent)
    requested = [t for t in (suite.get("toolsets") or DEFAULT_TOOLSETS)]
    toolsets = [t for t in requested if t in SAFE_TOOLSETS] or DEFAULT_TOOLSETS
    tasks = suite["tareas"]
    if args.get("tareas"):
        wanted = set(args["tareas"].split(","))
        tasks = [t for t in tasks if t["id"] in wanted]
    if args.get("limite"):
        tasks = tasks[: int(args["limite"])]
    repeats = max(1, int(args.get("repeticiones") or 1))
    timeout = int(args.get("timeout") or 600)
    model, provider = args.get("modelo") or "", args.get("proveedor") or ""
    if provider and not model:
        raise Fallo("`--proveedor` necesita `--modelo`.")

    sync_sandbox(agent)
    incumbent = current_model(SANDBOX)
    evaluated = {"modelo": model or incumbent["modelo"], "proveedor": provider or incumbent["proveedor"]}
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = agent_dir(agent) / "resultados"
    results_path = out_dir / f"{stamp}-{slug(evaluated['modelo'])}.jsonl"
    records = []
    for task in tasks:
        for repeat in range(1, repeats + 1):
            run = run_hermes(SANDBOX, task["prompt"], toolsets, model, provider, timeout)
            usage = run["uso"]
            records.append({
                "tarea": task["id"], "repeticion": repeat, "etiquetas": task.get("etiquetas") or [],
                "modelo": evaluated["modelo"], "proveedor": evaluated["proveedor"],
                "prompt": task["prompt"], "esperado": task.get("esperado") or "",
                "rubrica": task.get("rubrica") or suite.get("rubrica") or "",
                "salida": run["salida"], "valida": run["codigo"] == 0 and bool(run["salida"]),
                "codigo": run["codigo"], "error": run["error"], "latencia_s": run["latencia_s"],
                "coste_usd": usage.get("estimated_cost_usd"), "tokens_entrada": usage.get("input_tokens"),
                "tokens_salida": usage.get("output_tokens"), "modelo_real": usage.get("model"),
                "comprobaciones": run_checks(run["salida"], task.get("comprobaciones") or {}),
                "fecha": now(),
            })
    write_records(results_path, records)
    summary = summarize(records)
    summary.update({"agente": agent, "archivo": results_path.name, "toolsets": toolsets,
                    "herramientas_descartadas": [t for t in requested if t not in SAFE_TOOLSETS], **evaluated})
    write_text_atomic(results_path.with_suffix(".resumen.json"), json.dumps(summary, ensure_ascii=False, indent=2))
    return {"ok": True, "resultados": str(results_path), "resumen": summary}


def write_records(path: Path, records: list) -> None:
    write_text_atomic(path, "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records))


def read_records(path: Path) -> list:
    if not path.is_file():
        raise Fallo(f"No existe `{path}`.")
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _mean(values: list):
    values = [v for v in values if isinstance(v, (int, float))]
    return round(statistics.fmean(values), 4) if values else None


def summarize(records: list) -> dict:
    total = len(records)
    checks = [c["ok"] for r in records for c in r.get("comprobaciones") or []]
    latencies = sorted(r["latencia_s"] for r in records if isinstance(r.get("latencia_s"), (int, float)))
    cost = _mean([r.get("coste_usd") for r in records])
    summary = {
        "tareas": len({r["tarea"] for r in records}), "ejecuciones": total,
        "fiabilidad": round(sum(1 for r in records if r.get("valida")) / total, 4) if total else None,
        "comprobaciones": round(sum(checks) / len(checks), 4) if checks else None,
        "coste_medio_usd": cost, "coste_medio_eur": round(cost * EUR_PER_USD, 4) if cost is not None else None,
        "latencia_media_s": _mean(latencies),
        "latencia_p90_s": latencies[min(len(latencies) - 1, int(len(latencies) * 0.9))] if latencies else None,
        "fecha": now(),
    }
    judged = [r["juicio"] for r in records if isinstance(r.get("juicio"), dict)]
    if judged:
        scores = [j["calidad"] for j in judged]
        claims = sum(j.get("afirmaciones") or 0 for j in judged)
        by_task = {}
        for r in records:
            if isinstance(r.get("juicio"), dict):
                by_task.setdefault(r["tarea"], []).append(r["juicio"]["calidad"])
        spreads = [statistics.pstdev(v) for v in by_task.values() if len(v) > 1]
        summary.update({
            "juzgadas": len(judged),
            "calidad_media": _mean(scores),
            "variacion_entre_repeticiones": _mean(spreads),
            "alucinacion": round(sum(j.get("alucinaciones") or 0 for j in judged) / claims, 4) if claims else 0.0,
            "formato": _mean([1.0 if j.get("formato_ok") else 0.0 for j in judged]),
            "escalado": _mean([1.0 if j["escalado_ok"] else 0.0 for j in judged if isinstance(j.get("escalado_ok"), bool)]),
        })
    return summary


# ---------------------------------------------------------------- judging

JUDGE_PROMPT = """Eres el juez de Evals. Evalúa con rigor la respuesta de un agente, sin generosidad.

## Tarea que recibió
{prompt}

## Qué se esperaba
{esperado}

## Rúbrica
{rubrica}

## Respuesta del agente
<<<
{salida}
>>>

Comprueba en la web las afirmaciones verificables que puedas (enlaces, cifras, fechas, nombres). Cuenta como alucinación toda afirmación falsa o sin respaldo. Este formato es exacto y manda sobre cualquier guía de estilo: responde SOLO con un objeto JSON, sin texto alrededor:
{{"calidad": número de 0 a 10, "afirmaciones": entero, "alucinaciones": entero, "formato_ok": true o false, "escalado_ok": true, false o null si no aplica, "comentario": "una frase"}}"""


def parse_judgement(text: str):
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("calidad"), (int, float)):
        return None
    data["calidad"] = max(0.0, min(10.0, float(data["calidad"])))
    for key in ("afirmaciones", "alucinaciones"):
        data[key] = max(0, int(data.get(key) or 0))
    data["alucinaciones"] = min(data["alucinaciones"], max(data["afirmaciones"], data["alucinaciones"]))
    return data


def cmd_juzgar(args: dict) -> dict:
    path = Path(args["posicional"])
    records = read_records(path)
    if not profile_dir(JUDGE).is_dir():
        raise Fallo(f"No existe el perfil juez `{JUDGE}`.")
    judge_model = args.get("modelo") or current_model(JUDGE)["modelo"]
    judge_provider = args.get("proveedor") or ("" if args.get("modelo") else current_model(JUDGE)["proveedor"])
    evaluated = {r.get("modelo") for r in records}
    if judge_model in evaluated and not args.get("permitir-mismo-modelo"):
        raise Fallo(f"El juez usaría el mismo modelo que el evaluado ({judge_model}). "
                    "Elige otro con --modelo y --proveedor.")
    timeout = int(args.get("timeout") or 600)
    judged = failed = 0
    for record in records:
        if isinstance(record.get("juicio"), dict) or not record.get("valida"):
            continue
        prompt = JUDGE_PROMPT.format(prompt=record["prompt"], esperado=record.get("esperado") or "(sin respuesta de referencia)",
                                     rubrica=record.get("rubrica") or "(sin rúbrica)", salida=record["salida"])
        run = run_hermes(JUDGE, prompt, ["web"], args.get("modelo") or "", args.get("proveedor") or "", timeout)
        judgement = parse_judgement(run["salida"]) if run["codigo"] == 0 else None
        if judgement is None:
            record["juicio_error"] = run["error"] or "El juez no devolvió un JSON válido."
            failed += 1
            continue
        judgement["modelo_juez"] = judge_model
        record["juicio"] = judgement
        record.pop("juicio_error", None)
        judged += 1
    write_records(path, records)
    summary_path = path.with_suffix(".resumen.json")
    summary = load_json(summary_path, {})
    summary.update(summarize(records))
    summary.update({"modelo_juez": judge_model, "proveedor_juez": judge_provider})
    write_text_atomic(summary_path, json.dumps(summary, ensure_ascii=False, indent=2))
    return {"ok": failed == 0, "juzgadas": judged, "fallidas": failed, "resumen": summary}


# ---------------------------------------------------------------- scoreboard

def _pct(value) -> str:
    return "—" if value is None else f"{value * 100:.1f} %"


def cmd_marcador(args: dict) -> dict:
    agent = args["posicional"]
    folder = agent_dir(agent) / "resultados"
    summaries = sorted((load_json(p, {}) for p in folder.glob("*.resumen.json")), key=lambda s: s.get("fecha") or "")
    latest = {}
    for summary in summaries:
        latest[(summary.get("modelo") or "", summary.get("proveedor") or "")] = summary
    current = current_model(agent)
    ranked = sorted(latest.values(), key=lambda s: (s.get("calidad_media") is None, -(s.get("calidad_media") or 0)))
    lines = [f"# Marcador · {agent}", "",
             f"*Modelo actual:* {current['modelo'] or '—'} ({current['proveedor'] or '—'}) · *Actualizado:* {now()[:16].replace('T', ' ')}",
             "", "| Modelo | Calidad | Alucinación | Formato | Escalado | Fiabilidad | Comprobaciones | Coste medio | Latencia | Tareas | Fecha |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for s in ranked:
        name = f"{s.get('modelo')} ({s.get('proveedor') or '—'})"
        if s.get("modelo") == current["modelo"] and (s.get("proveedor") or "") == current["proveedor"]:
            name += " · actual"
        quality = "—" if s.get("calidad_media") is None else f"{s['calidad_media']:.1f}/10"
        cost = "—" if s.get("coste_medio_eur") is None else f"{s['coste_medio_eur']:.4f} €"
        latency = "—" if s.get("latencia_media_s") is None else f"{s['latencia_media_s']:.1f} s"
        lines.append(f"| {name} | {quality} | {_pct(s.get('alucinacion'))} | {_pct(s.get('formato'))} | "
                     f"{_pct(s.get('escalado'))} | {_pct(s.get('fiabilidad'))} | {_pct(s.get('comprobaciones'))} | "
                     f"{cost} | {latency} | {s.get('tareas', '—')} | {(s.get('fecha') or '')[:10]} |")
    lines += ["", f"Coste en euros aproximado (1 USD = {EUR_PER_USD} €)."]
    path = agent_dir(agent) / "marcador.md"
    write_text_atomic(path, "\n".join(lines) + "\n")
    return {"ok": True, "marcador": str(path), "modelos": len(ranked), "actual": current}


# ---------------------------------------------------------------- routing

def _base_url_for(provider: str) -> str:
    """The base URL another profile already uses for this provider, if any."""
    configs = [HOME / "config.yaml"] + sorted((HOME / "profiles").glob("*/config.yaml"))
    for path in configs:
        cfg = load_yaml(path)
        entries = [cfg.get("model")] + list(cfg.get("fallback_providers") or [])
        for entry in entries:
            if isinstance(entry, dict) and entry.get("provider") == provider and entry.get("base_url"):
                return entry["base_url"]
    return ""


def _set_model(agent: str, model: str, provider: str, base_url: str) -> None:
    for key, value in (("model.default", model), ("model.provider", provider), ("model.base_url", base_url)):
        proc = subprocess.run([HERMES_BIN, *profile_args(agent), "config", "set", key, value],
                              capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise Fallo(f"`hermes config set {key}` falló: {(proc.stderr or proc.stdout).strip()[-300:]}")


def _log(agent: str, line: str) -> None:
    path = agent_dir(agent) / "historial.md"
    previous = path.read_text(encoding="utf-8") if path.is_file() else f"# Historial · {agent}\n\n"
    write_text_atomic(path, previous + f"- {now()[:16].replace('T', ' ')} · {line}\n")


def cmd_aplicar(args: dict) -> dict:
    agent, model, provider = args["posicional"], args.get("modelo"), args.get("proveedor")
    if not model or not provider:
        raise Fallo("`aplicar` necesita `--modelo` y `--proveedor`.")
    config = profile_dir(agent) / "config.yaml"
    if not config.is_file():
        raise Fallo(f"No existe el agente `{agent}`.")
    before = current_model(agent)
    backup = agent_dir(agent) / "copias" / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-config.yaml"
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(config, backup)
    base_url = _base_url_for(provider)
    _set_model(agent, model, provider, base_url)
    _log(agent, f"modelo {before['modelo']} ({before['proveedor']}) → {model} ({provider}) · copia {backup.name}")
    return {"ok": True, "antes": before, "ahora": current_model(agent), "copia": str(backup)}


def cmd_revertir(args: dict) -> dict:
    agent = args["posicional"]
    backups = sorted((agent_dir(agent) / "copias").glob("*-config.yaml"))
    if not backups:
        raise Fallo(f"No hay copias de `{agent}` para revertir.")
    saved = load_yaml(backups[-1]).get("model") or {}
    if not isinstance(saved, dict) or not saved.get("default"):
        raise Fallo("La copia no tiene un modelo legible.")
    before = current_model(agent)
    _set_model(agent, saved["default"], saved.get("provider") or "", saved.get("base_url") or "")
    _log(agent, f"revertido {before['modelo']} ({before['proveedor']}) → {saved['default']} ({saved.get('provider') or ''}) · desde {backups[-1].name}")
    return {"ok": True, "antes": before, "ahora": current_model(agent), "copia": str(backups[-1])}


# ---------------------------------------------------------------- cli

COMMANDS = {"huella": cmd_huella, "modelos": cmd_modelos, "ejecutar": cmd_ejecutar, "juzgar": cmd_juzgar,
            "marcador": cmd_marcador, "aplicar": cmd_aplicar, "revertir": cmd_revertir}
NEEDS_TARGET = {"ejecutar", "juzgar", "marcador", "aplicar", "revertir"}
FLAGS = {"guardar", "nuevos", "permitir-mismo-modelo"}


def parse(argv: list) -> tuple:
    if not argv or argv[0] not in COMMANDS:
        raise Fallo("Uso: evals.py {" + ",".join(COMMANDS) + "} …")
    command, args, rest = argv[0], {}, argv[1:]
    index = 0
    while index < len(rest):
        item = rest[index]
        if item.startswith("--"):
            key = item[2:]
            if key in FLAGS:
                args[key] = True
            else:
                if index + 1 >= len(rest):
                    raise Fallo(f"Falta el valor de {item}.")
                args[key] = rest[index + 1]
                index += 1
        elif "posicional" not in args:
            args["posicional"] = item
        else:
            raise Fallo(f"Argumento de más: {item}")
        index += 1
    if command in NEEDS_TARGET and "posicional" not in args:
        raise Fallo(f"`{command}` necesita un agente o un archivo.")
    return command, args


def main(argv: list) -> int:
    try:
        command, args = parse(argv)
        result = COMMANDS[command](args)
    except Fallo as exc:
        result = {"ok": False, "error": str(exc)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
