"""Price evidence captured by a restricted service in disposable cart contexts.

The model supplies DOM locators, never an accepted amount. This service has no
vault access and exposes no checkout, arbitrary script or payment operation.
"""
from __future__ import annotations
import contextlib
import hashlib
import json
import secrets
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit
import importlib.util
import sys

def module(name):
    key = "alice_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, Path(__file__).with_name(name + ".py"))
        value = importlib.util.module_from_spec(spec)
        sys.modules[key] = value
        spec.loader.exec_module(value)
    return sys.modules[key]

TTL = 15 * 60

def fingerprint(cookies, origin):
    host = urlsplit(origin).hostname
    cookies = [c for c in cookies if host == c.get('domain','').lstrip('.') or host.endswith('.' + c.get('domain','').lstrip('.'))]
    return hashlib.sha256(json.dumps(cookies,sort_keys=True).encode()).hexdigest()


def https(url):
    from tools.url_safety import is_safe_url
    # The browser's existing URL validator remains authoritative (private targets blocked).
    if not is_safe_url(url):
        raise ValueError("La dirección de la tienda no es segura.")
    if urlsplit(url).scheme != 'https':
        raise ValueError('La comprobación requiere una tienda HTTPS.')
    return url


class Probe:
    """Own context, disposed even after failures. No personal cookies are copied."""
    def __init__(self, home, endpoint=None):
        from websockets.sync.client import connect
        endpoint = endpoint or module('browser_live').configured_url(home)
        with urllib.request.urlopen(endpoint.rstrip('/') + '/json/version', timeout=3) as response:
            ws = json.load(response)['webSocketDebuggerUrl']
        self.socket = connect(ws, open_timeout=3)
        self.sequence = 0
        self.context = self.call('Target.createBrowserContext', {'disposeOnDetach': True})['browserContextId']
        self.target = self.call('Target.createTarget', {'url': 'about:blank', 'browserContextId': self.context})['targetId']
        self.session = self.call('Target.attachToTarget', {'targetId': self.target, 'flatten': True})['sessionId']
        self.call('Page.enable', page=True)

    def call(self, method, params=None, page=False):
        self.sequence += 1
        message = {'id': self.sequence, 'method': method, 'params': params or {}}
        if page:
            message['sessionId'] = self.session
        self.socket.send(json.dumps(message))
        while True:
            reply = json.loads(self.socket.recv(timeout=15))
            if reply.get('id') == self.sequence:
                if reply.get('error'):
                    raise ValueError('La tienda no permitió comprobar la cesta temporal.')
                return reply.get('result') or {}

    def evaluate(self, script):
        result = self.call('Runtime.evaluate', {'expression': script, 'returnByValue': True, 'awaitPromise': True}, page=True)
        if result.get('exceptionDetails'):
            raise ValueError('No se pudo leer la cesta temporal.')
        return result['result'].get('value')

    def goto(self, url):
        self.call('Page.navigate', {'url': https(url)}, page=True)
        for _ in range(50):
            time.sleep(.1)
            if self.evaluate('document.readyState') == 'complete':
                current = self.evaluate('location.href')
                if urlsplit(current).netloc != urlsplit(url).netloc:
                    raise ValueError('La tienda redirigió a otro origen.')
                return
        raise ValueError('La tienda no terminó de cargar.')

    def read(self, selector):
        return self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');return e ? String(e.value ?? e.innerText).trim() : null})()')

    def units(self, selector, qty):
        result = self.evaluate('''(()=>{const e=document.querySelector(%s);if(!e || !['INPUT','SELECT'].includes(e.tagName) || /password|email|tel/i.test(e.type)) return false;
const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
if(e.tagName==='INPUT' && setter) setter.call(e,%s);else e.value=%s;
e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return String(e.value)===%s})()''' % (json.dumps(selector),json.dumps(str(qty)),json.dumps(str(qty)),json.dumps(str(qty))))
        if not result:
            raise ValueError('No se pudo comprobar esa cantidad.')

    def coupon(self, selector, code):
        if not self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');if(!e||e.tagName!=="INPUT"||!/coupon|cup[oó]n|promo|discount|descuento|code|c[oó]digo/i.test([e.name,e.id,e.placeholder].join(" ")))return false;e.value=' + json.dumps(code) + ';e.dispatchEvent(new Event("input",{bubbles:true}));e.dispatchEvent(new Event("change",{bubbles:true}));return true})()'):
            raise ValueError('No hay un campo de descuento público verificable.')

    def click(self, selector, action='add'):
        # Inspect the actual control, including ancestors. Merely labelling a payment locator as add cannot bypass this.
        result = self.evaluate('''(()=>{const e=document.querySelector(%s);if(!e)return false;
const text=[e.innerText,e.value,e.getAttribute('aria-label')].join(' ');
if(/pagar|pay\\b|place.order|comprar.ahora|confirmar.pedido|checkout/i.test(text)) return false;
if(!%s.test(text))return false;e.click();return true})()''' % (json.dumps(selector), '/add|añadir|adicionar|agregar|cesta|carrito|basket|cart/i' if action=='add' else '/apply|aplicar|aplicar|validar|coupon|cupón|código/i'))
        if not result:
            raise ValueError('El control no es una operación permitida en la cesta temporal.')
        time.sleep(.6)

    def close(self):
        try:
            self.call('Target.disposeBrowserContext', {'browserContextId': self.context})
        finally:
            self.socket.close()


