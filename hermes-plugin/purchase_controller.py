"""Purchase authority, shared by tools, engine and phone.

The model proposes navigation and observed locators. It never supplies accepted
prices, a payment result or arbitrary executable browser code. Every mutation
uses the pinned target; payment has a durable write-ahead attempt per checkout.
Unknown outcomes are reconciled, never automatically submitted again.
"""
from __future__ import annotations
import hashlib
import json
import re
import secrets
import time
from urllib.parse import urlsplit


def module(name):
    import importlib.util
    import sys
    from pathlib import Path
    key = 'alice_' + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, Path(__file__).with_name(name + '.py'))
        sys.modules[key] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sys.modules[key])
    return sys.modules[key]


TERMINAL = ('done', 'denied', 'stopped')
PHASES = ('preparing', 'review', 'approved', 'submitting', 'reconciling', 'confirmed', 'declined', 'cancelled')
PAY = r'\b(pagar|pago|pay|place.{0,12}order|confirmar.{0,12}pedido|realizar.{0,12}pedido|comprar ahora|buy now|complete purchase|submit order)\b'
CART = r'\b(add|añadir|adicionar|agregar|cesta|carrito|cart|basket)\b'
SAFE_CONTINUE = r'\b(continuar|continue|siguiente|next|iniciar sesi[oó]n|log.?in|sign.?in|crear cuenta|register|verificar|verify|cerrar|close|aceptar cookies|rechazar|decline|quitar|remove|eliminar|delete|aplicar|apply|checkout|tramitar|finalizar compra|env[ií]o|delivery)\b'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def mutate(home, errand_id, change):
    """A single transaction over the errand, including compare-and-set decisions."""
    errands = module('errands')
    with errands._locked(home) as path:
        entries = errands._read(path)
        entry = next((e for e in entries if e['id'] == errand_id), None)
        if entry is None:
            raise ValueError('El recado no existe.')
        result = change(entry)
        entry['updated_at'] = time.time()
        errands._write(path, entries)
        return result


def phase(entry, name, **fields):
    if name not in PHASES:
        raise ValueError('Fase de compra inválida.')
    state = dict(entry.get('purchase') or {})
    state.update(fields)
    state['phase'] = name
    state['version'] = int(state.get('version', 0)) + 1
    events = state.get('events') or []
    events.append({'phase':name, 'at':time.time(), 'version':state['version']})
    state['events'] = events[-64:]
    entry['purchase'] = state


def live(home, errand_id, *, inspect=None, evaluate=None):
    entry = module('errands').get(home, errand_id)
    if not entry or entry['status'] in TERMINAL:
        raise ValueError('El recado ya no está activo.')
    access = module('errand_access')
    origin, context, command = (inspect or access.target)(entry)
    expected = access.origin((entry.get('offer') or {}).get('url') or 'https://' + entry['site'])
    state = entry.get('purchase') or {}
    if origin != expected:
        bank = urlsplit(origin).hostname in module('vault_cards').PAYMENT_GATEWAYS
        if not bank or not state.get('attempt_id') or state.get('phase') not in ('submitting', 'reconciling'):
            raise ValueError('La página no pertenece a la tienda ni a su intento de pago.')
    return entry, origin, context, command, evaluate or access.page_evaluate


def observe(home, errand_id, *, inspect=None, evaluate=None):
    entry, origin, context, command, ev = live(home, errand_id, inspect=inspect, evaluate=evaluate)
    # Never report input values. Passwords and OTPs remain inside the secure API.
    raw = ev(context, r'''(()=>{const seen=e=>e.getClientRects().length>0&&getComputedStyle(e).visibility!=="hidden";
    const controls=Array.from(document.querySelectorAll('a,button,input,select,textarea')).filter(seen).map((e,i)=>{
      e.setAttribute('data-alice-control',String(i));
      return {selector:'[data-alice-control="'+i+'"]',tag:e.tagName,type:e.type||'',text:(e.innerText||e.getAttribute('aria-label')||e.placeholder||'').trim().slice(0,160),href:e.tagName==='A'?e.href:null,name:e.name||'',autocomplete:e.autocomplete||''};});
    return {url:location.href,title:document.title,text:(document.body?.innerText||'').slice(0,14000),controls};})()''')
    if not isinstance(raw, dict):
        raise ValueError('No se pudo observar la página del recado.')
    raw['phase'] = (entry.get('purchase') or {}).get('phase', 'preparing')
    return raw


