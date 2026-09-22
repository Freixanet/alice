#!/usr/bin/env python3
"""Instala la skill de internet en Hermes y deja `reach` en el PATH.

No toca el gateway, no reinicia Hermes y no copia secretos.
"""

from __future__ import annotations

import os
import shutil
import stat
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE / "SKILL.md"
REACH = HERE / "reach.py"
HOME = Path.home()
DEST = HOME / ".hermes" / "skills" / "research" / "internet"
LINK = HOME / ".local" / "bin" / "reach"


def install() -> None:
    if not SKILL.is_file() or not REACH.is_file():
        raise SystemExit("Faltan SKILL.md o reach.py junto a este instalador.")
    DEST.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SKILL, DEST / "SKILL.md")
    LINK.parent.mkdir(parents=True, exist_ok=True)
    if LINK.is_symlink() or LINK.is_file():
        LINK.unlink()
    LINK.symlink_to(REACH)
    mode = REACH.stat().st_mode
    REACH.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    state = HOME / ".agent-reach"
    state.mkdir(mode=0o700, exist_ok=True)
    os.chmod(state, 0o700)
    print(f"Skill: {DEST / 'SKILL.md'}")
    print(f"Comando: {LINK} -> {REACH}")


if __name__ == "__main__":
    if "--comprobar" in sys.argv:
        print("skill", "ok" if (DEST / "SKILL.md").is_file() else "falta")
        print("reach", "ok" if LINK.is_symlink() else "falta")
        raise SystemExit(0)
    install()
