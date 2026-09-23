"""Keys the person gives Alice in a secure card, written where Hermes reads them.

An agent that needs a key for a command never asks for it in the chat: it
ends its reply with ``[Dar clave](alice://connect/secret/NAME)``, Alice shows
a secure field, and the dashboard route saves the value here — the same
thing the terminal snippet did (``NAME=value`` in the main ``.env`` and in
every profile's ``.env`` that exists). The value never goes into a message,
a log or a reply; only whether a name is set is ever read back.

An agent with a terminal can still read these files, as it can any other key
Hermes keeps: the point is that the key is not in the transcript or the
model's context unless an agent prints it, which its instructions forbid.
"""

from __future__ import annotations

import os
import re
import tempfile
from pathlib import Path
from typing import List

NAME = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
# Hermes' own wiring, not a key a person hands to an agent: an injected
# request for one of these could re-point Hermes itself.
RESERVED_PREFIXES = ("HERMES_", "API_SERVER_", "ALICE_", "PATH", "HOME", "SHELL", "PYTHON", "LD_", "DYLD_")
MAX_VALUE = 4096


class SecretError(ValueError):
    pass


def check_name(name: str) -> str:
    name = (name or "").strip()
    if not NAME.fullmatch(name):
        raise SecretError("A key name is capital letters, digits and underscores, like EXA_API_KEY.")
    if name.startswith(RESERVED_PREFIXES):
        raise SecretError(f"{name} is part of Hermes' own setup and cannot be set from a chat.")
    return name


def check_value(value: str) -> str:
    value = (value or "").strip()
    if not value:
        raise SecretError("The key is empty.")
    if len(value) > MAX_VALUE or any(c in value for c in "\r\n\0"):
        raise SecretError("That does not look like a key: it is too long or spans several lines.")
    return value


def env_files(root: Path) -> List[Path]:
    """The main .env (created if missing) and each profile's .env that exists."""
    files = [root / ".env"]
    profiles = root / "profiles"
    if profiles.is_dir():
        files += sorted(p / ".env" for p in profiles.iterdir() if (p / ".env").is_file())
    return files


def _line_name(line: str) -> str:
    text = line.strip()
    if text.startswith("export "):
        text = text[len("export "):].strip()
    return text.split("=", 1)[0].strip() if "=" in text else ""


def _quoted(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_\-.:/+@%,=]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(path: Path, name: str, value: str) -> None:
    """Sets NAME in one .env, replacing an earlier line; atomic and private (0600)."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        lines = []
    entry = f"{name}={_quoted(value)}"
    kept = [line for line in lines if _line_name(line) != name]
    replaced = len(kept) != len(lines)
    if replaced:
        # Where the old line was, so the file reads as before.
        index = next(i for i, line in enumerate(lines) if _line_name(line) == name)
        kept.insert(min(index, len(kept)), entry)
    else:
        kept.append(entry)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".env.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("\n".join(kept) + "\n")
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def save(root: Path, name: str, value: str) -> List[str]:
    """Writes the key everywhere Hermes' agents read keys; returns the profiles, never the value."""
    name, value = check_name(name), check_value(value)
    saved = []
    for path in env_files(root):
        write(path, name, value)
        saved.append("default" if path.parent == root else path.parent.name)
    os.environ[name] = value  # this process (the dashboard) sees it at once too
    return saved


def is_set(root: Path, name: str) -> bool:
    name = check_name(name)
    try:
        lines = (root / ".env").read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    for line in lines:
        if _line_name(line) == name:
            return bool(line.split("=", 1)[1].strip().strip("\"'"))
    return False