def snapshot(home, errand_id, selectors, *, inspect=None, evaluate=None):
    """All commercial facts are read together, from one target and document."""
    entry, origin, context, command, ev = live(home, errand_id, inspect=inspect, evaluate=evaluate)
    offer = entry.get('offer') or {}
    if not entry.get('site') and offer.get('url'):
        entry = module('errands').update(home,errand_id,site=module('errands').shop(offer['url']))
    recipe = dict((entry.get('cart_evidence') or {}).get('recipe') or {})
    if not recipe:
        raise ValueError('Comprueba la cesta antes de revisar el pedido.')
    if origin != module('errand_access').origin(offer.get('url') or 'https://' + entry['site']):
        raise ValueError('El resumen inicial debe leerse en la tienda.')
    required = ('total_selector', 'delivery_selector', 'address_selector', 'email_selector')
    if any(not selectors.get(k) for k in required):
        raise ValueError('Lee total, entrega, destino y email mediante sus controles del resumen; no valores inventados.')
    locators = {k:selectors[k] for k in required}
    locators.update({k:recipe[k] for k in ('line','price','cart_quantity')})
    order = module('purchase_order')
    script = order.script(locators, module('purchase_prozis').supports(offer.get('url','')))
    raw = ev(context,script)
    if not isinstance(raw, dict) or any(not raw.get(k) for k in ('total','delivery','address','email')):
        raise ValueError('El resumen todavía no muestra todos los datos del pedido.')
    amount, line_cents, breakdown = order.validate(raw, offer, recipe, module('money'))
    line = raw['lines'][0]
    method=raw.get('payment_method') or {}
    if method.get('kind') not in ('card','bank_card','cod','invoice'):
        raise ValueError('El resumen no identifica un método de pago compatible. Selecciónalo en la tienda antes de aprobar.')
    if raw.get('recurring'):
        raise ValueError('El pedido incluye una suscripción; requiere una oferta y aprobación específicas.')
    facts = {'site':entry['site'], 'origin':origin, 'context':context['context'], 'target':context['target'],
             'total':module('money').text(*amount), 'total_cents':amount[0], 'currency':amount[1],
             'delivery':raw['delivery'], 'address':raw['address'], 'email':raw['email'],
             'items':[{'name':offer.get('title') or line['text'], 'variant':offer.get('variant',''),
                       'qty':int(raw['qty']), 'price':module('money').text(line_cents, amount[1])}],
             'line_cents':line_cents, 'breakdown':breakdown, 'product_identity':{'url':order.product_url(offer['url']), 'variant':line['variant'], 'sku':line.get('sku','')}, 'payment_method':method, 'requires_card':method['requires_card'], 'recurring':False}
    return {'facts':facts, 'digest':digest(facts), 'selectors':dict(selectors), 'observed':raw, 'script':script}


def review(home, errand_id, args, *, inspect=None, evaluate=None, saved_cards=None):
    value = snapshot(home,errand_id,args,inspect=inspect,evaluate=evaluate)
    facts = value['facts']
    cards = (saved_cards or module('vault_cards').cards)()
    allowed = list(cards)  # Explicit checkout consent delegates this exact saved handle to this merchant.
    def commit(entry):
        if entry['status'] not in ('working','needs_approval','needs_card') or (entry.get('purchase') or {}).get('attempt_id'):
            raise ValueError('No se puede sustituir este pedido; comprueba el pago existente.')
        if facts['requires_card'] and not allowed:
            entry.update(status='needs_card',card_origin=facts['origin'])
            return {'ok':True,'status':'needs_card','next':'La persona puede añadir una tarjeta segura; conserva el mismo pedido.'}
        checkout = {**facts,'id':secrets.token_hex(12),'status':'pending','merchant':facts['site'],
                    'card_label':(allowed[0]['label'] if len(allowed)==1 else '') if facts['requires_card'] else facts['payment_method']['label'],
                    'available_cards':[{k:c.get(k) for k in ('handle','label','card')} for c in allowed],
                    'snapshot':value,'requested_at':time.time()}
        old = entry.get('checkout') or {}
        if old.get('status')=='pending' and old.get('snapshot',{}).get('digest')==value['digest']:
            checkout={**old, 'snapshot':value}
        entry.update(checkout=checkout,status='needs_approval')
        phase(entry,'review')
        return {'ok':True,'status':'needs_approval','next':'El pedido completo está esperando una única aprobación de la persona.'}
    return mutate(home,errand_id,commit)


