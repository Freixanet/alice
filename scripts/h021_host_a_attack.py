"""Approved external Host A evidence probe; never provisions any infrastructure.

Requires root privileges on disposable HOST A and trust in B's separately
collected evidence. Negative TCP probes are NOT a claim of an existing service
unless the Alice-side positive listener attestation was independently verified.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import platform
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path


def tcp(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, help="B operator's redacted manifest")
    parser.add_argument("--ca", required=True)
    parser.add_argument("--proposal", required=True, help="one-use capability only")
    parser.add_argument("--approved-target", action="store_true",
                        help="operator confirms B IP belongs to authorized disposable fixture")
    args = parser.parse_args()
    if not args.approved_target or os.geteuid() != 0:
        raise SystemExit("requires explicit approved target and HOST A root privileges")
    info = json.loads(Path(args.manifest).read_text())
    if info.get("kind") != "H021_REMOTE_FIXTURE_NOT_INDEPENDENT_PROOF":
        raise SystemExit("incorrect fixture manifest")
    origin = urllib.parse.urlsplit(info["gateway"])
    if (origin.scheme != "https" or origin.port != 38444 or
            origin.username or origin.password or origin.path or origin.query or origin.fragment):
        raise SystemExit("only an explicit approved TLS gateway origin is supported")
    b_ip = origin.hostname
    if not b_ip or not info.get("private_runner_listener_positive_on_B"):
        raise SystemExit("independent B-side listener evidence required")
    try:
        target = ipaddress.ip_address(b_ip)
    except ValueError as exc:
        raise SystemExit("B target must be an explicitly approved IPv4 address") from exc
    if target.version != 4 or target.is_loopback or target.is_multicast or target.is_unspecified:
        raise SystemExit("refuse local/broadcast or non-IPv4 destination")
    # The B-side attestation is NOT authenticated by this file alone; an Alice
    # administrator must independently verify its origin/VM timestamps.
    command = [sys.executable, str(Path(__file__).with_name("h02_remote_probe.py")),
               "--gateway", info["gateway"], "--ca", args.ca,
               "--token-file", args.proposal, "--job", info["job"]]
    result = subprocess.run(command, check=False, text=True, capture_output=True, timeout=100)
    if result.returncode:
        print(result.stderr[-1200:], file=sys.stderr)
        raise SystemExit("authorized proposal/replay boundary not demonstrated")
    evidence = json.loads(result.stdout.strip().splitlines()[-1])
    negative = {}
    for port in (8443, 9222, 2375, 2376, 5432, 6379):
        reached = tcp(b_ip, port)
        negative[str(port)] = {"reached": reached, "classification": (
            "EXPOSED" if reached else "NOT_REACHABLE_OR_ABSENT_REQUIRES_B_POSITIVE_ATTESTATION")}
    evidence = {
        "headless_host_A_root": True,
        "host_A_kernel": platform.system() + "-" + platform.machine(),
        "host_A_machine_hash": hashlib.sha256(
            Path("/etc/machine-id").read_bytes() if Path("/etc/machine-id").exists()
            else platform.node().encode()).hexdigest()[:20],
        "host_A_time_utc_epoch": int(time.time()),
        "target_B": b_ip,
        "gateway_proposal": evidence,
        "selected_private_and_administrative_ports": negative,
        "actual_independent_administrative_control": "PENDING MANUAL CLOUD/IAM ATTESTATION",
        "B_private_listener_present": "B_OPERATOR_MANIFEST_UNTRUSTED_UNTIL_INDEPENDENTLY_ATTESTED",
    }
    print(json.dumps(evidence, sort_keys=True))
    return 1 if any(value["reached"] for value in negative.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
