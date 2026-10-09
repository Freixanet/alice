"""Durable purchase files. Missing is empty; unreadable is an actionable failure.

Never overwrite evidence after a truncated or invalid read. Writes are private,
atomic and flushed before an irreversible browser operation may be submitted.
Callers hold their existing process-safe file locks.
"""
import json
import os
import tempfile
from pathlib import Path


def read(path, expected=list):
    path = Path(path)
    try:
        with path.open(encoding='utf-8') as stream:
            data = json.load(stream)
    except FileNotFoundError:
        return expected()
    except (OSError, ValueError) as exc:
        raise ValueError('No se puede leer el estado de la compra; se conserva para recuperarlo.') from exc
    if not isinstance(data, expected):
        raise ValueError('El estado de la compra tiene un formato inválido; no se ha sustituido.')
    return data


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.purchase-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)