def ready(home, entry, *, inspect=None, evaluate=None):
    checkout = module('errands').approved_checkout(entry)
    if not checkout or not checkout.get('snapshot'):
        return False
    actual = snapshot(home,entry['id'],checkout['snapshot']['selectors'],inspect=inspect,evaluate=evaluate)
    return actual['digest'] == checkout['snapshot']['digest']


def reserve(home, errand_id, stage, *, inspect=None, evaluate=None):
    """Consume the exact authorization BEFORE the browser can submit, once per stage.

    The merchant handoff and bank submit share one attempt. Any lost response
    leaves that stage consumed. Refills/OTP never create another attempt.
    """
    entry, origin, context, _, ev = live(home,errand_id,inspect=inspect,evaluate=evaluate)
    checkout = module('errands').approved_checkout(entry)
    if not checkout or not checkout.get('snapshot') or checkout.get('requires_card',True) and not checkout.get('card_handle'):
        raise ValueError('Falta la aprobación vigente del pedido comprobado y su tarjeta exacta.')
    if stage == 'merchant' and not ready(home,entry,inspect=inspect,evaluate=evaluate):
        raise ValueError('El pedido cambió desde la aprobación; prepara un nuevo resumen.')
    bank_amounts = []
    if stage == 'bank':
        if origin == module('errand_access').origin(entry['offer']['url']):
            raise ValueError('El envío bancario debe ocurrir en la pasarela de este intento.')
        actual = ev(context, r'''(()=>{const values=Array.from(document.querySelectorAll('[data-total],.total,.amount,[class*=total],[id*=amount]')).filter(e=>e.getClientRects().length>0).map(e=>e.innerText.trim());return values})()''')
        bank_amounts = [t for t in actual or [] if module('money').parse(t,checkout['currency']) == (checkout['approved_cents'],checkout['currency'])]
        if not bank_amounts:
            raise ValueError('La pasarela no confirma el importe aprobado; revisa el pago en el navegador.')
    def commit(current):
        if current['status'] != 'working' or (current.get('checkout') or {}).get('id') != checkout['id']:
            raise ValueError('La autorización ya no está activa.')
        state = current.get('purchase') or {}
        if stage in state.get('submitted_stages', []):
            raise ValueError('Este pago ya se envió. Comprueba su resultado antes de repetirlo.')
        if stage == 'bank' and 'merchant' not in state.get('submitted_stages', []):
            raise ValueError('La pasarela no está ligada a un envío desde la tienda.')
        attempt = module('purchases').record(home,current['site'],current['session_id'],checkout_id=checkout['id'],
                 card_handle=checkout.get('card_handle',''),snapshot_digest=checkout.get('snapshot',{}).get('digest',''))
        phase(current,'submitting',attempt_id=attempt['id'],submitted_stages=state.get('submitted_stages',[])+[stage],
              payment_origin=origin,context=context['context'],target=context['target'],bank_amounts=bank_amounts)
        return attempt
    return mutate(home,errand_id,commit)


