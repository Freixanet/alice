"""Phone-mediated credentials for API errands. Only request metadata is persisted."""
from __future__ import annotations

import importlib.util
import json
import secrets
import sys
from pathlib import Path
from urllib.parse import urlsplit


def module(name):
    key = 'alice_' + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, Path(__file__).with_name(name + '.py'))
        value = importlib.util.module_from_spec(spec)
        sys.modules[key] = value
        spec.loader.exec_module(value)
    return sys.modules[key]


def origin(url):
    p = urlsplit(str(url))
    if p.scheme != 'https' or not p.hostname or p.username or p.password:
        raise ValueError('Abre primero una página HTTPS de acceso de la tienda.')
    return f'https://{p.netloc.lower()}'


def target(entry):
    """Use only this errand's pinned target, never the shared browser's busiest tab."""
    errands = module('errands')
    state = json.loads(errands.context_file(entry['id']).read_text())
    import urllib.request
    from hermes_constants import get_hermes_home
    profile_home = Path(get_hermes_home())
    root = profile_home.parent.parent if profile_home.parent.name == 'profiles' else profile_home
    endpoint = module('browser_live').configured_url(root)
    state['cdp'] = endpoint
    with urllib.request.urlopen(endpoint.rstrip('/') + '/json/version', timeout=3) as response:
        ws = json.load(response)['webSocketDebuggerUrl']
    from websockets.sync.client import connect
    def command(method, params=None):
        with connect(ws, open_timeout=3) as sock:
            sock.send(json.dumps({'id': 1, 'method': method, 'params': params or {}}))
            while True:
                reply = json.loads(sock.recv(timeout=5))
                if reply.get('id') == 1:
                    if reply.get('error'):
                        raise ValueError('No se pudo verificar la página del recado.')
                    return reply.get('result') or {}
    info = command('Target.getTargetInfo', {'targetId': state['target']})['targetInfo']
    if info.get('browserContextId') != state['context']:
        raise ValueError('La página no pertenece a este recado.')
    state['url'] = info['url']
    return origin(info['url']), state, command


def page_evaluate(context, expression):
    import urllib.request
    from websockets.sync.client import connect
    with urllib.request.urlopen(context.get('cdp', 'http://127.0.0.1:9222').rstrip('/') + '/json', timeout=3) as response:
        pages = json.load(response)
    page = next(p for p in pages if p['id'] == context['target'])
    with connect(page['webSocketDebuggerUrl'], open_timeout=3) as sock:
        sock.send(json.dumps({'id': 1, 'method': 'Runtime.evaluate', 'params': {
            'expression': expression, 'returnByValue': True, 'awaitPromise':True}}))
        while True:
            result = json.loads(sock.recv(timeout=5))
            if result.get('id') == 1:
                if result.get('error') or result.get('result', {}).get('exceptionDetails'):
                    raise ValueError('No se pudo rellenar el formulario seguro.')
                return result['result']['result'].get('value')


