"""Observe -> one action -> verify, adapted from Open Instinct's computer loop.

The browser context and approvals remain Alice's. Controls come from the actual
visible DOM; the model cannot supply JS, selectors, credentials or payment actions.
"""
from __future__ import annotations
import hashlib
import fcntl
import os
import json
import re
import time
from pathlib import Path

SNAPSHOT_JS = r'''(()=>{
const visible=e=>!!e.getClientRects().length && getComputedStyle(e).visibility!=='hidden';
const text=e=>String(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
const secret=e=>/password|contrase[nñ]a|one-time-code|cc-|card|tarjeta|cvc|cvv|otp|verification|security.?code|caducidad/i.test([e.type,e.autocomplete,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),text(e.labels?.[0]||e.closest('label')||{textContent:''})].join(' '));
const doc=document.documentElement;
if(!doc.dataset.alicePurchaseDocument)doc.dataset.alicePurchaseDocument=crypto.randomUUID();
const nodes=Array.from(document.querySelectorAll('button,a[href],input,select,textarea,[role=button],[role=radio],[role=checkbox]')).filter(visible).slice(0,180);
const controls=nodes.map(e=>{
if(!e.dataset.alicePurchaseControl)e.dataset.alicePurchaseControl=crypto.randomUUID();
const label=e.labels?.[0]||document.querySelector('label[for="'+CSS.escape(e.id||'')+'"]');
const name=String(e.getAttribute('aria-label')||text(label||e)||e.placeholder||e.name||e.id||'').slice(0,160);
const kind=e.tagName.toLowerCase(),type=e.type||e.getAttribute('role')||kind;
const numeric=/number|range/.test(type)||/quantity|cantidad|qty|unidades/i.test(e.name+' '+e.id);
// Track edits without returning or persisting a person's address/email/password.
if(!secret(e) && e.matches('input,select,textarea')){
const current=String(e.value||'');
if(e._alicePurchaseValue!==current){e._alicePurchaseValue=current;e.dataset.alicePurchaseEdit=String(Number(e.dataset.alicePurchaseEdit||0)+1);}
}
return {id:e.dataset.alicePurchaseControl,label:name,kind,type,autocomplete:e.autocomplete||'',required:!!e.required,disabled:!!e.disabled,secret:secret(e),
checked:!!e.checked,filled:!!e.value,edit:secret(e)?null:(e.dataset.alicePurchaseEdit||null),value:!secret(e)&&(numeric||kind==='select')?String(e.value).slice(0,80):null,
options:kind==='select'?Array.from(e.options).map(o=>({value:o.value,label:o.text,disabled:o.disabled})).slice(0,50):[],
invalid:!secret(e)&&!!e.validity&&!e.validity.valid};});
const errors=Array.from(document.querySelectorAll('[role=alert],[aria-live=assertive],.error,.errors,.invalid-feedback,[data-error]')).filter(visible).map(text).filter(Boolean).slice(0,8).map(t=>t.slice(0,240));
const headings=Array.from(document.querySelectorAll('h1,h2,h3')).filter(visible).map(text).slice(0,12);
const busy=Array.from(document.querySelectorAll('[aria-busy=true],[role=progressbar]')).some(visible);
return {url:location.href,document:doc.dataset.alicePurchaseDocument,headings,errors,busy,controls,visible_text:document.body.innerText.slice(0,6000)};})()'''

PAY = re.compile(r'\b(pagar|pago ahora|realizar (el )?pedido|confirmar (el )?pedido|comprar (ya|ahora)|pay|place (your )?order|buy now|complete (purchase|order)|submit order)\b', re.I)


def signature(snapshot):
    # Ignore random control ids; retain document identity, field completion,
    # selected variants, quantities, validation errors and disabled/busy states.
    # Not the page's free text: a carousel, a countdown or a stock line changes it every second,
    # and every action on Prozis came back «stale» until the errand gave up (06-10).
    value = {**snapshot, 'url': snapshot['url'].split('#')[0],
             'controls': [{k:v for k,v in c.items() if k != 'id'} for c in snapshot['controls']]}
    value.pop('visible_text', None)
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:24]


