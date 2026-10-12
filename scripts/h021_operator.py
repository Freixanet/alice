"""H02.1 trusted Alice synthetic operator, never run on personal Hermes."""
from __future__ import annotations

import json
import hashlib
import hmac
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from alice_secure_runner.h021_crypto import OfflineIssuer
from scripts import h02_operator as legacy

FIX = Path(os.environ["H02_FIXTURE_DIR"])
legacy.COMPOSE = ["docker", "compose", "-f", str(Path(__file__).resolve().parents[1] / "deploy/h021/compose.yaml")]
legacy.FIXTURE = FIX
GATEWAY = "https://" + os.environ.get("H02_PUBLIC_BIND", "127.0.0.1") + ":38444"


def issuer():
    return OfflineIssuer(str(FIX / "issuer-private.pem"), "h021-k1")


def signed(path, body, role="owner", job="", ttl=60):
    raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    token = issuer().mint(subject="test-user-a", tenant="fixture-tenant-a",
                          session="fixture-session-a", role=role, job=job,
                          path=path, body=raw, ttl=ttl)
    return raw, token


def request(path, body, role="owner", job=""):
    raw, token = signed(path, body, role, job)
    return send(path, raw, token)


def send(path, raw, token):
    ctx = ssl.create_default_context(cafile=str(FIX / "gateway.pem"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=ctx))
    req = urllib.request.Request(GATEWAY + path, data=raw, method="POST",
          headers={"Authorization": "Alice-H02 " + token, "Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def assert_live_private_asr(private_ip: str | None = None):
    code = ("import socket;"
            "s=socket.create_connection(('127.0.0.1',8443),timeout=3);s.close();"
            "print('LIVE_ASR_LISTENER')")
    out = legacy.docker("exec", "-T", "asr", "/opt/asr-python/bin/python", "-c", code)
    if "LIVE_ASR_LISTENER" not in out.stdout:
        raise AssertionError("cannot attest actual private ASR listener")
    if private_ip:
        # Check the exact Docker-private address that A will later probe,
        # not a guessed path or an absent public port.
        remote_code = ("import socket;"
                       "s=socket.create_connection((" + repr(private_ip) + ",8443),timeout=3);"
                       "s.close();print('LIVE_PRIVATE_BRIDGE_ASR_LISTENER')")
        out = legacy.docker("exec", "-T", "gateway", "python", "-c", remote_code)
        if "LIVE_PRIVATE_BRIDGE_ASR_LISTENER" not in out.stdout:
            raise AssertionError("B gateway cannot reach ASR private exact IP")


def simulate_gateway_compromise(token, raw, job):
    """Real existing job: H01 backend would permit resume with bearer ALONE."""
    correct = json.dumps({"job_id": job}, separators=(",", ":")).encode()
    # A captured owner capability for exact-body resume cannot authorize an
    # additional JSON field, even if gateway holds every backend bearer.
    _, captured_owner_token = signed("/v1/resume", {"job_id": job}, "owner", job)
    altered = json.dumps({"job_id": job, "extra": "malicious"},
                         separators=(",", ":")).encode()
    attempts = ((correct, None, "NO_SIGNATURE"),
                (altered, captured_owner_token, "MODIFIED_BODY"))
    for body, signed_capability, label in attempts:
        headers = "{'Authorization':'Bearer '+t,'Content-Type':'application/json'"
        if signed_capability:
            headers += ",'X-Alice-H021-Capability':" + repr(signed_capability)
        headers += "}"
        code = (
            "import ssl,urllib.request,urllib.error,pathlib;"
            "t=pathlib.Path('/run/h01-secrets/backend_coordinator_a').read_text().strip();"
            "ctx=ssl.create_default_context(cafile='/run/h01-ca/asr.pem');"
            "req=urllib.request.Request('https://asr:8443/v1/resume',"
            "data=" + repr(body) + ",method='POST',headers=" + headers + ");"
            "\ntry:\n urllib.request.urlopen(req,context=ctx,timeout=5);print('BYPASS')\n"
            "except urllib.error.HTTPError as exc:\n print('DENIED',exc.code)\n"
        )
        outcome = legacy.docker("exec", "-T", "gateway", "python", "-c", code)
        if "DENIED 403" not in outcome.stdout:
            raise AssertionError("gateway bearer/signed-body bypass: " + label)
        print("H021_GATEWAY_COMPROMISE_DENIED " + label, flush=True)


def verify_signed_fictional_checkout():
    """Cross the NEW double-signature boundary for every fake checkout step."""
    status, created = request("/v1/jobs", {
        "recipient": "Alice imaginary testing only",
        "create_request_id": "checkout-verify-only-001"})
    if status != 200:
        raise AssertionError("trusted synthetic job create denied")
    job = created["job_id"]
    actions = [
        {"action": "search", "query": "keyboard"},
        {"action": "read_product", "sku": "FAKE-ALICE-1"},
        {"action": "select_product", "sku": "FAKE-ALICE-1"},
        {"action": "add_to_cart", "quantity": 2},
        {"action": "prepare_checkout"},
    ]
    for epoch, action in enumerate(actions):
        body = {"job_id": job, "proposal": {**action, "epoch": epoch}}
        status, result = request("/v1/proposals", body, role="proposal", job=job)
        if status != 200:
            raise AssertionError("signed fake checkout step rejected: " + action["action"] +
                                 " HTTP " + str(status))
    if result.get("checkout", {}).get("amount_minor") != 4998:
        raise AssertionError("fictional total was not independently checked")
    status, challenge = request("/v1/challenge", {"job_id": job}, job=job)
    if status != 200:
        raise AssertionError("signed Alice challenge denied")
    # The synthetic USER key exists in B trusted operator fixture only;
    # gateway receives just a signature for this exact checkout challenge.
    approved_digest = hmac.new(
        bytes.fromhex((FIX / "device_hmac_hex").read_text().strip()),
        json.dumps(challenge, sort_keys=True, separators=(",", ":"),
                   ensure_ascii=False).encode(), hashlib.sha256).hexdigest()
    unsigned = {"job_id": job, "signature": "0" * 64}
    if request("/v1/approve", unsigned, job=job)[0] != 403:
        raise AssertionError("forged fictional user consent accepted")
    exact = {"job_id": job, "signature": approved_digest}
    if request("/v1/approve", exact, job=job)[0] != 200:
        raise AssertionError("exact fictional user consent rejected")
    if request("/v1/approve", exact, job=job)[0] != 403:
        raise AssertionError("approval replay accepted")
    status, receipt = request("/v1/commit", {"job_id": job}, job=job)
    if status != 200 or receipt.get("status") != "confirmed_simulated":
        raise AssertionError("fictional submit not verified")
    if request("/v1/commit", {"job_id": job}, job=job)[0] != 403:
        raise AssertionError("duplicate fake checkout dispatched")
    print("H021_SIGNED_FAKE_CHECKOUT_CONFIRMED_ONCE", flush=True)


def main():
    for _ in range(75):
        try:
            first, result = request("/v1/jobs", {
                "recipient":"Synthetic address", "create_request_id":"alice-create-case-0001"})
            if first == 200:
                break
        except OSError:
            pass
        time.sleep(1)
    else:
        raise AssertionError("H021 gateway or ASR not ready")
    job = result["job_id"]
    # Simulate lost success response, a NEW signed capability may retrieve
    # the SAME durable job via create_request_id, not create a second job.
    status, recovered = request("/v1/jobs", {
        "recipient":"Synthetic address", "create_request_id":"alice-create-case-0001"})
    if status != 200 or recovered["job_id"] != job:
        raise AssertionError("nonidempotent job creation")
    wrong, _ = request("/v1/jobs", {
        "recipient":"Changed address", "create_request_id":"alice-create-case-0001"})
    if wrong != 403:
        raise AssertionError("create_request_id changed recipient")
    ip = legacy.verify_policy()
    legacy.verify_sampled_asr_egress()
    assert_live_private_asr(ip)
    proposal_body = {"job_id":job,"proposal":{"action":"search","epoch":0,"query":"keyboard"}}
    raw, token = signed("/v1/proposals", proposal_body, role="proposal", job=job)
    (FIX/"untrusted_one_use_proposal").write_text("Alice-H02 " + token)
    probe = legacy.docker("--profile", "attack", "run", "--rm", "--no-deps",
        "hostile-hermes", "python", "/h02_remote_probe.py",
        "--gateway", "https://gateway:8443",
        "--ca", "/run/h02/gateway.pem",
        "--token-file", "/run/h02/untrusted_one_use_proposal",
        "--job", job, "--private-ip", ip)
    report = json.loads(probe.stdout.strip().splitlines()[-1])
    if not report["passed"]:
        raise AssertionError("hostile proposal test failed")
    print("H021_HOSTILE_PROBE " + json.dumps(report, sort_keys=True), flush=True)
    simulate_gateway_compromise(token, raw, job)
    verify_signed_fictional_checkout()
    # Signed resume survives ASR recreation, with the stable paired session.
    legacy.docker("up", "-d", "--force-recreate", "--no-deps", "asr")
    for _ in range(65):
        try:
            state, obj = request("/v1/resume", {"job_id":job}, job=job)
            if state == 200 and obj["job_id"] == job:
                break
        except OSError:
            pass
        time.sleep(1)
    else:
        raise AssertionError("durable ASR job not recoverable after restart")
    print("H021_DURABLE_JOB_RECOVERY_PASS", flush=True)
    print("H021_ADMIN_BOUNDARY_PENDING_NO_SECOND_VM", flush=True)


def prepare_remote():
    """Provision a throwaway test job; never export Alice's private issuer key."""
    for _ in range(80):
        try:
            status, result = request("/v1/jobs", {
                "recipient": "Remote synthetic acceptance address",
                "create_request_id": "remote-create-stable-0001"})
            if status == 200:
                break
        except OSError:
            pass
        time.sleep(1)
    else:
        raise AssertionError("Host B gateway or ASR not ready")
    job = result["job_id"]
    ip = legacy.verify_policy()
    legacy.verify_sampled_asr_egress()
    assert_live_private_asr(ip)
    proposal = {"job_id": job, "proposal": {
        "action": "search", "epoch": 0, "query": "keyboard"}}
    raw, token = signed("/v1/proposals", proposal, role="proposal", job=job, ttl=300)
    (FIX / "untrusted_one_use_proposal").write_text("Alice-H02 " + token)
    # This manifest contains no signing, workload, human or merchant secret.
    manifest = {"kind": "H021_REMOTE_FIXTURE_NOT_INDEPENDENT_PROOF",
                "gateway": "https://" + os.environ["H021_B_PUBLIC_IP"] + ":38444",
                "job": job, "private_runner_listener_positive_on_B": True,
                "private_runner_ip_B_only": ip,
                "gateway_ca_file": "gateway.pem",
                "token_file": "untrusted_one_use_proposal",
                "expires_after_seconds": 300,
                "B_admin_independence": "REQUIRES_EXTERNAL_ATTESTATION"}
    (FIX / "remote_manifest.json").write_text(json.dumps(manifest, sort_keys=True))
    print("H021_HOST_B_PRIVATE_LISTENER_PRESENT; remote proposal provisioned", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--prepare-remote"]:
        prepare_remote()
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit("h021_operator: no args (CI) or --prepare-remote (approved B)")