def fill_card(home, errand_id, handle, *, inspect=None, evaluate=None, backend=None):
    entry, origin, context, _, ev = live(home,errand_id,inspect=inspect,evaluate=evaluate)
    checkout = module('errands').approved_checkout(entry)
    if not checkout or not checkout.get('card_handle') or handle != checkout['card_handle']:
        raise ValueError('Usa únicamente la tarjeta exacta que la persona aprobó.')
    state = entry.get('purchase') or {}
    if 'bank' in state.get('submitted_stages',[]) or (origin == module('errand_access').origin(entry['offer']['url']) and state.get('attempt_id')):
        raise ValueError('El pago ya se envió; no vuelvas a rellenar ni pagar.')
    if not state.get('attempt_id') and not ready(home,entry,inspect=inspect,evaluate=evaluate):
        raise ValueError('El pedido cambió; solicita la aprobación del nuevo resumen.')
    if backend is None:
        from tools.browser_vault_tool import _confirm_payment_fill
        module('errands').update(home,errand_id,fill_consent={'checkout_id':checkout['id'],'handle':handle,'label':checkout.get('card_label',''),'origin':origin,'at':time.time()})
        try:
            if not _confirm_payment_fill(checkout.get('card_label',''), origin):
                raise ValueError('Hermes no autorizó rellenar la tarjeta para este pedido.')
        finally:
            module('errands').update(home,errand_id,fill_consent=None)
        from agent.vault_backends import backend_for_handle
        backend = backend_for_handle(handle)
    meta = backend.get_meta(handle) if backend else None
    if not meta or meta.kind != 'payment':
        raise ValueError('La tarjeta aprobada ya no está disponible.')
    if origin not in (list(meta.allowed_origins) or [meta.origin]):
        # General cards are explicitly approved for this exact merchant snapshot.
        # Bound cards may be delegated only to a known bank in this own context.
        if meta.origin and origin != checkout['snapshot']['facts']['origin'] and urlsplit(origin).hostname not in module('vault_cards').PAYMENT_GATEWAYS:
            raise ValueError('La tarjeta no está autorizada para este origen.')
    from agent.vault_login_classifier import LoginControl, classify_checkout_control, select_checkout_fills, build_inspection_js, build_fill_js
    from agent.vault_store import PAYMENT_FIELDS
    from agent.redact import register_vault_redaction_value
    nonce = secrets.token_hex(8)
    raw = ev(context,build_inspection_js(nonce))
    if isinstance(raw,str):raw=json.loads(raw)
    controls = [classify_checkout_control(LoginControl.from_dict(r)) for r in raw or [] if isinstance(r,dict)]
    secret = backend.resolve_secret(handle)
    try:
        for v in secret.values():register_vault_redaction_value(v)
        fills = select_checkout_fills([c for c in controls if c],secret,PAYMENT_FIELDS)
        if not fills:raise ValueError('La página no tiene campos de tarjeta compatibles.')
        result = ev(context,build_fill_js(fills,origin,nonce))
        if isinstance(result,str):result=json.loads(result)
        if not isinstance(result,dict) or not result.get('filled'):raise ValueError('La página cambió durante el rellenado seguro.')
        return {'ok':True,'filled':result['filled'],'next':'Envía una vez mediante purchase_action; no uses el navegador global.'}
    finally:
        secret.clear()


