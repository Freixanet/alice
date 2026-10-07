"""Alice for Hermes.

Most of this plugin lives in the dashboard: ``dashboard/plugin_api.py`` serves pairing,
memory, notes and the shared agent-create/rename engine under ``/api/plugins/alice/``,
and ``dashboard/dist/index.js`` is the Alice tab.

The agent gains one rule: the Business team talks only among itself. A
``pre_tool_call`` hook enforces it, and a system prompt section tells each agent whom
it may message, so it does not try the others. A profile filed in the Business channel (``ui_meta['alice']``, written by
``hermes-agents/business-team/instalar.py``) can message only teammates in that channel,
and nobody outside it can message them. Internal profiles (Evals' sandbox) neither send
nor receive messages.

A note-taking profile also gains a ``notes`` toolset for the store it keeps in
``workspace/inbox-store``, so capturing a note is a tool call instead of a shell command.
No changes to Hermes' own code.
"""
import contextvars
import logging
import json
import threading
from pathlib import Path

BUSINESS_CHANNEL = "Business (Beta)"
MESSAGE_TOOLS = frozenset({"message_agent"})


def _read_yaml(path: Path) -> dict:
    try:
        try:
            import hermes_yaml as yaml
        except ImportError:  # Hermes versions before the YAML facade
            import yaml

        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _placements(root: Path) -> dict:
    """``ui_meta['alice']`` of every named profile."""
    found = {}
    profiles = root / "profiles"
    if not profiles.is_dir():
        return found
    for child in profiles.iterdir():
        meta = _read_yaml(child / "profile.yaml").get("ui_meta")
        placement = meta.get("alice") if isinstance(meta, dict) else None
        if isinstance(placement, dict):
            found[child.name] = placement
    return found


def business_members(root: Path) -> set:
    """The profiles filed in the Business channel."""
    return {name for name, placement in _placements(root).items()
            if isinstance(placement.get("channel"), str)
            and placement["channel"].strip().casefold() == BUSINESS_CHANNEL.casefold()}


def internal_profiles(root: Path) -> set:
    """Technical profiles agents run on, such as Evals' sandbox: not anyone's teammate."""
    return {name for name, placement in _placements(root).items() if placement.get("internal") is True}


def _root_and_sender(home: Path) -> tuple:
    if home.parent.name == "profiles":
        return home.parent.parent, home.name
    return home, "default"


def _local_name(target: str) -> str:
    name = str(target or "").strip().lstrip("@").lower()
    # The mention middleware aliases the default profile as @hermes.
    return "default" if name == "hermes" else name


def _handles(names) -> str:
    return ", ".join(f"@{'hermes' if n == 'default' else n}" for n in sorted(names)) or "nadie"


def business_verdict(root: Path, sender: str, target: str):
    """None when the message may go; otherwise why it may not. A target that is not a
    local teammate (another machine, a peer) counts as outside the team."""
    receiver = _local_name(target)
    internal = internal_profiles(root)
    if receiver in internal:
        return f"No enviado: @{receiver} es un perfil técnico interno y no recibe mensajes. No lo reintentes."
    if sender in internal:
        return "No enviado: este perfil técnico interno no envía mensajes a otros agentes."
    members = business_members(root)
    if not members:
        return None
    sender_inside, receiver_inside = sender in members, receiver in members
    if sender_inside and not receiver_inside:
        return (f"No enviado: eres del equipo de Business y solo puedes escribir a tu equipo "
                f"({_handles(members - {sender})}); «{target}» está fuera. Resuélvelo con tu equipo "
                "o, si hace falta alguien de fuera, díselo al CEO en tu respuesta. No lo reintentes.")
    if receiver_inside and not sender_inside:
        return (f"No enviado: @{receiver} es del equipo de Business y solo recibe mensajes de su equipo. "
                "Si hace falta, díselo al CEO en tu respuesta. No lo reintentes.")
    return None


def team_prompt_for(root: Path, me: str) -> str:
    """What an agent is told about whom it may message, so it does not even try
    the ones Hermes will refuse. Empty when there is nothing to say."""
    heading = "## Con quién puedes hablar\n"
    if me in internal_profiles(root):
        return heading + "Eres un perfil técnico interno: no escribas a ningún agente."
    members = business_members(root)
    if not members:
        return ""
    if me in members:
        return heading + (
            f"Eres del equipo de Business. Con `message_agent` solo puedes escribir a: {_handles(members - {me})}. "
            "El resto de agentes de tu lista de compañeros **no existen para ti**: no les escribas, no los menciones "
            "y no expliques que no puedes escribirles. Si te piden consultar a uno de ellos, consulta a los tuyos y "
            "responde a lo que se pedía, sin una línea sobre el que falta.")
    return heading + (
        f"Los agentes del equipo de Business ({_handles(members)}) no están disponibles para ti: no les escribas "
        "ni lo intentes, aunque te lo pidan, porque Hermes bloquea esos mensajes.")