def fill_login(home, errand_id, handle, *, inspect=target, evaluate=page_evaluate, backend=None):
    entry = module('errands').get(home, errand_id)
    if not entry or entry['status'] in ('done','denied','stopped'):
        raise ValueError('El recado ya no está activo.')
    page_origin, context, _ = inspect(entry)
    if entry.get('ask_before_login') and backend is None:
        from tools.approval_prompt import request_elicitation_consent
        if request_elicitation_consent('Iniciar sesión en '+page_origin,'Usar el acceso guardado de esta tienda.',surface='vault-login',title='¿Iniciar sesión?') != 'accept':
            raise ValueError('La persona no autorizó iniciar sesión.')
    if backend is None:
        from agent.vault_backends import backend_for_handle
        backend = backend_for_handle(handle)
    meta = backend.get_meta(handle) if backend else None
    if not meta or meta.kind != 'login' or origin(meta.origin) != page_origin:
        raise ValueError('El acceso no pertenece al origen exacto de este recado.')
    from agent.vault_login_classifier import LoginControl, classify_login_control, select_password_fill, build_inspection_js, build_fill_js
    nonce = secrets.token_hex(8)
    raw = evaluate(context, build_inspection_js(nonce))
    if isinstance(raw, str):
        raw = json.loads(raw)
    controls = [classify_login_control(LoginControl.from_dict(r)) for r in (raw or []) if isinstance(r,dict)]
    controls = [c for c in controls if c]
    password = backend.resolve_password(handle)
    from agent.redact import register_vault_redaction_value
    register_vault_redaction_value(password)
    fills = select_password_fill(controls, password)
    if entry.get('account_action') == 'create':
        new_passwords = [LoginControl.from_dict(r) for r in (raw or []) if isinstance(r,dict) and r.get('type') == 'password' and 'new-password' in str(r.get('autocomplete',''))]
        if new_passwords:
            fills = [{'index':c.index, 'token':'new-password','value':password} for c in new_passwords]
    identifiers = [c for c in controls if c.token in ('email','username')]
    if entry.get('account_action') == 'create' and not fills:
        password = ''
        raise ValueError('La persona eligió crear cuenta: abre el formulario de registro de la tienda («Crear cuenta», '
                         '«Regístrate») hasta ver su campo de contraseña nueva y vuelve a llamar login_fill.')
    if not fills and not (identifiers and meta.identifier):
        password = ''
        raise ValueError('No hay un campo de acceso visible. Abre el formulario de iniciar sesión de la tienda y vuelve a llamar login_fill.')
    # Two-step logins (Prozis, Google, Amazon) show the email first and the password after it.
    first_step = not fills
    if identifiers and meta.identifier:
        c = sorted(identifiers, key=lambda c:-c.score)[0]
        fills.append({'index':c.control.index, 'token':c.token, 'value':meta.identifier})
    result = evaluate(context, build_fill_js(fills, page_origin, nonce))
    fills.clear()
    password = ''
    if isinstance(result,str):
        result = json.loads(result)
    if not isinstance(result,dict) or not result.get('filled'):
        raise ValueError('La página cambió durante el acceso seguro.')
    if first_step:
        return {'ok':True, 'origin':page_origin, 'filled':int(result['filled']), 'step':'identifier',
                'next':'Solo se ha rellenado el email: la tienda pide la contraseña en un segundo paso. Pulsa su botón de continuar (o «iniciar sesión con contraseña») y vuelve a llamar login_fill con el mismo acceso.'}
    return {'ok':True, 'origin':page_origin, 'filled':int(result['filled']),
            'next':'Solo se han rellenado los campos: todavía no has iniciado sesión. Envía el formulario de acceso, comprueba el resultado y solicita el código seguro si la tienda lo pide.'}


def request(home, errand_id, kind='vault.save_login', *, inspect=target):
    with module('purchase_flow')._locked(home):
        return _request(home,errand_id,kind,inspect=inspect)


def _request(home, errand_id, kind='vault.save_login', *, inspect=target):
    errands = module('errands')
    entry = errands.get(home, errand_id)
    if not entry or entry['status'] not in ('working', 'needs_login'):
        raise ValueError('El recado no está preparando el pedido.')
    page_origin, context, _ = inspect(entry)
    offer_url = (entry.get('offer') or {}).get('url')
    if offer_url and origin(offer_url) != page_origin and not (kind == 'vault.code' and (entry.get('purchase') or {}).get('attempt_id') and module('errands').shop(page_origin) in module('vault_cards').PAYMENT_GATEWAYS):
        raise ValueError('La página no pertenece a la tienda elegida.')
    if kind not in ('vault.save_login', 'vault.code'):
        raise ValueError('Solicitud de acceso desconocida.')
    saved = entry.get('saved_login') or {}
    if kind == 'vault.save_login' and saved.get('origin') == page_origin:
        raise ValueError(f"La persona ya dio el acceso de esta tienda ({saved['handle']}); no se lo pidas otra vez. "
                         "Usa login_fill con ese acceso: abre antes el formulario de iniciar sesión, o el de crear "
                         "cuenta si eligió crearla, y si la tienda pide la contraseña en un segundo paso, vuelve a llamarlo.")
    old = entry.get('secure_request') or {}
    if (old.get('origin') == page_origin and old.get('kind') == kind and entry['status'] == 'needs_login'
            and old.get('context') == context['context'] and old.get('target') == context['target']):
        return old
    value = {'request_id': 'srq-' + secrets.token_hex(12), 'kind': kind,
             'origin': page_origin, 'site': urlsplit(page_origin).hostname,
             'errand_id': errand_id, 'profile': entry.get('profile') or 'default',
             'context': context['context'], 'target': context['target']}
    errands.update(home, errand_id, status='needs_login', secure_request=value,
                   reason='', blocked=None)
    return value


