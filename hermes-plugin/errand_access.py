"""Phone-mediated credentials for API errands. Only request metadata is persisted."""
from __future__ import annotations

import importlib.util
import json
import re
import secrets
import time
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
    import urllib.request
    root = errands._default_home()
    path = errands.context_file(entry['id'], root)
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        raise ValueError('El recado todavía no tiene su página abierta en el navegador.') from None
    endpoint = errands._cdp_root(root)
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
    with urllib.request.urlopen((context.get('cdp') or module('errands')._cdp_root(None)).rstrip('/') + '/json', timeout=3) as response:
        pages = json.load(response)
    page = next(p for p in pages if p['id'] == context['target'])
    with connect(page['webSocketDebuggerUrl'], open_timeout=3) as sock:
        sock.send(json.dumps({'id': 1, 'method': 'Runtime.evaluate', 'params': {
            'expression': expression, 'returnByValue': True}}))
        while True:
            result = json.loads(sock.recv(timeout=5))
            if result.get('id') == 1:
                if result.get('error') or result.get('result', {}).get('exceptionDetails'):
                    raise ValueError('No se pudo rellenar el formulario seguro.')
                return result['result']['result'].get('value')


# The second step of a two-step sign-in: the form holding the filled email is sent on («Continuar»),
# so its password field appears. No secret is read or returned; only the button is pressed.
NEXT_STEP_JS = r"""(()=>{const seen=e=>e&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
const words=/^(continuar|siguiente|continue|next|seguir|acceder|iniciar sesi[oó]n|entrar|sign in|log in)$/i;
const filled=Array.from(document.querySelectorAll('input[type=email],input[autocomplete=username],input[autocomplete=email],input[name*=mail i],input[type=text]')).filter(e=>seen(e)&&e.value);
for(const field of filled){const form=field.closest('form');const scope=form||field.parentElement?.parentElement?.parentElement||document;
if(scope.querySelector&&Array.from(scope.querySelectorAll('input[type=password]')).some(seen))continue;
const buttons=Array.from(scope.querySelectorAll('button,input[type=submit],[role=button]')).filter(seen);
const b=buttons.find(b=>b.type==='submit'&&!/google|apple|facebook/i.test(b.innerText||''))||buttons.find(b=>words.test(String(b.innerText||b.value||'').trim()));
if(b){b.click();return 'pressed';}
if(form&&form.requestSubmit){form.requestSubmit();return 'submitted';}}
return '';})()"""


def fill_login(home, errand_id, handle, *, inspect=target, evaluate=page_evaluate, backend=None,
               sleep=time.sleep, second=False):
    entry = module('errands').get(home, errand_id)
    selected = (entry or {}).get('saved_login') or {}
    if selected.get('handle') and handle != selected['handle']:
        raise ValueError('Usa el acceso elegido en la tarjeta de este recado, no otro acceso guardado.')
    page_origin, context, _ = inspect(entry)
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
    # Filling is not authentication. Pin the used account and retain an attempt so a
    # still-visible rejected login can lead to secure correction, not a generic stop.
    module('errands').update(home, errand_id,
        saved_login={'handle': handle, 'origin': page_origin},
        account_action=entry.get('account_action') or 'login',
        login_attempt={'origin': page_origin, 'stage': 'identifier' if first_step else 'credentials'})
    if first_step and not second:
        # Sent on here, then the password filled in the same call: the agent filled the email three
        # times on Prozis and never pressed «Continuar» (06-10).
        try:
            moved = evaluate(context, NEXT_STEP_JS)
        except Exception:  # noqa: BLE001
            moved = ''
        if moved:
            sleep(2.5)
            try:
                return fill_login(home, errand_id, handle, inspect=inspect, evaluate=evaluate, backend=backend,
                                  sleep=sleep, second=True)
            except ValueError:
                pass  # no password field yet: say what is left to do, below
    if first_step:
        return {'ok':True, 'origin':page_origin, 'filled':int(result['filled']), 'step':'identifier',
                'next':'Solo se ha rellenado el email: la tienda pide la contraseña en un segundo paso. Pulsa su botón de continuar (o «iniciar sesión con contraseña») y vuelve a llamar login_fill con el mismo acceso.'}
    return {'ok':True, 'origin':page_origin, 'filled':int(result['filled']),
            'next':'Solo se han rellenado los campos: todavía no has iniciado sesión. Envía el formulario de acceso, comprueba el resultado y solicita el código seguro si la tienda lo pide.'}