def act(home, errand_id, args, *, inspect=None, evaluate=None):
    entry, origin, context, command, ev = live(home,errand_id,inspect=inspect,evaluate=evaluate)
    action = args.get('action')
    if action == 'read':return observe(home,errand_id,inspect=inspect,evaluate=evaluate)
    if action == 'navigate':
        url = module('purchase_prices').https(args.get('url',''))
        if module('errand_access').origin(url) != origin:
            raise ValueError('Navega solo dentro del origen actual; la pasarela se abre desde la tienda.')
        if (entry.get('purchase') or {}).get('attempt_id'):
            raise ValueError('No recargues un envío pendiente. Comprueba su resultado en la página actual.')
        ev(context,'location.href=' + json.dumps(url))
        return {'ok':True}
    if action == 'fill_card':return fill_card(home,errand_id,args.get('handle',''),inspect=inspect,evaluate=evaluate)
    if action not in ('click','input','select','quantity'):
        raise ValueError('Acción de compra desconocida.')
    selector = args.get('selector')
    if not isinstance(selector,str) or not selector or len(selector)>500:raise ValueError('Indica un control observado mediante un selector CSS.')
    desc = ev(context,r'''(()=>{const nodes=Array.from(document.querySelectorAll('''+json.dumps(selector)+r''')).filter(e=>e.getClientRects().length>0);if(nodes.length!==1)return null;const e=nodes[0];return {tag:e.tagName,type:e.type||'',text:[e.innerText,e.getAttribute('aria-label'),e.value].join(' ').trim(),name:[e.name,e.id,e.autocomplete].join(' '),href:e.tagName==='A'?e.href:null,form:e.form?.getAttribute('action')||'',submit:e.type==='submit'||e.tagName==='BUTTON'&&e.type!=='button'};})()''')
    if not isinstance(desc,dict):raise ValueError('El control debe ser único y visible en la página actual.')
    if re.search(r'password|cc-|cvv|cvc|cardnumber|one.time.code',desc['name']+' '+desc['type'],re.I):
        raise ValueError('Usa la tarjeta o el formulario seguro para secretos.')
    payment_page = bool(ev(context,module('errands').PAYMENT_STEP_JS))
    paying = action=='click' and (bool(re.search(PAY,desc['text'],re.I)) or payment_page and desc.get('submit') and not re.search(r'log.?in|sign.?in|iniciar|register|verificar|verify|coupon|aplicar|apply',desc['text'],re.I))
    if action == 'click':
        if desc.get('href') and not paying and module('errand_access').origin(desc['href']) != origin:
            raise ValueError('El enlace sale del origen del recado; no se sigue sin un envío de pago aprobado.')
        if paying:
            if not entry.get('offer'):raise ValueError('Este recado necesita un pedido comprobado antes de pagar.')
            stage = 'merchant' if origin == module('errand_access').origin(entry['offer']['url']) else 'bank'
            reserve(home,errand_id,stage,inspect=inspect,evaluate=evaluate)
            entry = module('errands').get(home,errand_id)
        elif (entry.get('purchase') or {}).get('attempt_id'):
            # After submission only an observed OTP verification control is allowed.
            if not re.search(r'\b(verify|verificar|autenticar|authenticate)\b',desc['text'],re.I):
                raise ValueError('El envío ya está pendiente; comprueba el resultado sin repetir operaciones.')
        elif not (desc.get('href') and module('errand_access').origin(desc['href'])==origin) and not re.search(SAFE_CONTINUE+'|'+CART,desc['text'],re.I):
            raise ValueError('No se reconoce la función comercial del control; lee su etiqueta o revisa la página.')
    if not paying and action!='click' and (entry.get('purchase') or {}).get('attempt_id'):
        raise ValueError('El pedido ya se envió; no lo modifiques.')
    # Recheck the descriptor inside the same evaluation which operates it (TOCTOU).
    expected = dict(desc)
    value = str(args.get('value') or '')
    if len(value)>500:raise ValueError('Valor demasiado largo.')
    script = r'''(()=>{const es=Array.from(document.querySelectorAll('''+json.dumps(selector)+r''')).filter(e=>e.getClientRects().length>0);if(es.length!==1)return {changed:true};const e=es[0];const d={tag:e.tagName,type:e.type||'',text:[e.innerText,e.getAttribute('aria-label'),e.value].join(' ').trim(),name:[e.name,e.id,e.autocomplete].join(' '),href:e.tagName==='A'?e.href:null,form:e.form?.getAttribute('action')||'',submit:e.type==='submit'||e.tagName==='BUTTON'&&e.type!=='button'};if(JSON.stringify(d)!==JSON.stringify('''+json.dumps(expected)+r'''))return {changed:true};'''
    script += 'if(location.origin!==' + json.dumps(origin) + ')return {changed:true};'
    if paying and stage=='bank':
        script += 'const amounts=Array.from(document.querySelectorAll("[data-total],.total,.amount,[class*=total],[id*=amount]")).filter(n=>n.getClientRects().length>0).map(n=>n.innerText.trim());if(!'+json.dumps(entry['purchase']['bank_amounts'])+'.some(a=>amounts.includes(a)))return {changed:true};'
    if paying and stage=='merchant':
        snap = entry['checkout']['snapshot']
        script += 'const observed='+snap['script']+';if(JSON.stringify(observed)!==JSON.stringify('+json.dumps(snap['observed'])+'))return {changed:true};'
    if action=='click':script+='e.click();return {ok:true};})()'
    else:
        if desc['tag'] not in ('INPUT','SELECT','TEXTAREA'):raise ValueError('El control no es editable.')
        if desc['tag']=='SELECT':script+='if(!Array.from(e.options).some(o=>o.value==='+json.dumps(value)+'))return {changed:true};'
        script+='const setter=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),"value")?.set;if(setter)setter.call(e,'+json.dumps(value)+');else e.value='+json.dumps(value)+';e.dispatchEvent(new Event("input",{bubbles:true}));e.dispatchEvent(new Event("change",{bubbles:true}));return {ok:true};})()'
    current=module('errands').get(home,errand_id)
    if not current or current['status'] in TERMINAL:
        raise ValueError('El recado se detuvo antes de ejecutar el paso.')
    result = ev(context,script)
    if not isinstance(result,dict) or not result.get('ok'):
        if paying:module('purchases').mark(home,(module('errands').get(home,errand_id)['purchase']['attempt_id']),status='unknown')
        raise ValueError('La página cambió antes de actuar; observa de nuevo. Si se envió el pago, reconcilia su resultado.')
    module('errands').add_step(home,errand_id,desc['text'][:100] or action,context.get('url',''))
    return result