@contextlib.contextmanager
def probe(home, factory=Probe):
    instance = factory(home)
    try:
        yield instance
    finally:
        instance.close()


def _path(home):
    return Path(home) / '.alice' / 'purchase-evidence.json'


def _load(home):
    path = _path(home)
    return json.loads(path.read_text()) if path.exists() else {'searches': {}, 'quotes': {}}


def _save(home, data):
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(path)


def discover(home, session, args, *, factory=Probe, now=None):
    with probe(home, factory) as browser:
        browser.goto(args['url'])
        selector = args['selector']
        rows = browser.evaluate('''Array.from(document.querySelectorAll(%s)).map(e=>{const a=e.matches('a')?e:e.querySelector('a[href]');return {url:a?.href||(e.matches('h1')?location.href:null),title:e.innerText.trim()}}).filter(r=>r.url&&r.title)''' % json.dumps(selector))
    candidates = []
    seen = set()
    for row in rows or []:
        key = (row['url'], row['title'])
        if key in seen:
            continue
        https(row['url'])
        seen.add(key)
        candidates.append({'id': secrets.token_hex(8), **row})
    if not candidates:
        raise ValueError('No se encontraron formatos en esa página.')
    search = {'id': secrets.token_hex(8), 'session': session, 'at': now or time.time(),
              'source': args['url'], 'candidates': candidates, 'rejected': {}}
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['searches'][search['id']] = search
        _save(home, data)
    return search