def guard_account_input(entry, tool_name, args, *, inspect=target, evaluate=page_evaluate, backend=None):
    """The selected vault identity owns account fields, never the shipping brief/model.
    No identifier or secret enters tool results. A submit with a mismatching identity is blocked.
    """
    saved = entry.get('saved_login') or {}
    if entry.get('account_action') != 'create' or not saved.get('handle'):
        return None
    message = 'La cuenta usa el acceso elegido en la tarjeta segura. Usa login_fill con su handle; el email de envío no sustituye al de la cuenta.'
    if tool_name in ('browser_type','browser_exec') and re.search(r'[\w.+-]+@[\w.-]+',json.dumps(args or {})):
        return {'action':'block','message':message}
    if tool_name not in ('browser_click','browser_press','browser_exec'):
        return None
    page_origin,context,_ = inspect(entry)
    if page_origin != origin(saved.get('origin','')):
        return None  # Cross-origin secrets are rejected by login_fill and the existing origin guard.
    if backend is None:
        from agent.vault_backends import backend_for_handle
        backend = backend_for_handle(saved['handle'])
    meta = backend.get_meta(saved['handle']) if backend else None
    if not meta or meta.kind != 'login' or origin(meta.origin) != page_origin:
        return {'action':'block','message':'No se pudo comprobar el acceso elegido. Vuelve a usar la tarjeta segura.'}
    from agent.vault_login_classifier import LoginControl, classify_login_control, build_inspection_js
    nonce = secrets.token_hex(8)
    raw = evaluate(context, build_inspection_js(nonce))
    if isinstance(raw,str): raw = json.loads(raw)
    if not isinstance(raw,list):
        return {'action':'block','message':'No se pudo comprobar el formulario de cuenta. Usa login_fill.'}
    # Use exactly the same classifier and ranking as login_fill, including forms without <form>.
    if not any(r.get('type') == 'password' for r in raw if isinstance(r,dict)):
        return None
    controls = [classify_login_control(LoginControl.from_dict(r)) for r in raw if isinstance(r,dict)]
    identifiers = [c for c in controls if c and c.token in ('email','username')]
    if not identifiers:
        return None
    c = sorted(identifiers,key=lambda c:-c.score)[0]
    slot = nonce + ':' + str(c.control.index)
    correct = evaluate(context, """(()=>{if(location.origin!==%s)return false;
const e=Array.from(document.querySelectorAll('input,select')).find(e=>e.getAttribute('data-hermes-vault-slot')===%s);
return !!e&&String(e.value||'').trim()===%s})()""" % (json.dumps(page_origin),json.dumps(slot),json.dumps(meta.identifier or '')))
    if correct is not True:
        return {'action':'block','message':message}
    return None


# The logins the vault already holds for an origin: [{'handle', 'origin'}]. Set by the plugin.
vault_logins = lambda origin: []


def parse_code_delivery(blocks):
    """Delivery statements only, never typed OTPs, footer contacts or guessed recipients."""
    observations = set()
    for text in blocks if isinstance(blocks,list) else []:
        if not isinstance(text,str) or len(text)>500: continue
        if not re.search(r'c[oó]digo|\bcode\b|\botp\b|verifica',text,re.I): continue
        if not re.search(r'enviad|enviamos|\bsent\b|hemos mandado|receb|recibid|check your|comprueba|authenticator|autenticador',text,re.I): continue
        channels=[]
        if re.search(r'correo|e-?mail|e-mail|courriel',text,re.I): channels.append('email')
        if re.search(r'\bsms\b|text message|mensaje de texto',text,re.I): channels.append('sms')
        if re.search(r'whatsapp',text,re.I): channels.append('whatsapp')
        if re.search(r'authenticator|autenticador|aplicaci[oó]n de autenticaci[oó]n',text,re.I): channels.append('authenticator')
        if len(channels)!=1: continue
        channel=channels[0];destinations=set()
        if channel=='email':
            destinations={m.rstrip('.,;:') for m in re.findall(r'[\w.+*•…-]+@[\w*•….-]+\.[A-Za-z*•]{2,}',text)}
        elif channel in ('sms','whatsapp'):
            for m in re.finditer(r'(?:\bto\b|\bal\b|\ba\b|n[uú]mero|number|phone|tel[eé]fono)\s*:?\s*([+\d*•xX][\d*•xX .()-]{3,30})',text,re.I):
                phone=m.group(1).strip(' .()-')
                if len(re.sub(r'\D','',phone))>=8 or (re.search(r'[*•xX]',phone) and len(re.sub(r'\D','',phone))>=2): destinations.add(phone)
            suffix=re.search(r'(?:termina(?:do)? en|ending (?:in|with))\s*([\d*•]{2,6})',text,re.I)
            if suffix: destinations.add('•••• '+suffix.group(1))
        if len(destinations)>1:continue
        observations.add((channel,next(iter(destinations),'')))
    # A long container without the address plus its child with it are the same statement.
    channels={c for c,d in observations};destinations={d for c,d in observations if d}
    if len(channels)!=1 or len(destinations)>1:return {}
    return {'delivery_channel':next(iter(channels)), 'delivery_destination':next(iter(destinations),'')}