def reconcile(home, errand_id, args, *, inspect=None, evaluate=None):
    entry, origin, context, _, ev = live(home,errand_id,inspect=inspect,evaluate=evaluate)
    state = entry.get('purchase') or {}
    if not state.get('attempt_id'):raise ValueError('No hay un intento de pago enviado en este recado.')
    page = observe(home,errand_id,inspect=inspect,evaluate=evaluate)
    outcome = args.get('outcome','unknown')
    order = str(args.get('order') or '').strip()
    if outcome=='paid':
        if not order or not re.search(r'\d{3,}',order) or order not in page['text'] or not re.search(r'confirm|gracias|thank|success|realizado|recibido|received',page['text'],re.I):
            raise ValueError('No hay una confirmación de pedido comprobada en esta página.')
        total = entry['checkout']['total']
        if not any(module('money').same(t,total,entry['checkout']['currency']) for t in re.findall(r'(?:[€$£]\s*)?\d[\d.,]*\s*(?:€|EUR|USD|GBP|\$|£)',page['text'])):
            raise ValueError('La confirmación no muestra el importe aprobado.')
    elif outcome in ('declined','not_charged'):
        # A timeout, HTTP error or failed confirmation can follow a successful charge.
        if not re.search(r'(?:pago|payment|card|tarjeta).{0,35}(?:rechazad|declined|denied)|(?:no se ha cobrado|no payment was taken|not charged)', page['text'], re.I):
            raise ValueError('La página no demuestra que no se cobró; registra unknown.')
    result = module('purchases').settle(home,entry['site'],outcome,order,entry['checkout']['total'],
             session=entry['session_id'],attempt_id=state['attempt_id'])
    if not result.get('ok'):return result
    module('errands').record_receipt(home,entry['session_id'],{**args,'site':entry['site'],'total':entry['checkout']['total']})
    def finish(current):
        phase(current,'confirmed' if outcome=='paid' else 'declined' if outcome in ('declined','not_charged') else 'reconciling')
        current['status'] = 'done' if outcome=='paid' else 'stuck'
        current['reason'] = '' if outcome=='paid' else 'El pago fue rechazado.' if outcome=='declined' else 'El resultado del pago sigue sin confirmar. Comprueba el pedido antes de repetirlo.'
    mutate(home,errand_id,finish)
    return result


def retry_after_no_charge(home, errand_id):
    """Retire only an exact, definitively unpaid attempt; never reuse its consent."""
    def reset(entry):
        state = entry.get('purchase') or {}
        if entry['status'] != 'stuck' or state.get('phase') != 'declined':
            raise ValueError('Primero confirma el resultado del intento existente.')
        if entry.get('run_submission'):
            raise ValueError('Conserva el envío de Hermes sin confirmar antes de preparar otro pedido.')
        purchases = module('purchases')
        with purchases._locked(home) as path:
            attempt = next((row for row in purchases._read(path)
                            if row.get('id') == state.get('attempt_id')
                            and row.get('session') == entry['session_id']
                            and row.get('shop') == purchases.shop(entry['site'])
                            and row.get('checkout_id') == (entry.get('checkout') or {}).get('id')), None)
        if not attempt or attempt.get('status') not in ('declined', 'not_charged'):
            raise ValueError('No está confirmado que este intento terminara sin cobrar.')
        errands = module('errands')
        context = errands.context_file(errand_id)
        if context.exists():
            saved = json.loads(context.read_text(encoding='utf-8'))
            # Never dispose the person's shared fallback browser.
            if not saved.get('cdp') or not errands.release_context(errand_id):
                raise ValueError('No se pudo cerrar el navegador del intento rechazado. Conserva su estado.')
        previous = list(state.get('previous_attempts') or [])
        previous.append({'id':attempt['id'], 'outcome':attempt['status'], 'checkout_id':attempt['checkout_id']})
        phase(entry, 'preparing', attempt_id=None, submitted_stages=[], prepared=False,
              previous_attempts=previous[-32:], payment_origin=None, bank_amounts=[], context=None, target=None)
        entry.update(checkout=None, cart_evidence=None, checkout_evidence=None, receipt=None,
                     browser_target=None, run_id='', run_submission=None, runs=0, reason='', blocked=None)
    return mutate(home, errand_id, reset)