def answer(home, errand_id, request_id, value, *, account_action='login', inspect=target,
           save=None, fill_code=None, resume=None):
    errands = module('errands')
    # The same file lock covers consumption, vault write and the resume decision.
    with module('purchase_flow')._locked(home):
        entry = errands.get(home, errand_id)
        pending = (entry or {}).get('secure_request') or {}
        if (entry or {}).get('secure_answered') == request_id:
            return entry
        if not entry or entry['status'] != 'needs_login' or pending.get('request_id') != request_id:
            raise ValueError('La solicitud ya no está pendiente.')
        if not value:
            return errands.update(home, errand_id, status='stopped', secure_request=None,
                                  secure_answered=request_id, reason='Has pospuesto el acceso a la tienda.')
        page_origin, context, command = inspect(entry)
        if page_origin != pending['origin'] or context['context'] != pending['context'] or context['target'] != pending['target']:
            raise ValueError('La página de acceso ha cambiado. Vuelve a solicitar el acceso.')
        if pending['kind'] == 'vault.save_login':
            if account_action not in ('login', 'create'):
                raise ValueError('Elige iniciar sesión o crear una cuenta.')
            data = json.loads(value)
            identifier, password = str(data.get('identifier') or '').strip(), str(data.get('password') or '')
            if not identifier or not password:
                raise ValueError('Faltan los datos de acceso.')
            from agent.redact import register_vault_redaction_value
            register_vault_redaction_value(password)
            register_vault_redaction_value(identifier)
            if save is None:
                from agent.vault_store import VaultStore
                profile = pending['profile']
                if profile != 'default' and (not profile or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in profile)):
                    raise ValueError('Perfil de acceso inválido.')
                base = Path(home) if profile == 'default' else Path(home) / 'profiles' / profile
                save = lambda payload, site: VaultStore(base / 'vault').add_item('login', pending['site'], payload, origin=site)
            meta = save({'identifier_type': 'email' if '@' in identifier else 'username',
                         'identifier': identifier, 'password': password}, page_origin)
            handle = meta if isinstance(meta, str) else meta.id
            saved_login = {'handle': handle, 'origin': page_origin}
            message = f'[acceso listo] La persona eligió {account_action}. Usa login_fill con el acceso {handle} de esta tienda. No uses accesos de otros sitios.'
            data.clear()
            password = ''
        else:
            account_action = entry.get('account_action') or 'login'
            from agent.redact import register_vault_redaction_value
            register_vault_redaction_value(value)
            if fill_code is None:
                from agent.vault_login_classifier import LoginControl, build_inspection_js, classify_otp_controls, build_otp_fills, build_fill_js
                evaluate = lambda expression: page_evaluate(context, expression)
                nonce = secrets.token_hex(8)
                raw = evaluate(build_inspection_js(nonce))
                if isinstance(raw, str):
                    raw = json.loads(raw)
                controls = classify_otp_controls([LoginControl.from_dict(r) for r in (raw or []) if isinstance(r, dict)])
                fills = build_otp_fills(controls, value)
                if not fills:
                    raise ValueError('La página no tiene un campo de código verificable.')
                filled = evaluate(build_fill_js(fills, page_origin, nonce))
                fills.clear()
                if isinstance(filled, str):
                    filled = json.loads(filled)
                if not isinstance(filled, dict) or not filled.get('filled'):
                    raise ValueError('La página cambió durante la introducción del código.')
            else:
                fill_code(entry, value)
            message = '[código listo] El código se ha introducido directamente en esta página. Envía el formulario de verificación y comprueba que la tienda haya iniciado la sesión. No pidas ni repitas el código.'
        result = errands.update(home, errand_id, secure_request=None, secure_answered=request_id,
                                account_action=account_action, status='working', resume_message=message, cart_evidence=None,
                                **({'saved_login': saved_login} if pending['kind'] == 'vault.save_login' else {}))
    (resume or errands.resume)(home, errand_id, message)
    return result