def code_delivery(entry, context, *, evaluate=page_evaluate, backend=None):
    result={}
    try:
        blocks=evaluate(context,r"""(()=>{const out=[];
for(const e of document.querySelectorAll('p,label,[role=alert],[role=status],h1,h2,h3,div,span')){
 if(e.closest('header,footer,nav,script,style,[hidden]')||!e.getClientRects().length||getComputedStyle(e).visibility==='hidden')continue;
 const t=(e.innerText||'').trim();if(t.length>0&&t.length<=500&&/c[oó]digo|\bcode\b|\botp\b|verifica/i.test(t)&&!out.includes(t))out.push(t);
}return out.slice(0,30)})()""")
        result=parse_code_delivery(blocks)
    except Exception:
        pass
    # If the shop hides its delivery destination, the chosen account is still useful context.
    # It is explicitly labelled as the account, never asserted to be the code's destination.
    saved=entry.get('saved_login') or {}
    if saved.get('handle'):
        try:
            if backend is None:
                from agent.vault_backends import backend_for_handle
                backend=backend_for_handle(saved['handle'])
            meta=backend.get_meta(saved['handle']) if backend else None
            if meta and meta.kind=='login' and origin(meta.origin)==origin(saved.get('origin','')) and meta.identifier:
                result['account_hint']=str(meta.identifier)[:160]
        except Exception:
            pass
    return result


def guest_available(entry, context, *, evaluate=None):
    # Unknown is not an available checkout; retain failed guest attempts across retries.
    if entry.get('guest_failed'):
        return False
    try:
        return (evaluate or page_evaluate)(context, GUEST_JS) is True
    except Exception:
        return False



ACCESS_REUSE_REASON = ('Ya has proporcionado el acceso de esta tienda. Alice no ha podido confirmar que la sesión '
                       'se haya iniciado; eso no significa que tus datos sean incorrectos. Abre el navegador para '
                       'ver qué pide la tienda y continúa desde esta misma cesta. No necesitas volver a crear una cuenta.')

# Return categories only: page text can contain addresses, identifiers or secrets.
LOGIN_RESULT_JS = r"""(()=>{const visible=e=>e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
const passwords=[...document.querySelectorAll('input[type=password]')].filter(visible);
const scopes=new Set();for(const p of passwords){for(let e=p.parentElement;e&&e!==document.body;e=e.parentElement){
if(e.tagName==='FORM'||e.getAttribute('role')==='dialog'||/login|sign.?in|auth/i.test(e.className+' '+e.id))scopes.add(e);}}
const errors=[...scopes].flatMap(s=>[...s.querySelectorAll('[role=alert],[aria-live],[class*=error],[class*=invalid]')]).filter(visible);
const rejected=/error de autenticaci[oó]n|authentication (?:error|failed)|invalid (?:credentials|password|email)|incorrect (?:password|email)|contrase[ñn]a incorrecta|credenciales (?:incorrectas|inv[aá]lidas)/i;
if(passwords.length&&errors.some(e=>rejected.test(e.innerText||e.textContent||'')))return {state:'authentication_rejected'};
return {state:passwords.length?'login_form':'unknown'};})()"""