def next_step(entry):
    """Deterministic continuation; prose and the judge cannot mark a purchase done."""
    state = entry.get('purchase') or {}
    if state.get('attempt_id'):
        return 'Lee el resultado con purchase_action action=read y registra purchase_outcome. No envíes el pago de nuevo.'
    if module('errands').approved_checkout(entry):
        return 'Usa purchase_action fill_card con la tarjeta aprobada, y click sobre el control observado de pago una sola vez.'
    if entry.get('cart_evidence'):
        return 'Prepara destino y entrega con purchase_action. Lee el resumen completo y llama checkout_request con los selectores observados.'
    return 'Usa purchase_action read para observar tu página; prepara la opción elegida y comprueba la cesta con purchase_check_cart.'


def ensure_context(home, entry):
    """Server-owned bootstrap: the browser exists even when the model emits no tools."""
    from pathlib import Path
    import urllib.request
    path = module('errands').context_file(entry['id'])
    if path.exists():
        try:
            module('errand_access').target(entry)
            return
        except Exception:
            if (entry.get('purchase') or {}).get('attempt_id'):
                raise ValueError('La página del pago no está disponible; conserva el intento y comprueba el pedido.')
            module('errands').release_context(entry['id'])
    if not module('browser_live').ensure(home):raise ValueError('El navegador no está disponible.')
    endpoint = module('browser_live').configured_url(home)
    with urllib.request.urlopen(endpoint.rstrip('/')+'/json/version',timeout=3) as response:
        ws = json.load(response)['webSocketDebuggerUrl']
    from websockets.sync.client import connect
    with connect(ws,open_timeout=3) as sock:
        sequence = 0
        def call(method,params):
            nonlocal sequence
            sequence += 1
            sock.send(json.dumps({'id':sequence,'method':method,'params':params}))
            while True:
                result=json.loads(sock.recv(timeout=5))
                if result.get('id')==sequence:
                    if result.get('error'):raise ValueError('No se pudo abrir el navegador del recado.')
                    return result.get('result') or {}
        context = call('Target.createBrowserContext',{'disposeOnDetach':False})['browserContextId']
        try:
            url = (entry.get('offer') or {}).get('url') or 'https://'+entry['site']
            module('purchase_prices').https(url)
            target = call('Target.createTarget',{'url':url,'browserContextId':context})['targetId']
            module('purchase_storage').write(path,{'context':context,'target':target,'cdp':endpoint})
        except Exception:
            call('Target.disposeBrowserContext',{'browserContextId':context})
            raise
    module('errands').update(home,entry['id'],browser_target=target)
    module('errands').add_step(home,entry['id'],'Abriendo la tienda elegida',url)


class PinnedCart:
    """Only fixed product/quantity/coupon recipes may mutate without model code."""
    def __init__(self,home,entry,*,inspect=None,evaluate=None):
        self.origin,self.context,self.command=(inspect or module('errand_access').target)(entry)
        self.ev=evaluate or module('errand_access').page_evaluate
    def evaluate(self,code):return self.ev(self.context,code)
    def read(self,selector):return module('purchase_prices').Probe.read(self,selector)
    def units(self,selector,qty):return module('purchase_prices').Probe.units(self,selector,qty)
    def coupon(self,selector,code):return module('purchase_prices').Probe.coupon(self,selector,code)
    def click(self,selector,action='add'):return module('purchase_prices').Probe.click(self,selector,action)
    def goto(self,url):
        if module('errand_access').origin(url)!=self.origin:raise ValueError('La cesta cambió de tienda.')
        self.evaluate('location.href='+json.dumps(url))
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            time.sleep(.2)
            if self.evaluate('document.readyState')=='complete':return
        raise ValueError('La cesta todavía no terminó de cargar.')


