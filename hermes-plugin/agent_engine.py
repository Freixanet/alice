#!/usr/bin/env python3
"""Shared Alice / Agent Maker engine for creating and renaming Hermes agents.

Both the iPhone form and Agent Maker call this module. It talks to Hermes
through the official CLI (`hermes profile create`, `hermes profile rename`,
`hermes config set`, `hermes cron create`). It does not invent a command chain,
does not pick a silent model fallback, and does not delete a partial profile.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Iterable, Optional

# Hermes `hermes_cli.profiles`: lowercase, then `^[a-z0-9][a-z0-9_-]{0,63}$`.
# Spaces and punctuation become hyphens so "Agent Maker" → "agent-maker".
PROFILE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
RESERVED = frozenset({"hermes", "default", "test", "tmp", "root", "sudo"})
EXAMPLES = re.compile(r"^##\s+(Ejemplos|Examples)\s*$", re.I | re.M)
STYLE_START = "<!-- alice:estilo inicio -->"
MAKER_ROLE = "agent-maker"
LEGACY_MAKER_ID = "forja"
PREFERRED_MAKER_ID = "agent-maker"
MAKER_TITLE = "Agent Maker"
CLARIFY = "clarify"
ALLOWED_TOOLS = {
    "web", "file", "skills", "memory", "clarify", "todo",
    "browser", "terminal", "code_execution", "vision", "image_gen", "tts",
    "session_search", "cronjob", "delegation",
}
# Never granted by this engine. Messaging stays on Hermes' own tools, which the
# Alice plugin already fences for Business / internal profiles.
BLOCKED_TOOLS = frozenset({"message_agent"})

STATUS_COMPLETED = "completed"
STATUS_PARTIAL = "partial"
STATUS_NEEDS_AUTH = "needs_auth"
STATUS_VERIFY_PENDING = "verification_pending"
STATUS_VERIFY_FAILED = "verification_failed"
STATUS_FAILED = "failed"

STEP_PROFILE = "perfil"
STEP_CONFIG = "configuracion"
STEP_SOUL = "instrucciones"
STEP_TITLE = "nombre_visible"
STEP_MEMORY = "memoria"
STEP_ROUTINES = "rutinas"
STEP_RENAME = "renombrado"
STEP_REBIND = "referencias"
STEP_VERIFY = "verificacion"
STEP_SMOKE = "humo"


class SpecError(ValueError):
    """The specification is not valid; nothing was written."""


class EngineError(RuntimeError):
    """A checked failure with a status the caller can surface."""

    def __init__(self, message: str, status: str = STATUS_FAILED, **extra: Any):
        super().__init__(message)
        self.status = status
        self.extra = extra


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def hermes_agent_root() -> Path:
    return Path(os.environ.get("HERMES_AGENT") or hermes_home() / "hermes-agent")


def hermes_bin() -> Path:
    return Path(os.environ.get("HERMES_BIN") or hermes_agent_root() / "venv" / "bin" / "hermes")


def ops_dir(home: Optional[Path] = None) -> Path:
    return (home or hermes_home()) / ".alice" / "agent-ops"


def profile_dir_for(name: str, home: Optional[Path] = None) -> Path:
    return (home or hermes_home()) / "profiles" / name


def slugify(display: str) -> str:
    """Turn a visible name into a Hermes profile id.

    Hermes itself only lowercases; "Agent Maker" would become the invalid
    ``agent maker``. Alice maps spaces and other punctuation to hyphens so the
    visible name and the identifier correspond: Agent Maker → agent-maker.
    """
    stripped = (display or "").strip().lower()
    if not stripped:
        return ""
    if stripped.casefold() == "default":
        return "default"
    chars = []
    for ch in stripped:
        if ch.isalnum() or ch in "_-":
            chars.append(ch)
        else:
            chars.append("-")
    collapsed = re.sub(r"[-_]{2,}", "-", "".join(chars))
    collapsed = collapsed.strip("-")
    return collapsed[:64]


def validate_profile_id(canon: str) -> None:
    if not canon:
        raise SpecError("The name needs at least one letter or number.")
    if not PROFILE_ID.match(canon):
        raise SpecError(
            f"`{canon}` is not a valid Hermes profile id. "
            "Use lowercase letters, numbers and hyphens (Agent Maker → agent-maker)."
        )
    if canon in RESERVED:
        raise SpecError(f"`{canon}` is reserved by Hermes. Choose another name.")


def profile_id_for(display: str, explicit: str = "") -> str:
    raw = (explicit or "").strip() or display
    canon = slugify(raw)
    validate_profile_id(canon)
    return canon


def slug_note(display: str, canon: str) -> Optional[str]:
    shown = (display or "").strip()
    if not shown or shown.lower() == canon:
        return None
    return f"Alice shows “{shown}”. Hermes knows this agent as `{canon}`."


def has_examples(soul: str) -> bool:
    match = EXAMPLES.search(soul or "")
    if not match:
        return False
    rest = soul[match.end():]
    nxt = re.search(r"^##\s+", rest, re.M)
    body = rest[:nxt.start()] if nxt else rest
    return len(body.strip()) >= 40


def after_title(text: str, block: str) -> str:
    lines = text.splitlines(keepends=True)
    insert = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith("# "):
            insert = i + 1
            if insert < len(lines) and lines[insert].strip() == "":
                insert += 1
            break
    return "".join(lines[:insert]) + block.strip() + "\n\n" + "".join(lines[insert:])


def with_style(soul: str, style_file: Optional[Path] = None) -> str:
    if STYLE_START in soul:
        return soul
    path = style_file
    if path is None:
        return soul
    if not path.is_file():
        return soul
    return after_title(soul, path.read_text(encoding="utf-8"))


def _read_mapping(path: Path) -> dict:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    try:
        import yaml
        data = yaml.safe_load(text)
        return data if isinstance(data, dict) else {}
    except Exception:
        try:
            data = json.loads(text)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _write_mapping(path: Path, data: dict) -> None:
    try:
        import sys
        sys.path.insert(0, str(hermes_agent_root()))
        from utils import atomic_yaml_write
        atomic_yaml_write(path, data, sort_keys=False)
        return
    except Exception:
        pass
    try:
        import yaml
        _atomic_write(path, yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
        return
    except Exception:
        _atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2))


def result(
    status: str,
    *,
    profile_id: Optional[str] = None,
    title: Optional[str] = None,
    confirmed: Optional[list] = None,
    checks: Optional[dict] = None,
    error: Optional[str] = None,
    job_id: Optional[str] = None,
    from_id: Optional[str] = None,
    to_id: Optional[str] = None,
    reused: bool = False,
    slug_note_text: Optional[str] = None,
    plan: Optional[dict] = None,
    same_id: bool = False,
) -> dict:
    payload = {
        "ok": status == STATUS_COMPLETED,
        "status": status,
        "profile_id": profile_id,
        "title": title,
        "confirmed": list(confirmed or []),
        "checks": checks or {},
        "error": error,
        "job_id": job_id,
        "from_id": from_id,
        "to_id": to_id,
        "reused": reused,
        "slug_note": slug_note_text,
        "same_id": same_id,
    }
    if plan is not None:
        payload["plan"] = plan
    return payload


def load_journal(job_id: str, home: Optional[Path] = None) -> dict:
    path = ops_dir(home) / f"{job_id}.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_journal(job: dict, home: Optional[Path] = None) -> None:
    job_id = job.get("job_id")
    if not job_id:
        return
    job = dict(job)
    job["updated_at"] = time.time()
    _atomic_write(ops_dir(home) / f"{job_id}.json", json.dumps(job, ensure_ascii=False, indent=2))


def new_job_id() -> str:
    return uuid.uuid4().hex


def load_spec(raw: Any, *, style_file: Optional[Path] = None, require_soul: bool = True) -> dict:
    if isinstance(raw, (str, Path)):
        path = Path(raw)
        try:
            spec = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise SpecError(f"Could not read the specification: {exc}") from exc
    elif isinstance(raw, dict):
        spec = raw
    else:
        raise SpecError("The specification must be a JSON object.")
    if not isinstance(spec, dict):
        raise SpecError("The specification must be a JSON object.")

    title = str(spec.get("title") or "").strip()
    explicit = str(spec.get("name") or "").strip()
    if not title and not explicit:
        raise SpecError("A title or name is required.")
    if not title:
        title = explicit
    name = profile_id_for(title, explicit)
    description = str(spec.get("description") or "").strip()
    soul = str(spec.get("soul") or "").strip()
    if require_soul and not soul:
        raise SpecError("Missing `soul`.")
    if soul:
        soul = with_style(soul, style_file) + "\n"
        if not has_examples(soul):
            raise SpecError("`soul` must include a ## Ejemplos or ## Examples section with example turns.")

    tools_raw = spec.get("tools")
    tools: Optional[list[str]]
    if tools_raw is None:
        tools = None
    elif not isinstance(tools_raw, list):
        raise SpecError("`tools` must be a list.")
    else:
        named = [str(t).strip() for t in tools_raw if str(t).strip()]
        blocked = [t for t in named if t in BLOCKED_TOOLS]
        if blocked:
            raise SpecError(f"These tools are not granted by agent creation: {', '.join(blocked)}.")
        unknown = [t for t in named if t not in ALLOWED_TOOLS]
        if unknown:
            raise SpecError(f"Unknown tools: {', '.join(unknown)}.")
        tools = []
        if CLARIFY not in named:
            tools.append(CLARIFY)
        tools.extend(t for t in named if t not in tools)

    routines = spec.get("routines") or []
    if not isinstance(routines, list):
        raise SpecError("`routines` must be a list.")
    cleaned_routines = []
    for routine in routines:
        if not isinstance(routine, dict) or not all(
            str(routine.get(k) or "").strip() for k in ("name", "schedule", "prompt")
        ):
            raise SpecError("Each routine needs `name`, `schedule` and `prompt`.")
        cleaned_routines.append({
            "name": str(routine["name"]).strip(),
            "schedule": str(routine["schedule"]).strip(),
            "prompt": str(routine["prompt"]).strip(),
            "deliver": str(routine.get("deliver") or "bot-chat").strip() or "bot-chat",
        })

    model = spec.get("model")
    provider = str(spec.get("provider") or "").strip()
    model_cfg = None
    if isinstance(model, dict):
        default = str(model.get("default") or model.get("id") or "").strip()
        provider = str(model.get("provider") or provider).strip()
        if default:
            model_cfg = {
                "default": default,
                "provider": provider,
                "base_url": str(model.get("base_url") or ""),
            }
    elif isinstance(model, str) and model.strip():
        if not provider:
            raise SpecError("A model needs its provider. Alice will not pick one.")
        model_cfg = {"default": model.strip(), "provider": provider, "base_url": ""}

    fallback = spec.get("fallback")
    if fallback is not None and not isinstance(fallback, list):
        raise SpecError("`fallback` must be a list when provided.")

    memory = str(spec.get("memory") or "").strip()
    copy_memory = bool(spec.get("copy_memory"))
    if memory and not copy_memory:
        raise SpecError("Initial memory needs `copy_memory: true` — Alice does not copy personal memory by default.")

    reuse = str(spec.get("reuse_profile") or "").strip()
    if reuse:
        reuse = profile_id_for(reuse, reuse)

    return {
        "name": name,
        "title": title,
        "description": description,
        "soul": soul,
        "tools": tools,
        "routines": cleaned_routines,
        "model": model_cfg,
        "fallback": list(fallback) if fallback else None,
        "memory": memory if copy_memory else "",
        "copy_memory": copy_memory,
        "reuse_profile": reuse,
        "source": str(spec.get("source") or "").strip(),
        "role": str(spec.get("role") or "").strip(),
        "job_id": str(spec.get("job_id") or "").strip(),
        "smoke": bool(spec.get("smoke")),
        "slug_note": slug_note(title, name),
    }


def hermes(*args: str, timeout: int = 300, home: Optional[Path] = None) -> str:
    env = os.environ.copy()
    if home is not None:
        env["HERMES_HOME"] = str(home)
    result = subprocess.run(
        [str(hermes_bin()), *args], capture_output=True, text=True,
        timeout=timeout, env=env,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()[-3:]
        raise RuntimeError(f"`hermes {' '.join(args[:2])}` failed: {' '.join(detail)}")
    return result.stdout


def _has_auth(profile: Path, home: Path) -> bool:
    return (profile / "auth.json").is_file() or (home / "auth.json").is_file()


def _merge_ui_meta(profile: Path, *, title: Optional[str] = None, role: Optional[str] = None) -> None:
    path = profile / "profile.yaml"
    existing = _read_mapping(path)
    current = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    if title:
        bots = dict(current.get("hermes-bots") or {})
        bots.update({"title": title, "created": bots.get("created") or time.time() * 1000,
                     "shape": bots.get("shape") or "blobatar", "imageKind": bots.get("imageKind") or "shape"})
        current["hermes-bots"] = bots
    if role:
        alice = dict(current.get("alice") or {}) if isinstance(current.get("alice"), dict) else {}
        alice["role"] = role
        current["alice"] = alice
    revisions = existing.get("_ui_meta_revisions") if isinstance(existing.get("_ui_meta_revisions"), dict) else {}
    if title:
        revisions["hermes-bots"] = int(revisions.get("hermes-bots") or 0) + 1
    if role:
        revisions["alice"] = int(revisions.get("alice") or 0) + 1
    existing["ui_meta"] = current
    existing["_ui_meta_revisions"] = revisions
    _write_mapping(path, existing)


def visible_title(profile: Path) -> Optional[str]:
    meta = _read_mapping(profile / "profile.yaml")
    bots = ((meta.get("ui_meta") or {}).get("hermes-bots") or {})
    title = bots.get("title") if isinstance(bots, dict) else None
    return str(title) if title else None


def alice_role(profile: Path) -> Optional[str]:
    meta = _read_mapping(profile / "profile.yaml")
    alice = ((meta.get("ui_meta") or {}).get("alice") or {})
    role = alice.get("role") if isinstance(alice, dict) else None
    return str(role) if role else None


def is_agent_maker(root: Path, name: str) -> bool:
    """Identify Agent Maker by stamped role, with a legacy `forja` fallback."""
    if not name or name == "default":
        return False
    folder = root / "profiles" / name
    if alice_role(folder) == MAKER_ROLE:
        return True
    return name == LEGACY_MAKER_ID and folder.is_dir()


def find_agent_maker(root: Path) -> Optional[str]:
    profiles = root / "profiles"
    if not profiles.is_dir():
        return None
    found = []
    for child in profiles.iterdir():
        if child.is_dir() and alice_role(child) == MAKER_ROLE:
            found.append(child.name)
    if found:
        return sorted(found)[0]
    legacy = profiles / LEGACY_MAKER_ID
    if legacy.is_dir():
        return LEGACY_MAKER_ID
    return None


def planned_maker_id(profile: Path, current_id: str) -> str:
    title = visible_title(profile) or current_id
    lowered = title.strip().lower()
    if current_id == LEGACY_MAKER_ID and lowered in {LEGACY_MAKER_ID, MAKER_TITLE.lower(), "forja"}:
        return PREFERRED_MAKER_ID
    return profile_id_for(title, "")


def stamp_maker_role(profile: Path, title: str = MAKER_TITLE) -> None:
    _merge_ui_meta(profile, title=title, role=MAKER_ROLE)


def _jobs(profile: Path) -> list:
    jobs_file = profile / "cron" / "jobs.json"
    if not jobs_file.is_file():
        return []
    try:
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
    except ValueError:
        return []
    if isinstance(data, dict):
        rows = data.get("jobs", [])
        return rows if isinstance(rows, list) else []
    return data if isinstance(data, list) else []


def _retarget_cron(profile: Path, old_id: str, new_id: str) -> None:
    """Update structured cron destinations that named the old profile. Not a text sweep."""
    jobs_file = profile / "cron" / "jobs.json"
    if not jobs_file.is_file():
        return
    try:
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
    except ValueError:
        return
    changed = False

    def fix_deliver(value: str) -> str:
        prefix = f"bot-chat:{old_id}"
        if value == prefix or value.startswith(prefix + ":"):
            return f"bot-chat:{new_id}" + value[len(prefix):]
        return value

    def walk(node):
        nonlocal changed
        if isinstance(node, dict):
            for key, value in list(node.items()):
                if key in {"deliver", "delivery", "failure_deliver"} and isinstance(value, str):
                    nxt = fix_deliver(value)
                    if nxt != value:
                        node[key] = nxt
                        changed = True
                elif key == "profile" and value == old_id:
                    node[key] = new_id
                    changed = True
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    if changed:
        _atomic_write(jobs_file, json.dumps(data, ensure_ascii=False, indent=2))


def _read_tools(profile: Path) -> list:
    cfg = _read_mapping(profile / "config.yaml")
    tools = (cfg.get("platform_toolsets") or {}).get("cli") or []
    if isinstance(tools, str):
        try:
            tools = json.loads(tools)
        except ValueError:
            tools = [tools]
    return list(tools) if isinstance(tools, list) else []


def verify_create(spec: dict, profile: Path, home: Path, smoked: Optional[bool]) -> dict:
    cfg = _read_mapping(profile / "config.yaml")
    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    fallback = cfg.get("fallback_providers") or []
    soul = (profile / "SOUL.md").read_text(encoding="utf-8") if (profile / "SOUL.md").is_file() else ""
    jobs = _jobs(profile)
    checks = {
        "perfil_creado": profile.is_dir() and (profile / "config.yaml").is_file(),
    }
    if spec.get("soul"):
        checks["instrucciones"] = bool(soul.strip())
        checks["ejemplos"] = has_examples(soul)
    if spec.get("title"):
        checks["nombre_visible"] = visible_title(profile) == spec["title"]
    if spec.get("model"):
        checks["modelo"] = model.get("default") == spec["model"]["default"]
        checks["proveedor"] = (model.get("provider") or "") == spec["model"]["provider"]
        checks["sin_reserva_silenciosa"] = not spec.get("fallback") or True
        if spec.get("fallback"):
            checks["reserva"] = [f.get("model") for f in fallback] == [
                (spec["fallback"][0] or {}).get("model")
            ]
        else:
            wanted = spec["model"]["default"]
            extras = [f.get("model") for f in fallback if isinstance(f, dict) and f.get("model") and f.get("model") != wanted]
            checks["sin_reserva_silenciosa"] = not extras
    if spec.get("tools") is not None:
        pinned = _read_tools(profile)
        checks["herramientas"] = all(t in pinned for t in spec["tools"])
        checks["herramienta_preguntas"] = CLARIFY in pinned
        checks["sin_herramientas_extra"] = all(t in spec["tools"] for t in pinned)
    if spec.get("routines"):
        names = {str(j.get("name") or "") for j in jobs if isinstance(j, dict)}
        checks["rutinas"] = all(r["name"] in names for r in spec["routines"])
        checks["rutinas_en_perfil"] = True
    if spec.get("copy_memory") and spec.get("memory"):
        memory = profile / "MEMORY.md"
        checks["memoria"] = memory.is_file() and spec["memory"] in memory.read_text(encoding="utf-8")
        checks["sin_user_md"] = not bool(spec.get("memory")) or True
    if spec.get("model"):
        checks["autenticacion"] = _has_auth(profile, home)
    if smoked is not None:
        checks["humo"] = smoked
    return checks


def _status_from_checks(checks: dict, spec: dict) -> str:
    if spec.get("model") and checks.get("autenticacion") is False:
        others = {k: v for k, v in checks.items() if k != "autenticacion"}
        if others and all(others.values()):
            return STATUS_NEEDS_AUTH
        return STATUS_NEEDS_AUTH
    if not checks:
        return STATUS_VERIFY_PENDING
    if all(checks.values()):
        return STATUS_COMPLETED
    return STATUS_VERIFY_FAILED


def create_agent(
    spec_raw: Any,
    *,
    home: Optional[Path] = None,
    style_file: Optional[Path] = None,
    require_soul: bool = True,
    dry_run: bool = False,
    no_alias: bool = False,
    job_id: Optional[str] = None,
) -> dict:
    home = home or hermes_home()
    spec = load_spec(spec_raw, style_file=style_file, require_soul=require_soul)
    job_id = job_id or spec.get("job_id") or new_job_id()
    profile = profile_dir_for(spec["name"], home)
    reuse = spec.get("reuse_profile")
    journal = load_journal(job_id, home)
    confirmed = list(journal.get("confirmed") or [])
    plan = {
        "name": spec["name"],
        "title": spec["title"],
        "tools": spec["tools"],
        "routines": [r["name"] for r in spec["routines"]],
        "path": str(profile),
        "model": (spec["model"] or {}).get("default") if spec.get("model") else None,
        "provider": (spec["model"] or {}).get("provider") if spec.get("model") else None,
    }
    note = spec.get("slug_note")

    if dry_run:
        if profile.exists() and not reuse and STEP_PROFILE not in confirmed:
            return result(
                STATUS_FAILED, profile_id=spec["name"], title=spec["title"],
                error=f"Ya existe un agente llamado `{spec['name']}`. Elige otro nombre.",
                job_id=job_id, slug_note_text=note, plan=plan,
            )
        return result(
            STATUS_COMPLETED, profile_id=spec["name"], title=spec["title"],
            job_id=job_id, slug_note_text=note, plan=plan,
        )

    save_journal({
        "job_id": job_id, "kind": "create", "profile_id": spec["name"],
        "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL,
    }, home)

    existed = profile.exists()
    reused = False
    if existed:
        owned = journal.get("profile_id") == spec["name"] and STEP_PROFILE in confirmed
        if reuse and reuse == spec["name"]:
            reused = True
            if STEP_PROFILE not in confirmed:
                confirmed.append(STEP_PROFILE)
        elif owned:
            reused = True
        else:
            return result(
                STATUS_FAILED, profile_id=spec["name"], title=spec["title"],
                confirmed=confirmed, job_id=job_id, slug_note_text=note, plan=plan,
                error=f"Ya existe un agente llamado `{spec['name']}`. El original no se ha modificado.",
            )

    smoked: Optional[bool] = None
    try:
        if not existed:
            create_args = ["profile", "create", spec["name"]]
            if spec["description"]:
                create_args.extend(["--description", spec["description"]])
            if no_alias:
                create_args.append("--no-alias")
            hermes(*create_args, home=home)
            confirmed.append(STEP_PROFILE)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if spec.get("model") and STEP_CONFIG not in confirmed:
            model = spec["model"]
            for key in ("default", "provider", "base_url"):
                hermes("-p", spec["name"], "config", "set", f"model.{key}", model[key], home=home)
            if spec.get("fallback"):
                hermes("-p", spec["name"], "config", "set", "fallback_providers",
                       json.dumps(spec["fallback"]), home=home)
            if spec.get("tools") is not None:
                hermes("-p", spec["name"], "config", "set", "platform_toolsets.cli",
                       json.dumps(spec["tools"]), home=home)
            confirmed.append(STEP_CONFIG)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)
        elif spec.get("tools") is not None and STEP_CONFIG not in confirmed:
            hermes("-p", spec["name"], "config", "set", "platform_toolsets.cli",
                   json.dumps(spec["tools"]), home=home)
            confirmed.append(STEP_CONFIG)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if spec.get("soul") and STEP_SOUL not in confirmed:
            _atomic_write(profile / "SOUL.md", spec["soul"])
            confirmed.append(STEP_SOUL)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if STEP_TITLE not in confirmed:
            _merge_ui_meta(profile, title=spec["title"], role=spec.get("role") or None)
            confirmed.append(STEP_TITLE)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if spec.get("memory") and STEP_MEMORY not in confirmed:
            _atomic_write(profile / "MEMORY.md", spec["memory"].rstrip() + "\n")
            confirmed.append(STEP_MEMORY)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if spec["routines"] and STEP_ROUTINES not in confirmed:
            existing_names = {str(j.get("name") or "") for j in _jobs(profile) if isinstance(j, dict)}
            for routine in spec["routines"]:
                if routine["name"] in existing_names:
                    continue
                hermes(
                    "-p", spec["name"], "cron", "create",
                    routine["schedule"], routine["prompt"],
                    "--name", routine["name"], "--deliver", routine["deliver"],
                    home=home,
                )
                existing_names.add(routine["name"])
            confirmed.append(STEP_ROUTINES)
            save_journal({"job_id": job_id, "kind": "create", "profile_id": spec["name"],
                          "title": spec["title"], "confirmed": confirmed, "status": STATUS_PARTIAL}, home)

        if spec.get("smoke") and STEP_SMOKE not in confirmed:
            out = hermes("-p", spec["name"], "-z", "Reply with exactly OK and nothing else.",
                         timeout=120, home=home)
            smoked = "OK" in out.upper()
            confirmed.append(STEP_SMOKE)

        checks = verify_create(spec, profile, home, smoked)
        status = _status_from_checks(checks, spec)
        if status == STATUS_COMPLETED:
            confirmed.append(STEP_VERIFY)
        save_journal({
            "job_id": job_id, "kind": "create", "profile_id": spec["name"],
            "title": spec["title"], "confirmed": confirmed, "status": status, "checks": checks,
        }, home)
        return result(
            status, profile_id=spec["name"], title=spec["title"], confirmed=confirmed,
            checks=checks, job_id=job_id, reused=reused, slug_note_text=note, plan=plan,
            error=None if status == STATUS_COMPLETED else (
                "Provider authentication is still needed." if status == STATUS_NEEDS_AUTH
                else "Creation finished with unverified steps."
            ),
        )
    except SpecError as exc:
        return result(STATUS_FAILED, profile_id=spec["name"], title=spec["title"],
                      confirmed=confirmed, error=str(exc), job_id=job_id,
                      slug_note_text=note, plan=plan)
    except Exception as exc:
        status = STATUS_PARTIAL if confirmed else STATUS_FAILED
        save_journal({
            "job_id": job_id, "kind": "create", "profile_id": spec["name"],
            "title": spec["title"], "confirmed": confirmed, "status": status, "error": str(exc),
        }, home)
        return result(
            status, profile_id=spec["name"], title=spec["title"], confirmed=confirmed,
            error=str(exc), job_id=job_id, reused=reused, slug_note_text=note, plan=plan,
        )


def rename_agent(
    current_id: str,
    new_title: str,
    *,
    home: Optional[Path] = None,
    job_id: Optional[str] = None,
    busy_profiles: Optional[Iterable[str]] = None,
    execute: bool = True,
) -> dict:
    """Rename via official `hermes profile rename`. Never create-empty + delete."""
    home = home or hermes_home()
    old_id = slugify(current_id)
    validate_profile_id(old_id)
    title = (new_title or "").strip()
    if not title:
        return result(STATUS_FAILED, profile_id=old_id, error="The new name cannot be empty.")
    try:
        new_id = profile_id_for(title, "")
    except SpecError as exc:
        return result(STATUS_FAILED, profile_id=old_id, title=title, error=str(exc))

    job_id = job_id or new_job_id()
    old_dir = profile_dir_for(old_id, home)
    new_dir = profile_dir_for(new_id, home)
    note = slug_note(title, new_id)
    busy = {slugify(p) for p in (busy_profiles or []) if p}

    journal = load_journal(job_id, home)
    confirmed = list(journal.get("confirmed") or [])

    if old_id == "default":
        return result(
            STATUS_FAILED, profile_id=old_id, title=title, job_id=job_id,
            error="The main Alice profile cannot change its Hermes id.",
        )
    if old_id in busy or new_id in busy:
        return result(
            STATUS_FAILED, profile_id=old_id, title=title, from_id=old_id, to_id=new_id,
            job_id=job_id, slug_note_text=note,
            error="This agent is in the middle of a request. Wait for it to finish, then rename.",
        )

    # Resume: directory already moved for this job.
    if STEP_RENAME in confirmed and new_dir.is_dir() and not old_dir.exists():
        old_id = journal.get("from_id") or old_id

    if not old_dir.is_dir() and not new_dir.is_dir():
        return result(
            STATUS_FAILED, profile_id=old_id, title=title, job_id=job_id,
            error=f"There is no agent named `{old_id}`.",
        )

    if old_id == new_id:
        if execute:
            _merge_ui_meta(old_dir, title=title, role=alice_role(old_dir))
        return result(
            STATUS_COMPLETED, profile_id=old_id, title=title, from_id=old_id, to_id=new_id,
            confirmed=["titulo"], job_id=job_id, slug_note_text=note, same_id=True,
        )

    if new_dir.exists() and not (STEP_RENAME in confirmed and journal.get("to_id") == new_id):
        return result(
            STATUS_FAILED, profile_id=old_id, title=title, from_id=old_id, to_id=new_id,
            job_id=job_id, slug_note_text=note,
            error=f"`{new_id}` already exists. The original agent `{old_id}` was left unchanged.",
        )

    if not execute:
        return result(
            STATUS_COMPLETED, profile_id=new_id, title=title, from_id=old_id, to_id=new_id,
            job_id=job_id, slug_note_text=note, plan={"from": old_id, "to": new_id},
        )

    save_journal({
        "job_id": job_id, "kind": "rename", "from_id": old_id, "to_id": new_id,
        "title": title, "confirmed": confirmed, "status": STATUS_PARTIAL,
    }, home)

    try:
        if STEP_RENAME not in confirmed:
            hermes("profile", "rename", old_id, new_id, home=home)
            if not new_dir.is_dir() or old_dir.exists():
                return result(
                    STATUS_FAILED, profile_id=old_id, title=title, from_id=old_id, to_id=new_id,
                    job_id=job_id,
                    error="Hermes did not finish the rename. The original agent was left in place.",
                )
            confirmed.append(STEP_RENAME)
            save_journal({
                "job_id": job_id, "kind": "rename", "from_id": old_id, "to_id": new_id,
                "title": title, "confirmed": confirmed, "status": STATUS_PARTIAL,
            }, home)

        if STEP_REBIND not in confirmed:
            _retarget_cron(new_dir, old_id, new_id)
            _merge_ui_meta(new_dir, title=title, role=alice_role(new_dir))
            confirmed.append(STEP_REBIND)
            save_journal({
                "job_id": job_id, "kind": "rename", "from_id": old_id, "to_id": new_id,
                "title": title, "confirmed": confirmed, "status": STATUS_PARTIAL,
            }, home)

        if not new_dir.is_dir():
            return result(
                STATUS_FAILED, profile_id=old_id, title=title, from_id=old_id, to_id=new_id,
                confirmed=confirmed, job_id=job_id,
                error="The renamed profile could not be verified. The original id is still the one to use.",
            )
        if old_dir.exists():
            return result(
                STATUS_PARTIAL, profile_id=new_id, title=title, from_id=old_id, to_id=new_id,
                confirmed=confirmed, job_id=job_id, slug_note_text=note,
                error="Both names still exist after rename. Alice will not treat this as finished.",
            )

        confirmed.append(STEP_VERIFY)
        save_journal({
            "job_id": job_id, "kind": "rename", "from_id": old_id, "to_id": new_id,
            "title": title, "confirmed": confirmed, "status": STATUS_COMPLETED,
        }, home)
        return result(
            STATUS_COMPLETED, profile_id=new_id, title=title, from_id=old_id, to_id=new_id,
            confirmed=confirmed, job_id=job_id, slug_note_text=note,
        )
    except Exception as exc:
        still_old = old_dir.is_dir()
        status = STATUS_PARTIAL if STEP_RENAME in confirmed else STATUS_FAILED
        profile = new_id if new_dir.is_dir() else old_id
        save_journal({
            "job_id": job_id, "kind": "rename", "from_id": old_id, "to_id": new_id,
            "title": title, "confirmed": confirmed, "status": status, "error": str(exc),
        }, home)
        return result(
            status, profile_id=profile, title=title, from_id=old_id, to_id=new_id,
            confirmed=confirmed, job_id=job_id, slug_note_text=note,
            error=str(exc) if not still_old or STEP_RENAME in confirmed else (
                f"{exc} The original agent `{old_id}` was left unchanged."
            ),
        )


def prepare_maker_migration(root: Optional[Path] = None, *, execute: bool = False) -> dict:
    """Plan (or, only when execute=True) Forja → agent-maker. Tests pass execute."""
    root = root or hermes_home()
    current = find_agent_maker(root)
    if current is None:
        return result(STATUS_FAILED, error="Agent Maker is not installed on this Hermes.")
    folder = profile_dir_for(current, root)
    target = planned_maker_id(folder, current)
    if current == target:
        stamp_maker_role(folder)
        return result(
            STATUS_COMPLETED, profile_id=current, title=visible_title(folder) or MAKER_TITLE,
            same_id=True, confirmed=["titulo"],
        )
    return rename_agent(
        current, visible_title(folder) or MAKER_TITLE, home=root, execute=execute,
        job_id=f"maker-migrate-{current}-to-{target}",
    )


def create_from_tool(args: dict) -> dict:
    spec = args.get("spec") if isinstance(args.get("spec"), dict) else args
    return create_agent(spec, job_id=str(args.get("job_id") or "") or None, require_soul=True)


def rename_from_tool(args: dict) -> dict:
    return rename_agent(
        str(args.get("from") or args.get("from_profile") or ""),
        str(args.get("to") or ""),
        job_id=str(args.get("job_id") or "") or None,
        busy_profiles=[str(args.get("busy_profile"))] if args.get("busy_profile") else None,
    )


def main(argv: list[str]) -> int:
    """CLI used by crear_agente.py and isolated tests."""
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if not args:
        print(json.dumps({"ok": False, "status": STATUS_FAILED,
                          "error": "Usage: agent_engine.py <spec.json> | rename <from> <to>"}))
        return 2
    try:
        if args[0] == "rename":
            payload = rename_agent(args[1], args[2], execute="--comprobar" not in flags)
        elif args[0] == "migrate-maker":
            payload = prepare_maker_migration(execute="--execute" in flags)
        else:
            payload = create_agent(
                Path(args[0]),
                dry_run="--comprobar" in flags,
                no_alias="--sin-atajo" in flags,
                require_soul=True,
            )
            if "--comprobar" in flags:
                payload["comprobacion"] = True
    except SpecError as exc:
        payload = result(STATUS_FAILED, error=str(exc))
    print(json.dumps(payload, ensure_ascii=False))
    if payload.get("status") == STATUS_COMPLETED:
        return 0
    if payload.get("status") in {STATUS_PARTIAL, STATUS_NEEDS_AUTH, STATUS_VERIFY_FAILED, STATUS_VERIFY_PENDING}:
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main(__import__("sys").argv[1:]))