def team_prompt(_session_info=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, me = _root_and_sender(Path(get_hermes_home()))
        return team_prompt_for(root, me)
    except Exception:
        return ""


def _egress_guard():
    module = _module("egress_guard.py", "alice_egress_guard")
    if module.STORE is None:
        try:
            module.STORE = Path(_hermes_root()) / ".alice" / "taint.json"
        except Exception:
            logging.getLogger(__name__).warning("alice: taint kept in memory only", exc_info=True)
    return module


def _guard_egress(tool_name=None, args=None, session_id="", **_):
    """After reading the web, a command that could send data out or read secrets asks first."""
    try:
        return _egress_guard().check(tool_name or "", args, session_id or "")
    except Exception:
        # The check itself failed: a command that runs code is not let through unseen (qa static).
        if str(tool_name or "") in {"terminal", "execute_code", "shell", "bash", "run_command"}:
            return {"action": "approve", "message": "No se pudo comprobar si este comando es seguro: apruébalo solo si lo has pedido tú.",
                    "rule_key": "alice-egress-unchecked:" + __import__("secrets").token_hex(8)}
        return None


def _route_card_fill(tool_name=None, args=None, **_):
    """A card fill uses the saved card for the page actually open: the shop's www twin, or the
    bank's payment page the shop sent the person to. Otherwise Hermes asks the person to pay and
    then refuses the page (the Piensos Raposo purchase failed twice that way)."""
    if tool_name != "browser_vault_fill" or not isinstance(args, dict) or not args.get("handle"):
        return None
    try:
        live = _browser()
        urls = [str(tab.get("url") or "") for tab in live.pages(live.configured_url(_hermes_root()))]
        handle = _cards_module().route_fill(str(args["handle"]), urls)
    except Exception:  # qa: allow fail-open — routing only; _guard_errand and the repeat guard still decide
        return None
    return {"action": "modify", "args": {"handle": handle}} if handle else None


def _purchases():
    return _module("purchases.py", "alice_purchases")


def _purchase_flow():
    return _module("purchase_flow.py", "alice_purchase_flow")


def _catalog():
    return _module("catalog.py", "alice_catalog")


def _open_tabs() -> list:
    live = _browser()
    return [str(tab.get("url") or "") for tab in live.pages(live.configured_url(_hermes_root()))]


def _card_fill(tool_name, args):
    """The saved card a browser_vault_fill call is about to write, or None for any other call."""
    if tool_name != "browser_vault_fill" or not isinstance(args, dict) or not args.get("handle"):
        return None
    meta = _cards_module()._store().get_meta(str(args["handle"]))
    return meta if meta is not None and meta.kind == "payment" else None


# Sessions whose last payment could not be written in the ledger: no card goes in for them until
# `purchase_outcome` says how that payment ended. In memory on purpose — a ledger that cannot be
# written cannot hold the flag either.
_LEDGER_ERRORS: set = set()
_LEDGER_ERROR_MESSAGE = ("El pago anterior de esta conversación no pudo anotarse en el libro de pagos. No rellenes "
                         "ninguna tarjeta: comprueba cómo acabó ese pago y regístralo con `purchase_outcome`.")


def _guard_repeat_payment(tool_name=None, args=None, session_id="", **_):
    """One payment per order (purchases.py): an unsettled payment on the same shop blocks the fill;
    a paid or unknown one asks the person (in a chat through Hermes' card; in an errand the errand
    stops on it and only «Seguir desde aquí» lets one fill through). Any doubt — the vault or the
    ledger unreadable — blocks: a card is never filled on a guess."""
    if tool_name != "browser_vault_fill" or not isinstance(args, dict) or not args.get("handle"):
        return None
    try:
        meta = _card_fill(tool_name, args)
    except Exception:
        return {"action": "block", "message": "No se pudo leer la bóveda para comprobar este pago; no rellenes la tarjeta."}
    if meta is None:
        return None
    session = _session_id(session_id)
    if session in _LEDGER_ERRORS:
        return {"action": "block", "message": _LEDGER_ERROR_MESSAGE}
    try:
        cards = _cards_module()
        root = _hermes_root()
        site = _purchases().merchant(_open_tabs(), meta.origin or "", cards.PAYMENT_GATEWAYS)
        errands = _errands()
        entry = errands.of_session(root, session) if session.startswith(errands.SESSION_PREFIX) else None
        if entry is None:
            return _purchases().guard(root, site, session)
        if float(entry.get("pay_again_until") or 0) > __import__("time").time():
            # The person said this is another order (errands.go_on): one payment may go through.
            return None
        verdict = _purchases().guard(root, site, session, in_errand=True)
        if verdict and verdict.get("kind") == "paid_before":
            errands.update(root, entry["id"], status="stuck", reason=verdict.get("reason") or verdict["message"],
                           blocked={"kind": "paid_before", "shop": _purchases().shop(site)})
        return verdict
    except Exception:
        return {"action": "block", "message": "No se pudo comprobar el libro de pagos; no pagues."}


def _errands():
    return _module("errands.py", "alice_errands")


def _feed():
    return _module("feed.py", "alice_feed")


def _feed_sources(tool_name=None, result=None, session_id="", **_):
    """In a feed run, each source a web or browser result carries is named [alice_source: src_N],
    the only way feed_publish can cite it (feed.py)."""
    try:
        return _feed().annotate(_session_id(session_id), tool_name or "", result)
    except Exception:
        logging.getLogger(__name__).debug("feed: could not annotate sources", exc_info=True)
        return None


def _guard_feed_publish(tool_name=None, session_id="", **_):
    """feed_publish belongs to the feed run under way; any other session is refused before it runs."""
    if tool_name != "feed_publish":
        return None
    try:
        if _feed().is_feed_session(_session_id(session_id)):
            return None
    except Exception:
        pass
    return {"action": "block", "message": "feed_publish only works inside a feed run. Use feed_steer to change the feed."}


def _session_id(session_id: str = "") -> str:
    """The Hermes session a call belongs to. In a /v1/runs errand the approval key is the run's
    id, so the session comes from the hook's argument or the gateway's session vars."""
    if session_id:
        return str(session_id)
    try:
        from gateway.session_context import get_session_env

        return get_session_env("HERMES_SESSION_ID", "") or get_session_env("HERMES_SESSION_CHAT_ID", "")
    except Exception:
        return ""


def _conversation_key() -> str:
    """Where ask_person keeps its questions: the errand's session inside one, else the chat's."""
    session = _session_id()
    if session.startswith(_errands().SESSION_PREFIX):
        return session
    from tools.approval_context import get_current_session_key

    return get_current_session_key(default="")


def _vault_meta(tool_name, args):
    if tool_name != "browser_vault_fill" or not isinstance(args, dict) or not args.get("handle"):
        return None
    return _cards_module()._store().get_meta(str(args["handle"]))


def _active_url() -> str:
    """The tab where something last happened: where an agent is acting now."""
    try:
        live = _browser()
        tabs = live.pages(live.configured_url(_hermes_root()))
        tab = live.busiest(tabs)
        return str((tab or {}).get("url") or "")
    except Exception:
        return ""


def _isolate_errand_browser(tool_name=None, args=None, session_id="", **_):
    """An errand's browser code runs in the errand's own browser context (errands.context_preamble)."""
    if tool_name != "browser_exec" or not isinstance(args, dict) or not isinstance(args.get("code"), str):
        return None
    session = _session_id(session_id)
    errands = _errands()
    if not session.startswith(errands.SESSION_PREFIX):
        return None
    entry = errands.of_session(_hermes_root(), session)
    if (entry or {}).get("offer"):
        # Check the model's code before attaching our trusted CDP preamble.
        # HTTP, filesystem and interpreter access would bypass checkout guards.
        import ast
        import re
        try:
            nodes = list(ast.walk(ast.parse(args["code"])))
            denied = {"open", "exec", "eval", "compile", "getattr", "setattr", "globals", "locals", "vars",
                      "os", "sys", "requests", "urllib", "httpx", "aiohttp", "socket", "websockets", "subprocess", "pathlib", "builtins", "cdp"}
            # `import time` for a wait, `json`/`re` to read what the page gave: what every model
            # writes, and none of it reaches the network, the disk or the CDP socket.
            harmless = {"time", "json", "re", "math", "random", "string", "datetime", "unicodedata", "textwrap"}
            def imports_more(node):
                if isinstance(node, ast.Import):
                    return any(alias.name.split(".")[0] not in harmless for alias in node.names)
                return isinstance(node, ast.ImportFrom) and str(node.module or "").split(".")[0] not in harmless
            bypass = any(imports_more(n) or
                         (isinstance(n, ast.Name) and (n.id in denied or n.id.startswith("_"))) or
                         (isinstance(n, ast.Attribute) and (n.attr.startswith("_") or n.attr in {"send_cdp", "execute_cdp", "request"}))
                         for n in nodes)
            bypass = bypass or bool(re.search(r"\b(fetch|XMLHttpRequest|WebSocket|sendBeacon)\b", args["code"]))
        except SyntaxError as exc:
            # Said as what it is: answered as a security refusal, a stray indent made the agent
            # believe it could not go back to the product page, and it gave up (06-10).
            return {"action": "block", "message": f"El código tiene un error de sintaxis (línea {exc.lineno}: "
                    f"{exc.msg}); no se ejecutó nada. Corrígelo (sangría, paréntesis, comillas) y vuelve a enviarlo."}
        if bypass:
            return {"action":"block", "message":"Usa los helpers de navegador ya importados para leer y operar la página. Este recado no permite imports, archivos, intérpretes ni transporte HTTP/CDP directo que evite comprobar el total."}
    return {"action": "modify",
            "args": {**args, "session": session,
                     "code": errands.context_preamble(session[len(errands.SESSION_PREFIX):]) + args["code"]}}


def _errand_context_lost(tool_name=None, result=None, session_id="", **_):
    """After a browser step in an errand whose browser context had to be made again (Chrome
    closed or crashed): nothing read in the old one stands, and the agent hears it in this result."""
    if tool_name != "browser_exec" or not isinstance(result, str):
        return None
    try:
        errands = _errands()
        session = _session_id(session_id)
        if not session.startswith(errands.SESSION_PREFIX):
            return None
        errand_id = session[len(errands.SESSION_PREFIX):]
        path = errands.context_file(errand_id, _hermes_root())
        saved = json.loads(path.read_text(encoding="utf-8"))
        if not saved.get("lost"):
            return None
        saved.pop("lost", None)
        path.write_text(json.dumps(saved), encoding="utf-8")
        note = errands.context_lost(_hermes_root(), errand_id)
        return result + note if note else None
    except Exception:
        return None


def _transform_tool_result(tool_name=None, args=None, result=None, session_id="", **kw):
    """The plugin's rewrites of a tool's result, applied one after another (Hermes uses only the
    first string any transform_tool_result hook returns: qa sim, hermes_cli/plugins.py). Order: the
    vault list is filtered to the errand's shop; a payment error on the page is flagged; a lost
    browser context is said; a feed run's sources get their ids. Returns None when none applied."""
    current, changed = result, False
    for step in (_filter_errand_access, _payment_error_note, _errand_context_lost, _feed_sources,
                 _skill_staged_note):
        try:
            out = step(tool_name=tool_name, args=args, result=current, session_id=session_id, **kw)
        except Exception:
            logging.getLogger(__name__).debug("alice: a result rewrite failed", exc_info=True)
            out = None
        if isinstance(out, str):
            current, changed = out, True
    return current if changed else None


def _filter_errand_access(tool_name="", result=None, session_id="", **_):
    if tool_name != 'browser_vault_list':
        return None
    entry = _errands().of_session(_hermes_root(), _session_id(session_id))
    if not entry:
        return None
    try:
        access = _module("errand_access.py", "alice_errand_access")
        page_origin, _, _ = access.target(entry)
        payload = json.loads(result) if isinstance(result,str) else dict(result)
        payload['items'] = [r for r in payload.get('items',[]) if r.get('kind') != 'login' or r.get('origin') == page_origin]
        payload.pop('errors',None)
        return json.dumps(payload)
    except Exception:
        return json.dumps({'items':[], 'error':'No se pudo comprobar el origen del recado. Abre su página antes de consultar accesos.'})


def _guard_errand_access(tool_name=None, args=None, session_id="", **_):
    session = _session_id(session_id)
    errands = _errands()
    if not session.startswith(errands.SESSION_PREFIX):
        return None
    entry = errands.of_session(_hermes_root(), session)
    if not entry:
        return None
    access = _module("errand_access.py", "alice_errand_access")
    if tool_name in errands.BROWSER_ACTIONS:
        try:
            verdict = access.guard_account_input(entry, tool_name, args)
            if verdict:
                return verdict
        except Exception:
            return {"action":"block", "message":"No se pudo comprobar la identidad elegida antes de actuar en el formulario. Usa login_fill para el acceso de este recado."}
    if tool_name in ("browser_vault_save_login", "browser_vault_enter_code"):
        try:
            access.request(_hermes_root(), entry['id'],
                           'vault.code' if tool_name == 'browser_vault_enter_code' else 'vault.save_login')
            return {"action": "block", "message": "Acceso solicitado de forma segura en el iPhone. Termina el turno; el mismo recado continuará al recibirlo."}
        except Exception:
            return {"action": "block", "message": "No se pudo verificar el origen del recado para pedir acceso. No solicites secretos en el chat."}
    if tool_name == 'browser_vault_fill':
        try:
            meta = _vault_meta(tool_name, args)
            if meta and meta.kind == 'login':
                page_origin, _, _ = access.target(entry)
                if access.origin(meta.origin) == page_origin:
                    return {"action":"block","message":"Usa login_fill con ese handle; rellena únicamente la página propia del recado."}
                if access.origin(meta.origin) != page_origin:
                    return {"action": "block", "message": "Ese acceso pertenece a otra tienda. Usa solo uno del origen actual o llama a login_request."}
        except Exception:
            return {"action": "block", "message": "No se pudo comprobar el origen del acceso. No lo rellenes."}
    if str(tool_name or "").startswith("browser_") and (entry or {}).get("offer") and (entry or {}).get("secure_answered"):
        if not errands.context_file(entry["id"], _hermes_root()).exists():
            # The page that held the typed secret is gone with its context: nothing to shield, and
            # blocking every browser step here left the errand unable to make a new one.
            errands.update(_hermes_root(), entry["id"], secure_answered=None, cart_evidence=None)
            return None
        try:
            _module("errand_access.py", "alice_errand_access").protect_browser_secrets(entry)
        except Exception:
            return {"action":"block", "message":"No se pudo proteger el formulario seguro de este recado. Solicita de nuevo el acceso de esta tienda antes de leer la página."}
    return None


def _guard_errand(tool_name=None, args=None, session_id="", **_):
    """Nothing is paid without the person's approved checkout, and a saved login is used without
    asking unless they asked to be asked (errands.py). If the check itself fails, paying is refused."""
    name = str(tool_name or "")
    raw = name in _errands().RAW_BROWSER and _errands()._raw_presses(name, args)
    # browser_eval/browser_evaluate are not Hermes tools today; kept refused in case one appears.
    if name in ("terminal", "execute_code", "browser_eval", "browser_evaluate") or (name == "browser_get_state" and (args or {}).get("expression")) \
            or (raw and name != "browser_dialog"):
        session = _session_id(session_id)
        if session.startswith(_errands().SESSION_PREFIX):
            try:
                offer = bool((_errands().of_session(_hermes_root(), session) or {}).get("offer"))
            except Exception:
                offer = True  # unreadable: treated as a purchase
            if offer:
                return {"action": "block", "message": "Este recado de compra usa únicamente el navegador y las herramientas de compra comprobadas. No ejecutes pagos ni solicitudes por terminal, código o evaluación directa."}
        if not raw:
            return None
    if name != "browser_vault_fill" and name not in _errands().BROWSER_ACTIONS and name not in _errands().RAW_BROWSER:
        return None
    session = _session_id(session_id)
    try:
        errands = _errands()
        root = _hermes_root()
        entry = errands.of_session(root,session)
        active_url = _active_url()
        presses = name in ('browser_click','browser_press') or bool(errands.CLICKS.search(errands._text_of(args)))
        payment_step = None
        if presses and (entry or {}).get('offer'):
            access = _module("errand_access.py", "alice_errand_access")
            try:
                page_origin, context, _ = access.target(entry)
                active_url = context.get('url') or page_origin
            except Exception:
                return {"action":"block","message":"No se pudo verificar la página de este recado antes de pulsar un control. Abre su propia página y reintenta."}
            if errands.STEP_WORDS.search(errands._text_of(args)):
                try:
                    payment_step = bool(access.page_evaluate(context, errands.PAYMENT_STEP_JS))
                except Exception:
                    payment_step = None  # unread: «Finalizar compra» stays treated as paying
        meta = _vault_meta(name, args)
        if meta is not None and meta.kind != "payment":
            return errands.login_gate(root, session)
        if meta is not None:
            cards = _cards_module()
            merchant = _purchases().merchant(_open_tabs(), meta.origin or "", cards.PAYMENT_GATEWAYS)
            verdict = errands.pay_gate(root, session, card_fill_site=meta.origin or "", merchant_site=merchant,
                                       gateways=cards.PAYMENT_GATEWAYS)
            chosen = str(((entry or {}).get("checkout") or {}).get("card_label") or "")
            identity = getattr(cards, "identity", lambda label: label)
            if not verdict and chosen and identity(chosen) != identity(str(getattr(meta, "label", "") or "")):
                verdict = {"action": "block", "message": (
                    f"La persona eligió pagar con «{chosen}». Rellena esa tarjeta (búscala en `browser_vault_list` "
                    "por su etiqueta), no otra.")}
        else:
            # Inside an errand, pressing anything through raw page code, DevTools or a page dialog
            # counts as paying: those calls carry no reliable words to tell a pay button apart.
            press_pays = raw and session.startswith(errands.SESSION_PREFIX)
            verdict = errands.pay_gate(root, session, tool_name=name, args=args, active_url=active_url,
                                       payment_step=payment_step, press_pays=press_pays,
                                       gateways=_cards_module().PAYMENT_GATEWAYS)
        if verdict:
            return verdict
        paying = meta is not None or errands.is_pay_action(name,args,active_url,payment_step) or (
            raw and session.startswith(errands.SESSION_PREFIX))
        entry = errands.of_session(root,session)
        if paying and (entry or {}).get('offer'):
            if not _module("purchase_prices.py", "alice_purchase_prices").payment_ready(
                    root, entry, gateways=_cards_module().PAYMENT_GATEWAYS):
                return {"action":"block", "message":"El total o la sesión cambiaron, o falta evidencia del resumen aprobado. Comprueba la cesta y llama a checkout_request para mostrar el total actual antes de pagar."}
        if (meta is None and entry is not None
                and errands.is_strong_pay_action(name, args, active_url, _cards_module().PAYMENT_GATEWAYS)):
            # A press that pays by itself (PayPal, Bizum, a card the shop keeps, the bank's own
            # button) leaves its entry in the ledger before it happens: a second one on the same
            # shop is refused until `purchase_outcome` says how this one ended. A card fill is
            # written when it actually succeeds (_record_payment).
            refused = _note_payment(root, entry, session)
            if refused:
                return {"action": "block", "message": refused}
        return None
    except Exception:
        if name == "browser_vault_fill" or raw or _errands().is_pay_action(name,args,_active_url()):
            return {"action": "block", "message": "No se pudo comprobar la aprobación del pago; no pagues."}
        return None


_STEP = __import__("re").compile(r"^\s*#\s*(.+)$", __import__("re").M)


def _errand_step(tool_name, args, session_id) -> None:
    """What the errand's agent is doing, for its card: the comment on each browser step."""
    session = _session_id(session_id)
    errands = _errands()
    if not session.startswith(errands.SESSION_PREFIX) or not str(tool_name or "").startswith("browser"):
        return
    code = str((args or {}).get("code") or "") if isinstance(args, dict) else ""
    # The browser's setup put before the agent's code is Alice's, never a step: its own notes
    # («Keep page transitions…», «Agent attachment…») were the only steps a purchase showed (06-10).
    preamble = errands.context_preamble(session[len(errands.SESSION_PREFIX):])
    if code.startswith(preamble):
        code = code[len(preamble):]
    # The first comment of the agent's own: not a note put there by Alice or Hermes.
    text = next((c.strip() for c in _STEP.findall(code) if not c.strip().startswith(("alice:", "hermes:"))), "")
    if text:
        errands.add_step(_hermes_root(), session[len(errands.SESSION_PREFIX):], text, _active_url())


_PRESSED_MESSAGE = ("Ya se pulsó el botón que paga en este recado y nadie ha registrado cómo acabó. No lo pulses "
                    "otra vez: lee la página (confirmación, error del banco) y llama a `purchase_outcome`; un segundo "
                    "clic puede cobrar dos veces.")


def _note_payment(root, entry, session: str):
    """Writes the payment an errand is about to send in the ledger. Returns None when written, or why
    the press must not happen: the ledger could not take it, or this payment's button was already
    pressed and its outcome is still unknown (a second press can charge twice; qa sim: pay_twice)."""
    try:
        ledger = _purchases()
        open_entry = ledger.open_payment(root, session)
        if open_entry is not None and open_entry.get("pressed"):
            return _PRESSED_MESSAGE
        checkout = entry.get("checkout") if isinstance(entry.get("checkout"), dict) else {}
        site = checkout.get("site") or entry.get("site") or str((entry.get("offer") or {}).get("url") or "")
        written = ledger.record(root, site, session)
        ledger.mark(root, written["id"], pressed=True)
    except Exception:
        return "No se pudo anotar este pago en el libro de pagos; no pagues."
    try:
        _schedule_payment_check(written)
    except Exception:
        pass  # the check is a courtesy; the entry is what refuses a second payment
    return None


def _record_payment(tool_name, args, result, session_id) -> None:
    """A card Hermes actually wrote into a checkout is a payment attempt until it is settled. If the
    ledger could not take it, the session is flagged and no card goes in until purchase_outcome."""
    if tool_name != "browser_vault_fill":
        return
    session = _session_id(session_id)
    try:
        out = json.loads(result) if isinstance(result, str) else (result or {})
        if not (isinstance(out, dict) and out.get("success") and out.get("kind") == "payment"):
            return
    except Exception:
        return
    try:
        site = _purchases().merchant(_open_tabs(), str(out.get("origin") or ""),
                                     _cards_module().PAYMENT_GATEWAYS)
        entry = _purchases().record(_hermes_root(), site, session)
    except Exception:
        if session:
            _LEDGER_ERRORS.add(session)
        return
    try:
        errands = _errands()
        if session.startswith(errands.SESSION_PREFIX):
            # The one payment the person allowed after «paid before» has been used.
            found = errands.of_session(_hermes_root(), session)
            if found and found.get("pay_again_until"):
                errands.update(_hermes_root(), found["id"], pay_again_until=None)
    except Exception:
        pass
    try:
        _schedule_payment_check(entry)
    except Exception:
        logging.getLogger(__name__).error("alice: a card payment was not recorded in the ledger", exc_info=True)


def _schedule_payment_check(entry) -> None:
    """Ten minutes after a payment, a check that needs no model: if its outcome is still unknown,
    the person gets a line in this same chat (a no_agent cron job; silent when all is settled)."""
    import datetime as _dt

    from hermes_constants import get_hermes_home

    root = _hermes_root()
    # Only for the real Hermes home: the plugin's own tests write payments into a temporary one,
    # and their checks reached the person's chat as «a card payment at hsnstore.com» (06-10).
    try:
        # A profile's home sits inside the root (~/.hermes/profiles/x under ~/.hermes).
        Path(get_hermes_home()).resolve().relative_to(Path(root).resolve())
    except ValueError:
        return
    if not _purchases().mark(root, entry["id"], check_scheduled=True):
        return  # a refill of the same payment: its check is already on the way
    from cron.jobs import create_job
    from tools.cronjob_job_args import _origin_from_env

    scripts = Path(get_hermes_home()) / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    name = f"alice-pago-{entry['id']}.py"
    (scripts / name).write_text(
        _purchases().follow_up_script(Path(__file__).resolve().parent, root, entry["id"]), encoding="utf-8")
    at = _dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(seconds=_purchases().FOLLOW_UP)
    origin = _origin_from_env()
    # Telegram or iMessage: back to that chat. Alice's app chats have no such origin: the agent's chat.
    create_job(None, at.isoformat(timespec="seconds"), name=f"Comprobar pago en {entry['shop']}",
               repeat=1, origin=origin, deliver=None if origin else "bot-chat", script=name, no_agent=True)


def _skill_staged_note(tool_name=None, args=None, result=None, session_id="", **_):
    """A staged skill write reads as saved, not «pending your approval» (skill_keeper.staged_note)."""
    if tool_name != "skill_manage":
        return None
    try:
        tainted = _egress_guard().tainted(_session_id(session_id))
    except Exception:
        tainted = True
    try:
        return _skill_keeper().staged_note(args, result, tainted=tainted)
    except Exception:
        return None


def _payment_error_note(tool_name=None, result=None, session_id="", **_):
    """A browser page that says the payment failed is flagged to the agent at once, so the person
    hears it now rather than never (purchases.error_note)."""
    try:
        if not str(tool_name or "").startswith("browser") or not isinstance(result, str):
            return None
        note = _purchases().error_note(_hermes_root(), session_id or "", result)
        return result + note if note else None
    except Exception:
        return None


def purchases_prompt(_session_info=None) -> str:
    return _purchases().prompt()


def _register_purchase_tools(ctx) -> None:
    module = _purchases()
    schema = {**module.SCHEMA, "parameters": {
        **module.SCHEMA["parameters"],
        "properties": {**module.SCHEMA["parameters"]["properties"], **_errands().outcome_properties()}}}

    def handler(args, **_):
        session = _session_id()
        ensure = ""
        try:
            # In an errand whose checkout the person approved, the payment may have gone by a way no
            # hook wrote down (PayPal, Bizum, the person on the bank's page): its outcome is still kept.
            errands = _errands()
            entry = errands.of_session(_hermes_root(), session) if session.startswith(errands.SESSION_PREFIX) else None
            checkout = (entry or {}).get("checkout") if isinstance((entry or {}).get("checkout"), dict) else {}
            if checkout.get("status") in ("approved", "pending"):
                ensure = session
        except Exception:
            ensure = ""
        out = module.run_tool(_hermes_root(), args or {}, ensure_session=ensure)
        try:
            if isinstance(out, dict) and out.get("ok"):
                _LEDGER_ERRORS.discard(session)
                _errands().record_receipt(_hermes_root(), session, args or {})
        except Exception:
            pass
        return _agent_json(out)

    ctx.register_tool(
        name="purchase_outcome", toolset="alice_purchases", schema=schema, handler=handler,
        check_fn=_always, description=module.SCHEMA["description"], emoji="🧾",
    )
    # The same rules as a skill anyone can open and audit (alice:comprar).
    if hasattr(ctx, "register_skill"):
        ctx.register_skill("comprar", module.SKILL, description="Cómo compra Alice online, de elegir a confirmar el pedido.")


def _pre_tool_call(tool_name=None, args=None, **_):
    if tool_name not in MESSAGE_TOOLS:
        return None
    try:
        from hermes_constants import get_hermes_home

        # Context-local: under a multiplexed gateway this is the home of the profile whose
        # turn is running, so the sender is the agent making the call.
        root, sender = _root_and_sender(Path(get_hermes_home()))
        reason = business_verdict(root, sender, (args or {}).get("target") or "")
    except Exception:
        # The team's boundary is a rule, not a preference: when it cannot be checked, the
        # message does not go.
        reason = "No enviado: no se pudo comprobar si el mensaje respeta el equipo de Business."
    return {"action": "block", "message": reason} if reason else None

# ── Notes tools ──────────────────────────────────────────────────────────────
# A note-taking profile keeps its notes in its own ``workspace/inbox-store``, driven by
# ``inbox.py``. Reaching it through the terminal tool is what made Hermes ask permission
# before every capture: the note's text arrives as a heredoc piped into an interpreter,
# which is exactly what the security scanner is there to stop. The commands are the same
# here, as tools: no shell to scan, no quoting to get wrong, no approval to wait for, and
# no interpreter to start. A profile without that store sees none of these tools.

NOTES_STORE = Path("workspace") / "inbox-store"
NOTES_TOOLSET = "notes"


def _notes_root() -> Path:
    from hermes_constants import get_hermes_home

    return Path(get_hermes_home()) / NOTES_STORE


def _store_module():
    """The store's own ``inbox.py``, imported from the running profile's workspace."""
    import importlib.util

    root = _notes_root()
    script = root / "inbox.py"
    if not script.is_file():
        return None, None
    spec = importlib.util.spec_from_file_location("alice_inbox_store", script)
    if spec is None or spec.loader is None:
        return None, None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, root


def _store_call(work) -> str:
    """Runs ``work(module, root)`` and returns what the store printed, as its commands do."""
    import io
    import json
    from contextlib import redirect_stdout

    module, root = _store_module()
    if module is None:
        return json.dumps({"ok": False, "error": "este perfil no tiene un almacén de notas"},
                          ensure_ascii=False)
    printed = io.StringIO()
    try:
        with redirect_stdout(printed):
            work(module, root)
    except SystemExit:
        pass  # `inbox.py` reports a refusal by printing it and exiting; the text is the answer.
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False)
    return printed.getvalue().strip() or json.dumps({"ok": True}, ensure_ascii=False)


