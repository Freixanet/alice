"""One synchronized path loader for Alice's phone and agent entry points."""
import importlib.util
import sys
import threading

_LOCK = sys.__dict__.setdefault('_alice_module_load_lock', threading.RLock())


def load(path, name):
    with _LOCK:
        if name in sys.modules:
            return sys.modules[name]
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            # A failed import must be retryable instead of caching incomplete code.
            sys.modules.pop(name, None)
            raise
        return module
