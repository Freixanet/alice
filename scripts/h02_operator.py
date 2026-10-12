"""Synthetic Alice test operator: gateway + signed requests, never personal."""
from __future__ import annotations

import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from alice_secure_runner.h02_identity import Keyring

FIXTURE = Path(os.environ["H02_FIXTURE_DIR"])
GATEWAY = "https://127.0.0.1:38444"
COMPOSE = ["docker", "compose", "-f", str(Path(__file__).resolve().parents[1] / "deploy/h02/compose.yaml")]


def docker(*cmd):
    return subprocess.run([*COMPOSE, *cmd], check=True, capture_output=True, text=True, timeout=180)


def call(path, body, role, job=""):
    data = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    keys = Keyring.load(str(FIXTURE / "keyring.json"))
    token = keys.mint(subject="test-user-a", tenant="fixture-tenant-a",
                      session="fixture-session-a", role=role, job=job,
                      path=path, body=data)
    ctx = ssl.create_default_context(cafile=str(FIXTURE / "gateway.pem"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=ctx))
    req = urllib.request.Request(GATEWAY + path, data=data, method="POST",
                                 headers={"Authorization": "Alice-H02 " + token,
                                          "Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=12) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def main():
    for _ in range(80):
        try:
            status, response = call("/v1/jobs", {"recipient": "Fictional address"}, role="owner")
            if status == 200:
                break
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(1)
    else:
        raise AssertionError("H02 gateway->ASR not ready")
    job = response["job_id"]
    # Provision ONE specific low-authority request capability to a completely
    # separate process. The attacker cannot mint/change/reuse it.
    raw = b'{"job_id":"' + job.encode() + b'","proposal":{"action":"search","epoch":0,"query":"keyboard"}}'
    token = Keyring.load(str(FIXTURE / "keyring.json")).mint(
        subject="test-user-a", tenant="fixture-tenant-a", session="fixture-session-a",
        role="proposal", job=job, path="/v1/proposals", body=raw)
    token_path = FIXTURE / "untrusted_one_use_proposal"
    token_path.write_text("Alice-H02 " + token)
    asr_id = docker("ps", "-q", "asr").stdout.strip()
    observed = json.loads(subprocess.check_output(["docker", "inspect", asr_id], text=True))[0]
    networks = observed["NetworkSettings"]["Networks"]
    expected_name = os.environ["H02_COMPOSE_PROJECT"] + "_asr_backplane"
    if set(networks) != {expected_name}:
        raise AssertionError("ASR has unexpected routable Docker networks")
    network = json.loads(subprocess.check_output(["docker", "network", "inspect", expected_name], text=True))[0]
    if network["Internal"] is not True:
        raise AssertionError("ASR Docker network allows unanticipated egress")
    if any(observed["NetworkSettings"].get("Ports", {}).values()):
        raise AssertionError("private ASR port exposed to host")
    ip = networks[expected_name]["IPAddress"]
    if not ip:
        raise AssertionError("ASR real private IP missing")
    print("H02_ALICE_OPERATOR_PRIVATE_POLICY_VERIFIED", flush=True)
    result = docker("--profile", "attack", "run", "--rm", "--no-deps",
                    "hostile-hermes", "python", "/h02_remote_probe.py",
                    "--gateway", "https://gateway:8443",
                    "--ca", "/run/h02/gateway.pem",
                    "--token-file", "/run/h02/untrusted_one_use_proposal",
                    "--job", job, "--private-ip", ip)
    output = json.loads(result.stdout.strip().splitlines()[-1])
    if not output["passed"]:
        raise AssertionError("H02 hostile proposal or private socket checks failed")
    print("H02_ATTACK_REPORT " + json.dumps(output, sort_keys=True), flush=True)
    print("H02_SINGLE_DOCKER_HOST_TEST_ONLY: independent administrative host still PENDING", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] != "e2e":
        raise SystemExit("usage: python scripts/h02_operator.py e2e")
    main()