def detect_pending(home, errand_id, *, inspect=target, evaluate=page_evaluate):
    """Convert an empty visible login/OTP form into a phone action after an agent turn.

    This keeps a model's prose-only login request from stranding an API errand.
    Inspection returns descriptors and booleans, never field contents.
    """
    entry = module('errands').get(home,errand_id)
    if not entry or entry['status'] != 'working':
        return None
    page_origin, context, _ = inspect(entry)
    if (entry.get('offer') or {}).get('url') and origin(entry['offer']['url']) != page_origin and not ((entry.get('purchase') or {}).get('attempt_id') and module('errands').shop(page_origin) in module('vault_cards').PAYMENT_GATEWAYS):
        return None
    from agent.vault_login_classifier import LoginControl, build_inspection_js, classify_login_control, classify_otp_controls
    nonce = secrets.token_hex(8)
    raw = evaluate(context,build_inspection_js(nonce))
    if isinstance(raw,str):raw=json.loads(raw)
    controls = [LoginControl.from_dict(r) for r in (raw or []) if isinstance(r,dict)]
    otp = classify_otp_controls(controls)
    passwords = [c for c in controls if (classified := classify_login_control(c)) and classified.token == 'current-password']
    chosen = [c.control for c in otp] if otp else passwords
    if not chosen:return None
    slots = [nonce + ':' + str(c.index) for c in chosen]
    empty = evaluate(context,'Array.from(document.querySelectorAll("input, select")).some(e=>' + json.dumps(slots) + '.includes(e.getAttribute("data-hermes-vault-slot")) && !e.value)')
    if not empty:return None
    return request(home,errand_id,'vault.code' if otp else 'vault.save_login',inspect=inspect)


def protect_browser_secrets(entry, *, inspect=target, evaluate=page_evaluate):
    """Restore process-local redaction after the dashboard filled an OTP.

    Values travel only from this pinned page to Hermes' in-memory redactor;
    neither metadata nor tool results receive them. Also mask OTP screenshots.
    """
    page_origin, context, _ = inspect(entry)
    if origin(entry['offer']['url']) != page_origin and not ((entry.get('purchase') or {}).get('attempt_id') and module('errands').shop(page_origin) in module('vault_cards').PAYMENT_GATEWAYS):
        return None
    from agent.vault_login_classifier import LoginControl, build_inspection_js, classify_otp_controls
    from agent.redact import register_vault_redaction_value
    nonce = secrets.token_hex(8)
    raw = evaluate(context, build_inspection_js(nonce))
    if isinstance(raw, str):
        raw = json.loads(raw)
    controls = [LoginControl.from_dict(r) for r in (raw or []) if isinstance(r, dict)]
    otp = classify_otp_controls(controls)
    otp_slots = [nonce + ':' + str(c.control.index) for c in otp]
    values = evaluate(context, "(()=>{const inputs=Array.from(document.querySelectorAll('input, select'));"
                      "const otp=inputs.filter(e=>" + json.dumps(otp_slots) +
                      ".includes(e.getAttribute('data-hermes-vault-slot')));"
                      "otp.forEach(e=>e.style.setProperty('-webkit-text-security','disc','important'));"
                      "return {passwords:inputs.filter(e=>e.type==='password').map(e=>String(e.value||'')),"
                      "otp:otp.map(e=>String(e.value||''))}})()")
    if not isinstance(values, dict) or any(not isinstance(values.get(k), list) or
            any(not isinstance(v, str) for v in values[k]) for k in ('passwords','otp')):
        raise ValueError('No se pudo proteger el formulario seguro.')
    for value in values['passwords']:
        register_vault_redaction_value(value)
    digits = values['otp']
    if digits and all(digits):
        # A split OTP is one secret, not six one-character passwords: masking
        # each digit would erase unrelated amounts and browser control indices.
        for representation in (''.join(digits), ' '.join(digits), '-'.join(digits),
                               str(digits), str(tuple(digits)), json.dumps(digits),
                               json.dumps(digits,separators=(',',':'))):
            register_vault_redaction_value(representation)
    values.clear()
    return None


def public(value):
    return {k: v for k, v in value.items() if k not in ('context', 'target')}