def login_result(context, *, evaluate=page_evaluate):
    try:
        value = evaluate(context, LOGIN_RESULT_JS)
        if isinstance(value, str): value = json.loads(value)
        state = value.get('state') if isinstance(value, dict) else None
        return state if state in ('authentication_rejected', 'login_form') else 'unknown'
    except Exception:  # An unreadable page never proves incorrect credentials.
        return 'unknown'


ACCESS_REJECTED_REASON = ('La tienda ha rechazado el inicio de sesión y muestra un error de autenticación. '
                          'Corrige el acceso en la tarjeta segura o resuélvelo en el navegador de esta misma cesta. '
                          'No se ha creado otra cuenta.')


def login_was_provided(entry):
    # Older errands persisted the answered request and chosen login, without this explicit flag.
    return bool(entry.get('user_login_provided') or
                (entry.get('secure_answered') and (entry.get('saved_login') or {}).get('handle')))


class AccessAlreadyProvided(ValueError):
    access_already_provided = True


CODE_FIELD = r"""(()=>{const seen=e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
for(const e of document.querySelectorAll('input')){
 if(!seen(e)||e.disabled||['hidden','password','email','search','checkbox','radio','submit'].includes(e.type))continue;
 const words=[e.autocomplete,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),
  ...(e.labels?[...e.labels].map(l=>l.innerText):[])].join(' ');
 if(e.autocomplete==='one-time-code'||/otp|one.?time|verif|c[oó]digo|\bcode\b|pin|token|2fa|mfa/i.test(words))return true;
 if(e.maxLength===1&&/numeric|tel|number/.test(e.inputMode+' '+e.type))return true;
}return false})()"""


def code_asked(context, *, evaluate=page_evaluate):
    """Whether the page shows a field to type a verification code in. Unknown counts as asked: a
    page that cannot be read must not keep a real code wall from the person."""
    try:
        return bool(evaluate(context, CODE_FIELD))
    except Exception:  # noqa: BLE001
        return True


def request(home, errand_id, kind='vault.save_login', *, inspect=target, replace=False, evaluate=page_evaluate):
    with module('purchase_flow')._locked(home):
        return _request(home,errand_id,kind,inspect=inspect,replace=replace,evaluate=evaluate)


