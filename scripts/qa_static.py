"""Fragility rules over Alice's source, run by `python scripts/qa.py static`.

Each rule names a kind of defect that broke a purchase before or would break one silently. A line
may opt out with `# qa: allow <rule> — <why>` on that line or the one above it; the reason is part
of the code review, never a way to make a run green.

    fail-open        a money or secrets guard whose `except` lets the call through
    fixed-port       Chrome's debugging port written as a constant outside its one definition
    temp-state       persistent state kept in the system's temporary folder
    route-untested   a dashboard route of errands or purchases that no test calls
    tool-undeclared  a tool the purchase map names that plugin.yaml does not declare
    contract-drift   a key the app reads from an errand that the plugin never sends
    nothing-paid     «no se ha pagado/cobrado» written where an approved payment is not ruled out
    secret-log       a log or print that names a password, code or card number
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List

PLUGIN_SOURCES = ("hermes-plugin/*.py", "hermes-plugin/dashboard/*.py")


def _allowed(lines: List[str], index: int, rule: str) -> bool:
    for line in lines[max(0, index - 1): index + 1]:
        if re.search(r"#\s*qa:\s*allow\s+" + re.escape(rule) + r"\b", line):
            return True
    return False


def _finding(root: Path, path: Path, index: int, rule: str, detail: str) -> Dict[str, Any]:
    return {"invariant": "STATIC", "rule": rule, "where": f"{path.relative_to(root)}:{index + 1}", "detail": f"{rule}: {detail}"}


def _functions(source: str) -> List[tuple]:
    """(name, first line index, last line index) of each top-level function."""
    lines = source.splitlines()
    starts = [(i, m.group(1)) for i, line in enumerate(lines) for m in [re.match(r"def (\w+)\(", line)] if m]
    out = []
    for n, (start, name) in enumerate(starts):
        end = starts[n + 1][0] - 1 if n + 1 < len(starts) else len(lines) - 1
        out.append((name, start, end))
    return out


def fail_open(root: Path) -> List[Dict[str, Any]]:
    findings = []
    path = root / "hermes-plugin" / "__init__.py"
    lines = path.read_text(encoding="utf-8").splitlines()
    for name, start, end in _functions("\n".join(lines)):
        if not (name.startswith("_guard_") or name in ("_route_card_fill", "_isolate_errand_browser")):
            continue
        for i in range(start, end + 1):
            if re.match(r"\s*except\b", lines[i]):
                following = next((lines[j].strip() for j in range(i + 1, min(end + 1, i + 4)) if lines[j].strip()), "")
                if following == "pass":
                    # Closed if what comes after the try block blocks the call anyway.
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    after = next((lines[j] for j in range(i + 2, end + 1)
                                  if lines[j].strip() and len(lines[j]) - len(lines[j].lstrip()) <= indent), "")
                    if '"block"' in after:
                        continue
                if following in ("return None", "pass", "return") and not _allowed(lines, i, "fail-open"):
                    findings.append(_finding(root, path, i, "fail-open", f"«{name}» deja pasar la llamada si su comprobación falla"))
    return findings


def fixed_port(root: Path) -> List[Dict[str, Any]]:
    findings = []
    for pattern in PLUGIN_SOURCES:
        for path in root.glob(pattern):
            lines = path.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                if "9222" in line and not line.lstrip().startswith("#") and not _allowed(lines, i, "fixed-port"):
                    findings.append(_finding(root, path, i, "fixed-port", "puerto de Chrome fijo; usa el configurado (browser_live.configured_url)"))
    return findings


def temp_state(root: Path) -> List[Dict[str, Any]]:
    findings = []
    for pattern in PLUGIN_SOURCES:
        for path in root.glob(pattern):
            lines = path.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                if "gettempdir()" in line and not _allowed(lines, i, "temp-state"):
                    findings.append(_finding(root, path, i, "temp-state", "estado en la carpeta temporal del sistema; se pierde al reiniciar"))
    return findings


def route_untested(root: Path) -> List[Dict[str, Any]]:
    findings = []
    path = root / "hermes-plugin" / "dashboard" / "plugin_api.py"
    lines = path.read_text(encoding="utf-8").splitlines()
    tests = "\n".join(p.read_text(encoding="utf-8") for p in (root / "hermes-plugin" / "tests").glob("*.py"))
    tests += "\n".join(p.read_text(encoding="utf-8") for p in (root / "hermes-plugin" / "qa").glob("*.py"))
    for i, line in enumerate(lines):
        found = re.match(r'@router\.(get|post|put|delete)\("(/(errands|purchase)[^"]*)"', line)
        if not found:
            continue
        route = found.group(2)
        # The distinctive tail of the route («/checkout», «/purchase/sets»), as a test would write it.
        tail = re.sub(r"\{[^}]+\}", "", route).rstrip("/").split("/")[-1] or route
        if f"/{tail}" not in tests and not _allowed(lines, i, "route-untested"):
            findings.append(_finding(root, path, i, "route-untested", f"ninguna prueba llama a {found.group(1).upper()} {route}"))
    return findings


def tool_undeclared(root: Path) -> List[Dict[str, Any]]:
    findings = []
    manifest = (root / "hermes-plugin" / "plugin.yaml").read_text(encoding="utf-8")
    declared = set(re.findall(r"^\s*-\s*([a-z_]+)\s*$", manifest, re.M))
    for flow in (root / "qa" / "flows").glob("*.yaml"):
        for tool in sorted(set(re.findall(r"tool:([a-z_]+)", flow.read_text(encoding="utf-8")))):
            if tool not in declared:
                findings.append({"invariant": "STATIC", "rule": "tool-undeclared", "where": str(flow.relative_to(root)),
                                 "detail": f"tool-undeclared: «{tool}» no está en plugin.yaml"})
    return findings


def contract_drift(root: Path) -> List[Dict[str, Any]]:
    """Keys the app reads from an errand (`row["…"]`, `raw["…"]` in Errand.swift) that no state the
    simulator produced contains: either the plugin stopped sending them, or the app reads a name
    the plugin never used."""
    states_path = root / "hermes-plugin" / "tests" / "fixtures" / "errand_states.json"
    if not states_path.exists():
        return [{"invariant": "STATIC", "rule": "contract-drift", "where": str(states_path.relative_to(root)),
                 "detail": "contract-drift: faltan los estados (python scripts/qa.py snapshots)"}]
    keys: set = set()

    def walk(value):
        if isinstance(value, dict):
            for k, v in value.items():
                keys.add(k)
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)

    walk(json.loads(states_path.read_text(encoding="utf-8"))["states"])
    path = root / "ios" / "Alice" / "Models" / "Errand.swift"
    lines = path.read_text(encoding="utf-8").splitlines()
    findings = []
    for i, line in enumerate(lines):
        for key in re.findall(r'(?:row|raw|item|\$0)\["([a-z_]+)"\]', line):
            if key not in keys and not _allowed(lines, i, "contract-drift"):
                findings.append(_finding(root, path, i, "contract-drift", f"la app lee «{key}» y ningún estado del plugin lo trae"))
    return findings


def nothing_paid(root: Path) -> List[Dict[str, Any]]:
    findings = []
    for path in (root / "ios" / "Alice").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        if not re.search(r"No se ha (pagado|cobrado) nada", text):
            continue
        if re.search(r"paymentUnconfirmed|checkout\?\.status == \.approved|receipt\.outcome|switch receipt\.outcome", text):
            continue
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if re.search(r"No se ha (pagado|cobrado) nada", line) and not _allowed(lines, i, "nothing-paid"):
                findings.append(_finding(root, path, i, "nothing-paid", "afirma que no se pagó sin descartar un pago aprobado"))
    return findings


def secret_log(root: Path) -> List[Dict[str, Any]]:
    findings = []
    for pattern in PLUGIN_SOURCES:
        for path in root.glob(pattern):
            lines = path.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                if re.search(r"\b(log\w*\.(debug|info|warning|error|exception)|print)\(", line) \
                        and re.search(r"\b(password|passwd|otp|cvv|card_number|secret_value)\b", line, re.I) \
                        and not _allowed(lines, i, "secret-log"):
                    findings.append(_finding(root, path, i, "secret-log", "un log o print nombra un secreto"))
    return findings


RULES = (fail_open, fixed_port, temp_state, route_untested, tool_undeclared, contract_drift, nothing_paid, secret_log)


def scan(root: Path) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    for rule in RULES:
        findings.extend(rule(Path(root)))
    return findings


if __name__ == "__main__":
    for f in scan(Path(__file__).resolve().parents[1]):
        print(f["where"], "—", f["detail"])