def verify(home, session, args, *, factory=Probe, now=None):
    data = _load(home)
    search = data['searches'].get(args['search_id'])
    if not search or search['session'] != session:
        raise ValueError('La búsqueda no pertenece a este chat.')
    candidate = next((r for r in search['candidates'] if r['id'] == args['candidate_id']), None)
    if not candidate:
        raise ValueError('Ese formato no se encontró en la tienda.')
    qty = args.get('qty', 1)
    if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 20:
        raise ValueError('La cantidad debe estar entre 1 y 20.')
    if args.get('reject_reason'):
        recipe = args.get('recipe') or {}
        with probe(home,factory) as browser:
            browser.goto(candidate['url'])
            evidence = browser.read(recipe['unavailable']) if recipe.get('unavailable') else None
        import re
        if not evidence or not re.search(r'no disponible|sin stock|agotad|out of stock|sold out|unavailable|discontinued',evidence,re.I):
            raise ValueError('No descartes un formato sin una falta de disponibilidad comprobada en su ficha. Verifícalo antes de presentar opciones.')
        with module('purchase_flow')._locked(home):
            data = _load(home)
            data['searches'][search['id']]['rejected'][candidate['id']] = str(evidence)[:300]
            _save(home, data)
        return {'discarded': candidate['id'], 'why': args['reject_reason']}
    recipe = args['recipe']
    if not recipe.get('cart_quantity'):
        raise ValueError('Falta el selector de unidades comprobadas en la cesta.')
    with probe(home, factory) as browser:
        browser.goto(candidate['url'])
        title = browser.read(recipe['title'])
        variant = browser.read(recipe['variant']) if recipe.get('variant') else candidate['title']
        if not title or not variant:
            raise ValueError('El producto y la variante no son verificables.')
        if recipe.get('quantity'):
            browser.units(recipe['quantity'], qty)
        elif qty != 1:
            raise ValueError('Falta el selector de cantidad para revalidar.')
        browser.click(recipe['add'])
        inline_line = browser.read(recipe['line'])
        inline_cart = (inline_line and title.casefold() in inline_line.casefold() and variant.casefold() in inline_line.casefold()
            and browser.read(recipe['cart_quantity']) == str(qty)
            and browser.evaluate('(()=>{const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!e && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden"})()'))
        if recipe.get('cart_url') and not inline_cart:
            if urlsplit(recipe['cart_url']).netloc != urlsplit(candidate['url']).netloc:
                raise ValueError('La cesta no pertenece a esta tienda.')
            browser.goto(recipe['cart_url'])
        line = browser.read(recipe['line'])
        if not line or title.casefold() not in line.casefold() or variant.casefold() not in line.casefold():
            raise ValueError('El producto no aparece en la cesta temporal.')
        if not browser.evaluate('(()=>{const line=document.querySelector(' + json.dumps(recipe['line']) + ');const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!e && !!line && line.contains(e) && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden" && !e.closest("del,s,strike") && getComputedStyle(e).textDecorationLine!=="line-through"})()'):
            raise ValueError('El precio de la línea de cesta debe ser actual y visible; no sirve un importe oculto o tachado.')
        actual_qty = browser.read(recipe['cart_quantity'])
        if actual_qty != str(qty):
            raise ValueError('La cesta no confirmó la cantidad del formato.')
        amount = browser.read(recipe['price'])
        parsed = module('money').parse(amount, args['currency'])
        if not parsed:
            raise ValueError('La cesta no muestra un precio verificable en su moneda.')
        coupon_results = []
        best = parsed
        for code in args.get('coupons', [])[:5]:
            browser.coupon(recipe['coupon'], str(code))
            browser.click(recipe['apply'], action='coupon')
            current = module('money').parse(browser.read(recipe['price']), args['currency'])
            if not current:
                raise ValueError('El cupón dejó el precio sin comprobar.')
            coupon_results.append({'code':str(code), 'applied':current[0] < parsed[0], 'price':module('money').text(*current)})
            if current[0] < best[0]:
                best = current
        if coupon_results and current != best:
            best_code = next(r['code'] for r in coupon_results if module('money').parse(r['price'],args['currency']) == best)
            browser.coupon(recipe['coupon'], best_code)
            browser.click(recipe['apply'], action='coupon')
            if module('money').parse(browser.read(recipe['price']),args['currency']) != best:
                raise ValueError('El descuento público ya no se aplica.')
        parsed = best
        shipping = browser.read(recipe['shipping']) if recipe.get('shipping') else None
        condition = browser.read(recipe['condition']) if recipe.get('condition') else None
        quote = {'id': 'pq-' + secrets.token_hex(16), 'search_id': search['id'], 'candidate_id': candidate['id'],
                 'session': session, 'url': candidate['url'], 'title': title, 'variant': variant,
                 'qty': qty, 'price_cents': parsed[0], 'currency': parsed[1],
                 'price': module('money').text(*parsed), 'shipping': shipping, 'condition': condition,
                 'coupons':args.get('coupons',[])[:5], 'coupon_results':coupon_results,
                 'origin': module('errand_access').origin(candidate['url']), 'at': now or time.time(), 'recipe': recipe}
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['quotes'][quote['id']] = quote
        _save(home, data)
    return {k:v for k,v in quote.items() if k != 'recipe'}


def resolve(home, session, ref, *, qty=1, now=None, revalidate=False, factory=Probe):
    quote = _load(home)['quotes'].get(ref)
    if not quote or quote['session'] != session:
        raise ValueError('Falta una comprobación de cesta para esta oferta.')
    if revalidate or qty != quote['qty'] or (now or time.time()) - quote['at'] > TTL:
        return verify(home, session, {**quote, 'qty':qty}, now=now, factory=factory)
    return quote