def _has_notes_store(**_) -> bool:
    try:
        return (_notes_root() / "inbox.py").is_file()
    except Exception:
        return False


_TEXT = {"type": "string"}
_IDS = {"type": "array", "items": {"type": "string"}}
_TAGS = {"type": "string", "description": "De 1 a 3 etiquetas separadas por comas."}
_FOLDER = {"type": "string", "description": "Nombre o id de una carpeta que ya exista."}
_LIMIT = {"type": "integer", "description": "Cuántas notas devolver como máximo."}


def _ids(args) -> list:
    return [str(i) for i in (args.get("ids") or []) if str(i)]


# name, emoji, description, (properties, required), call
NOTE_TOOLS = (
    ("note_add", "📥",
     "Guarda una nota en el almacén, tal cual, y la archiva en una carpeta que ya exista. "
     "Devuelve su id, su carpeta y sus etiquetas.",
     ({"text": dict(_TEXT, description="El texto exacto de la nota, sin reescribir."),
       "folder": dict(_FOLDER, description="Carpeta existente; omítela para dejarla en Quick Notes."),
       "tags": _TAGS}, ["text"]),
     lambda a, m, root: m.cmd_add(root, str(a.get("text") or ""), a.get("folder"), a.get("tags"))),

    ("note_file", "🗂",
     "Archiva notas ya guardadas en una carpeta, y opcionalmente cambia sus etiquetas.",
     ({"ids": dict(_IDS, description="Ids de las notas a archivar."),
       "folder": dict(_FOLDER, description="Carpeta existente; «none» las devuelve a Quick Notes."),
       "tags": dict(_TAGS, description="De 1 a 3 etiquetas; omítelas para conservar las suyas.")},
      ["ids"]),
     lambda a, m, root: m.cmd_file(root, _ids(a), a.get("folder") or "none", a.get("tags"))),

    ("note_folders", "📁",
     "Las carpetas del almacén con cuántas notas tiene cada una, las etiquetas en uso y "
     "cuántas notas siguen sin archivar.",
     ({}, []),
     lambda a, m, root: m.cmd_folders(root)),

    ("note_folder_create", "➕",
     "Crea una carpeta. Solo después de que la persona haya aprobado esa carpeta concreta.",
     ({"name": dict(_TEXT, description="Nombre de la carpeta, como lo aprobó la persona.")},
      ["name"]),
     lambda a, m, root: m.cmd_folder_create(root, str(a.get("name") or ""))),

    ("note_folder_rename", "✏️",
     "Cambia el nombre de una carpeta. Sus notas se quedan dentro.",
     ({"folder": _FOLDER, "name": dict(_TEXT, description="El nombre nuevo.")}, ["folder", "name"]),
     lambda a, m, root: m.cmd_folder_rename(root, str(a.get("folder") or ""),
                                            str(a.get("name") or ""))),

    ("note_folder_delete", "🗑",
     "Borra una carpeta. Sus notas vuelven a Quick Notes; ninguna nota se pierde.",
     ({"folder": _FOLDER}, ["folder"]),
     lambda a, m, root: m.cmd_folder_delete(root, str(a.get("folder") or ""))),

    ("note_get", "🔎",
     "Una nota entera por su id, con su enriquecimiento.",
     ({"id": _TEXT}, ["id"]),
     lambda a, m, root: m.cmd_get(root, str(a.get("id") or ""))),

    ("note_search", "🔍",
     "Busca notas por texto, con filtros opcionales de fecha y de tipo.",
     ({"query": dict(_TEXT, description="Qué buscar."),
       "start": dict(_TEXT, description="Fecha ISO desde la que buscar (AAAA-MM-DD)."),
       "end": dict(_TEXT, description="Fecha ISO hasta la que buscar (AAAA-MM-DD)."),
       "type": dict(_TEXT, description="Solo notas de este tipo."),
       "limit": _LIMIT}, ["query"]),
     lambda a, m, root: m.cmd_search(root, str(a.get("query") or ""), a.get("start"), a.get("end"),
                                     a.get("type"), int(a.get("limit") or 20))),

    ("note_recent", "🕒",
     "Las notas de los últimos días, de la más nueva a la más vieja.",
     ({"days": {"type": "integer", "description": "Cuántos días atrás mirar."}, "limit": _LIMIT}, []),
     lambda a, m, root: m.cmd_recent(root, int(a.get("days") or 7), int(a.get("limit") or 50))),

    ("note_similar", "🪞",
     "Notas parecidas a un texto. Para no duplicar lo que ya está guardado.",
     ({"text": _TEXT, "limit": _LIMIT}, ["text"]),
     lambda a, m, root: m.cmd_similar(root, str(a.get("text") or ""), int(a.get("limit") or 5))),

    ("note_unprocessed", "📌",
     "Las notas que aún no se han enriquecido.",
     ({"limit": _LIMIT}, []),
     lambda a, m, root: m.cmd_unprocessed(root, int(a.get("limit") or 50))),

    ("note_enrich", "✨",
     "Guarda el enriquecimiento de una nota (types, topics, entities, actions, "
     "open_questions, implicit_important, summary). Conserva su carpeta y sus etiquetas.",
     ({"id": _TEXT,
       "payload": {"type": "object", "description": "Los campos del enriquecimiento."}},
      ["id", "payload"]),
     lambda a, m, root: m.cmd_enrich(root, str(a.get("id") or ""), a.get("payload") or {})),

    ("note_mark_processed", "✅",
     "Marca notas como ya procesadas, para que la rutina no las vuelva a mirar.",
     ({"ids": _IDS}, ["ids"]),
     lambda a, m, root: m.cmd_mark_processed(root, _ids(a))),

    ("note_digest_week", "📰",
     "Los datos de los últimos días agrupados para el resumen semanal.",
     ({"days": {"type": "integer", "description": "Cuántos días cubre el resumen."}}, []),
     lambda a, m, root: m.cmd_digest_week(root, int(a.get("days") or 7))),

    ("note_relate", "🔗",
     "Relaciona dos notas, solo cuando la relación es clara.",
     ({"a": dict(_TEXT, description="Id de la primera nota."),
       "b": dict(_TEXT, description="Id de la segunda nota."),
       "kind": dict(_TEXT, description="Qué tipo de relación es (duplica, continúa, contradice…)."),
       "note": dict(_TEXT, description="Una línea explicando la relación.")},
      ["a", "b", "kind"]),
     lambda a, m, root: m.cmd_relate(root, str(a.get("a") or ""), str(a.get("b") or ""),
                                     str(a.get("kind") or ""), str(a.get("note") or ""))),
)