def _request(home, errand_id, kind='vault.save_login', *, inspect=target, replace=False, evaluate=page_evaluate):
    errands = module('errands')
    entry = errands.get(home, errand_id)
    if not entry or entry['status'] not in ('working', 'needs_login'):
        raise ValueError('El recado no está preparando el pedido.')
    page_origin, context, _ = inspect(entry)
    offer_url = (entry.get('offer') or {}).get('url')
    if offer_url and origin(offer_url) != page_origin:
        raise ValueError('La página no pertenece a la tienda elegida.')
    if kind not in ('vault.save_login', 'vault.code'):
        raise ValueError('Solicitud de acceso desconocida.')
    if kind == 'vault.code' and not code_asked(context, evaluate=evaluate):
        # 06-10: a code was asked of the person on a page with no code field at all (the login
        # form had not been opened), with no reason and nowhere it was sent.
        raise ValueError('La página no pide ningún código: no hay un campo para escribirlo. No se lo pidas a la '
                         'persona. Abre el formulario de iniciar sesión y usa login_fill con el acceso guardado; '
                         'pide un código solo cuando la tienda muestre su campo.')
    old = entry.get('secure_request') or {}
    if (entry['status'] == 'needs_login' and old.get('kind') == kind and
            old.get('origin') == page_origin and old.get('context') == context['context'] and
            old.get('target') == context['target'] and old.get('access_error') == 'authentication_rejected'):
        return old
    correction = False
    if kind == 'vault.save_login' and login_was_provided(entry):
        # replace=true is a model argument, not fresh permission from the person. A login wall
        # alone proves neither rejected credentials nor a need to collect the same secrets again.
        state = login_result(context)
        if state == 'unknown':
            # No visible login form or verified rejection: a redundant model request must not
            # stop an already authenticated checkout (nor interpret an unreadable page as logout).
            raise ValueError('No hay un formulario de acceso ni un rechazo de autenticación comprobado. '
                             'No vuelvas a pedir el acceso ni detengas la compra por esta llamada. '
                             'Relee la página de esta misma cesta y continúa el checkout; si no se puede leer, '
                             'recupera el navegador antes de decidir qué necesita la tienda.')
        rejected = ((entry.get('login_attempt') or {}).get('stage') == 'credentials' and
                    state == 'authentication_rejected')
        correction = bool(replace and rejected and not entry.get('login_corrections'))
        if not correction:
            reason = ACCESS_REJECTED_REASON if rejected else ACCESS_REUSE_REASON
            errands.update(home, errand_id, status='stuck', secure_request=None,
                           reason=reason, blocked={'kind': 'access'})
            raise AccessAlreadyProvided(reason + ' El acceso ya fue proporcionado: no se lo pidas otra vez.')
    saved = entry.get('saved_login') or {}
    if kind == 'vault.save_login' and not saved and not replace:
        # The vault already has this shop's login (given in an earlier errand): it is used, not
        # asked again, and no account is created beside it. «replace» only after login_fill failed.
        try:
            existing = [l for l in vault_logins(page_origin) if origin(l.get('origin') or '') == page_origin]
        except Exception:  # noqa: BLE001
            existing = []
        if existing:
            handles = ', '.join(str(l.get('handle')) for l in existing)
            raise ValueError(f"La tienda ya tiene un acceso guardado ({handles}): inicia sesión con login_fill y ese "
                             "handle, y no crees una cuenta nueva. Solo si login_fill falla con ese acceso, vuelve a "
                             "llamar login_request con replace=true.")
    if kind == 'vault.save_login' and saved.get('origin') == page_origin and not replace:
        raise ValueError(f"La persona ya dio el acceso de esta tienda ({saved['handle']}); no se lo pidas otra vez. "
                         "Usa login_fill con ese acceso: abre antes el formulario de iniciar sesión, o el de crear "
                         "cuenta si eligió crearla, y si la tienda pide la contraseña en un segundo paso, vuelve a llamarlo.")
    old = entry.get('secure_request') or {}
    if (old.get('origin') == page_origin and old.get('kind') == kind and entry['status'] == 'needs_login'
            and old.get('context') == context['context'] and old.get('target') == context['target']):
        if kind == 'vault.code':
            for key in ('delivery_channel','delivery_destination','account_hint'): old.pop(key,None)
            old.update(code_delivery(entry,context))
            errands.update(home,errand_id,secure_request=old)
        if kind == 'vault.save_login':
            old['guest_available'] = guest_available(entry,context)
            errands.update(home,errand_id,secure_request=old)
        return old
    value = {'request_id': 'srq-' + secrets.token_hex(12), 'kind': kind,
             'origin': page_origin, 'site': urlsplit(page_origin).hostname,
             'errand_id': errand_id, 'profile': entry.get('profile') or 'default',
             'context': context['context'], 'target': context['target']}
    if kind == 'vault.save_login':
        value['guest_available'] = guest_available(entry,context)
        if correction:
            value['access_error'] = 'authentication_rejected'
    if kind == 'vault.code':
        value.update(code_delivery(entry,context))
    errands.update(home, errand_id, status='needs_login', secure_request=value,
                   reason=ACCESS_REJECTED_REASON if correction else '', blocked=None,
                   **({'login_corrections': 1} if correction else {}))
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
        if not value and pending['kind'] == 'vault.code':
            # A missing code does not revoke the person's chosen account or request guest checkout.
            message = ('[código no disponible] La persona no tiene el código. Conserva la cuenta elegida y la cesta. '
                       'Comprueba primero si la página pide realmente un código. Si ofrece acceso con contraseña, '
                       'úsalo con login_fill y el mismo acceso guardado; si falta el acceso, usa login_request. '
                       'Si sigue pidiendo un código, busca reenviarlo o elegir otro canal y lee el aviso de destino '
                       'antes de solicitarlo de nuevo. No crees otra cuenta ni sigas como invitado por esta respuesta. '
                       'Si no hay recuperación automática, pide una decisión concreta con ask_person; no termines '
                       'diciendo simplemente que la tienda exige iniciar sesión. No pagues sin aprobación.')
            result = errands.update(home, errand_id, status='working', secure_request=None,
                                    secure_answered=request_id, login_declined=False,
                                    code_unavailable=True, resume_message=message, reason='')
            declined = message
        elif not value:
            page_origin, context, _ = inspect(entry)
            if (page_origin != pending['origin'] or context['context'] != pending['context']
                    or not guest_available(entry, context)):
                pending['guest_available'] = False
                errands.update(home, errand_id, secure_request=pending)
                raise ValueError('La página no ofrece ahora una compra como invitado. Continúa con el acceso seguro.')
            # «Ahora no»: the person does not want to sign in here. The errand goes on as a guest if
            # the shop allows it; stopping the whole purchase for a login nobody wanted was worse.
            message = ('[sin acceso] La persona no quiere iniciar sesión ni crear cuenta en esta tienda. Sigue '
                       'como invitado si la tienda lo permite (busca «comprar sin cuenta», «invitado», «guest»). '
                       'Si la tienda exige cuenta, termina con «BLOQUEADO: la tienda exige iniciar sesión».')
            result = errands.update(home, errand_id, status='working', secure_request=None, secure_answered=request_id,
                                    login_declined=True, guest_attempted=True, resume_message=message, reason='')
            declined = message
        else:
            declined = None
            result = _answer_locked(home, errand_id, request_id, value, entry, pending, account_action, inspect, save, fill_code)
    (resume or errands.resume)(home, errand_id, declined or result['resume_message'])
    return result