def stage(snapshot):
    controls = snapshot['controls']
    if snapshot.get('busy'):
        return 'loading'
    if any(c['secret'] and re.search(r'password', c['type'], re.I) for c in controls):
        return 'login'
    if any(c['secret'] for c in controls):
        return 'secure_step'
    if snapshot.get('errors') or any(c.get('invalid') and c.get('filled') for c in controls):
        return 'validation_error'
    return 'preparing'


# A cookie banner covers the page and takes the clicks meant for it. It is answered the most
# private way the shop offers (reject the optional ones, or necessary only), never by accepting.
CONSENT_JS = r'''(()=>{const seen=e=>e&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
const ids=['#onetrust-reject-all-handler','#CybotCookiebotDialogBodyButtonDecline','#didomi-notice-disagree-button',
'[data-testid=uc-deny-all-button]','.qc-cmp2-summary-buttons button[mode=secondary]','#truste-consent-required',
'.cmplz-deny','#cookiescript_reject','.cc-deny','[data-cookiefirst-action=reject]'];
for(const q of ids){const e=document.querySelector(q);if(seen(e)){e.click();return q;}}
const words=/^(rechazar( todas?| todo| cookies)?|solo (las )?(necesarias|esenciales)|usar solo (las )?necesarias|continuar sin aceptar|denegar|reject( all)?|decline( all)?|only (necessary|essential)|necessary only|refuse|tout refuser|refuser)$/i;
const box=Array.from(document.querySelectorAll('[id*=cookie i],[class*=cookie i],[id*=consent i],[class*=consent i],[aria-label*=cookie i],[role=dialog]')).filter(seen);
for(const b of box){for(const e of b.querySelectorAll('button,a,[role=button]')){
const t=String(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();if(seen(e)&&words.test(t)){e.click();return t;}}}
return '';})()'''


def observe(entry, inspect, evaluate):
    origin, context, _ = inspect(entry)
    try:
        evaluate(context, CONSENT_JS)
    except Exception:  # noqa: BLE001 — a banner left there is read as part of the page
        pass
    snapshot = evaluate(context, SNAPSHOT_JS)
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get('controls'), list):
        raise ValueError('No se pudo observar la página del recado. No repitas el último clic.')
    if not str(snapshot.get('url', '')).startswith(origin + '/') and snapshot.get('url') != origin:
        raise ValueError('La observación no pertenece al origen del recado.')
    snapshot['observation_id'] = signature(snapshot)
    snapshot['stage'] = stage(snapshot)
    return snapshot


def record(home, entry, snapshot, errands, action=None):
    previous = entry.get('browser_observation') or {}
    progress = snapshot['observation_id'] != previous.get('id')
    state = {'id': snapshot['observation_id'], 'stage': snapshot['stage'], 'url': snapshot['url'], 'at': time.time(),
             'progress_at': time.time() if progress else previous.get('progress_at', time.time()),
             'unchanged': 0 if progress else int(previous.get('unchanged', 0)) + 1}
    if action is not None:
        state['action'] = action
    elif previous.get('action'):
        state['action'] = previous['action']
    errands.update(home, entry['id'], browser_observation=state)
    return state


def result(snapshot, *, outcome='observed', changed=None):
    return {'ok': True, 'outcome': outcome, 'changed': changed, **snapshot,
            'next': ('La página pide acceso o verificación: usa login_request/login_fill o la toma de control, nunca escribas secretos aquí.'
                     if snapshot['stage'] in ('login', 'secure_step') else
                     'Corrige fields_to_fix usando suggested_actions si existen: contienen solo la opción elegida y datos de envío guardados. No repitas el botón sin corregir el campo.' if snapshot['stage']=='validation_error' else
                     'Espera y vuelve a observar, sin otro clic.' if snapshot['stage']=='loading' else
                     'Elige una única acción usando un control de esta observación. Verifica después; el mismo URL no significa el mismo estado.')}