def prepare(home,entry):
    """Execute the verified offer's recipe once. No search/cart instructions needed."""
    offer = entry.get('offer') or {}
    if not offer or not offer.get('recipe') or entry.get('cart_evidence') or entry.get('checkout') or (entry.get('purchase') or {}).get('attempt_id'):
        return False
    state=entry.get('purchase') or {}
    if state.get('prepared'):return False
    browser = PinnedCart(home,entry)
    recipe = dict(offer['recipe'])
    if module('purchase_prozis').supports(offer['url']):
        recipe=module('purchase_prozis').product_recipe(browser,recipe)
    if recipe.get('quantity'):browser.units(recipe['quantity'],offer.get('qty',1))
    # Consume the add before dispatch: a timeout must inspect the cart, not add again.
    mutate(home,entry['id'],lambda current:phase(current,'preparing',prepared=True))
    browser.click(recipe['add'])
    if module('purchase_prozis').supports(offer['url']):
        module('purchase_prozis').wait_added(browser,offer['title'],offer.get('variant',''),offer.get('qty',1))
    if recipe.get('cart_url'):browser.goto(recipe['cart_url'])
    if offer.get('coupon_code') and recipe.get('coupon') and recipe.get('apply'):
        browser.coupon(recipe['coupon'],offer['coupon_code']);browser.click(recipe['apply'],action='coupon')
    module('purchase_prices').check_cart(home,entry['id'],recipe)
    return True


def advance(home, errand_id, *, inspect=None, evaluate=None, saved_cards=None, card_backend=None):
    """Advance recognizable checkout states without spending a model turn.

    Unambiguous standard controls are executed through the same capability as
    model proposals. A novel or incomplete page is left for observation; it does
    not become a fabricated rejection or a successful order.
    """
    entry, origin, context, command, ev = live(home,errand_id,inspect=inspect,evaluate=evaluate)
    state = entry.get('purchase') or {}
    page = observe(home,errand_id,inspect=inspect,evaluate=evaluate)
    if state.get('attempt_id'):
        order = re.search(r'(?:pedido|order)(?:\s*(?:confirmado|confirmed|number|n[uú]mero|n[ºo°.]|#|:))*\s*([A-Z0-9-]*\d{3,}[A-Z0-9-]*)',page['text'],re.I)
        if order and re.search(r'confirm|gracias|thank|success|realizado|recibido|received',page['text'],re.I):
            result=reconcile(home,errand_id,{'outcome':'paid','order':order.group(1)},inspect=inspect,evaluate=evaluate)
            return result.get('ok') is True
        module('errand_access').detect_pending(home,errand_id,inspect=inspect or module('errand_access').target,evaluate=ev)
        return False
    checkout = module('errands').approved_checkout(entry)
    if checkout:
        pay = [c for c in page['controls'] if c['tag'] in ('BUTTON','INPUT') and re.search(PAY,c['text'],re.I)]
        if len(pay)!=1:return False
        card_fields=any(re.search(r'cc-number|card.?number',c.get('autocomplete','')+' '+c.get('name',''),re.I) for c in page['controls'])
        if card_fields:
            if card_backend is None:
                from agent.vault_backends import backend_for_handle
                card_backend=backend_for_handle(checkout['card_handle'])
            fill_card(home,errand_id,checkout['card_handle'],inspect=inspect,evaluate=evaluate,backend=card_backend)
        act(home,errand_id,{'action':'click','selector':pay[0]['selector']},inspect=inspect,evaluate=evaluate)
        return True
    if entry.get('cart_evidence'):
        # These are document contracts, not quantities/totals supplied by the model.
        selectors=ev(context,r'''(()=>{const visible=e=>e&&e.getClientRects().length>0;const one=s=>{const a=Array.from(document.querySelectorAll(s)).filter(visible);return a.length===1?s:null};return {
        total_selector:one('[data-order-total],[data-grand-total],#grand-total,#order-total,#total'),
        delivery_selector:one('[data-order-delivery],#order-delivery,#delivery'),
        address_selector:one('[data-order-address],#order-address,#address'),
        email_selector:one('[data-order-email],#order-email,#email')};})()''')
        if isinstance(selectors,dict) and all(selectors.values()):
            review(home,errand_id,selectors,inspect=inspect,evaluate=evaluate,saved_cards=saved_cards)
            return True
    return False
