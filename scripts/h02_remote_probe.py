"""Disposable H02 adversary; can run unprivileged on a genuinely separate host.

Receives a ONE-TIME proposal capability only, never issuer keys or Alice owner
authority. A single-host CI invocation is NOT independent-host evidence.
"""
from __future__ import annotations

import argparse
import json
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BODY = b'{"job_id":"__REPLACE__","proposal":{"action":"search","epoch":0,"query":"keyboard"}}'


def connect(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=3):
            return True
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway", required=True, help="https://Alice-gateway:port")
    parser.add_argument("--ca", required=True, help="synthetic gateway CA certificate")
    parser.add_argument("--token-file", required=True, help="one-use PROPOSAL bearer only")
    parser.add_argument("--job", required=True)
    parser.add_argument("--private-ip", help="trusted operator-observed ASR IP; should not route from attacker")
    parser.add_argument("--expected-gateway-port", type=int, default=443)
    args = parser.parse_args()
    url = urllib.parse.urlsplit(args.gateway)
    if url.scheme != "https" or url.username or url.password or url.query or url.fragment or url.path:
        raise SystemExit("exact HTTPS gateway origin required")
    token = Path(args.token_file).read_text().strip()
    if not token.startswith("Alice-H02 "):
        raise SystemExit("expected scoped H02 proposal token")
    ctx = ssl.create_default_context(cafile=args.ca)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=ctx))
    body = BODY.replace(b"__REPLACE__", args.job.encode("ascii"))
    evidence = []

    def post(label: str, path: str, data: bytes, expected: int):
        request = urllib.request.Request(args.gateway + path, data=data, method="POST",
            headers={"Authorization": token, "Content-Type": "application/json"})
        try:
            with opener.open(request, timeout=12) as response:
                status = response.status
                response.read(16384)
        except urllib.error.HTTPError as exc:
            status = exc.code
            exc.read(16384)
        evidence.append({"test": label, "status": status, "expected": expected,
                         "passed": status == expected,
                         "classification": "AUTHORIZATION_OR_STATE"})

    post("scoped_proposal_works", "/v1/proposals", body, 200)
    post("consumed_capability_replay_denied", "/v1/proposals", body, 403)
    post("same_signature_different_payload_denied", "/v1/proposals", body + b" ", 403)
    post("proposal_bearer_no_commit", "/v1/commit", b'{"job_id":"' + args.job.encode() + b'"}', 403)
    post("proposal_bearer_no_human_takeover", "/v1/human-handoff",
         b'{"job_id":"' + args.job.encode() + b'"}', 403)
    if args.private_ip:
        for port, label in ((8443, "private_runner_tcp"), (9222, "private_cdp_tcp")):
            reached = connect(args.private_ip, port)
            evidence.append({"test": label, "passed": not reached,
                             "classification": "ROUTING_NEGATIVE_ONLY",
                             "limitation": "must independently attest live listener on Alice host"})
    print(json.dumps({"checks": evidence, "passed": all(e["passed"] for e in evidence),
                      "machine_separation": "REQUIRES_TRUSTED_OPERATOR_ATTESTATION"},
                     sort_keys=True))
    return 0 if all(e["passed"] for e in evidence) else 1


if __name__ == "__main__":
    raise SystemExit(main())
