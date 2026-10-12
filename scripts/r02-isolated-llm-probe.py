"""Opt-in real local model / official Hermes facade experiment, NO accounts.

This is NOT a complete Hermes plugin-host E2E: it imports pristine official
PluginLlm source from a temporary git archive, injects a test-only caller to a
new dedicated Ollama daemon, and runs a real locally cached open-weight model.
No personal Hermes/Ollama services, tokens, config, accounts or production.

Invoke ONLY in an approved disposable R02 laboratory:
  python3.11 scripts/r02-isolated-llm-probe.py \
      --hermes-source /path/to/official/hermes-agent \
      --model-cache /path/to/read-only/model-cache
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))


def _clone_model_weights(source: Path, target: Path, model: str) -> None:
    name, tag = model.split(":", 1)
    path = source / "manifests" / "registry.ollama.ai" / "library" / name / tag
    manifest = json.loads(path.read_text())
    out = target / "manifests" / "registry.ollama.ai" / "library" / name / tag
    out.parent.mkdir(parents=True)
    out.write_text(json.dumps(manifest))
    blobs = target / "blobs"
    blobs.mkdir(parents=True)
    for item in [manifest["config"], *manifest["layers"]]:
        digest = item["digest"].replace(":", "-")
        # APFS copy-on-write clone has an independent inode, unlike hardlinks;
        # the disposable server cannot modify the original cached weights.
        # Fail closed on filesystems where a cheap independent clone is absent.
        subprocess.run(["cp", "-c", str(source / "blobs" / digest), str(blobs / digest)],
                       check=True, stdout=subprocess.DEVNULL)


def _request(port: int, endpoint: str, payload: dict | None = None, timeout=10):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{endpoint}", data=data,
                                 headers={"Content-Type": "application/json"})
    # Never inherit any proxies or cloud services from the caller environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes-source", required=True)
    parser.add_argument("--model-cache", required=True)
    parser.add_argument("--model", default="deepseek-r1:1.5b")
    args = parser.parse_args()
    source = Path(args.hermes_source).resolve()
    if not (source / ".git").exists() or not (source / "agent" / "plugin_llm.py").exists():
        raise SystemExit("Official Hermes source checkout required")
    ollama = shutil.which("ollama")
    if not ollama:
        raise SystemExit("No local open-weight Ollama runtime")

    import test_alice_secure_runner as fixture
    from alice_secure_runner.core import AliceRunner, FictionalHTTPSAdapter
    from alice_secure_runner.coordinator import Coordinator
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="alice-r02-isolated-real-model-") as td:
        home = Path(td)
        # The source file is copied from a clean official Git HEAD into a
        # disposable module tree. No importing or editing personal Hermes.
        blob = subprocess.check_output(["git", "-C", str(source), "show", "HEAD:agent/plugin_llm.py"])
        impl = home / "official_agent" / "plugin_llm.py"
        impl.parent.mkdir()
        impl.write_bytes(blob)
        spec = importlib.util.spec_from_file_location("r02_pristine_official_plugin_llm", impl)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod
        spec.loader.exec_module(mod)
        verified_git = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        _clone_model_weights(Path(args.model_cache).resolve(), home / "models", args.model)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home / "home"),
               "OLLAMA_MODELS": str(home / "models"), "OLLAMA_HOST": f"127.0.0.1:{port}",
               "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_LOADED_MODELS": "1",
               "OLLAMA_KEEP_ALIVE": "0", "OLLAMA_NOHISTORY": "1", "OLLAMA_NUM_GPU": "0"}
        (home / "home").mkdir()
        process = subprocess.Popen([ollama, "serve"], cwd=str(home), env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise RuntimeError("Disposable local model server exited")
                try:
                    _request(port, "/api/version", timeout=1)
                    break
                except (OSError, ValueError):
                    time.sleep(.2)
            else:
                raise RuntimeError("Disposable local model server did not start")

            def transport(**kw):
                if kw.get("provider_override") or kw.get("model_override") or kw.get("task"):
                    raise RuntimeError("Unexpected host/model/tool override")
                messages = []
                for msg in kw["messages"]:
                    content = msg["content"]
                    if isinstance(content, list):
                        content = "\n".join(block.get("text", "") for block in content if isinstance(block, dict))
                    messages.append({"role": msg["role"], "content": content})
                request = {"model": args.model, "messages": messages, "stream": False,
                           "format": "json", "options": {"num_predict": 140, "temperature": 0},
                           "keep_alive": "0s"}
                out = _request(port, "/api/chat", request, timeout=180)
                generated = out.get("message", {}).get("content", "")
                response = SimpleNamespace(
                    choices=[SimpleNamespace(message=SimpleNamespace(content=generated))],
                    usage=SimpleNamespace(prompt_tokens=out.get("prompt_eval_count", 0),
                                          completion_tokens=out.get("eval_count", 0)), model=args.model)
                return ("isolated-local-ollama", args.model, response)

            llm = mod.make_plugin_llm_for_test(plugin_id="alice_r02_fixture",
                                                policy=mod._TrustPolicy(plugin_id="alice_r02_fixture"),
                                                sync_caller=transport)
            planner_path = repo / "hermes-plugin" / "r02_planner.py"
            pspec = importlib.util.spec_from_file_location("r02_planner_for_real_test", planner_path)
            planner_module = importlib.util.module_from_spec(pspec)
            pspec.loader.exec_module(planner_module)
            ctx = SimpleNamespace(llm=llm)

            class ActualModelPlanner:
                def __init__(self):
                    self.observations = []
                    self.calls = 0

                def next_action(self, obs):
                    self.observations.append(obs)
                    self.calls += 1
                    return planner_module.propose(ctx, goal=(
                        "Fictional testing only: prepare purchase of 2 FAKE-ALICE-1 keyboards. "
                        "Order of actions: search(query='keyboard'), read_product(sku='FAKE-ALICE-1'), "
                        "select_product(sku='FAKE-ALICE-1'), add_to_cart(quantity=2), "
                        "prepare_checkout(). Do not skip or repeat steps."),
                        observations=self.observations, epoch=obs["epoch"])

            fixture.RunnerHTTPSContractTests.setUpClass()
            try:
                cls = fixture.RunnerHTTPSContractTests
                key = secrets.token_bytes(32)
                runner = AliceRunner(FictionalHTTPSAdapter(origin=cls.shop.url,
                                  ca_file=cls.cert, merchant_token=cls.shop_secret), approval_key=key)
                planner = ActualModelPlanner()
                coordinator = Coordinator(runner, tenant="test-tenant", session="separate-official-facade",
                                          recipient="Fake address", planner=planner)
                state = "not_started"
                failure = ""
                try:
                    out = coordinator.run_to_approval(max_steps=5)
                    state = out["status"]
                except Exception as exc:
                    state = type(exc).__name__
                    failure = str(exc)[:180]
                    if exc.__cause__ is not None:
                        failure += "; cause=" + type(exc.__cause__).__name__ + ":" + str(exc.__cause__)[:120]
                print(json.dumps({"official_source": verified_git, "facade_sha256": hashlib.sha256(blob).hexdigest(),
                                  "provider": "isolated local open-weight model", "model": args.model,
                                  "calls": planner.calls, "reason": failure,
                                  "result": state, "merchant_checkout_submits": cls.store.submit_attempts,
                                  "isolated_temporary_ollama_home_and_port": True,
                                  "full_hermes_plugin_host_test": False}, sort_keys=True))
                return 0 if state == "awaiting_approval" else 2
            finally:
                fixture.RunnerHTTPSContractTests.tearDownClass()
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