def coverage(home, session, search_id, refs):
    data = _load(home)
    search = data['searches'].get(search_id)
    if not search or search['session'] != session:
        raise ValueError('Falta el registro de formatos encontrados.')
    shown = {data['quotes'][ref]['candidate_id'] for ref in refs if ref in data['quotes'] and data['quotes'][ref]['search_id'] == search_id}
    omitted = [r for r in search['candidates'] if r['id'] not in shown and r['id'] not in search['rejected']]
    if omitted:
        raise ValueError('Presenta o descarta con motivo estos formatos: ' + '; '.join(r['title'] for r in omitted))
    return search


def present(home, session, args, *, currency="", picture=None, request="", now=None, factory=Probe):
    raw = [o for o in args.get('options', []) if isinstance(o, dict)]
    if not raw:
        return {'ok': False, 'error': 'Busca y comprueba los formatos antes de mostrarlos.'}
    try:
        search = coverage(home, session, args.get('search_id'), [o.get('quote_ref') for o in raw])
        options = []
        candidates = set()
        for row in raw:
            quote = resolve(home, session, row.get('quote_ref'), now=now, factory=factory)
            if quote['candidate_id'] in candidates:
                raise ValueError('No repitas el mismo formato para completar las tarjetas.')
            candidates.add(quote['candidate_id'])
            options.append({**row, **{k: quote[k] for k in ('title','variant','qty','url','price','currency')},
                            'in_stock': True, 'channel':'browser', 'quote_ref': quote['id'],
                            'verified_at': quote['at'], 'shipping': quote['shipping'], 'condition': quote['condition']})
        result = module('purchase_flow').present(home, session, {'options':options}, currency=currency,
                                               picture=picture, request=request, now=now, exact_item=True)
        if result.get('ok'):
            # The quote, rather than any model-supplied price, remains the offer's authority.
            flow = module('purchase_flow')
            with flow._locked(home) as path:
                sets = flow._read(path)
                found = next(s for s in sets if s['key']==result['set'] and s['session']==session)
                for option in found['options']:
                    source = options[int(option['id'].rsplit('-',1)[1])-1]
                    option.update({k:source[k] for k in ('quote_ref','verified_at','shipping','condition')})
                original_key = flow.set_key(raw[:flow.MAX_OPTIONS])
                for option in found['options']:
                    option['id'] = original_key + '-' + option['id'].rsplit('-',1)[1]
                found['key'] = original_key
                result['set'] = original_key
                result['options'] = [{'id':o['id'],'title':o['title'],'price':o['price']} for o in found['options']]
                found['search_id'] = search['id']
                found['phase'] = 'verified_options'
                flow._write(path, sets)
            result['key'] = result['set']
        return result
    except (ValueError, KeyError, TypeError) as exc:
        return {'ok':False,'error':str(exc)}