def action_script(control, action, value):
    # Arguments are JSON values, never model-provided executable code or CSS.
    return r'''(()=>{const id=%s;const e=Array.from(document.querySelectorAll('[data-alice-purchase-control]')).find(e=>e.dataset.alicePurchaseControl===id);
if(!e||!e.getClientRects().length||e.disabled)return {acted:false,error:'El control dejó de estar disponible.'};
if(/password|contrase[nñ]a|one-time-code|cc-|card|tarjeta|cvc|cvv|otp|verification|security.?code|caducidad/i.test([e.type,e.autocomplete,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),(e.labels?.[0]||e.closest('label'))?.textContent||''].join(' ')))return {acted:false,error:'Usa la tarjeta segura de Alice.'};
const action=%s,value=%s;
if(action==='click')e.click();
else if(action==='select'){
if(e.tagName!=='SELECT'||!Array.from(e.options).some(o=>o.value===value&&!o.disabled))return {acted:false,error:'Esa opción no existe en el desplegable observado.'};
e.value=value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
}else if(action==='fill'){
if(!e.matches('input,textarea')||/checkbox|radio|button|submit|file|hidden/.test(e.type))return {acted:false,error:'Ese control no es un campo editable.'};
const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
Object.getOwnPropertyDescriptor(proto,'value').set.call(e,value);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
}else return {acted:false,error:'Acción desconocida.'};
return {acted:true};})()''' % (json.dumps(control['id']), json.dumps(action), json.dumps(value))


