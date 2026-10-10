"""Explicit browser integration check with synthetic products and isolated Chrome.

Run with Hermes' Python containing browser-harness, with its source on PYTHONPATH.
Never connects to the person's Hermes gateway, Chrome on 9222, vault or shops.
"""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import socket
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main():
    with tempfile.TemporaryDirectory(prefix="alice-bh-", dir="/tmp") as folder:
        home = Path(folder)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        assert port != 9222
        url = f"http://127.0.0.1:{port}"
        os.environ.update({
            "HERMES_HOME": str(home), "BU_CDP_URL": url, "BROWSER_CDP_URL": url,
            "BH_HOME": str(home / "harness"), "BH_TMP_DIR": str(home / "tmp"),
            "BH_RUNTIME_DIR": str(home / "runtime"), "BH_RUNTIME_DIR_SHARED": "1",
            "BH_TMP_DIR_SHARED": "1", "ANONYMIZED_TELEMETRY": "false",
        })
        (home / "config.yaml").write_text(f"browser:\n  cdp_url: {url}\n")
        plugin_dir = Path(__file__).resolve().parents[1] / "hermes-plugin"
        live = load("alice_browser_live", plugin_dir / "browser_live.py")
        live.MANAGED_URL = url
        launch = live.launch
        live.launch = lambda root: launch(root, port=port)
        live._save_state(home, {"managed": True})
        plugin = load("alice_browser_smoke_plugin", plugin_dir / "__init__.py")
        errands, flow = plugin._errands(), plugin._purchase_flow()
        plugin._hermes_root = lambda: home
        from tools.browser_use_cli import browser_exec
        from browser_harness import _ipc

        ids = [os.urandom(5).hex(), os.urandom(5).hex()]
        try:
            assert not live.reachable(url), "The fixture browser must begin shut down"
            assert errands.prepare_browser(home), "Cold browser start failed"
            assert live.reachable(url)
            print("PASS: cold start through the errand preflight", flush=True)

            html = """<h1>Prozis Creapure 300 g</h1><div id="cart">0</div>
<button onclick="document.getElementById('cart').textContent='1'">Añadir</button>
<div id="total">24,49 €</div>"""
            page = "data:text/html;charset=utf-8," + quote(html)

            def execute(identifier, code):
                directive = plugin._isolate_errand_browser(
                    "browser_exec", {"code": code, "timeout_s": 45},
                    session_id="errand-" + identifier)
                result = browser_exec(**directive["args"], task_id="fixture-" + identifier)
                if isinstance(result, str):
                    result = json.loads(result)
                if result.get("_multimodal"):
                    assert result.get("meta", {}).get("native_vision"), "Screenshot was not attached"
                    result = json.loads(result["text_summary"].split("\n\nThe screenshot", 1)[0])
                assert result.get("success"), str(result)
                return result.get("output", "")

            assert errands.pay_gate(home, "errand-" + ids[0], tool_name="browser_exec",
                                    args={"code": "print(js(\"document.body.innerText.includes('pagar')\"))"},
                                    active_url="https://example.com/checkout/payment") is None
            first = execute(ids[0], f"""# Preparar la cesta de prueba
foreign = cdp("Target.createTarget", url={page!r}).get("targetId")
ensure_real_tab()
assert current_tab()["targetId"] != foreign, "ensure_real_tab escaped to another basket"
goto_url({page!r})
wait_for_load()
print(js("document.querySelector('button').textContent"))
js("document.querySelector('button').click()")
cdp("Network.setCookie", name="basket", value="A", url="https://example.com")
print("CART=" + js("document.getElementById('cart').textContent"))
""")
            assert "CART=1" in first, first
            second = execute(ids[1], f"""# Otra cesta aislada
new_tab({page!r})
wait_for_load()
print("COOKIES=" + str(len(cdp("Network.getCookies", urls=["https://example.com"]).get("cookies", []))))
""")
            assert "COOKIES=0" in second, second
            again = execute(ids[0], f"""# Recuperar el recado y abrir otra pestaña
ensure_real_tab()
assert js("document.querySelector('button').textContent") == "Añadir", "Product controls disappeared between steps"
new_tab({page!r})
wait_for_load()
cookies = cdp("Network.getCookies", urls=["https://example.com"]).get("cookies", [])
print("BASKET=" + str(next((c["value"] for c in cookies if c["name"] == "basket"), "")))
print("TOTAL=" + js("document.getElementById('total').textContent"))
capture_screenshot()
""")
            assert "BASKET=A" in again and "TOTAL=24,49 €" in again, again
            assert "shot.png" in again, "The screenshot path was lost instead of reaching Hermes"
            print("PASS: real Hermes browser_exec, separate baskets, restored context, controls, new tabs and screenshots", flush=True)

            options = [
                {"title": "Prozis Creapure 300 g", "merchant": "Prozis", "price": "24,49 €",
                 "currency": "EUR", "url": "https://www.prozis.com/fixture", "in_stock": True},
                {"title": "Creapure 500 g", "merchant": "Body&Fit", "price": "24,99 €",
                 "currency": "EUR", "url": "https://www.bodyandfit.com/fixture", "in_stock": True},
            ]
            shown = flow.present(home, "fixture-chat", {"options": options},
                                 request="Compra la creatina creapure de prozis")
            assert shown["ok"] and len(shown["options"]) == 1
            chosen = flow.choose(home, "fixture-chat", shown["options"][0]["id"])
            entry = errands.create(home, flow.task(chosen), offer=flow.offer(chosen))
            checkout = errands.request_checkout(home, entry["id"], {
                "site": "prozis.com", "merchant": "Prozis", "items": [{"name": chosen["title"], "qty": 1}],
                "total": "24,49 €", "currency": "EUR",
            }, fetch=lambda *_: (b"", "text/html"), saved_cards=lambda: [{"label": "Fixture card"}])
            assert checkout["status"] == "needs_approval"
            checkout_id = errands.get(home, entry["id"])["checkout"]["id"]
            approved = errands.decide_checkout(home, entry["id"], True, checkout_id=checkout_id)
            assert approved["checkout"]["approved_cents"] == 2449
            errands.record_receipt(home, entry["session_id"], {
                "outcome": "paid", "order": "FIXTURE-ONLY", "total": "24,49 €",
            })
            assert errands.get(home, entry["id"])["receipt"]["total_cents"] == 2449
            print("PASS: requested brand → choice → fixture checkout → exact approval → fixture receipt", flush=True)
        finally:
            try:
                version = live._get_json(url + "/json/version")
                for identifier in ids:
                    errands.release_context(identifier, browser_ws=version["webSocketDebuggerUrl"])
                live._command(version["webSocketDebuggerUrl"], "Browser.close", {})
            except Exception:
                pass
            for identifier in ids:
                pid_file = _ipc.pid_path("errand-" + identifier)
                try:
                    os.kill(int(pid_file.read_text().strip()), signal.SIGTERM)
                except (OSError, ValueError):
                    pass
                errands.context_file(identifier).unlink(missing_ok=True)
            time.sleep(1)


if __name__ == "__main__":
    main()
