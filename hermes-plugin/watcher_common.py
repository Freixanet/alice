"""Private-host helpers. No model or tool execution lives here."""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


class WatcherError(ValueError):
    pass


def sibling(file):
    name = "alice_" + file.removesuffix(".py")
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def bounded(value, limit=16384):
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if len(encoded.encode()) > limit:
        raise WatcherError("JSON exceeds the watcher limit.")
    return json.loads(encoded)