def _register_notes_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in NOTE_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset=NOTES_TOOLSET, schema=schema,
            handler=lambda args, _call=call, **_: _store_call(
                lambda m, root, _a=args or {}: _call(_a, m, root)),
            check_fn=_has_notes_store, description=description, emoji=emoji,
        )


def _agent_engine():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "agent_engine.py"
    name = "alice_agent_engine"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _free_web():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "free_web.py"
    name = "alice_free_web"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _action_log():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "action_log.py"
    name = "alice_action_log"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _post_tool_call(tool_name=None, args=None, result=None, session_id="", status=None, **_):
    """Keeps what an agent did that changed something — sent, scheduled, signed in, deleted —
    for Alice's Activity. An observer: it never changes the call, and a failure here is
    swallowed so it can never break a turn."""
    try:
        _egress_guard().observe(session_id or "", tool_name or "", args=args)
    except Exception:
        logging.getLogger(__name__).warning("alice: could not record that this session read outside content",
                                            exc_info=True)
    try:
        from hermes_constants import get_hermes_home

        root, profile = _root_and_sender(Path(get_hermes_home()))
        _action_log().observe(root, profile, tool_name=tool_name or "", args=args, result=result,
                              session_id=session_id or "", status=status)
    except Exception:
        pass
    _record_payment(tool_name, args, result, session_id)
    try:
        _errand_step(tool_name, args, session_id)
    except Exception:
        pass
    if tool_name == "skill_manage" and status != "error":
        # Proposed after reading the web: a page may have written it, so it waits (skill_keeper.py).
        try:
            staged = json.loads(result) if isinstance(result, str) else (result or {})
            if isinstance(staged, dict) and staged.get("staged") and staged.get("pending_id") \
                    and _egress_guard().tainted(_session_id(session_id)):
                _skill_keeper().mark_tainted(_hermes_root(), str(staged["pending_id"]))
        except Exception:
            logging.getLogger(__name__).warning("alice: could not check where a lesson came from", exc_info=True)
        # A skill written now is kept now, unless it reads like an injection (skill_keeper.py).
        _keep_skills(delay=1.0)
    if tool_name == "memory" and status != "error":
        _keep_memory(args, session_id or "")
    return None


def _memory_keeper():
    return _module("memory_keeper.py", "alice_memory_keeper")


def _keep_memory(args, session_id: str) -> None:
    """An agent just wrote to memory: note where the entry came from, then tidy (or only
    propose, by default). Never raises into the turn."""
    try:
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
        _, profile = _root_and_sender(home)
        a = args if isinstance(args, dict) else {}
        target = str(a.get("target") or "memory")
        keeper_module = _memory_keeper()
        keeper = keeper_module.Keeper(home, keeper_module.HermesFiles())
        # Recorded before anything looks: an entry nobody recorded reads as hand-written.
        operations = a.get("operations") if isinstance(a.get("operations"), list) else [a]
        targets = set()
        for op in operations:
            if not isinstance(op, dict):
                continue
            op_target = str(op.get("target") or target)
            targets.add(op_target)
            text = op.get("content") or op.get("new_text") or op.get("new_content")
            if op.get("action") in ("add", "replace") and text:
                keeper.record(op_target, str(text), "agent", session=session_id, profile=profile)
        keeper.run(targets=tuple(t for t in sorted(targets) if t in keeper_module.TARGETS))
    except Exception:
        pass


# A conversation counts as paused after this long without a new turn; then what the person
# said in it is read once for facts about them that were not kept (memory_review.py).
_REVIEW_AFTER_S = 90
_review_timers: dict = {}
_review_lock = threading.Lock()


def _skill_keeper():
    return _module("skill_keeper.py", "alice_skill_keeper")


def _keep_skills(delay: float = 0.0) -> None:
    try:
        from hermes_constants import get_hermes_home

        _skill_keeper().run_soon(Path(get_hermes_home()), delay=delay)
    except Exception:
        pass


def _keep_reviewed_skills(**_) -> None:
    """Hermes reviews a finished conversation in the background and may stage skills from it."""
    _keep_skills(delay=120.0)


def _schedule_memory_review(session_id="", platform="", **_) -> None:
    """Each finished turn restarts its conversation's wait; the look happens once it is quiet."""
    try:
        if not session_id or str(platform or "") == "cron":
            return
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
        root, profile = _root_and_sender(home)
        if profile in internal_profiles(root):
            return
        key = f"{home}|{session_id}"
        # The profile the turn ran under travels with the look, on another thread.
        context = contextvars.copy_context()
        timer = threading.Timer(_REVIEW_AFTER_S, lambda: context.run(_review_memory, home, profile, session_id))
        timer.daemon = True
        with _review_lock:
            previous = _review_timers.pop(key, None)
            if previous:
                previous.cancel()
            _review_timers[key] = timer
        timer.start()
    except Exception:
        pass


def _review_ask(messages):
    """The profile's own model, so the person's words go nowhere their conversation did not
    already go — unless ``auxiliary.alice_memory_review`` chooses another on purpose."""
    from agent.auxiliary_client import call_llm, extract_content_or_reasoning
    from hermes_cli.config import load_config

    config = load_config() or {}
    chosen = ((config.get("auxiliary") or {}).get("alice_memory_review") or {})
    model = config.get("model") or {}
    route = {} if chosen.get("provider") or not isinstance(model, dict) else {
        "provider": model.get("provider") or None, "model": model.get("default") or None,
        "base_url": model.get("base_url") or None}
    response = call_llm(task="alice_memory_review", messages=messages, max_tokens=900, timeout=90, **route)
    return extract_content_or_reasoning(response) or ""


def _review_memory(home: Path, profile: str, session_id: str) -> None:
    key = f"{home}|{session_id}"
    with _review_lock:
        _review_timers.pop(key, None)
    try:
        from hermes_state import SessionDB

        keeper_module = _module("memory_keeper.py", "alice_memory_keeper")
        review = _module("memory_review.py", "alice_memory_review")
        keeper = keeper_module.Keeper(home, keeper_module.HermesFiles())
        if not keeper.settings()["learn"] or not keeper.files.store.target_enabled("user"):
            return
        seen = keeper._read("reviewed.json", {})
        seen = seen if isinstance(seen, dict) else {}
        db = SessionDB(read_only=True)
        try:
            session = db.get_session(session_id) or {}
            if str(session.get("source") or "") == "cron":
                return
            after = seen.get(session_id)
            messages = db.get_messages(session_id, after_id=int(after) if after else None)
        finally:
            db.close()
        if not messages:
            return
        turns = review.person_turns(messages)
        if turns:
            review.review(turns, keeper, _review_ask, session=session_id, profile=profile)
        # And what the person corrected, as a standing lesson (lessons.py): no model call
        # unless a turn actually corrects the assistant.
        try:
            if keeper.files.store.target_enabled("memory"):
                lessons = _module("lessons.py", "alice_lessons")
                lessons.review(
                    messages, keeper, _review_ask,
                    person_text=lambda m: (review.person_turns([m]) or [""])[0],
                    quoted=review.quoted, plain=review._plain,
                    risky=lambda text: _skill_keeper().review({"payload": {"content": text}}),
                    session=session_id, profile=profile)
        except Exception:
            pass
        # Read once: the same words are never looked at again, whatever the model said.
        seen[session_id] = max(int(m.get("id") or 0) for m in messages) or after
        keeper._write("reviewed.json", dict(list(seen.items())[-500:]))
    except Exception:
        pass


def _is_agent_maker(**_) -> bool:
    """Agent Maker's tools follow the stamped role, including after a rename."""
    try:
        from hermes_constants import get_hermes_home

        root, me = _root_and_sender(Path(get_hermes_home()))
        return _agent_engine().is_agent_maker(root, me)
    except Exception:
        return False


def _agent_json(payload: dict) -> str:
    import json

    return json.dumps(payload, ensure_ascii=False)


AGENT_TOOLS = (
    ("agent_create", "🛠️",
     "Crea o configura un agente de Hermes a partir de una especificación validada. "
     "No inventes otros comandos. Si Alice ya creó el perfil para ESTE encargo, "
     "pasa reuse_profile y el mismo job_id. Un perfil de otro trabajo no se reutiliza.",
     ({"spec": {"type": "object", "description":
                "title o name, description, soul con ## Ejemplos, tools, routines, "
                "model y provider. reuse_profile solo con el job_id que creó ese perfil."},
       "job_id": dict(_TEXT, description="El mismo trabajo reanuda y no duplica.")},
      ["spec"]),
     lambda a: _agent_engine().create_from_tool(a or {})),
    ("agent_rename", "✏️",
     "Renombra un agente y su perfil Hermes, conservando conversaciones, instrucciones, "
     "rutinas y credenciales. No elige otro identificador si el nombre está ocupado.",
     ({"from": dict(_TEXT, description="Identificador actual del perfil."),
       "to": dict(_TEXT, description="Nombre visible nuevo (Agent Maker → agent-maker)."),
       "job_id": dict(_TEXT, description="El mismo trabajo reanuda y no duplica.")},
      ["from", "to"]),
     lambda a: _agent_engine().rename_from_tool(a or {})),
)


def _register_agent_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in AGENT_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_agents", schema=schema,
            handler=lambda args, _call=call, **_: _agent_json(_call(args or {})),
            check_fn=_is_agent_maker, description=description, emoji=emoji,
        )


_ERROR_MARKS = ("fail", "error", "timeout", "losttouch", "reconnecting", "endedunseen")


def _always(**_) -> bool:
    return True


def _diagnostics_reports(root: Path) -> list:
    import json

    folder = root / ".alice" / "diagnostics"
    if not folder.is_dir():
        return []
    found = []
    for path in folder.glob("*.json"):
        if path.name.startswith("."):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(data, dict):
            data["_mtime"] = path.stat().st_mtime
            found.append(data)
    found.sort(key=lambda row: row.get("_mtime") or 0, reverse=True)
    return found


