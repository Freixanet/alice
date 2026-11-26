#!/usr/bin/env python3
"""Synthetic R02 NO-GO canary against the installed Hermes *source contract*.

This script executes no browser, network, payment, real tool or personal profile.
All callbacks that represent an effect append to an in-memory list. It is NOT
part of green CI: exit code 2 means a required invariant is not enforced.

Usage:
    PYTHONPATH=/path/to/hermes-agent /path/to/hermes-venv/bin/python \
        scripts/verify-r02-executor-contract.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import types
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def _load_plugin():
    spec = importlib.util.spec_from_file_location("r02_canary_alice_plugin", ROOT / "hermes-plugin" / "__init__.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    # Importing source functions is not dispatching real agent/browser tools.
    from agent import tool_executor
    from hermes_cli import middleware

    found: dict[str, bool] = {}
    stub = types.SimpleNamespace(
        name="browser_click", args={"ref": "@e7"}, task_id="synthetic",
        call_id="synthetic-1", trace=[],
    )
    with mock.patch("hermes_cli.plugins._dispatch_pre_tool_call_hooks",
                    side_effect=RuntimeError("synthetic hook failure")):
        block, _args = tool_executor._pre_tool_block(None, stub)
    found["unsafe_core_hook_failure_allows_action"] = block is None

    effects: list[str] = []

    def failing_middleware(**_):
        raise RuntimeError("synthetic middleware failure before authorization")

    manager = types.SimpleNamespace(
        _middleware={middleware.TOOL_EXECUTION_MIDDLEWARE: [failing_middleware]},
        _report_hook_failure=lambda *args, **kwargs: None,
    )
    with mock.patch("hermes_cli.plugins._delivery_manager", return_value=manager):
        middleware.run_tool_execution_middleware(
            "browser_click", {"ref": "@e7"},
            lambda _args: effects.append("simulated-only"), session_id="synthetic",
        )
    found["unsafe_core_middleware_failure_allows_action"] = bool(effects)

    plugin = _load_plugin()
    errands = plugin._errands()
    access = plugin._module("errand_access.py", "alice_errand_access")
    with tempfile.TemporaryDirectory(prefix="alice-r02-canary-") as root:
        home = Path(root)
        entry = errands.create(
            home, "Synthetic product browse only", title="Synthetic cart", offer={
                "option_id": "synthetic", "url": "https://shop.invalid/item", "price": "34,99 €",
            },
        )
        context = ("https://shop.invalid", {"url": "https://shop.invalid/order/final"}, None)
        with mock.patch.object(plugin, "_hermes_root", return_value=home), \
                mock.patch.object(plugin, "_active_url", return_value="https://shop.invalid/item"), \
                mock.patch.object(access, "target", return_value=context), \
                mock.patch.object(access, "page_evaluate", return_value=False):
            decision = plugin._guard_errand(
                "browser_click", {"ref": "@e7"}, session_id=entry["session_id"])
            found["unsafe_opaque_final_button_allowed"] = decision is None
            with mock.patch.object(errands, "pay_gate", side_effect=RuntimeError("synthetic gate failure")):
                decision = plugin._guard_errand(
                    "browser_click", {"ref": "@e7"}, session_id=entry["session_id"])
            found["unsafe_plugin_exception_allows_click"] = decision is None
            found["safe_read_helper_allowed"] = plugin._guard_errand(
                "browser_exec", {"code": "print(page_info())"},
                session_id=entry["session_id"]) is None
            found["raw_cdp_blocked"] = bool((plugin._guard_errand(
                "browser_cdp", {"method": "Runtime.evaluate", "params": {"expression": "0"}},
                session_id=entry["session_id"]) or {}).get("action") == "block")
            found["indirect_js_blocked"] = bool((plugin._guard_errand(
                "browser_exec", {"code": 'js("window[\'cl\'+\'ick\']()")'},
                session_id=entry["session_id"]) or {}).get("action") == "block")
            found["chained_tab_switch_blocked"] = bool((plugin._guard_errand(
                "browser_exec", {"code": "switch_tab('x'); click(2)"},
                session_id=entry["session_id"]) or {}).get("action") == "block")
            found["unapproved_recognized_payment_blocked"] = bool((errands.pay_gate(
                home, entry["session_id"], tool_name="browser_click",
                args={"text": "Pay now"}, active_url="https://shop.invalid/checkout/payment",
                payment_step=True) or {}).get("action") == "block")

            requested = errands.request_checkout(home, entry["id"], {
                "merchant": "Synthetic", "site": "https://shop.invalid", "total": "34,99 €",
                "currency": "EUR", "items": [{"name": "Fictional product"}],
            }, fetch=lambda *_: (b"", "text/html"))
            if requested.get("ok"):
                current = errands.get(home, entry["id"])["checkout"]
                errands.decide_checkout(home, entry["id"], True, checkout_id=current["id"])
                def recognized_payment(merchant):
                    return errands.pay_gate(home, entry["session_id"],
                                            tool_name="browser_click", args={"text": "Pay now"},
                                            active_url=merchant + "/checkout/payment", payment_step=True)
                found["approved_shop_matches_pay_gate_only"] = recognized_payment(
                    "https://shop.invalid") is None
                found["wrong_approved_shop_payment_blocked"] = bool((recognized_payment(
                    "https://other.invalid") or {}).get("action") == "block")
                # This canary has deliberately *not* established trusted cart or
                # checkout_evidence; a live payment_ready cannot be claimed.
                prices = plugin._module("purchase_prices.py", "alice_purchase_prices")
                found["mock_checkout_not_executable_without_evidence"] = not prices.payment_ready(
                    home, errands.get(home, entry["id"]))
                # The two calls model two *authorization decisions*, not real
                # payments. A proper action capability would be single-use.
                found["unsafe_checkout_approval_reusable_for_pay_gate"] = (
                    recognized_payment("https://shop.invalid") is None and
                    recognized_payment("https://shop.invalid") is None)
            else:
                found["approved_shop_matches_pay_gate_only"] = False
                found["wrong_approved_shop_payment_blocked"] = False
                found["mock_checkout_not_executable_without_evidence"] = False
                found["unsafe_checkout_approval_reusable_for_pay_gate"] = False

    unsafe = sorted(k for k, v in found.items() if k.startswith("unsafe_") and v)
    positives_missing = sorted(k for k, v in found.items() if not k.startswith("unsafe_") and not v)
    print(json.dumps({"kind": "synthetic R02 executor-contract canary", "checks": found,
                      "unsafe_gap_count": len(unsafe), "unsafe_gaps": unsafe,
                      "positive_regressions": positives_missing,
                      "contract_probes_pass": not unsafe and not positives_missing,
                      "ready_to_close_R02": False,
                      "reason": "A green synthetic canary is never full browser/executor integration evidence."},
                     indent=2, sort_keys=True))
    return 2 if unsafe or positives_missing else 0


if __name__ == "__main__":
    # Set a disposable HOME before importing Hermes source, even though no
    # browser, service, network transport or real tool is invoked by the probe.
    with tempfile.TemporaryDirectory(prefix="alice-r02-synthetic-home-") as sandbox:
        os.environ["HOME"] = sandbox
        os.environ["HERMES_HOME"] = str(Path(sandbox) / ".hermes")
        sys.dont_write_bytecode = True
        try:
            sys.exit(main())
        except Exception as exc:
            print(json.dumps({"kind": "synthetic R02 executor-contract canary",
                              "ready_to_close_R02": False, "probe_error": type(exc).__name__}))
            sys.exit(3)