def check_cart(home, errand_id, recipe, *, inspect=None, evaluate=None, now=None):
    """Read the errand's cart after its session/login changed; never mutate it."""
    access, errands = module('errand_access'), module('errands')
    entry = errands.get(home, errand_id)
    offer = (entry or {}).get('offer') or {}
    if not offer or not offer.get('quote_ref'):
        raise ValueError('Esta oferta antigua necesita una comprobación de precio antes de comprar.')
    page_origin, context, command = (inspect or access.target)(entry)
    if page_origin != access.origin(offer['url']):
        raise ValueError('La cesta no pertenece al origen de la opción elegida.')
    ev = evaluate or access.page_evaluate
    def read(selector):
        result = ev(context,'(()=>{let e;try{e=document.querySelector(' + json.dumps(selector) + ')}catch{return {invalid_selector:true}};return e ? String(e.value ?? e.innerText).trim() : null})()')
        if isinstance(result,dict) and result.get('invalid_selector'):
            raise ValueError('Usa selectores CSS de la página para line, price y cart_quantity, no nombres de producto, importes o cantidades. Lee los controles y vuelve a comprobar la cesta.')
        return result
    line = read(recipe['line'])
    if not line or offer['title'].casefold() not in line.casefold() or str(offer.get('variant') or '').casefold() not in line.casefold():
        raise ValueError('La cesta no contiene el formato elegido.')
    if read(recipe['cart_quantity']) != str(offer.get('qty',1)):
        raise ValueError('La cesta tiene otra cantidad. Corrígela antes de pedir aprobación.')
    if not ev(context,'(()=>{const line=document.querySelector(' + json.dumps(recipe['line']) + ');const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!line && !!e && line.contains(e) && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden" && !e.closest("del,s,strike") && getComputedStyle(e).textDecorationLine!=="line-through"})()'):
        raise ValueError('No hay un precio actual verificable de ese artículo en la cesta.')
    amount = module('money').parse(read(recipe['price']),offer['currency'])
    if not amount:
        raise ValueError('La cesta no tiene un precio verificable.')
    real = module('money').text(*amount)
    if not module('money').same(real,offer['price'],offer['currency']):
        errands.update(home,errand_id,status='stuck',blocked={'kind':'price','price':real},
                       reason='La cesta cobra ' + real + ' por el formato elegido, frente a ' + offer['price'] + '.')
        return {'ok':False,'price_changed':True,'old':offer['price'],'price':real,'next':'Termina el turno. La persona puede aceptar el cambio real desde su tarjeta.'}
    cookies = command('Storage.getCookies',{'browserContextId':context['context']}).get('cookies',[])
    session_hash = fingerprint(cookies,page_origin)
    errands.update(home,errand_id,cart_evidence={'origin':page_origin,'context':context['context'],'recipe':recipe,
        'qty':offer.get('qty',1),'price_cents':amount[0],'currency':amount[1], 'at':now or time.time(),'session':session_hash})
    return {'ok':True,'price':real,'qty':offer.get('qty',1),'next':'El precio sigue coincidiendo. Prepara el envío y el resumen final sin volver a pedir aceptar el mismo precio.'}


def fresh_cart(home, entry, *, inspect=None, now=None):
    evidence = entry.get('cart_evidence') or {}
    if not evidence or (now or time.time())-evidence.get('at',0) > TTL:
        return False
    access = module('errand_access')
    page_origin, context, command = (inspect or access.target)(entry)
    cookies = command('Storage.getCookies',{'browserContextId':context['context']}).get('cookies',[])
    session_hash = fingerprint(cookies,page_origin)
    return (context['context']==evidence['context'] and page_origin==evidence['origin'] and session_hash==evidence['session']
            and evidence['qty']==(entry.get('offer') or {}).get('qty',1)
            and module('money').parse((entry.get('offer') or {}).get('price'),evidence['currency']) == (evidence['price_cents'],evidence['currency']))


def checkout_amount(entry, selector, *, inspect=None, evaluate=None):
    access = module('errand_access')
    page_origin, context, _ = (inspect or access.target)(entry)
    if page_origin != access.origin(entry['offer']['url']):
        raise ValueError('El resumen no pertenece a la tienda elegida.')
    result = (evaluate or access.page_evaluate)(context,
        '(()=>{const e=document.querySelector(' + json.dumps(selector) + ');if(!e||!e.getClientRects().length||getComputedStyle(e).visibility==="hidden"||e.closest("del,s,strike"))return null;return e.innerText.trim()})()')
    amount = module('money').parse(result,entry['offer']['currency'])
    if not amount or amount[0] < module('money').parse(entry['offer']['price'],entry['offer']['currency'])[0] * entry['offer'].get('qty',1):
        raise ValueError('El total final no cubre los artículos comprobados.')
    return module('money').text(*amount)


def verify_remaining(home, session, args, *, factory=Probe):
    data = _load(home)
    search = data['searches'][args['search_id']]
    done = {q['candidate_id'] for q in data['quotes'].values() if q['search_id']==search['id']}
    done.update(search['rejected'])
    quotes, failures = [], []
    for candidate in search['candidates']:
        if candidate['id'] in done:
            continue
        try:
            quote = verify(home,session,{**args,'candidate_id':candidate['id'],'qty':1},factory=factory)
            quotes.append(quote)
        except Exception as exc:
            failures.append({'candidate_id':candidate['id'],'title':candidate['title'],
                             'why':str(exc) if isinstance(exc,ValueError) else 'No se pudo abrir la ficha en la cesta temporal.'})
    return {'other_formats':quotes,'unverified':failures}