def alice_app_status(_args=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        reports = _diagnostics_reports(root)
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    if not reports:
        return _agent_json({"ok": True, "reports": 0, "note": "no dump from the phone yet"})
    latest = reports[0]
    return _agent_json({
        "ok": True,
        "reports": len(reports),
        "device_id": latest.get("device_id"),
        "captured_at": latest.get("captured_at"),
        "version": latest.get("version"),
        "build": latest.get("build"),
        "revision": latest.get("revision"),
        "wellbeing": latest.get("wellbeing"),
        "connected": latest.get("connected"),
        "dashboard_ready": latest.get("dashboard_ready"),
        "gateway_configured": latest.get("gateway_configured"),
        "unknown_events": latest.get("unknown_events") or [],
        "line_count": len(latest.get("lines") or []),
    })


def alice_recent_errors(_args=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        reports = _diagnostics_reports(root)
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    if not reports:
        return _agent_json({"ok": True, "errors": [], "note": "no dump from the phone yet"})
    lines = reports[0].get("lines") or []
    errors = [
        line for line in lines
        if any(mark in str(line).lower() for mark in _ERROR_MARKS)
    ]
    return _agent_json({"ok": True, "errors": errors[-40:], "scanned": len(lines)})


def secret_prompt(_session_info=None) -> str:
    """How an agent gets a key it needs, without the key ever entering the chat."""
    return (
        "## Claves y tokens\n"
        "Si para un comando o una herramienta necesitas una clave, token o contraseña de la persona, "
        "**nunca se la pidas en el chat** ni le pidas que la pegue en un mensaje o en la terminal. "
        "Di en una frase para qué la necesitas y dónde conseguirla, y termina con esta línea sola: "
        "`[Dar clave](alice://connect/secret/NOMBRE)`, con NOMBRE en mayúsculas como variable de entorno "
        "(por ejemplo `EXA_API_KEY`). Alice la pide en un campo seguro y la guarda como `NOMBRE=…` en "
        "`~/.hermes/.env` y en el `.env` de cada perfil. Cuando diga que está, úsala desde ahí sin mostrarla: "
        "`NOMBRE=\"$(sed -n 's/^NOMBRE=//p' ~/.hermes/.env | tr -d '\\\"')\" comando`. "
        "Nunca imprimas, repitas ni resumas su valor, ni lo escribas en notas, memoria o archivos. "
        "No uses nombres de la configuración de Hermes (`HERMES_*`, `API_SERVER_*`)."
    )


def resolve_prompt(_session_info=None) -> str:
    """Finish what was asked: obstacles are part of the task, not a reason to stop.

    Hermes keeps 4,000 characters per plugin section and 8,000 for all of them: this text was
    4,322 and was dropped from every prompt, with the purchase rules beside it."""
    return (
        "## Terminar lo que te piden\n"
        "Cuando te piden hacer algo, tu trabajo es **dejarlo hecho**, no contar por qué no se pudo. Los "
        "imprevistos (cookies, pop-ups, sesión caducada, error de la página, un paso inesperado, una cesta "
        "con cosas de antes) son tuyos: mira la página en vez de suponer, arréglalo si es reversible y encaja "
        "con lo pedido, y si falla prueba dos o tres caminos distintos antes de rendirte. No preguntes por "
        "nada de esto.\n"
        "«No lo encuentro» nunca es la primera respuesta: busca en conversaciones pasadas "
        "(`session_search`), prueba el nombre oficial y variantes, `site:` de la tienda y su categoría. "
        "Al dar con el producto exacto de una compra, guarda la tienda y el enlace en tu memoria.\n"
        "Comprueba el resultado tras cada acción importante y, al terminar, cita la prueba (número de "
        "pedido o reserva, texto de confirmación). Sin prueba no está hecho.\n"
        "Solo te paras por: (a) un paso irreversible —pagar, enviar, publicar, borrar—; al pagar, el sí es "
        "su aprobación del checkout en Alice, nunca la confirmación de Hermes; (b) algo que cambia lo pedido "
        "(otro producto, más precio, otra fecha); (c) algo que solo tiene la persona (contraseña, tarjeta, "
        "código), que se pide con su tarjeta segura, nunca en el chat. Entonces pregunta una sola cosa con "
        "una propuesta concreta. Proyectos grandes y ambiguos: pregunta antes, de una vez, las 2–3 cosas que "
        "cambian el resultado. Una compra sigue «Comprar».\n"
        "Si algo quedó sin comprobar o dependía de una suposición, añade una línea «Sin comprobar: …»."
    )


def _text_channel():
    return _module("text_channel.py", "alice_text_channel")


# Channels that show text as it comes: markdown would show as ** and [text](url).
_PLAIN_TEXT_PLATFORMS = {"photon", "sms", "imessage", "bluebubbles"}


def _plain_text_reply(**kwargs):
    session = _session_id(kwargs.get('session_id', ''))
    window = _PURCHASE_TURN_WINDOWS.get(session)
    if window and session not in _AUTOMATED_TURNS and session not in _ERRAND_TURN_IDS:
        if not window[0] or window[0] == kwargs.get('turn_id'):
            try:
                canonical = _purchase_flow().recommendation_reply(_hermes_root(), session, window[1])
                if canonical:
                    return _text_channel().plain(canonical) if str(kwargs.get('platform') or '').lower() in _text_channel().PLATFORMS else canonical
            except Exception:
                logging.getLogger(__name__).warning('Could not render the stored purchase recommendation', exc_info=True)
    return _text_channel().transform(**kwargs)


def channel_prompt(session_info=None) -> str:
    """How to write when the person reads Alice in iMessage or SMS rather than the app."""
    platform = str((session_info or {}).get("platform") or "").lower()
    if platform not in _PLAIN_TEXT_PLATFORMS:
        return ""
    return (
        "## Estás en iMessage\n"
        "La persona te lee en iMessage, que muestra el texto tal cual: **nada de Markdown** — sin "
        "asteriscos, almohadillas, tablas ni enlaces con corchetes. Escribe como un mensaje de texto "
        "entre personas: frases cortas, lo importante primero, y si hay varias cosas, una por línea "
        "empezando con «•». Los enlaces van como la dirección sola en su propia línea "
        "(https://…), nunca como [texto](url). Nunca un párrafo largo: una idea por párrafo, "
        "con una línea en blanco entre ellos. Por ejemplo:\n"
        "Hoy en Chollometro, lo mejor:\n\n"
        "• Sandwichera Create: 21,80 € (antes 54,95 €)\n"
        "• Lidl: 3 € de descuento en compras de 30 €, solo hoy\n\n"
        "Ojo: el de Apple Music es para estudiantes de India.\n\n"
        "https://www.chollometro.com/ofertas"
    )


def doubts_prompt(_session_info=None) -> str:
    """Contradictions between memory and what the person said lately, to be asked, not assumed."""
    try:
        from hermes_constants import get_hermes_home

        keeper_module = _module("memory_keeper.py", "alice_memory_keeper")
        review = _module("memory_review.py", "alice_memory_review")
        keeper = keeper_module.Keeper(Path(get_hermes_home()), keeper_module.HermesFiles())
        return review.doubts_prompt(review.open_doubts(keeper))
    except Exception:
        return ""


def errands_prompt(_session_info=None) -> str:
    """How errands start, and those Alice may offer once (kept short: see resolve_prompt)."""
    return (
        _errands().PROMPT + "\n"
        "Ofrece una vez, cuando encajen, y con su sí déjalos funcionando: revisar suscripciones del correo "
        "(cancelar pide su sí), avisar 3 días antes del fin de un plazo de devolución (léelo en la tienda), "
        "vigilar citas o stock (`page_watch_create`, o una rutina con el navegador) y facturar vuelos cuando "
        "abra la facturación."
    )


def debug_prompt(_session_info=None) -> str:
    return (
        "## Alice app diagnostics\n"
        "When the person asks what is wrong with Alice or the iPhone app, "
        "call `alice_app_status` and `alice_recent_errors` before guessing. "
        "Do not invent connection state. Typical causes: notConfigured means they "
        "have not paired; unreachable means local network, Tailscale or Hermes is "
        "down; reconnecting or lostTouch means the gateway dropped mid-turn and "
        "Alice does not retry mutations; turn.failed is the last send; unknown "
        "event kinds are stream events Alice has not learnt, and the reply should "
        "still have been kept.\n"
    )


DEBUG_TOOLS = (
    ("alice_app_status", "📱",
     "Connection, build and unknown events from the last dump the iPhone uploaded. "
     "Call this before guessing why Alice is failing.",
     ({}, []),
     lambda _a: alice_app_status()),
    ("alice_recent_errors", "⚠️",
     "Recent failure, timeout and reconnect lines from the last dump the iPhone uploaded.",
     ({}, []),
     lambda _a: alice_recent_errors()),
)


def _register_debug_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in DEBUG_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_debug", schema=schema,
            handler=lambda args, _call=call, **_: _call(args or {}),
            check_fn=_always, description=description, emoji=emoji,
        )


def _calendar():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "calendar_snapshot.py"
    name = "alice_calendar_snapshot"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def calendar_events_tool(args=None) -> str:
    """The person's calendar, read on demand so a long chat never works from a stale copy."""
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        a = args or {}
        return _agent_json(_calendar().events(
            root, days_ahead=float(a.get("days_ahead", 7) or 7),
            days_back=float(a.get("days_back", 0) or 0), tz=_calendar().zone(root),
        ))
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


CALENDAR_TOOLS = (
    ("calendar_events", "📅",
     "The person's calendar, as their iPhone last sent it (read-only). Always returns `status`: "
     "`connected` with the events in the window asked for; `not_connected` when they have not "
     "connected it; `declined` when they said not now. Call it before answering anything about "
     "their schedule, plans, free time, meetings or trips.",
     ({"days_ahead": {"type": "number", "description": "How many days ahead to include (default 7, at most 60)."},
       "days_back": {"type": "number", "description": "Whole days before today to include (default 0: from midnight today, so this morning is always in)."}}, []),
     calendar_events_tool),
)


def _register_calendar_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in CALENDAR_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_calendar", schema=schema,
            handler=lambda args, _call=call, **_: _call(args or {}),
            check_fn=_always, description=description, emoji=emoji,
        )


# ── Page watches, PDF forms, spending, and the shared browser ──────────────────────


def _module(filename: str, name: str):
    import importlib.util
    import sys

    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _watch():
    return _module("page_watch.py", "alice_page_watch")


def _documents():
    return _module("documents.py", "alice_documents")


def _browser():
    return _module("browser_live.py", "alice_browser_live")


def _hermes_root() -> Path:
    from hermes_constants import get_hermes_home

    return _root_and_sender(Path(get_hermes_home()))[0]


def _tool(call):
    """A handler that answers JSON and never raises: failures are the agent's to explain."""
    def handler(args=None, **_):
        try:
            return _agent_json({"ok": True, **call(args or {})})
        except Exception as exc:  # noqa: BLE001
            return _agent_json({"ok": False, "error": str(exc) or type(exc).__name__})
    return handler


def _watch_create(a):
    from hermes_constants import get_hermes_home

    root, profile = _root_and_sender(Path(get_hermes_home()))
    below = a.get("below")
    return {"watch": _watch().create(
        root, url=str(a.get("url") or ""), kind=str(a.get("kind") or "change"), label=str(a.get("label") or ""),
        below=float(below) if below not in (None, "") else None, text=str(a.get("text") or ""),
        every_minutes=int(a.get("every_minutes") or 60), profile=profile)}


WATCH_TOOLS = (
    ("page_watch_create", "👀",
     "Watch a public web page for the person and tell them when something happens, without them asking again. "
     "kind: `price` (tell when the price drops, or with `below` when it is at or under that amount), `stock` "
     "(tell when it is available again), `text` (tell when `text` appears on the page) or `change` (any change). "
     "Checks every `every_minutes` (default 60, minimum 15); news reaches their Alice chat on its own. Use it "
     "whenever they say «avísame si/cuando…» about a page, a product, tickets or availability. If it says the "
     "feature is not active, tell them to turn it on in Alice › Vigilancias.",
     ({"url": {"type": "string", "description": "The page, http(s)."},
       "kind": {"type": "string", "enum": ["price", "stock", "text", "change"]},
       "label": {"type": "string", "description": "A short name for it, in their language."},
       "below": {"type": "number", "description": "For price: tell when the price is at or under this."},
       "text": {"type": "string", "description": "For text: the words to wait for."},
       "every_minutes": {"type": "integer"}}, ["url", "kind"]),
     _watch_create),
    ("page_watch_list", "👀", "The pages being watched for the person, with the current price, stock and status.",
     ({}, []), lambda a: {"watches": _watch().listing(_hermes_root())}),
    ("page_watch_delete", "👀", "Stop watching a page (by the id page_watch_list gives).",
     ({"id": {"type": "string"}}, ["id"]),
     lambda a: (_watch().delete(_hermes_root(), str(a.get("id") or "")), {"deleted": a.get("id")})[1]),
)

DOCUMENT_TOOLS = (
    ("pdf_form_read", "📄",
     "Read a fillable PDF form: its fields (name, kind, current value, choices) and the start of its text. "
     "`path` is the file's absolute path or its alice://file link.",
     ({"path": {"type": "string"}}, ["path"]),
     lambda a: _documents().form_read(str(a.get("path") or ""))),
    ("pdf_form_fill", "📄",
     "Fill a PDF form's fields exactly and save a copy next to it (…-rellenado.pdf). `values` maps field "
     "names from pdf_form_read to values; for checkboxes use one of the field's options. Then show the copy "
     "as ![Título](alice://file?path=…) so the person can review and sign it on their iPhone before it goes "
     "anywhere. Never invent data you do not have: ask for it.",
     ({"path": {"type": "string"}, "values": {"type": "object"}}, ["path", "values"]),
     lambda a: _documents().form_fill(str(a.get("path") or ""), a.get("values") or {})),
    ("spending_summary", "💶",
     "Add up a bank statement CSV exactly: income, spending, categories, top merchants, months and the "
     "largest payments from a bank CSV. Show a `spending` alice-ui component with the returned "
     "`income`, `spent`, `net`, `currency`, `from`, `to` and `categories` fields unchanged, "
     "then 2–4 plain observations. If `uncategorized` has recognisable merchants, call again with `rules` "
     "({\"text in the description\": \"Category\"}) instead of guessing sums yourself.",
     ({"path": {"type": "string"}, "rules": {"type": "object"}}, ["path"]),
     lambda a: _documents().spending(str(a.get("path") or ""), a.get("rules") or None)),
)


def _register_work_tools(ctx) -> None:
    for toolset, tools in (("alice_watch", WATCH_TOOLS), ("alice_documents", DOCUMENT_TOOLS)):
        for name, emoji, description, (properties, required), call in tools:
            schema = {"name": name, "description": description,
                      "parameters": {"type": "object", "properties": properties, "required": required}}
            ctx.register_tool(name=name, toolset=toolset, schema=schema, handler=_tool(call),
                              check_fn=_always, description=description, emoji=emoji)


BROWSER_HELD = (
    "The person has taken over the shared browser (a sign-in, a verification code, a CAPTCHA "
    "or a payment) and is using it now. Do not use the browser until they hand it back. Tell "
    "them in one short sentence what you will do once they do, then stop; do not retry this "
    "call, and do not open another browser to get around it."
)


def _browser_ready(tool_name=None, **_):
    """Before an agent browses: the shared browser Alice keeps is running — unless the
    person has taken it over, and then the agent waits for it to be handed back."""
    name = str(tool_name or "")
    if not (name.startswith("browser_") or name in ("browser", "purchase_browser")):
        return None
    try:
        root = _hermes_root()
        module = _browser()
        if module.managed(root) and module.control(root)["holder"] == "human":
            return {"action": "block", "message": BROWSER_HELD}
        if not module.ensure(root):
            return {"action": "block", "message": "El navegador de Alice no pudo arrancar. No ejecutes este paso ni afirmes que se hizo."}
    except Exception as exc:
        logging.getLogger(__name__).warning("Alice browser startup failed: %s", type(exc).__name__)
        return {"action": "block", "message": "No se pudo preparar el navegador de Alice. No ejecutes este paso ni afirmes que se hizo."}
    return None


# ── Goals: what the person wants reached, and Alice's plan (goals.py) ───────────────


def _goals_module():
    return _module("goals.py", "alice_goals")


def _goals_store():
    from hermes_constants import get_hermes_home

    return _goals_module().Goals(Path(get_hermes_home()))


def _cards_module():
    return _module("vault_cards.py", "alice_vault_cards")


def cards_prompt(_session_info=None) -> str:
    try:
        from hermes_cli.profiles import get_active_profile_name

        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    # Only an errand pays, and its brief carries these rules (errands.card_rules): in every chat's
    # prompt they took 2,000 of the 8,000 characters Hermes allows all plugin sections.
    return ""


def _health():
    return _module("health.py", "alice_health")


def _health_root() -> Path:
    from hermes_constants import get_hermes_home

    root, _ = _root_and_sender(Path(get_hermes_home()))
    return root


def _measured(goal):
    """A measured goal's progress from the person's Health data, or None without enough days."""
    measure = goal.get("measure") or {}
    try:
        return _health().goal_progress(_health_root(), measure["metric"], measure["target"],
                                       measure.get("direction", "at_least"), measure.get("window_days", 7),
                                       daily=bool(measure.get("daily")))
    except Exception:
        return None


