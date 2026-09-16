#!/usr/bin/env python3
"""Hermes falso para las pruebas de crear_agente.py. No habla con ningún modelo."""
import json
import os
import sys
from pathlib import Path


def home() -> Path:
    return Path(os.environ["HERMES_HOME"])


def profile_dir(name: str) -> Path:
    return home() / "profiles" / name


def log(argv: list[str]) -> None:
    path = home() / "hermes.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(" ".join(argv) + "\n")


def write_yaml(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def set_nested(cfg: dict, dotted: str, value: str) -> None:
    keys = dotted.split(".")
    cursor = cfg
    for key in keys[:-1]:
        nxt = cursor.get(key)
        if not isinstance(nxt, dict):
            nxt = {}
            cursor[key] = nxt
        cursor = nxt
    try:
        cursor[keys[-1]] = json.loads(value)
    except ValueError:
        cursor[keys[-1]] = value


def read_cfg(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except ValueError:
        return {}


def write_cfg(path: Path, cfg: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def main(argv: list[str]) -> int:
    log(argv)
    if "-z" in argv or "--oneshot" in argv:
        print("OK")
        return 0
    if "profile" in argv and "create" in argv:
        name = argv[argv.index("create") + 1]
        folder = profile_dir(name)
        folder.mkdir(parents=True, exist_ok=True)
        write_cfg(folder / "config.yaml", {"model": {}, "platform_toolsets": {"cli": []}})
        (folder / "profile.yaml").write_text("ui_meta: {}\n", encoding="utf-8")
        return 0
    if "config" in argv and "set" in argv:
        name = argv[argv.index("-p") + 1] if "-p" in argv else ""
        key = argv[argv.index("set") + 1]
        value = argv[argv.index("set") + 2]
        path = profile_dir(name) / "config.yaml"
        cfg = read_cfg(path)
        set_nested(cfg, key, value)
        write_cfg(path, cfg)
        return 0
    if "cron" in argv and "create" in argv:
        name = argv[argv.index("-p") + 1] if "-p" in argv else ""
        folder = profile_dir(name) / "cron"
        folder.mkdir(parents=True, exist_ok=True)
        jobs_file = folder / "jobs.json"
        jobs = json.loads(jobs_file.read_text(encoding="utf-8")) if jobs_file.is_file() else {"jobs": []}
        jobs["jobs"].append({"name": argv[argv.index("--name") + 1] if "--name" in argv else "job"})
        jobs_file.write_text(json.dumps(jobs), encoding="utf-8")
        return 0
    print("unexpected", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
