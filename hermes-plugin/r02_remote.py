"""Proposal-only HTTPS transport usable by the official Hermes plugin loader.

There is no ASR import, checkout or browser authority in this module. A trusted
Alice operator must separately provision its short-lived proposal bearer and
private-CA certificate in a disposable Hermes installation. No personal
Hermes configuration is touched by this module.
"""

from __future__ import annotations

import json
import os
import re
import ssl
import stat
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


TOOL_NAME = "alice_secure_plan_remote"
TOOLSET = "alice_secure_planning"
SCHEMA = {
    "name": TOOL_NAME,
    "description": "Submit exactly one non-executing shopping plan to a paired Alice proposal mailbox.",
    "parameters": {
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": False,
    },
}


class RemotePlanningDenied(ValueError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise RemotePlanningDenied("planner redirect denied")


def _settings(config: dict[str, str]) -> tuple[str, ssl.SSLContext, str]:
    origin = config.get("origin", "")
    parsed = urllib.parse.urlsplit(origin)
    if (parsed.scheme != "https" or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")
            or parsed.hostname not in ("localhost", "127.0.0.1", "::1")):
        # The proof transport is deliberately loopback-only until a real Alice
        # IdP, deployment allowlist and remote TLS policy have been audited.
        raise RemotePlanningDenied("only disposable local Alice HTTPS pairing is supported")
    ca = Path(config.get("ca_file", ""))
    bearer_file = Path(config.get("bearer_file", ""))
    if not ca.is_file() or ca.is_symlink() or not bearer_file.is_file() or bearer_file.is_symlink():
        raise RemotePlanningDenied("missing or untrusted local pairing material")
    mode = bearer_file.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise RemotePlanningDenied("planner-only bearer file must be private")
    token = bearer_file.read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
        raise RemotePlanningDenied("invalid proposal-only token")
    try:
        context = ssl.create_default_context(cafile=str(ca))
    except (OSError, ssl.SSLError) as exc:
        raise RemotePlanningDenied("unknown Alice control plane CA") from exc
    return origin.rstrip("/"), context, token


def _exchange(config: dict[str, str], *, method: str, path: str,
              payload: dict[str, Any] | None = None) -> dict[str, Any]:
    origin, context, token = _settings(config)
    # Fixed URLs only. Disable ambient proxy and redirections: credentials must
    # never follow a merchant, fake Alice endpoint or env-controlled proxy.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
        _NoRedirect())
    body = json.dumps(payload, separators=(",", ":")).encode() if payload is not None else None
    request = urllib.request.Request(
        origin + path, data=body, method=method,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"})
    try:
        with opener.open(request, timeout=5) as response:
            raw = response.read(8193)
    except (OSError, ValueError, RemotePlanningDenied) as exc:
        raise RemotePlanningDenied("remote proposal-only transport unavailable") from exc
    if len(raw) > 8192:
        raise RemotePlanningDenied("unbounded remote observation")
    try:
        parsed = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise RemotePlanningDenied("malformed Alice response") from exc
    if not isinstance(parsed, dict):
        raise RemotePlanningDenied("invalid Alice response")
    return parsed


def plan_once(ctx: Any, *, config: dict[str, str], planner_module: Any) -> dict:
    """One official-LLM proposal. No action executed by Hermes or this tool."""
    step = _exchange(config, method="GET", path="/v1/planner/next")
    if step.get("status") == "idle":
        return {"status": "idle", "execution_authority": False}
    if (set(step) != {"status", "step_id", "epoch", "nonce", "goal",
                      "observation", "execution_authority"}
            or step.get("status") != "pending" or step.get("execution_authority") is not False
            or not isinstance(step.get("observation"), dict)
            or type(step.get("epoch")) is not int):
        raise RemotePlanningDenied("invalid trusted Alice step")
    proposal = planner_module.propose(
        ctx, goal=step["goal"], observations=[step["observation"]], epoch=step["epoch"])
    response = _exchange(config, method="POST", path="/v1/planner/proposal",
                         payload={"step_id": step["step_id"], "nonce": step["nonce"],
                                  "proposal": proposal})
    if response != {"status": "accepted_untrusted", "execution_authority": False}:
        raise RemotePlanningDenied("proposal acknowledgement not verified")
    return {"status": "submitted_untrusted", "execution_authority": False}


def register(ctx: Any, planner_module: Any) -> None:
    registration = getattr(ctx, "register_tool", None)
    if not callable(registration):
        raise RemotePlanningDenied("official Hermes plugin registration missing")

    def handler(args=None, **_):
        # No model-supplied endpoint, token, arbitrary URL, credentials or
        # callback. Configured by the Alice installation administrator only.
        if args not in (None, {}):
            return json.dumps({"status": "denied", "execution_authority": False})
        try:
            result = plan_once(
                ctx, config={
                    "origin": os.environ.get("ALICE_R02_PLANNER_ORIGIN", ""),
                    "ca_file": os.environ.get("ALICE_R02_PLANNER_CA_FILE", ""),
                    "bearer_file": os.environ.get("ALICE_R02_PLANNER_BEARER_FILE", ""),
                }, planner_module=planner_module)
            return json.dumps(result, sort_keys=True)
        except Exception:
            return json.dumps({"status": "denied", "execution_authority": False})

    registration(name=TOOL_NAME, toolset=TOOLSET, schema=SCHEMA,
                 handler=handler, check_fn=lambda *_a, **_kw: True,
                 description=SCHEMA["description"], emoji="🔒")