def goals_prompt(_session_info=None) -> str:
    """The open goals, so the agent knows them and keeps them current."""
    try:
        return _goals_module().prompt_section(_goals_store().list(include_done=False), measured=_measured)
    except Exception:
        return ""


def _register_health_tools(ctx) -> None:
    module = _health()
    ctx.register_tool(
        name="health", toolset="alice_health", schema=module.SCHEMA,
        handler=lambda args, **_: _agent_json(module.run_tool(_health_root(), args or {})),
        check_fn=_always, description=module.SCHEMA["description"], emoji="❤️",
    )


def _places():
    return _module("places.py", "alice_places")


def _register_place_tools(ctx) -> None:
    module = _places()

    def handler(args, **_):
        from hermes_constants import get_hermes_home

        return _agent_json(module.run_tool(Path(get_hermes_home()), args or {}))

    ctx.register_tool(
        name="place_trigger", toolset="alice_places", schema=module.SCHEMA, handler=handler,
        check_fn=_always, description=module.SCHEMA["description"], emoji="📍",
    )


def _task_finish():
    return _module("task_finish.py", "alice_task_finish")


def _ask_person():
    return _module("ask_person.py", "alice_ask_person")


def _keep_ask_person_visible() -> None:
    """Plugin tools are deferred behind tool_search; ask_person behind it was looked up under the
    wrong name, not found, and the question went into the reply as text — the one thing it exists
    to prevent. Like clarify, it stays in view. Core's list is extended, not replaced."""
    try:
        import toolsets

        core = getattr(toolsets, "_HERMES_CORE_TOOLS", None)
        if isinstance(core, list) and "ask_person" not in core:
            core.append("ask_person")
    except Exception:
        logging.getLogger(__name__).debug("ask_person: could not keep it out of tool_search", exc_info=True)


def _register_ask_tools(ctx) -> None:
    module = _ask_person()
    _keep_ask_person_visible()

    def handler(args, **_):
        from hermes_constants import get_hermes_home

        key = _conversation_key()
        if key.startswith(_errands().SESSION_PREFIX):
            # Inside an errand only what changes the purchase reaches the person; cards have their own card.
            refused = _errands().vet_questions(module._normalized(args or {}))
            if refused:
                return _agent_json({"ok": False, "error": refused})
        session = _session_id() or key
        if session in _PURCHASE_OPEN:
            # A purchase: country and currency are deduced, products are cards, and no choice is
            # offered before the shop was looked at.
            refused = _purchase_flow().ask_refusal((args or {}).get("questions") or [], session in _LOOKED)
            if refused:
                return _agent_json({"ok": False, "error": refused})
        out = module.run_tool(Path(get_hermes_home()), args or {}, key)
        if key.startswith(_errands().SESSION_PREFIX) and out.get("asked"):
            wanted = set(out["asked"])
            questions = [q for q in module._normalized(args or {}) if q["id"] in wanted]
            _errands().ask(_hermes_root(), key[len(_errands().SESSION_PREFIX):], str((args or {}).get("title") or ""),
                           questions)
            out["note"] = ("The person sees the questions in the errand. End your turn now with one line "
                           "saying what you are waiting for; the errand resumes with their answer.")
        return _agent_json(out)

    ctx.register_tool(
        name="ask_person", toolset="alice_tasks", schema=module.SCHEMA, handler=handler,
        check_fn=_always, description=module.SCHEMA["description"], emoji="💬",
    )


# The errand a chat turn's choice started, by session: errand_start in that turn gets it, however the
# model words its arguments (reading an old conversation, it once answered «ya está en marcha» about
# errands that had been stopped).
_ERRAND_TURN_IDS: dict = {}
_PURCHASE_TURN_WINDOWS: dict = {}
# Turns no person wrote — a routine running (cron_ sessions) or its output handed to a chat for
# review. They never start an errand: a routine's prompt and the "Cierre del día" summary once
# started purchases (a Prozis checkout at 34,99 €) that nobody had asked for that day.
_AUTOMATED_TURNS: set = set()
AUTOMATED_MARKERS = ("[IMPORTANT: You are running as a scheduled cron job", "[Cronjob ",
                     "[IMPORTANT: The user has invoked the")


def _automated(session: str, text) -> bool:
    return str(session or "").startswith("cron_") or " ".join(str(text or "").split()).startswith(AUTOMATED_MARKERS)


def _purchase_context() -> str:
    """Step 2 of buying: country, currency, where it goes, shops and cards used before (labels only)."""
    from hermes_constants import get_hermes_home

    flow = _purchase_flow()
    details = _ask_person().load_details(Path(get_hermes_home()))
    try:
        cards = _cards_module().cards()
    except Exception:
        cards = []
    recent = [e["receipt"] for e in _errands().listing(_hermes_root())
              if isinstance(e.get("receipt"), dict) and e["receipt"].get("outcome") == "paid"]
    return flow.context_block(details, cards, recent, timezone=_hermes_timezone())


def _hermes_timezone() -> str:
    """The `timezone:` of the main config.yaml, for deducing the person's country."""
    try:
        text = (_hermes_root() / "config.yaml").read_text(encoding="utf-8")
    except OSError:
        return ""
    found = __import__("re").search(r"^timezone:\s*['\"]?([^'\"\s#]+)", text, __import__("re").M)
    return found.group(1) if found else ""


def _purchase_locale() -> tuple:
    """(country, currency) as ISO codes: kept details first, else Hermes' time zone."""
    from hermes_constants import get_hermes_home

    return _purchase_flow().locale(_ask_person().load_details(Path(get_hermes_home())), _hermes_timezone())


# Chats whose last request was a purchase, and those that have looked at a shop or the catalog
# since: an ask_person with choices before looking offered formats the shop did not sell.
_PURCHASE_OPEN: set = set()
# What the person asked to buy, by chat: a link in it is an exact item, which may be one card.
_PURCHASE_REQUESTS: dict = {}
_LOOKED: set = set()


def _start_purchase(session: str, chosen: dict) -> dict:
    """Step 7 starts from the chosen option: its page, variant, quantity and price go to the errand."""
    from hermes_constants import get_hermes_home

    flow = _purchase_flow()
    _root, profile = _root_and_sender(Path(get_hermes_home()))
    prices = _module("purchase_prices.py", "alice_purchase_prices")
    errands = _errands()
    previous_price = chosen.get('price')
    try:
        quote = prices.resolve(_hermes_root(), session, chosen.get("quote_ref"), qty=chosen.get("qty",1))
    except Exception:  # noqa: BLE001
        # The disposable re-check failed (the shop was slow, the browser was down): the tap still
        # counts. The errand checks the real basket itself (purchase_check_cart) before anything
        # is approved, so nothing is lost by starting from the price the person saw.
        logging.getLogger(__name__).warning("purchases: could not revalidate the chosen option", exc_info=True)
        quote = None
    if quote is not None:
        price_changed = not _module('money.py','alice_money').same(previous_price,quote['price'],quote['currency'])
        chosen.update({k:quote[k] for k in ('title','variant','qty','currency','url')})
        if not price_changed:
            chosen['price'] = quote['price']
        chosen['quote_ref'] = quote['id']
        chosen['verified_at'] = quote['at']
        if price_changed:
            # One stopped errand per option and chat: tapping again shows that one, not a twin.
            for other in errands.listing(_hermes_root()):
                if (other.get("origin_session") == session and other.get("status") == "stuck"
                        and (other.get("offer") or {}).get("option_id") == chosen["id"]
                        and (other.get("blocked") or {}).get("price") == quote["price"]):
                    return errands.started_result(other)
            entry = errands.create(_hermes_root(),flow.task(chosen),title=flow.title(chosen),site=chosen['url'],origin_session=session,profile=profile,offer=flow.offer(chosen))
            errands.open_goal(entry)
            entry = errands.update(_hermes_root(),entry['id'],status='stuck',blocked={'kind':'price','price':quote['price']},reason='El precio comprobado cambió de ' + str(previous_price) + ' a ' + quote['price'] + '.')
            return errands.started_result(entry)
    return errands.start(_hermes_root(), {"task": flow.task(chosen), "title": flow.title(chosen)},
                         origin_session=session, profile=profile, offer=flow.offer(chosen))


def _errand_turn(session_id="", user_message=None, **_):
    """Before a chat turn. A purchase request gets the person's context and the steps (1–6); nothing
    starts on its own. A tapped option («[elección:<id>]») starts that option's errand here, not at
    the model's discretion."""
    try:
        session = _session_id(session_id)
        errands, flow = _errands(), _purchase_flow()
        if not session or session.startswith(errands.SESSION_PREFIX):
            return None
        _ERRAND_TURN_IDS.pop(session, None)
        _PURCHASE_TURN_WINDOWS[session] = (_.get('turn_id'), __import__('time').time())
        if _automated(session, user_message):
            _AUTOMATED_TURNS.add(session)
            return None
        _AUTOMATED_TURNS.discard(session)
        option_id = flow.chosen_id(user_message)
        if option_id:
            quantity = __import__("re").search(r"\[cantidad:([0-9]+)\]", str(user_message))
            chosen = flow.choose(_hermes_root(), session, option_id, qty=int(quantity.group(1)) if quantity else 1, commit=False)
            if chosen is None:
                return {"context": "[Alice] " + flow.UNKNOWN_OPTION}
            out = _start_purchase(session, chosen)
            flow.choose(_hermes_root(), session, option_id, qty=chosen.get("qty",1))
            _ERRAND_TURN_IDS[session] = out["errand_id"]
            _PURCHASE_OPEN.discard(session)
            return {"context": flow.chosen_note(out, chosen)}
        if flow.is_purchase_request(user_message):
            _PURCHASE_OPEN.add(session)
            _PURCHASE_REQUESTS[session] = str(user_message or "")
            flow.remember_request(_hermes_root(), session, str(user_message or ""))
            _LOOKED.discard(session)
            again = flow.reshow(_hermes_root(), session, str(user_message or ""))
            if again:
                # Asked again for what was already searched here: the same cards are back on
                # screen (the app draws them under this reply). No new search, no answer from
                # memory with nothing to tap.
                best = next((o for o in again["options"] if o.get("recommended")), again["options"][0])
                return {"context": (
                    "[Alice · compra] La persona vuelve a pedir lo mismo. Las tarjetas de esa búsqueda ya se "
                    f"muestran otra vez bajo tu respuesta ({len(again['options'])} formatos comprobados; la marcada "
                    f"«Recomendada» es «{best.get('title')} · {best.get('variant') or ''} · {best.get('price')}»). "
                    "No busques ni compruebes nada de nuevo salvo que pida otra cosa: recomienda esa en una o dos "
                    "líneas, di que toque su tarjeta, y termina el turno.")}
            note = flow.turn_note(_purchase_context())
            search = _module('purchase_prozis.py', 'alice_purchase_prozis').search_request(
                str(user_message or ''), _purchase_locale()[0])
            words = _module('purchase_prozis.py', 'alice_purchase_prozis').keywords(str(user_message or ''))
            if not search and words:
                # Any shop: its own search, every format that names the asked words, nothing guessed.
                note += (' [Búsqueda] Llama a purchase_discover con shop (la tienda pedida, o varias si no nombra '
                         'ninguna: una llamada por tienda) y query con lo que pidió, y keywords=' + json.dumps(words, ensure_ascii=False)
                         + '. El plugin encuentra el buscador y los productos; no escribas selectores ni URLs de ficha. Después, '
                         'purchase_verify del formato que mejor encaje (variant si la persona la dijo). No digas que '
                         'algo no existe sin haber buscado ahí.')
            if search:
                note += (' [Contrato de búsqueda Prozis] Empieza por purchase_discover con ' + json.dumps(search, ensure_ascii=False)
                         + '. Es el buscador de la tienda, no la portada ni una URL adivinada. purchase_verify admite omitir recipe: el servicio '
                         'reconoce sus controles reales, espera la carga, selecciona y comprueba la variante y '
                         'prueba los cupones públicos observados. Incluye todos los other_formats comprobados. '
                         'Si falla la comprobación, no cambies de producto ni afirmes que no existe.')
            return {"context": note}
    except Exception as exc:  # noqa: BLE001
        # Never silent: a purchase that could not start is said as such, or the model improvises
        # one (each model differently). Anything else in this hook is not worth a word.
        logging.getLogger(__name__).warning("purchases: the turn hook failed", exc_info=True)
        if _purchase_flow_safe_chosen(user_message):
            return {"context": ("[Alice] No he podido iniciar la compra de la opción elegida "
                                f"({type(exc).__name__}). Díselo a la persona en una línea, sin decir que "
                                "está en marcha, y no la inicies tú: que vuelva a tocar la opción.")}
    return None


def _purchase_flow_safe_chosen(user_message) -> bool:
    try:
        return bool(_purchase_flow().chosen_id(user_message))
    except Exception:  # noqa: BLE001
        return False


def _guard_chat_errand(tool_name=None, args=None, session_id="", **_):
    """A chat may search and read shops, but a cart is filled only by the errand of a chosen option."""
    name = str(tool_name or "")
    session = _session_id(session_id)
    if not session or session.startswith(_errands().SESSION_PREFIX):
        return None
    if name.startswith(("browser", "catalog_", "web_search", "web_extract")):
        _LOOKED.add(session)
    if _purchase_flow().is_cart_action(name, args):
        return {"action": "block", "message": _purchase_flow().CART_BLOCK}
    return None


