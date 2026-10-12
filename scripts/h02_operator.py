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


def verify_policy():
    """Inspect *effective* Docker network/port policy, not just Compose YAML."""
    if not __debug__:
        raise RuntimeError("refuse Docker security verification under python -O")
    project = os.environ["H02_COMPOSE_PROJECT"]
    private = project + "_asr_backplane"
    public = project + "_public_front"
    expected = {"asr": {private}, "gateway": {private, public}}
    for service in ("asr", "gateway"):
        identifier = docker("ps", "-q", service).stdout.strip()
        if not identifier:
            raise AssertionError("container not running: " + service)
        observed = json.loads(subprocess.check_output(["docker", "inspect", identifier], text=True))[0]
        host = observed["HostConfig"]
        if (host.get("Privileged") or host.get("ReadonlyRootfs") is not True
                or host.get("NetworkMode") == "host"
                or host.get("PidMode") == "host"
                or "ALL" not in (host.get("CapDrop") or [])
                or observed["Config"]["User"] !=
                ("12001:12001" if service == "asr" else "12002:12002")
                or any(m["Destination"] == "/var/run/docker.sock" for m in observed.get("Mounts", []))):
            raise AssertionError("unsafe live container privileges: " + service)
        networks = observed["NetworkSettings"]["Networks"]
        if set(networks) != expected[service]:
            raise AssertionError("unexpected live Docker network membership: " + service)
        for name in networks:
            net = json.loads(subprocess.check_output(["docker", "network", "inspect", name], text=True))[0]
            if net["Internal"] != (name == private):
                raise AssertionError("unexpected live network internal policy: " + name)
        ports = observed["NetworkSettings"].get("Ports") or {}
        if service == "asr":
            if any(v for v in ports.values()):
                raise AssertionError("private ASR port exposed on host")
            private_ip = networks[private].get("IPAddress")
            if not private_ip:
                raise AssertionError("private ASR IP missing")
        else:
            bindings = ports.get("8443/tcp") or []
            if (set(ports) != {"8443/tcp"} or len(bindings) != 1
                    or bindings[0].get("HostIp") != os.environ["H02_PUBLIC_BIND"]
                    or bindings[0].get("HostPort") != "38444"):
                raise AssertionError("H02 gateway binding unexpectedly widened")
    return private_ip


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
    ip = verify_policy()
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