def run(home, entry, args, errands, inspect, evaluate, sleep=time.sleep, details=None):
    # Tool calls can arrive concurrently. Serialize the whole observation/action/
    # verification, and reload the journal under the lock before deciding to act.
    directory = Path(home) / '.alice' / 'purchase-browser'
    directory.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(entry['id'].encode()).hexdigest() + '.lock'
    fd = os.open(directory / name, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            current = errands.get(home, entry['id'])
            if not current or current.get('session_id') != entry.get('session_id'):
                raise ValueError('El recado ya no existe o cambió de sesión.')
            if args.get('action','observe') != 'observe' and current.get('status') != 'working':
                raise ValueError('El recado espera a la persona o ya se ha detenido. No cambies su cesta ni su formulario.')
            payload = _run(home, current, args, errands, inspect, evaluate, sleep)
            if 'controls' in payload:
                payload['suggested_actions'] = plan(current, payload, details or {})
                payload['fields_to_fix'] = [{'control_id':c['id'],'label':c['label']} for c in payload['controls']
                    if not c['secret'] and (c.get('invalid') or (c.get('required') and not c.get('filled')))]
                if (payload.get('stage') == 'validation_error' and not payload['fields_to_fix']
                        and action_was_correction(errands.get(home, entry['id']))):
                    payload['next'] = ('El campo se ha corregido desde el rechazo anterior. La tienda puede conservar ese mensaje hasta validar de nuevo. '
                        'Si el valor coincide con los datos guardados y no quedan campos inválidos, envía una vez el formulario con su control observado y comprueba la respuesta. '
                        'El mensaje anterior no demuestra un nuevo rechazo; si vuelve a rechazarlo, no inventes otro dato ni repitas sin una nueva corrección.')
            return payload
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def action_was_correction(entry):
    previous = (entry.get('browser_observation') or {}).get('action') or {}
    return previous.get('action') in ('fill','select') and previous.get('outcome') == 'changed'


def _run(home, entry, args, errands, inspect, evaluate, sleep):
    action = args.get('action', 'observe')
    if action not in ('observe', 'click', 'fill', 'select'):
        raise ValueError('Usa observe, click, fill o select.')
    before = observe(entry, inspect, evaluate)
    if action == 'observe':
        record(home, entry, before, errands)
        return result(before)
    previous = entry.get('browser_observation') or {}
    if args.get('observation_id') != before['observation_id'] or previous.get('id') != before['observation_id']:
        record(home, entry, before, errands)
        return {**result(before, outcome='stale'), 'ok': False,
                'error': 'La página cambió: ninguna acción se ejecutó. Decide usando esta nueva observación.'}
    control = next((c for c in before['controls'] if c['id'] == args.get('control_id')), None)
    if not control or control['disabled'] or control['secret'] or before['busy']:
        raise ValueError('El control no está disponible o requiere la tarjeta segura de Alice. Observa antes de actuar.')
    if action == 'click':
        _, context, _ = inspect(entry)
        payment_step = bool(evaluate(context, errands.PAYMENT_STEP_JS))
        if PAY.search(control['label']) or errands.is_pay_action(
                'browser_click', {'text':control['label']}, before['url'], payment_step):
            raise ValueError('Este control puede pagar. Prepara checkout_request y usa las herramientas de pago con sus barreras habituales; purchase_browser nunca paga.')
    value = args.get('value', '')
    if not isinstance(value, str) or len(value) > 500:
        raise ValueError('El valor del campo debe ser texto de hasta 500 caracteres.')
    key = hashlib.sha256(json.dumps([before['observation_id'], action, control['id'], value]).encode()).hexdigest()
    last = previous.get('action') or {}
    if last.get('key') == key and last.get('outcome') in ('executing', 'unknown', 'unchanged', 'changed'):
        record(home, entry, before, errands)
        return {**result(before, outcome='duplicate'), 'ok': False,
                'error': 'Esa acción ya se intentó. No se repitió: lee el estado, los errores y cambia el siguiente paso.'}
    metadata = {'key': key, 'action': action, 'control': control['label'], 'outcome': 'executing'}
    record(home, entry, before, errands, metadata)  # Before action: lost response never becomes a blind retry.
    _, context, _ = inspect(entry)
    try:
        acted = evaluate(context, action_script(control, action, value))
    except Exception:
        metadata['outcome'] = 'unknown'
        record(home, entry, before, errands, metadata)
        return {'ok': False, 'outcome': 'unknown', 'error': 'No se pudo comprobar el resultado. Puede haberse ejecutado: observa antes de reintentar.'}
    if not isinstance(acted, dict) or not acted.get('acted'):
        metadata['outcome'] = 'unchanged'
        record(home, entry, before, errands, metadata)
        return {'ok': False, 'outcome': 'unchanged', 'error': (acted or {}).get('error', 'El control no se pudo usar.')}
    after = before
    verified = False
    for _ in range(12):
        sleep(.2)
        try:
            after = observe(entry, inspect, evaluate)
            verified = True
            if after['observation_id'] != before['observation_id'] and not after.get('busy'):
                break
        except Exception:
            continue  # Navigation can replace the document; do not click again.
    if not verified:
        metadata['outcome'] = 'unknown'
        record(home, entry, before, errands, metadata)
        return {'ok':False,'outcome':'unknown','error':'La acción se envió, pero no se pudo leer la página posterior. No repitas: observa y comprueba la cesta.'}
    changed = after['observation_id'] != before['observation_id']
    metadata['outcome'] = 'changed' if changed else 'unchanged'
    record(home, entry, after, errands, metadata)
    if changed:
        # Said as the person would: «Pulsado «Añadir a la cesta»», not «click: … · cambio comprobado».
        done = {'click': 'Pulsado', 'fill': 'Rellenado', 'select': 'Elegido'}.get(action, action)
        errands.add_step(home, entry['id'], f"{done} «{control['label']}»", after['url'])
    return result(after, outcome=metadata['outcome'], changed=changed)


def register(ctx, plugin):
    def handler(args, session_id='', **_):
        try:
            from hermes_constants import get_hermes_home
            _, profile = plugin._root_and_sender(Path(get_hermes_home()))
            session = plugin._session_id(session_id)
            errands = plugin._errands()
            entry = errands.of_session(plugin._hermes_root(), session)
            if not entry or not entry.get('offer') or entry.get('profile', '') != profile:
                return plugin._agent_json({'ok': False, 'error': 'Solo dentro del recado de una opción elegida en este perfil.'})
            access = plugin._module('errand_access.py', 'alice_errand_access')
            if (args or {}).get('action','observe') != 'observe' and hasattr(access, 'guard_account_input'):
                name = 'browser_type' if (args or {}).get('action') == 'fill' else 'browser_click'
                verdict = access.guard_account_input(entry, name, {'text': (args or {}).get('value','')})
                if verdict:
                    return plugin._agent_json({'ok':False,'error':verdict.get('message','Usa el acceso elegido.')})
            # Existing secret masking applies before any DOM read.
            if entry.get('secure_answered'):
                access.protect_browser_secrets(entry)
            from agent.redact import redact_registered_vault_values, redact_sensitive_text
            details = plugin._ask_person().load_details(Path(get_hermes_home()))
            payload = plugin._agent_json(run(plugin._hermes_root(), entry, args or {}, errands, access.target, access.page_evaluate, details=details))
            return redact_registered_vault_values(redact_sensitive_text(payload, force=True))
        except ValueError as exc:
            return plugin._agent_json({'ok': False, 'error': str(exc)})
        except Exception:
            return plugin._agent_json({'ok': False, 'error': 'No se pudo comprobar la página propia del recado. Observa con el navegador, sin repetir la última acción.'})
    ctx.register_tool(name='purchase_browser', toolset='alice_tasks', handler=handler, check_fn=lambda: True,
        schema={'name':'purchase_browser','description':'Observe the actual errand page, perform ONE pre-payment action on an observed control, and return the verified post-action state. No guessed selectors, JS, secrets or payment. Start with observe; action requires the returned observation_id and control_id. On unchanged/stale/unknown do not blindly repeat.',
                'parameters':{'type':'object','properties':{'action':{'type':'string','enum':['observe','click','fill','select']},
                    'observation_id':{'type':'string'},'control_id':{'type':'string'},'value':{'type':'string'}},'required':['action'],'additionalProperties':False}})


def plan(entry, snapshot, details):
    """Suggest only exact chosen variant/units or saved shipping values.

    It never guesses a substitute, account, address or payment. Recommendations
    carry the same observation ids as manual actions and pass the same checks.
    """
    if snapshot.get('stage') in ('loading','login','secure_step'):
        return []
    offer = entry.get('offer') or {}
    variant = str(offer.get('variant') or '').strip().casefold()
    proposed = []
    for c in snapshot['controls']:
        if c['secret'] or c['disabled']:
            continue
        action, value, reason = None, None, ''
        label = c['label'].casefold()
        if c['kind'] == 'select' and variant:
            option = next((o for o in c.get('options',[]) if str(o['label']).strip().casefold()==variant and not o.get('disabled')),None)
            if option and c.get('value') != option['value']:
                action,value,reason='select',option['value'],'La variante exacta elegida.'
        if c['kind']=='input' and re.search(r'quantity|cantidad|qty|unidades',label) and offer.get('qty'):
            expected=str(offer['qty'])
            if c.get('value') != expected:
                action,value,reason='fill',expected,'La cantidad exacta elegida.'
        if c['kind'] in ('input','textarea') and (not c.get('filled') or c.get('invalid')):
            autocomplete = c.get('autocomplete','').split()[-1:] or ['']
            mapping={'street-address':'address','address-line1':'address','postal-code':'postcode','address-level2':'city',
                     'address-level1':'province','given-name':'name','family-name':'surname','tel':'phone','email':'email'}
            field=mapping.get(autocomplete[0])
            if not field:
                for pattern,candidate in ((r'postal|postcode|zip','postcode'),(r'street|direcci[oó]n|address','address'),
                    (r'city|ciudad','city'),(r'surname|apellido','surname'),(r'phone|tel[eé]fono','phone')):
                    if re.search(pattern,label):field=candidate;break
            if field and details.get(field):
                action,value,reason='fill',str(details[field]),'Un dato de envío ya guardado; corrige el campo vacío o inválido.'
        if action:
            proposed.append({'action':action,'control_id':c['id'],'observation_id':snapshot['observation_id'],'value':value,'reason':reason})
    return proposed[:8]