def _keep_errand_tools_visible() -> None:
    """Behind tool_search, the chat went looking for errand_start after browsing and asking on its
    own; like ask_person, the errand tools stay in view. Core's list is extended, not replaced."""
    try:
        import toolsets

        core = getattr(toolsets, "_HERMES_CORE_TOOLS", None)
        if isinstance(core, list):
            for name in ("errand_start", "checkout_request", "card_request", "purchase_options",
                         "catalog_search", "catalog_product", "purchase_discover", "purchase_verify", "login_request", "login_fill", "purchase_check_cart", "purchase_browser"):
                if name not in core:
                    core.append(name)
    except Exception:
        logging.getLogger(__name__).debug("errands: could not keep the tools out of tool_search", exc_info=True)


def _pause_chat_goals() -> None:
    """Goals the old errand loop opened on chats (its contract) are paused: judged after every
    later turn of that chat, they resumed purchases nobody had asked about again."""
    try:
        import sqlite3

        from hermes_cli.goals import GoalManager
        from hermes_constants import get_hermes_home

        db = Path(get_hermes_home()) / "state.db"
        if not db.is_file():
            return
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2) as conn:
            rows = conn.execute("SELECT key, value FROM state_meta WHERE key LIKE 'goal:%'").fetchall()
        prefix = "goal:" + _errands().SESSION_PREFIX
        # The loop's contract, in any of its wordings since it was introduced.
        marker = _task_finish().CONSTRAINTS[:40]
        for key, value in rows:
            try:
                state = json.loads(value)
            except (TypeError, ValueError):
                continue
            contract = state.get("contract") or {}
            if (key.startswith(prefix) or state.get("status") != "active"
                    or not str(contract.get("constraints") or "").startswith(marker)):
                continue
            GoalManager(session_id=key[len("goal:"):]).pause("recado antiguo: ahora los recados van aparte")
    except Exception:
        logging.getLogger(__name__).debug("errands: could not pause old chat goals", exc_info=True)


def _repeat_guard(user_message=None, assistant_response=None, session_id="", **_):
    """The goal stops sending the agent back once it only repeats itself (task_finish.guard_repeat)."""
    try:
        from tools.approval_context import get_current_session_key

        session_key = get_current_session_key(default="")
        session = _session_id(session_id) or session_key
        # Errands have their own bounded guard, with the recorded browser steps.
        # The chat-only text guard otherwise pauses a progressing errand first.
        if not str(session).startswith(_errands().SESSION_PREFIX):
            _task_finish().guard_repeat(user_message, assistant_response, session_key)
    except Exception:
        logging.getLogger(__name__).debug("finish_task: repeat guard failed", exc_info=True)


def _absorb_answers(conversation_history=None, **_):
    """The person's answers to ask_person, steered into the turn or sent as the next one."""
    try:
        from hermes_constants import get_hermes_home

        _ask_person().absorb(Path(get_hermes_home()), _conversation_key(),
                             # Every user row: after an answer a turn can run a hundred browser
                             # steps, and a window of the last rows missed the answer itself.
                             [m for m in (conversation_history or []) if m.get("role") == "user"])
    except Exception:
        logging.getLogger(__name__).debug("ask_person: could not read the answers", exc_info=True)


def ask_prompt(_session_info=None) -> str:
    from hermes_constants import get_hermes_home

    return _ask_person().prompt(Path(get_hermes_home()))


def _vault_logins(origin: str) -> list:
    """The logins Hermes' vault holds for an origin (handle and origin only, never values)."""
    try:
        store = _cards_module()._store()
        found = [m for m in store.list_items()
                 if m.kind == "login" and str(m.origin or "").rstrip("/").lower() == str(origin or "").rstrip("/").lower()]
        # Newest first: the last one the person gave is the one that works. Listed oldest first,
        # the agent took an old login with a stale password every time (06-10, 15 Prozis logins).
        found.sort(key=lambda m: str(getattr(m, "created_at", "") or ""), reverse=True)
        return [{"handle": m.id, "origin": m.origin} for m in found]
    except Exception:  # noqa: BLE001
        return []


def _profile_home(profile: str) -> Path:
    """The home of a Hermes profile: the root for the main one, ``profiles/<name>`` otherwise."""
    root = _hermes_root()
    name = str(profile or "").strip()
    if name and name != "default" and "/" not in name and name not in (".", ".."):
        candidate = root / "profiles" / name
        if candidate.is_dir():
            return candidate
    return root


def _delivery_details(profile: str):
    """The saved delivery details of the errand's own profile, or None when unreadable. Read by
    profile, not from whichever home the calling process has (the dashboard's is the main one)."""
    try:
        return _ask_person().load_details(_profile_home(profile))
    except Exception:  # noqa: BLE001
        return None


def _card_rules(profile: str) -> str:
    try:
        return _cards_module().prompt(profile or "default")
    except Exception:
        return ""


def _register_task_tools(ctx) -> None:
    """Errands (errands.py) replace finish_task: a goal on a chat's session was judged after every
    later turn of that chat, and an old purchase resumed in the middle of an unrelated question."""
    errands = _errands()
    errands.card_rules = _card_rules
    errands.details_block = _delivery_details
    _module("errand_access.py", "alice_errand_access").vault_logins = _vault_logins
    _keep_errand_tools_visible()

    def start(args, **_):
        from hermes_constants import get_hermes_home

        try:
            from tools.approval_context import get_current_session_key

            flow = _purchase_flow()
            args = args or {}
            _root, profile = _root_and_sender(Path(get_hermes_home()))
            session = _session_id() or get_current_session_key(default="")
            # A choice tapped this turn already started its errand (_errand_turn): the model's call,
            # however worded, gets that one.
            if _automated(session, "") or session in _AUTOMATED_TURNS:
                return _agent_json({"ok": False, "error": (
                    "Un recado lo pide la persona, no una rutina. No lo inicies: si algo está pendiente de "
                    "comprar o reservar, dilo en tu resumen y que ella decida.")})
            turn_id = _ERRAND_TURN_IDS.get(session)
            entry = errands.get(_hermes_root(), turn_id) if turn_id else None
            if (entry is not None and entry.get("origin_session") == session
                    and (entry.get("profile") or "") == profile):
                return _agent_json({"ok": True, **errands.started_result(entry)})
            option_id = str(args.get("option_id") or "").strip()
            if option_id:
                chosen_set = flow.options_set(_hermes_root(), option_id.split('-')[0], session=session)
                if not chosen_set or chosen_set.get('chosen') != option_id:
                    return _agent_json({"ok":False,"error":flow.NEEDS_CHOICE})
                chosen = flow.choose(_hermes_root(), session, option_id, qty=chosen_set.get('chosen_qty',1))
                if chosen is None:
                    return _agent_json({"ok": False, "error": flow.UNKNOWN_OPTION})
                return _agent_json({"ok": True, **_start_purchase(session, chosen)})
            # A purchase never starts from words alone: the person chooses among verified options first.
            if flow.is_purchase_request(args.get("task")) or flow.open_options(_hermes_root(), session):
                return _agent_json({"ok": False, "error": flow.NEEDS_CHOICE})
            return _agent_json({"ok": True, **errands.start(
                _hermes_root(), args, origin_session=session, profile=profile)})
        except Exception as exc:  # noqa: BLE001
            return _agent_json({"ok": False, "error": str(exc) or type(exc).__name__})

    def checkout(args, **_):
        session = _session_id()
        entry = errands.of_session(_hermes_root(), session)
        if entry is None:
            return _agent_json({"ok": False, "error": "Only inside an errand. Purchases are errands: use errand_start."})
        if entry.get('offer'):
            try:
                prices = _module("purchase_prices.py", "alice_purchase_prices")
                if not prices.fresh_cart(_hermes_root(),entry):
                    return _agent_json({"ok":False,"error":"Comprueba primero la cesta de este recado con purchase_check_cart. Cambió la sesión o la oferta carece de evidencia vigente."})
                # The total is read from the page by the plugin: at the agent's selector if it gave
                # one, else next to «Total» (shop_engine). A total the model writes is never used.
                selector = str((args or {}).get('total_selector') or '')
                total = prices.checkout_amount(entry,selector)
                offer = entry['offer']
                args = {**(args or {}), 'total':total, 'currency':offer['currency'],
                        'items':[{'name':offer['title'],'variant':offer.get('variant',''),'qty':offer.get('qty',1),'price':offer['price']}]}
            except ValueError as exc:
                return _agent_json({"ok":False,"error":str(exc)})
            except Exception:
                return _agent_json({"ok":False,"error":"No se pudo verificar la cesta y el total de este recado. Comprueba el resumen final antes de pedir aprobación."})
        result = errands.request_checkout(_hermes_root(), entry["id"], args or {}, saved_cards=_cards_module().cards)
        if entry.get('offer') and result.get('ok') and result.get('status') == 'needs_approval':
            pending = errands.get(_hermes_root(),entry['id'])['checkout']
            errands.update(_hermes_root(),entry['id'],checkout_evidence={'checkout_id':pending['id'],'selector':selector,'engine':not selector})
        return _agent_json(result)

    def check_cart(args, **_):
        entry = errands.of_session(_hermes_root(), _session_id())
        if not entry:
            return _agent_json({"ok":False,"error":"Solo en la cesta del recado elegido."})
        try:
            return _agent_json(_module("purchase_prices.py", "alice_purchase_prices").check_cart(_hermes_root(),entry['id'],args or {}))
        except Exception as exc:
            return _agent_json({"ok":False,"error":str(exc) if isinstance(exc,ValueError) else "No se pudo leer la cesta del recado."})
    ctx.register_tool(name="purchase_check_cart", toolset="alice_tasks", handler=check_cart,
        schema={"name":"purchase_check_cart","description":"With the errand's cart open (the cart page or drawer showing the chosen product), read and revalidate the chosen format, units and current price. Call it with no arguments: the plugin finds the line itself. No cart mutation or payment.",
                "parameters":{"type":"object","properties":{name:{'type':'string','description':desc} for name,desc in (('line','Optional, only if the plugin could not find the line: CSS selector of the cart line. Never product text.'),('price','Optional: CSS selector of the unit price inside that line. Never an amount.'),('cart_quantity','Optional: CSS selector of the line quantity. Never a number.'))},"required":[]}},
        check_fn=_always, description="Revalidate this errand's cart after login", emoji="🛒")

    def login_fill(args, **_):
        entry = errands.of_session(_hermes_root(), _session_id())
        if not entry:
            return _agent_json({"ok":False,"error":"Solo dentro de un recado."})
        gate = errands.login_gate(_hermes_root(), entry['session_id'])
        if gate:
            return _agent_json({"ok":False,"error":gate.get('message','Espera la aprobación de acceso.')})
        try:
            return _agent_json(_module("errand_access.py", "alice_errand_access").fill_login(_hermes_root(),entry['id'],str((args or {}).get('handle',''))))
        except ValueError as exc:
            return _agent_json({"ok":False,"error":str(exc)})
        except Exception:
            return _agent_json({"ok":False,"error":"No se pudo rellenar el acceso en la página de este recado. Comprueba el origen o solicita login_request."})

    ctx.register_tool(name="login_fill", toolset="alice_tasks", handler=login_fill,
        schema={"name":"login_fill","description":"Fill this errand's pinned shop page from an exact-origin vault login. Secrets never enter the tool result.",
                "parameters":{"type":"object","properties":{"handle":{"type":"string"}},"required":["handle"]}},
        check_fn=_always, description="Fill a saved login in this errand's own page", emoji="🔐")

    def login_request(args, **_):
        entry = errands.of_session(_hermes_root(), _session_id())
        if not entry:
            return _agent_json({"ok": False, "error": "Solo dentro de un recado."})
        try:
            access = _module("errand_access.py", "alice_errand_access")
            result = access.request(_hermes_root(), entry['id'], (args or {}).get('kind', 'vault.save_login'),
                                    replace=bool((args or {}).get('replace')))
            return _agent_json({"ok": True, "request": access.public(result, for_agent=True), "next": "Termina el turno. Espera el acceso seguro del iPhone; el mismo recado continúa."})
        except ValueError as exc:
            return _agent_json({"ok": False, "error": str(exc)})
        except Exception:
            return _agent_json({"ok": False, "error": "Abre la página HTTPS de acceso dentro del recado antes de solicitarlo."})

    ctx.register_tool(name="login_request", toolset="alice_tasks", handler=login_request,
        schema={"name": "login_request", "description": "Ask securely on the iPhone for this errand's exact shop login or OTP. Never ask for secrets in chat.",
                "parameters": {"type": "object", "properties": {"kind": {"type": "string", "enum": ["vault.save_login", "vault.code"]},
                                                                 "replace": {"type": "boolean", "description": "Only after login_fill failed with the saved access of this shop."}}}},
        check_fn=_always, description="Request this shop's login or OTP securely on iPhone", emoji="🔐")

    def options(args, **_):
        from hermes_constants import get_hermes_home

        session = _session_id()
        if not session or session.startswith(errands.SESSION_PREFIX):
            return _agent_json({"ok": False, "error": "Only in the chat, before the purchase starts."})
        details = _ask_person().load_details(Path(get_hermes_home()))
        return _agent_json(_module("purchase_prices.py", "alice_purchase_prices").present(
            _hermes_root(), session, args or {}, currency=_purchase_locale()[1],
            picture=lambda page: errands.page_picture(page),
            request=_PURCHASE_REQUESTS.get(session, "")))

    def price_tool(method, args):
        session = _session_id()
        if not session or session.startswith(errands.SESSION_PREFIX):
            return _agent_json({"ok":False,"error":"Solo en la búsqueda del chat."})
        try:
            prices = _module("purchase_prices.py", "alice_purchase_prices")
            args = dict(args or {})
            if method == 'verify':
                args['qty'] = 1
            result = getattr(prices, method)(_hermes_root(), session, args)
            if method == 'verify' and result.get('id'):
                result.update(prices.verify_remaining(_hermes_root(),session,args))
                # The cards go up from the evidence itself: the person can tap one whether or
                # not the model goes on to call purchase_options (it writes about them; it does
                # not have to make them appear).
                try:
                    shown = prices.auto_present(_hermes_root(), session, args.get('search_id'),
                                                currency=_purchase_locale()[1],
                                                picture=lambda page: errands.page_picture(page),
                                                request=_PURCHASE_REQUESTS.get(session, ""))
                except Exception:  # noqa: BLE001
                    logging.getLogger(__name__).warning("purchases: could not show the cards from the evidence", exc_info=True)
                    shown = None
                if shown and shown.get('ok'):
                    result['set'] = shown['set']
                    result['cards'] = shown['options']
                    result['next'] = ('La persona YA VE las tarjetas de todos los formatos comprobados (set ' + shown['set']
                                      + '). Llama a purchase_options con search_id y todos los quote_refs marcando tu '
                                      'recomendada y por qué; después, una o dos líneas y termina el turno.')
            # The set at the top too: the app reads the cards' key from the call's result.
            out = {"ok": True, "result": result}
            if isinstance(result, dict) and result.get('set'):
                out["set"] = result['set']
            return _agent_json(out)
        except Exception as exc:
            return _agent_json({"ok": False, "error": str(exc) if isinstance(exc, ValueError) else "La comprobación de la cesta temporal no está disponible."})

    for tool_name, method, properties, required in (
        ('purchase_discover','discover', {'shop':{'type':'string','description':"The shop's domain or address, e.g. tienda.com. The plugin finds its search and the product links itself."},'query':{'type':'string','description':'What to search for, in the words a shop would use, e.g. "creatina creapure"'},'url':{'type':'string','description':"Instead of shop+query: the shop's own results or category page. Never a guessed product URL."},'selector':{'type':'string','description':'Optional and rarely needed: CSS selector for the product links on that page'},'keywords':{'type':'array','items':{'type':'string'},'description':'Product words every candidate must name (url or title), e.g. ["creapure"]'}}, []),
        ('purchase_verify','verify', {'search_id':{'type':'string'},'candidate_id':{'type':'string'},'currency':{'type':'string'},'variant':{'type':'string','description':'The variant to check (size, flavour…) as the page names it; omit for the page default'},'qty':{'type':'integer','minimum':1,'maximum':20},'reject_reason':{'type':'string'},'coupons':{'type':'array','maxItems':5,'items':{'type':'string'}},
         'recipe':{'type':'object','description':'Optional and rarely needed: observed DOM selectors, only if the plugin said it could not read this shop.','properties':{name:{'type':'string'} for name in ('title','variant','quantity','add','cart_url','line','price','cart_quantity','shipping','condition','coupon','apply','unavailable')}}},['search_id','candidate_id','currency'])):
        description = ('Find the formats of a product in a shop: give shop and query (or the shop\'s results page). The plugin uses the shop\'s own search and lists the product pages; never guess selectors or product URLs.' if method=='discover' else
                       'Check one format\'s real price in a disposable basket (no login, no payment): the plugin opens the product, picks the variant, adds it and reads the basket itself. Give search_id, candidate_id, currency and, if it matters, variant. The remaining formats are checked too; the cards appear from the evidence. A quote with basis «page» is the product page\'s price, confirmed later in the errand\'s basket. Returns trusted quote_ref.')
        ctx.register_tool(name=tool_name, toolset='alice_tasks', handler=lambda args,_method=method,**_:price_tool(_method,args),
            schema={'name':tool_name,'description':description,'parameters':{'type':'object','properties':properties,'required':required}},
            check_fn=_always, description=description, emoji='🛒')

    def catalog_search(args, **_):
        from hermes_constants import get_hermes_home

        args = args or {}
        details = _ask_person().load_details(Path(get_hermes_home()))
        return _agent_json(_catalog().search(
            str(args.get("query") or ""), country=_purchase_locale()[0], currency=_purchase_locale()[1],
            limit=int(args.get("limit") or 6), max_price=args.get("max_price")))

    def catalog_product(args, **_):
        from hermes_constants import get_hermes_home

        args = args or {}
        details = _ask_person().load_details(Path(get_hermes_home()))
        selected = args.get("options") if isinstance(args.get("options"), dict) else None
        return _agent_json(_catalog().product(
            str(args.get("product_id") or ""), selected=selected,
            country=_purchase_locale()[0], currency=_purchase_locale()[1]))

    product_list = _module("product_list.py", "alice_product_list")

    def show_products(args, **_):
        try:
            return _agent_json(product_list.check(args or {}))
        except product_list.ProductListError as error:
            return _agent_json({"ok": False, "error": str(error)})

    ctx.register_tool(name="product_list", toolset="alice_tasks", schema=product_list.SCHEMA,
                      handler=show_products, check_fn=_always, description=product_list.SCHEMA["description"],
                      emoji="🛍️")

    flow, catalog = _purchase_flow(), _catalog()
    ctx.register_tool(name="purchase_options", toolset="alice_tasks", schema=flow.OPTIONS_SCHEMA, handler=options,
                      check_fn=_always, description=flow.OPTIONS_SCHEMA["description"], emoji="🛒")
    ctx.register_tool(name="catalog_search", toolset="alice_tasks", schema=catalog.SEARCH_SCHEMA,
                      handler=catalog_search, check_fn=_always, description=catalog.SEARCH_SCHEMA["description"],
                      emoji="🔎")
    ctx.register_tool(name="catalog_product", toolset="alice_tasks", schema=catalog.PRODUCT_SCHEMA,
                      handler=catalog_product, check_fn=_always, description=catalog.PRODUCT_SCHEMA["description"],
                      emoji="🔎")

    ctx.register_tool(name="errand_start", toolset="alice_tasks", schema=errands.START_SCHEMA, handler=start,
                      check_fn=_always, description=errands.START_SCHEMA["description"], emoji="🛍️")
    def card(args, **_):
        entry = errands.of_session(_hermes_root(), _session_id())
        if entry is None:
            return _agent_json({"ok": False, "error": "Only inside an errand."})
        return _agent_json(errands.request_card(_hermes_root(), entry["id"], str((args or {}).get("page") or "")))

    ctx.register_tool(name="card_request", toolset="alice_tasks", schema=errands.CARD_SCHEMA, handler=card,
                      check_fn=_always, description=errands.CARD_SCHEMA["description"], emoji="💳")
    ctx.register_tool(name="checkout_request", toolset="alice_tasks", schema={**errands.CHECKOUT_SCHEMA, "parameters": {**errands.CHECKOUT_SCHEMA["parameters"], "properties": {**errands.CHECKOUT_SCHEMA["parameters"]["properties"], "total_selector": {"type":"string","description":"Optional: CSS selector of the final total, only if the plugin could not find «Total» on the page. The plugin reads the amount from the page; a total you write is never used."}}}},
                      handler=checkout, check_fn=_always, description=errands.CHECKOUT_SCHEMA["description"],
                      emoji="🧾")