def _answer_locked(home, errand_id, request_id, value, entry, pending, account_action, inspect, save, fill_code):
    errands = module('errands')
    page_origin, context, command = inspect(entry)
    # The same shop in the same browser context: the tab may have been reloaded or replaced
    # while the person typed (the agent did not end its turn at once), and that is no reason to
    # make them type it again.
    if page_origin != pending['origin'] or context['context'] != pending['context']:
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
        message = f'[acceso listo] La persona eligió {account_action}. Usa login_fill con el acceso {handle} de esta tienda. No uses accesos de otros sitios. El email de los datos de envío no es el identificador de esta cuenta: solo login_fill rellena el identificador elegido.'
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
                            **({'saved_login': saved_login, 'user_login_provided': True, 'login_attempt': None}
                               if pending['kind'] == 'vault.save_login' else {}))
    return result


# A way past the login without an account, on the page: the errand prefers it to asking.
GUEST_JS = r"""(()=>{const names=/^(?:(?:continuar|comprar|seguir|finalizar(?: compra)?) (?:como invitado|sin (?:crear )?cuenta|sin registrarse)|(?:continue|checkout|check out|buy|proceed)(?: to checkout)? (?:as (?:a )?guest|without (?:an )?account)|guest checkout|comprar como convidado|continuer en tant qu.invité|als gast (?:bestellen|fortfahren))$/i;
return Array.from(document.querySelectorAll('a,button,input[type=submit],input[type=button],[role=button]')).some(e=>{
if(e.disabled||e.getAttribute('aria-disabled')==='true'||e.closest('header,footer,nav,[hidden]')||!e.getClientRects().length)return false;
const style=getComputedStyle(e);if(style.display==='none'||style.visibility==='hidden')return false;
const text=(e.innerText||e.value||e.getAttribute('aria-label')||'').replace(/\s+/g,' ').trim();return names.test(text);})})()"""


def detect_pending(home, errand_id, *, inspect=target, evaluate=page_evaluate):
    """Convert an empty visible login/OTP form into a phone action after an agent turn.

    This keeps a model's prose-only login request from stranding an API errand.
    Inspection returns descriptors and booleans, never field contents. A password field next to
    a «continuar como invitado» is not a login the person must give; nor is one the person
    already declined for this errand.
    """
    entry = module('errands').get(home,errand_id)
    if not entry or entry['status'] != 'working':
        return None
    page_origin, context, _ = inspect(entry)
    if (entry.get('offer') or {}).get('url') and origin(entry['offer']['url']) != page_origin:
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
    if not otp and (entry.get('login_declined') or evaluate(context, GUEST_JS)):
        return None
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
    if origin(entry['offer']['url']) != page_origin:
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


def public(value, *, for_agent=False):
    hidden = {'context','target'} | ({'account_hint','delivery_destination'} if for_agent else set())
    return {k: v for k, v in value.items() if k not in hidden}
