#!/usr/bin/env python3
"""Alice's QA, one entry point for any coding agent or person (docs/qa-protocol.md).

    python scripts/qa.py list                        # processes, their states, faults and gaps
    python scripts/qa.py coverage                    # the map against the code and the tests
    python scripts/qa.py run purchase                # every fault on every fixture shop, in jsdom
    python scripts/qa.py run purchase --level 2      # the shop engine and the gates in a real Chrome
    python scripts/qa.py fuzz purchase --seeds 50    # combinations; shrinks and writes the regression
    python scripts/qa.py static                      # fragility rules over the source
    python scripts/qa.py snapshots                   # regenerate the errand states iOS is tested against
    python scripts/qa.py all                         # coverage + static + run + fuzz (fixed seeds)

Writes qa/reports/<date>-<what>.json (for agents) and prints a summary ordered by severity.
Exit status: 0 when nothing new was found, 1 otherwise. Findings accepted on purpose live in
qa/known.yaml with a reason and a date; nothing is silenced in the code.

Nothing here touches a real Hermes, browser (port 9222), shop, account or payment. Level 3 (a real
model on fixture shops) and level 4 (a real shop up to the pay step) are manual and need the
person's explicit permission: they only print what to run.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import re
import subprocess
import sys
import time
import warnings
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / "qa"
PLUGIN = ROOT / "hermes-plugin"
sys.path.insert(0, str(PLUGIN / "qa"))
SEVERITY = ["I1", "I2", "I3", "I7", "I5", "I4", "P1", "I6", "I8", "HOOK", "FLOW", "SIM", "STATIC", "COVERAGE"]


def yaml_load(path: Path) -> Any:
    try:
        import yaml
    except ImportError:  # Hermes ships PyYAML; outside it, `pip install pyyaml`
        sys.exit("PyYAML is needed: pip install pyyaml (Hermes' own environment has it).")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def flows() -> Dict[str, Dict[str, Any]]:
    return {p.stem: yaml_load(p) for p in sorted((QA / "flows").glob("*.yaml"))}


def known() -> List[Dict[str, Any]]:
    path = QA / "known.yaml"
    data = yaml_load(path) if path.exists() else None
    return list((data or {}).get("known") or [])


def is_known(finding: Dict[str, Any], accepted: List[Dict[str, Any]]) -> bool:
    return any(k.get("invariant") == finding.get("invariant") and str(k.get("match") or "") in str(finding.get("detail"))
               for k in accepted)


def report(name: str, findings: List[Dict[str, Any]], extra: Dict[str, Any]) -> int:
    accepted = known()
    new = [f for f in findings if not is_known(f, accepted)]
    new.sort(key=lambda f: SEVERITY.index(f["invariant"]) if f.get("invariant") in SEVERITY else len(SEVERITY))
    (QA / "reports").mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = QA / "reports" / f"{stamp}-{name}.json"
    path.write_text(json.dumps({"what": name, "at": stamp, "new": new, "known": len(findings) - len(new), **extra},
                               ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\n{name}: {len(new)} hallazgo(s) nuevo(s), {len(findings) - len(new)} conocido(s). Informe: {path.relative_to(ROOT)}")
    for f in new[:40]:
        where = f.get("where") or f.get("event") or ""
        print(f"  [{f['invariant']}] {where} — {str(f.get('detail'))[:220]}")
    return 1 if new else 0


# ── list and coverage ─────────────────────────────────────────────────────────────

def cmd_list(_args) -> int:
    for name, flow in flows().items():
        faults = flow.get("faults") or {}
        gaps = [k for k, v in faults.items() if any(str(c).startswith("gap:") for c in v.get("covered") or [])]
        print(f"{name}: {flow.get('title')}")
        print(f"  estados {len(flow.get('states') or {})} · pasos {len(flow.get('steps') or [])} · "
              f"invariantes {len(flow.get('invariants') or {})} · fallos {len(faults)} · huecos {len(gaps)}")
        for gap in gaps:
            print(f"    hueco: {gap}")
    return 0


def _exists(ref: str) -> bool:
    """Whether a reference in a map still names something real."""
    ref = str(ref).strip()
    if ref.startswith("gap:"):
        return True
    if ref.startswith("sim:"):
        import sim
        name = ref[4:]
        return name == "happy" or name in sim.FAULTS
    if "::" in ref:
        file, name = ref.split("::", 1)
        path = ROOT / file
        return path.exists() and re.search(r"\b" + re.escape(name.split(".")[-1]) + r"\b", path.read_text(encoding="utf-8")) is not None
    kind, _, name = ref.partition(":")
    init = (PLUGIN / "__init__.py").read_text(encoding="utf-8")
    if kind == "tool":
        return re.search(r"name=[\"']" + re.escape(name) + r"[\"']|\('" + re.escape(name) + r"'", init) is not None
    if kind == "hook":
        return re.search(r"^def " + re.escape(name) + r"\(", init, re.M) is not None
    if kind == "route":
        api = (PLUGIN / "dashboard" / "plugin_api.py").read_text(encoding="utf-8")
        return re.search(re.escape(name.replace("{id}", "{errand_id}")) + r"[\"']", api) is not None
    if kind == "skill":
        return (PLUGIN / "skills" / name / "SKILL.md").exists()
    if "." in ref and "/" not in ref:
        module, attr = ref.split(".", 1)
        path = PLUGIN / (module + ".py")
        return path.exists() and re.search(r"^(def|class) " + re.escape(attr) + r"\b", path.read_text(encoding="utf-8"), re.M) is not None
    return (ROOT / ref).exists()


def coverage_findings() -> List[Dict[str, Any]]:
    findings = []
    for name, flow in flows().items():
        sections = [("state", k, v) for k, v in (flow.get("states") or {}).items()]
        sections += [("step", str(s.get("n")), s) for s in flow.get("steps") or []]
        sections += [("fault", k, v) for k, v in (flow.get("faults") or {}).items()]
        for kind, key, item in sections:
            covered = item.get("covered") or []
            if not covered:
                findings.append({"invariant": "COVERAGE", "where": f"{name}.{kind}.{key}", "detail": "sin cobertura ni hueco declarado"})
            for ref in list(covered) + list(item.get("implemented_by") or []):
                if not _exists(ref):
                    findings.append({"invariant": "COVERAGE", "where": f"{name}.{kind}.{key}", "detail": f"deriva: «{ref}» ya no existe"})
        if name == "purchase":
            # Every errand status and every purchase tool is in the map (nothing new left unmapped).
            errands_src = (PLUGIN / "errands.py").read_text(encoding="utf-8")
            statuses = re.search(r"^STATUSES = \(([^)]*)\)", errands_src, re.M)
            for status in re.findall(r'"([a-z_]+)"', statuses.group(1) if statuses else ""):
                if status not in (flow.get("states") or {}):
                    findings.append({"invariant": "COVERAGE", "where": f"{name}.states", "detail": f"estado «{status}» del recado sin mapear"})
            mapped = json.dumps(flow, ensure_ascii=False)
            for tool in ("purchase_discover", "purchase_verify", "purchase_options", "purchase_check_cart", "checkout_request",
                         "purchase_outcome", "errand_start", "card_request", "login_request", "login_fill", "ask_person"):
                if tool not in mapped:
                    findings.append({"invariant": "COVERAGE", "where": f"{name}.steps", "detail": f"herramienta «{tool}» sin mapear"})
    return findings


def cmd_coverage(_args) -> int:
    findings = coverage_findings()
    total = covered = 0
    for flow in flows().values():
        for item in list((flow.get("states") or {}).values()) + list(flow.get("steps") or []) + list((flow.get("faults") or {}).values()):
            total += 1
            refs = [str(c) for c in item.get("covered") or []]
            covered += bool(refs) and not all(r.startswith("gap:") for r in refs)
    print(f"Cobertura del mapa: {covered}/{total} elementos probados; el resto son huecos declarados.")
    return report("coverage", findings, {"covered": covered, "total": total})


# ── run and fuzz ──────────────────────────────────────────────────────────────────

def _quiet():
    warnings.filterwarnings("ignore")
    logging.disable(logging.CRITICAL)


def _need_jsdom() -> None:
    sys.path.insert(0, str(PLUGIN / "tests" / "fixtures"))
    import shops
    if not shops.jsdom_available():
        sys.exit("jsdom is needed: run `npm ci` at the repository root (or set NODE_PATH to a jsdom install).")


def run_matrix(shop_filter: str = "", fault_filter: str = "") -> List[Dict[str, Any]]:
    import sim
    findings, results = [], []
    shops_ = [s for s in sim.CASES if not shop_filter or s in shop_filter.split(",")]
    faults_ = [()] + [(f,) for f in sim.FAULTS]
    if fault_filter:
        faults_ = [tuple(x.split("+")) if x != "happy" else () for x in fault_filter.split(",")]
    for shop in shops_:
        for faults in faults_:
            r = sim.run(shop, faults)
            mark = "ok  " if not r["findings"] else "FAIL"
            print(f"  {mark} {shop:22} {'+'.join(faults) or 'happy':30} → {r['status']}/{r['outcome']} pagos={r['pays']} ({r['seconds']}s)", flush=True)
            for f in r["findings"]:
                findings.append({**f, "where": f"{shop} {'+'.join(faults) or 'happy'}"})
            results.append({k: r[k] for k in ("shop", "faults", "status", "outcome", "pays", "seconds")})
    return findings, results


def cmd_run(args) -> int:
    if args.flow != "purchase":
        print(f"«{args.flow}» aún no tiene simulador: su mapa declara qué tests lo cubren (qa.py list).")
        return 0
    if args.level == 2:
        return subprocess.call([sys.executable, str(ROOT / "scripts" / "verify-shops.py")])
    if args.level in (3, 4):
        print("Nivel manual: necesita el permiso explícito de la persona.\n"
              "  3: python scripts/verify-purchase-complete.py --agent   (modelo real, tiendas ficticias, sin pago)\n"
              "  4: una tienda real hasta el paso de pago, sin aprobar, con la persona presente (docs/qa-protocol.md)")
        return 0
    _quiet()
    _need_jsdom()
    started = time.monotonic()
    findings, results = run_matrix(args.shops, args.faults)
    return report("run-purchase", findings, {"results": results, "seconds": round(time.monotonic() - started)})


def cmd_fuzz(args) -> int:
    _quiet()
    _need_jsdom()
    import fuzz
    start = args.start if args.start is not None else (int(time.time()) % 100000 if args.fresh else 0)
    seeds = range(start, start + args.seeds)
    print(f"Fuzz: semillas {seeds.start}–{seeds.stop - 1}")
    found = fuzz.fuzz(seeds, write=not args.no_write)
    findings = [{**f, "where": f"seed {item['seed']} {item['shop']} {'+'.join(item['minimal'])}"}
                for item in found for f in item["findings"]]
    return report("fuzz-purchase", findings, {"seeds": [seeds.start, seeds.stop - 1], "failures": found})


# ── the plugin↔iOS contract ───────────────────────────────────────────────────────

STATES = PLUGIN / "tests" / "fixtures" / "errand_states.json"
ID_KEYS = {"id", "session_id", "origin_session", "option_id", "quote_ref", "checkout_id", "request_id", "run_id"}


def normalize(value: Any, key: str = "") -> Any:
    """Ids and times made fixed, so the file changes only when the shape of an errand changes."""
    if isinstance(value, dict):
        return {k: normalize(v, k) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [normalize(v, key) for v in value]
    if key in ID_KEYS and isinstance(value, str) and value:
        return {"session_id": "errand-0a0b0c0d0e", "origin_session": "20261002_120000_000001",
                "option_id": "a1b2c3d4-1"}.get(key, "0a0b0c0d0e" if key == "id" else "x-" + key)
    if (key == "at" or key.endswith("_at") or key == "pay_again_until") and isinstance(value, (int, float)):
        return 1790000000.0
    if isinstance(value, str):
        value = re.sub(r"\b(errand-)?[0-9a-f]{10}\b", lambda m: (m.group(1) or "") + "0a0b0c0d0e", value)
        value = re.sub(r"\bSIM-[0-9a-f]{6}\b", "SIM-0a0b0c", value)
    return value


def cmd_snapshots(_args) -> int:
    """Every state the simulator saw an errand in, as the app receives it, for iOS's own tests."""
    _quiet()
    _need_jsdom()
    import sim
    states: Dict[str, Any] = {}
    for faults in [()] + [(f,) for f in sim.FAULTS]:
        for key, public in sim.run("tienda-tres.example", faults)["states"].items():
            states.setdefault(key, {"seen_in": "+".join(faults) or "happy", "errand": normalize(public)})
    STATES.write_text(json.dumps({"comment": "Generated by `python scripts/qa.py snapshots` from the purchase simulator; "
                                  "read by ios/AliceTests/ErrandContractTests.swift. Do not edit by hand.",
                                  "states": dict(sorted(states.items()))}, ensure_ascii=False, indent=1) + "\n",
                      encoding="utf-8")
    print(f"{len(states)} estados escritos en {STATES.relative_to(ROOT)}")
    return 0