def _register_feed_tools(ctx) -> None:
    """The editorial feed (feed.py): feed_publish for its own runs, feed_steer for Alice's chat,
    and the schedule that queues runs twice a day."""
    feed = _feed()
    try:
        import toolsets

        core = getattr(toolsets, "_HERMES_CORE_TOOLS", None)
        if isinstance(core, list):
            for name in ("feed_publish", "feed_steer"):
                if name not in core:
                    core.append(name)
    except Exception:
        logging.getLogger(__name__).debug("feed: could not keep the tools out of tool_search", exc_info=True)

    ctx.register_tool(
        name="feed_publish", toolset="alice_feed", schema=feed.PUBLISH_SCHEMA,
        handler=lambda args, **_: _agent_json(feed.run_publish(_hermes_root(), _session_id(), args or {})),
        check_fn=_always, description=feed.PUBLISH_SCHEMA["description"], emoji="📰")
    ctx.register_tool(
        name="feed_steer", toolset="alice_feed", schema=feed.STEER_SCHEMA,
        handler=lambda args, **_: _agent_json(feed.run_steer(_hermes_root(), args or {})),
        check_fn=_always, description=feed.STEER_SCHEMA["description"], emoji="🧭")
    _start_feed()


def _start_feed() -> None:
    """The schedule, and a run left queued or orphaned by a restart settled or followed again."""
    try:
        from hermes_constants import get_hermes_home

        feed = _feed()
        root, profile = _root_and_sender(Path(get_hermes_home()))
        feed.ensure_schedule(root, profile=profile)
        feed.kick(root)
    except Exception:
        logging.getLogger(__name__).debug("feed: could not set up the schedule", exc_info=True)


def _register_goal_tools(ctx) -> None:
    module = _goals_module()
    ctx.register_tool(
        name="goals", toolset="alice_goals", schema=module.SCHEMA,
        handler=lambda args, **_: _agent_json(module.run_tool(_goals_store(), args or {}, measured=_measured)),
        check_fn=_always, description=module.SCHEMA["description"], emoji="🎯",
    )


def register(ctx) -> None:
    _module("fallback_notices.py", "alice_fallback_notices").install(_errands())
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    # The shared browser the iPhone can watch is started before an agent needs it.
    ctx.register_hook("pre_tool_call", _browser_ready)
    # And each errand browses in its own context of it, never another errand's basket.
    ctx.register_hook("pre_tool_call", _isolate_errand_browser)
    ctx.register_hook("pre_tool_call", _guard_errand_access)
    # Checkouts expire, forgotten pages close and restarted errands go on without anyone looking.
    try:
        _errands().start_sweeper(_hermes_root())
    except Exception:
        logging.getLogger(__name__).warning("errands: the sweeper could not start", exc_info=True)
    # After reading the web, sending data out or reading secrets needs the person (egress_guard.py).
    ctx.register_hook("pre_tool_call", _guard_egress)
    # A card is filled with the copy for the page open, or bound to the bank's payment page.
    # One payment per order, kept by the plugin rather than the model (purchases.py).
    # Nothing is paid without the person's approved checkout (errands.py).
    ctx.register_hook("pre_tool_call", _guard_errand)
    # A chat turn that asks for an errand starts it, and neither browses nor asks itself.
    ctx.register_hook("pre_llm_call", _errand_turn)
    ctx.register_hook("pre_tool_call", _guard_chat_errand)
    ctx.register_hook("pre_tool_call", _guard_repeat_payment)
    ctx.register_hook("pre_tool_call", _route_card_fill)
    # A payment error on the page reaches the agent, and through it the person (purchases.py).
    # In a feed run, every source research surfaces gets a citable id (feed.py).
    # Every result rewrite of this plugin, chained in one hook: Hermes keeps only the first string a
    # transform_tool_result hook returns, so two separate ones silently dropped each other's note.
    ctx.register_hook("transform_tool_result", _transform_tool_result)
    ctx.register_hook("pre_tool_call", _guard_feed_publish)
    # What each agent did with consequences, for Alice's Activity.
    ctx.register_hook("post_tool_call", _post_tool_call)
    # In iMessage and SMS the reply is made readable as a text message (text_channel.py).
    ctx.register_hook("transform_llm_output", _plain_text_reply)
    # What the person said about themselves and no agent kept, read once a conversation pauses.
    ctx.register_hook("on_session_end", _schedule_memory_review)
    # And what Hermes learned from it is kept, once reviewed (skill_keeper.py).
    ctx.register_hook("on_session_end", _keep_reviewed_skills)
    # Frozen into each new session prompt; a SOUL change refreshes Bot Chats.
    ctx.register_system_prompt_section("alice.equipos", team_prompt)
    ctx.register_system_prompt_section("alice.debug", debug_prompt)
    ctx.register_system_prompt_section("alice.resolver", resolve_prompt)
    ctx.register_system_prompt_section("alice.canal", channel_prompt)
    ctx.register_system_prompt_section("alice.claves", secret_prompt)
    ctx.register_system_prompt_section("alice.recados", errands_prompt)
    ctx.register_system_prompt_section("alice.dudas", doubts_prompt)
    ctx.register_system_prompt_section("alice.tarjetas", cards_prompt)
    ctx.register_system_prompt_section("alice.compras", purchases_prompt)
    ctx.register_system_prompt_section("alice.preguntas", ask_prompt)
    # Answers to ask_person close their questions and release a goal parked on them.
    ctx.register_hook("post_llm_call", _absorb_answers)
    # A goal left open on a chat by the old errand loop is paused, once (errands replace it).
    _pause_chat_goals()
    # And a goal whose agent only repeats itself is paused, not replayed to the person.
    ctx.register_hook("post_llm_call", _repeat_guard)
    ctx.register_system_prompt_section("alice.objetivos", goals_prompt)
    _register_goal_tools(ctx)
    _register_feed_tools(ctx)
    # A task of several steps is kept going by Hermes' goal judge until done or it needs the person.
    _register_task_tools(ctx)
    _register_purchase_browser(ctx)
    _register_ask_tools(ctx)
    # How a card payment ended, so the same order is never paid twice (purchases.py).
    _register_purchase_tools(ctx)
    # When the person arrives at or leaves a place, their iPhone wakes the agent (places.py).
    _register_place_tools(ctx)
    # Sleep, activity, heart rate and HRV from the iPhone's Health app (health.py).
    _register_health_tools(ctx)
    _register_notes_tools(ctx)
    # Search and page reading free first (Exa, Jina); Firecrawl only as fallback.
    _free_web().register(ctx)
    _register_agent_tools(ctx)
    _register_debug_tools(ctx)
    _register_calendar_tools(ctx)
    _register_work_tools(ctx)


def _register_purchase_browser(ctx):
    from types import SimpleNamespace
    _module("purchase_browser.py", "alice_purchase_browser").register(ctx, SimpleNamespace(**globals()))
