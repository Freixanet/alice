"""Python watcher subprocess, Seatbelt on macOS, no host credentials or ambient tools.

The host brokers a closed set of JSON RPC capabilities. Fail closed on other OSes
until an equivalent runner is installed. Resource limits supplement OS confinement.
"""
from __future__ import annotations

import ast
import hashlib
import json
import os
import selectors
import subprocess
import sys
import sysconfig
import time
import psutil
from pathlib import Path


class RunnerError(RuntimeError):
    pass


CAPABILITIES = {"notify", "state.get", "state.put", "ack", "log", "source.read", "http_get", "classify"}

BOOTSTRAP = r'''
import sys, json, resource
resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
packet = json.loads(sys.stdin.readline())
def rpc(name, *args):
    sys.stdout.write(json.dumps({'capability': name, 'args': args}, allow_nan=False) + '\n')
    sys.stdout.flush()
    response = json.loads(sys.stdin.readline())
    if not response['ok']:
        raise RuntimeError(response['error'])
    return response.get('value')
class State:
    def get(self): return rpc('state.get')
    def put(self, value): return rpc('state.put', value)
class Source:
    def read(self): return rpc('source.read')
safe = {k: getattr(__builtins__, k) for k in ('str','int','float','bool','len','min','max','sum','abs','round','sorted','list','dict','tuple','enumerate','range','zip','any','all','isinstance','Exception','ValueError','RuntimeError')}
env = {'__builtins__': safe, 'event': packet['event'], 'config': packet['config'], 'state': State(), 'source': Source()}
for name in ('notify','ack','log','http_get','classify'):
    env[name] = (lambda *args, _name=name: rpc(_name, *args))
exec(compile(packet['code'], '<watcher>', 'exec'), env, env)
'''


def validate_code(code):
    if not isinstance(code, str) or len(code.encode()) > 32768:
        raise RunnerError("Watcher code exceeds 32 KB.")
    tree = ast.parse(code)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom, ast.ClassDef, ast.Global, ast.Nonlocal)):
            raise RunnerError("Imports, classes and global/nonlocal declarations are not watcher capabilities.")
        if isinstance(node, ast.Attribute) and node.attr not in {"get", "put", "read", "lower", "casefold", "strip", "startswith", "endswith", "split", "replace", "items", "keys", "values", "append", "pop", "join", "count"}:
            raise RunnerError("Private runtime attributes are not watcher capabilities.")
        if isinstance(node, ast.Name) and node.id.startswith("_"):
            raise RunnerError("Private runtime names are not watcher capabilities.")
    return code


def executable():
    # Framework Python bin is a launcher which posix_spawns Python.app. Execute
    # the real interpreter directly so no subprocess permission is necessary.
    app = Path(sys.base_prefix) / "Resources/Python.app/Contents/MacOS/Python"
    return str((app if app.is_file() else Path(sys.executable)).resolve())


def profile():
    interpreter = executable()
    stdlib = str(Path(sysconfig.get_path("stdlib")).resolve())
    runtime = ["/System/Library", "/usr/lib", "/Library/Caches/com.apple.dyld", stdlib,
               sys.base_prefix, str(Path(sys.base_prefix).resolve())]
    reads = " ".join("(subpath " + json.dumps(p, ensure_ascii=False) + ")" for p in runtime)
    return ('(version 1)(deny default)'
            '(allow process-exec (literal ' + json.dumps(interpreter) + '))'
            '(allow sysctl-read)(allow mach-lookup)'
            '(allow file-read* ' + reads + ' (literal ' + json.dumps(interpreter) + ') (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom") (literal "/"))'
            '(allow file-read-metadata)')


class Runner:
    def __init__(self, timeout=45):
        self.timeout = timeout

    def available(self):
        return sys.platform == "darwin" and Path("/usr/bin/sandbox-exec").is_file()

    def run(self, code, event, config, call):
        validate_code(code)
        if not self.available():
            raise RunnerError("Watcher activation requires the macOS sandbox runner. No unconfined Python fallback is allowed.")
        cmd = ["/usr/bin/sandbox-exec", "-p", profile(), executable(), "-I", "-S", "-c", BOOTSTRAP]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"}, cwd="/", start_new_session=True)
        deadline = time.monotonic() + self.timeout
        selector = selectors.DefaultSelector()
        buffers = {proc.stdout: b"", proc.stderr: b""}
        total = 0
        try:
            proc.stdin.write((json.dumps({"code": code, "event": event, "config": config}, allow_nan=False) + "\n").encode())
            proc.stdin.flush()
            for pipe in buffers:
                selector.register(pipe, selectors.EVENT_READ)
            while selector.get_map():
                try:
                    if proc.poll() is None and psutil.Process(proc.pid).memory_info().rss > 268435456:
                        raise RunnerError("Watcher memory limit exceeded.")
                except psutil.NoSuchProcess:
                    pass
                if time.monotonic() >= deadline:
                    raise RunnerError("Watcher timed out.")
                for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                    data = os.read(key.fileobj.fileno(), 4096)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(data)
                    if total > 131072:
                        raise RunnerError("Watcher output limit exceeded.")
                    buffers[key.fileobj] += data
                    if key.fileobj is proc.stderr:
                        continue
                    while b"\n" in buffers[proc.stdout]:
                        line, buffers[proc.stdout] = buffers[proc.stdout].split(b"\n", 1)
                        packet = json.loads(line)
                        if (set(packet) != {"capability", "args"} or packet["capability"] not in CAPABILITIES
                                or not isinstance(packet["args"], list)):
                            raise RunnerError("Unknown watcher capability.")
                        # A capability failure terminates the entire event, even if code
                        # attempts to catch it and ack. The parent never licenses that ack.
                        result = call(packet["capability"], packet["args"])
                        proc.stdin.write((json.dumps({"ok": True, "value": result}, allow_nan=False) + "\n").encode())
                        proc.stdin.flush()
            proc.wait(timeout=1)
            if proc.returncode:
                raise RunnerError("Watcher exited with an error; event retained.")
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            selector.close()
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                pipe.close()


def load_code(watcher):
    path = Path(watcher["code_path"])
    if path.is_symlink():
        raise RunnerError("Watcher code cannot be a symlink.")
    data = path.read_bytes()
    if len(data) > 32768 or hashlib.sha256(data).hexdigest() != watcher["code_sha256"]:
        raise RunnerError("Watcher code hash changed. Save a new watcher version before loading it.")
    return validate_code(data.decode())