# ── static and all ────────────────────────────────────────────────────────────────

def cmd_static(_args) -> int:
    import importlib.util
    spec = importlib.util.spec_from_file_location("qa_static", ROOT / "scripts" / "qa_static.py")
    if spec is None or not (ROOT / "scripts" / "qa_static.py").exists():
        print("qa_static.py todavía no existe.")
        return 0
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return report("static", module.scan(ROOT), {})


def cmd_all(args) -> int:
    codes = [cmd_coverage(args), cmd_static(args)]
    args.flow, args.level, args.shops, args.faults = "purchase", 1, "", ""
    codes.append(cmd_run(args))
    args.seeds, args.start, args.fresh, args.no_write = args.seeds or 20, 0, False, False
    codes.append(cmd_fuzz(args))
    return 1 if any(codes) else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("coverage")
    sub.add_parser("static")
    sub.add_parser("snapshots")
    run = sub.add_parser("run")
    run.add_argument("flow")
    run.add_argument("--level", type=int, default=1, choices=(1, 2, 3, 4))
    run.add_argument("--shops", default="", help="comma-separated hosts (default: all fixture shops)")
    run.add_argument("--faults", default="", help="comma-separated, «happy» for none, «a+b» for a combination")
    fz = sub.add_parser("fuzz")
    fz.add_argument("flow")
    fz.add_argument("--seeds", type=int, default=20)
    fz.add_argument("--start", type=int, default=None)
    fz.add_argument("--fresh", action="store_true", help="start from a seed nobody ran yet (time-based)")
    fz.add_argument("--no-write", action="store_true", help="do not write regression tests")
    al = sub.add_parser("all")
    al.add_argument("--seeds", type=int, default=20)
    args = parser.parse_args(argv)
    return {"list": cmd_list, "coverage": cmd_coverage, "static": cmd_static, "run": cmd_run,
            "fuzz": cmd_fuzz, "all": cmd_all, "snapshots": cmd_snapshots}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
