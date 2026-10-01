"""Price evidence captured by a restricted service in disposable cart contexts.

The model supplies DOM locators, never an accepted amount. This service has no
vault access and exposes no checkout, arbitrary script or payment operation.
"""
from __future__ import annotations
import contextlib
import hashlib
import json
import secrets
import re
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
# More formats than this on one search page is a broad search, not one product's formats.
BROAD = 8

def fingerprint(cookies, origin):
    host = urlsplit(origin).hostname
    cookies = [c for c in cookies if host == c.get('domain','').lstrip('.') or host.endswith('.' + c.get('domain','').lstrip('.'))]
    return hashlib.sha256(json.dumps(sorted([(c.get('name'),c.get('value'),c.get('domain'),c.get('path')) for c in cookies if re.search(r'sess|auth|cart|basket|token',c.get('name',''),re.I)]),sort_keys=True).encode()).hexdigest()


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
        # The browser Alice keeps may be closed (a restart, a crash): bring it up, as browsing does.
        if not endpoint and not module('browser_live').ensure(home):
            raise ValueError('El navegador de Alice no pudo arrancar; vuelve a intentarlo en un momento.')
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
        return self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');return e ? String(e.matches("input,select,textarea") ? e.value : e.innerText).trim() : null})()')

    def units(self, selector, qty):
        # Vue quantity counters are real controls, not editable inputs. Click
        # their observed +/- controls and read back every change; never set a
        # display node's value and mistake it for application state.
        counter = self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');return e?.matches(".item-qty") && !!e.closest(".quantity-picker-wrapper")})()')
        if counter:
            for _ in range(20):
                current = self.read(selector)
                if current == str(qty):
                    return
                if not current or not current.isdigit():
                    break
                direction = '.prz-plus' if int(current) < qty else '.prz-minus'
                clicked = self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');const b=e?.closest(".quantity-picker-wrapper")?.querySelector(' + json.dumps(direction) + ');if(!b || b.classList.contains("at-limit"))return false;b.click();return true})()')
                if not clicked:
                    break
                time.sleep(.15)
                if self.read(selector) == current:
                    break
            raise ValueError('No se pudo comprobar esa cantidad con los controles de la ficha.')
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
        if action == 'variant':
            selected = self.evaluate('(()=>{const e=document.querySelector(' + json.dumps(selector) + ');if(!e?.matches(".snap-slider-item") || !e.closest("#addToCartSection .option-slide-container") || !e.getClientRects().length)return false;e.click();return true})()')
            if not selected:
                raise ValueError('La variante no es un control observado de la ficha.')
            time.sleep(.2)
            return
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
    data = module('purchase_storage').read(_path(home), dict)
    data.setdefault('searches', {})
    data.setdefault('quotes', {})
    return data


def _save(home, data):
    at = time.time()
    active_refs = {e.get('offer', {}).get('quote_ref') for e in module('errands').listing(home) if e.get('offer') and e.get('status') in module('errands').ACTIVE + ('stuck',)}
    data['quotes'] = {k:v for k,v in data['quotes'].items() if k in active_refs or at-v.get('at',at) < 3*86400}
    referenced = {q.get('search_id') for q in data['quotes'].values()}
    data['searches'] = {k:v for k,v in data['searches'].items() if k in referenced or at-v.get('at',at) < 3*86400}
    module('purchase_storage').write(_path(home), data)


def discover(home, session, args, *, factory=Probe, now=None):
    prozis = module('purchase_prozis')
    selector = args['selector']
    if prozis.supports(args['url']) and 'creapure' in selector.lower():
        # A narrower second query must not silently drop the 320-caps format.
        selector = 'a[href*="creapure"]'
    with probe(home, factory) as browser:
        browser.goto(args['url'])
        rows = browser.evaluate('''Array.from(document.querySelectorAll(%s)).map(e=>{const a=e.matches('a')?e:e.querySelector('a[href]');return {url:a?.href||(e.matches('h1')?location.href:null),title:e.innerText.trim()}}).filter(r=>r.url&&r.title)''' % json.dumps(selector))
    if len(rows or []) > 100:
        raise ValueError('Acota la búsqueda o pagina los resultados: hay más de 100 candidatos en esta página.')
    candidates = []
    seen = set()
    stems = [str(w).casefold()[:6] for w in args.get('keywords') or [] if str(w).strip()]
    named = lambda row: all(s in (row['url'] + ' ' + row['title']).casefold() for s in stems)
    if stems and not any(named(row) for row in rows or []):
        raise ValueError('La búsqueda no contiene coincidencias comprobadas; reformula la consulta sin sustituir el producto.')
    for row in rows or []:
        lines = [line.strip() for line in row['title'].splitlines() if line.strip()]
        row['title'] = ' '.join(line for line in lines if not re.fullmatch(r'[€$£\d.,\s%]+',line))
        # A search page also lists bars, shakes and bundles: keep the rows that name every asked word.
        if stems and not named(row):
            continue
        key = row['url']
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
    try:
        return _verify(home, session, args, factory=factory, now=now)
    except ValueError as exc:
        if _note_failure(home, session, args, str(exc)):
            raise ValueError(str(exc) + ' Queda anotado como no comprobable: no lo reintentes más de una vez; '
                             'sigue con los demás formatos y di en una línea cuál no se pudo comprobar.') from exc
        raise


def _note_failure(home, session, args, why):
    """A format the service could not check is said as such, not a lock on every other option."""
    if args.get('reject_reason') or not args.get('search_id') or args.get('quote_ref') or args.get('id', '').startswith('pq-'):
        return False
    with module('purchase_flow')._locked(home):
        data = _load(home)
        search = data['searches'].get(args['search_id'])
        if search and search['session'] == session and any(r['id'] == args.get('candidate_id') for r in search['candidates']):
            search.setdefault('failed', {})[args['candidate_id']] = why[:300]
            _save(home, data)
            return True
    return False


def _verify(home, session, args, *, factory=Probe, now=None):
    data = _load(home)
    search = data['searches'].get(args['search_id'])
    if not search or search['session'] != session:
        raise ValueError('La búsqueda no pertenece a este chat.')
    candidate = next((r for r in search['candidates'] if r['id'] == args['candidate_id']), None)
    if not candidate:
        raise ValueError('Ese formato no se encontró en la tienda.')
    qty = args.get('qty', 1)
    if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 999:
        raise ValueError('La cantidad debe estar entre 1 y 999.')
    if args.get('reject_reason'):
        recipe = args.get('recipe') or {}
        with probe(home,factory) as browser:
            browser.goto(candidate['url'])
            evidence = browser.read(recipe['unavailable']) if recipe.get('unavailable') else None
        if not evidence or not re.search(r'no disponible|sin stock|agotad|out of stock|sold out|unavailable|discontinued',evidence,re.I):
            raise ValueError('No descartes un formato sin una falta de disponibilidad comprobada en su ficha. Verifícalo antes de presentar opciones.')
        with module('purchase_flow')._locked(home):
            data = _load(home)
            data['searches'][search['id']]['rejected'][candidate['id']] = str(evidence)[:300]
            _save(home, data)
        return {'discarded': candidate['id'], 'why': args['reject_reason']}
    recipe = dict(args.get('recipe') or {})
    prozis = module('purchase_prozis')
    adapted = prozis.supports(candidate['url'])
    with probe(home, factory) as browser:
        browser.goto(candidate['url'])
        if adapted:
            recipe = prozis.product_recipe(browser, recipe)
        else:
            if recipe.get('price_basis', 'unit') not in ('unit', 'line_total'):
                raise ValueError('Indica la base del precio: unit o line_total.')
        if not recipe.get('cart_quantity'):
            raise ValueError('Falta el selector de unidades comprobadas en la cesta.')
        title = browser.read(recipe['title'])
        variant = browser.read(recipe['variant']) if recipe.get('variant') else candidate['title']
        if adapted and recipe.get('package_variant') and variant:
            variant = re.sub(r'^.*?(?=\d)', '', variant)
        if not title or not variant:
            raise ValueError('El producto y la variante no son verificables.')
        if recipe.get('quantity'):
            browser.units(recipe['quantity'], qty)
        elif qty != 1:
            raise ValueError('Falta el selector de cantidad para revalidar.')
        browser.click(recipe['add'])
        if adapted:
            prozis.wait_added(browser, title, variant, qty)
        inline_line = browser.read(recipe['line'])
        inline_cart = (inline_line and title.casefold() in inline_line.casefold() and variant.casefold() in inline_line.casefold()
            and browser.read(recipe['cart_quantity']) == str(qty)
            and browser.evaluate('(()=>{const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!e && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden"})()'))
        if recipe.get('cart_url') and (adapted or not inline_cart):
            if urlsplit(recipe['cart_url']).netloc != urlsplit(candidate['url']).netloc:
                raise ValueError('La cesta no pertenece a esta tienda.')
            browser.goto(recipe['cart_url'])
        if adapted:
            prozis.wait_read(browser, recipe['line'])
        line = browser.read(recipe['line'])
        if not line or title.casefold() not in line.casefold() or variant.casefold() not in line.casefold():
            raise ValueError('El producto no aparece en la cesta temporal: ' + title + ' / ' + variant + '. Línea observada: ' + str(line or '')[:300])
        if not browser.evaluate('(()=>{const line=document.querySelector(' + json.dumps(recipe['line']) + ');const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!e && !!line && line.contains(e) && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden" && !e.closest("del,s,strike") && getComputedStyle(e).textDecorationLine!=="line-through"})()'):
            raise ValueError('El precio de la línea de cesta debe ser actual y visible; no sirve un importe oculto o tachado.')
        actual_qty = browser.read(recipe['cart_quantity'])
        if actual_qty != str(qty):
            raise ValueError('La cesta no confirmó la cantidad del formato.')
        amount = browser.read(recipe['price'])
        parsed = cart_amount(amount, args['currency'], qty, recipe)
        if not parsed:
            raise ValueError('La cesta no muestra un precio verificable en su moneda.')
        coupon_results = []
        best = parsed
        base_line = module('money').parse(amount,args['currency'])[0]
        best_line = base_line
        best_code = ''
        codes = list(dict.fromkeys((args.get('coupons') or []) + recipe.get('public_codes', [])))[:5]
        for code in codes:
            browser.coupon(recipe['coupon'], str(code))
            browser.click(recipe['apply'], action='coupon')
            if adapted:
                time.sleep(1.5)
            current = cart_amount(browser.read(recipe['price']), args['currency'], qty, recipe)
            if not current:
                raise ValueError('El cupón dejó el precio sin comprobar.')
            current_line=module('money').parse(browser.read(recipe['price']),args['currency'])[0]
            coupon_results.append({'code':str(code), 'applied':current_line < base_line, 'price':module('money').text(*current)})
            if current_line < best_line:
                best_line = current_line
                best = current
                best_code = str(code)
        if coupon_results and current_line != best_line:
            # Empty code restores the undiscounted cart if no coupon improves it.
            browser.coupon(recipe['coupon'], best_code)
            browser.click(recipe['apply'], action='coupon')
            if module('money').parse(browser.read(recipe['price']),args['currency'])[0] != best_line:
                raise ValueError('El descuento público ya no se aplica.')
        parsed = best
        line_cents = module('money').parse(browser.read(recipe['price']), args['currency'])[0]
        if recipe.get('price_basis') != 'line_total':
            line_cents *= qty
        shipping = browser.read(recipe['shipping']) if recipe.get('shipping') else None
        condition = browser.read(recipe['condition']) if recipe.get('condition') else None
        if adapted and browser.evaluate('Array.from(document.querySelectorAll("input[type=email]")).some(e=>e.getClientRects().length>0)'):
            condition = 'El descuento anunciado requiere iniciar sesión; no se ha aplicado a esta cesta. El precio mostrado es el comprobado sin ese descuento.'
        quote = {'id': 'pq-' + secrets.token_hex(16), 'search_id': search['id'], 'candidate_id': candidate['id'],
                 'session': session, 'url': candidate['url'], 'title': title, 'variant': variant,
                 'qty': qty, 'price_cents': parsed[0], 'currency': parsed[1],
                 'price': module('money').text(*parsed), 'shipping': shipping, 'condition': condition,
                 'coupons':codes, 'coupon_results':coupon_results, 'coupon_code':best_code,
                 'line_cents':line_cents, 'product_identity': {'url':candidate['url'], 'variant':variant},
                 'origin': module('errand_access').origin(candidate['url']), 'at': now or time.time(), 'recipe': recipe}
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['quotes'][quote['id']] = quote
        _save(home, data)
    return {k:v for k,v in quote.items() if k != 'recipe'}


def cart_amount(text, currency, qty, recipe):
    amount = module('money').parse(text, currency)
    if amount and recipe.get('price_basis') == 'line_total':
        amount = ((amount[0] + qty // 2) // qty, amount[1])
    return amount


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
    omitted = [r for r in search['candidates'] if r['id'] not in shown and r['id'] not in search['rejected']
               and r['id'] not in search.get('failed', {})]
    if omitted:
        raise ValueError('Presenta o descarta con motivo estos formatos: ' + '; '.join(r['title'] for r in omitted))
    return search


def present(home, session, args, *, currency="", picture=None, request="", now=None, factory=Probe):
    raw = [o for o in args.get('options', []) if isinstance(o, dict)]
    if not raw:
        return {'ok': False, 'error': 'Busca y comprueba los formatos antes de mostrarlos.'}
    try:
        search_ids = args.get('search_ids') or [args.get('search_id')]
        searches = [coverage(home,session,sid,[o.get('quote_ref') for o in raw]) for sid in search_ids]
        search = searches[0]
        options = []
        candidates = set()
        for row in raw:
            quote = resolve(home, session, row.get('quote_ref'), now=now, factory=factory)
            if quote['search_id'] not in {s['id'] for s in searches}:
                raise ValueError('La oferta pertenece a otra búsqueda; presenta cada inventario con su propia cobertura.')
            if quote['candidate_id'] in candidates:
                raise ValueError('No repitas el mismo formato para completar las tarjetas.')
            candidates.add(quote['candidate_id'])
            options.append({**row, **{k: quote[k] for k in ('title','variant','qty','url','price','currency')},
                            'in_stock': True, 'channel':'browser', 'quote_ref': quote['id'],
                            'verified_at': quote['at'], 'shipping': quote['shipping'], 'condition': quote['condition'],
                            **{k:quote.get(k) for k in ('line_cents','recipe','coupon_code','product_identity')}})
        intent = module('purchase_intent').current(home,session)
        rejected = [o for o in options if not module('purchase_intent').accepts(intent,o)]
        if rejected:
            raise ValueError('Estas ofertas incumplen la petición vigente: '+ '; '.join(o['title'] for o in rejected))
        result = module('purchase_flow').present(home, session, {'options':options, 'set_key':module('purchase_flow').set_key(raw[:module('purchase_flow').MAX_OPTIONS])}, currency=currency,
                                               picture=picture, request=request, now=now, exact_item=True)
        if result.get('ok'):
            # The quote, rather than any model-supplied price, remains the offer's authority.
            flow = module('purchase_flow')
            with flow._locked(home) as path:
                sets = flow._read(path)
                found = next(s for s in sets if s['key']==result['set'] and s['session']==session)
                for option in found['options']:
                    source = options[int(option['id'].rsplit('-',1)[1])-1]
                    option.update({k:source[k] for k in ('quote_ref','verified_at','shipping','condition','line_cents','recipe','coupon_code','product_identity')})
                found['search_id'] = search['id']
                found['search_ids'] = [s['id'] for s in searches]
                found['request_revision'] = (intent or {}).get('revision')
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
    if module('purchase_prozis').supports(offer['url']):
        recipe = module('purchase_prozis').cart_recipe(lambda code: ev(context, code))
    else:
        recipe = dict(recipe)
    def read(selector):
        result = ev(context,'(()=>{let e;try{e=document.querySelector(' + json.dumps(selector) + ')}catch{return {invalid_selector:true}};return e ? String(e.matches("input,select,textarea") ? e.value : e.innerText).trim() : null})()')
        if isinstance(result,dict) and result.get('invalid_selector'):
            raise ValueError('Usa selectores CSS de la página para line, price y cart_quantity, no nombres de producto, importes o cantidades. Lee los controles y vuelve a comprobar la cesta.')
        return result
    inventory = ev(context,'Array.from(document.querySelectorAll(' + json.dumps(recipe.get('all_lines') or recipe['line']) + ')).filter(e=>e.getClientRects().length>0).length')
    if inventory != 1:
        raise ValueError('La cesta contiene artículos adicionales; retira los sobrantes y vuelve a comprobarla.')
    line = read(recipe['line'])
    if not line or offer['title'].casefold() not in line.casefold() or str(offer.get('variant') or '').casefold() not in line.casefold():
        raise ValueError('La cesta no contiene el formato elegido.')
    if read(recipe['cart_quantity']) != str(offer.get('qty',1)):
        browser = module('purchase_controller').PinnedCart(home,entry,inspect=inspect,evaluate=evaluate)
        browser.units(recipe['cart_quantity'],offer.get('qty',1))
        if read(recipe['cart_quantity']) != str(offer.get('qty',1)):
            raise ValueError('No se pudo corregir la cantidad mediante el control de la cesta.')
    if not ev(context,'(()=>{const line=document.querySelector(' + json.dumps(recipe['line']) + ');const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!line && !!e && line.contains(e) && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden" && !e.closest("del,s,strike") && getComputedStyle(e).textDecorationLine!=="line-through"})()'):
        raise ValueError('No hay un precio actual verificable de ese artículo en la cesta.')
    line_amount = module('money').parse(read(recipe['price']),offer['currency'])
    amount = cart_amount(read(recipe['price']),offer['currency'],offer.get('qty',1),recipe)
    if not amount:
        raise ValueError('La cesta no tiene un precio verificable.')
    line_cents = line_amount[0] if recipe.get('price_basis') == 'line_total' else line_amount[0]*offer.get('qty',1)
    real = module('money').text(*amount)
    note = 'El precio sigue coincidiendo. Prepara el envío y el resumen final sin volver a pedir aceptar el mismo precio.'
    old_price = module('money').parse(offer['price'], offer['currency'])
    if old_price and amount[0] < old_price[0]:
        # Cheaper in the basket (a member discount after login): the person's choice only got
        # better, and the final total is approved before paying anyway.
        errands.update(home, errand_id, offer={**offer, 'price': real, 'line_cents':line_cents})
        note = ('La cesta cobra ' + real + ', menos que los ' + offer['price'] + ' elegidos: sigue con ese precio '
                'sin preguntar y menciónalo en el resumen final.')
    elif not module('money').same(real,offer['price'],offer['currency']):
        errands.update(home,errand_id,status='stuck',blocked={'kind':'price','price':real},
                       reason='La cesta cobra ' + real + ' por el formato elegido, frente a ' + offer['price'] + '.')
        return {'ok':False,'price_changed':True,'old':offer['price'],'price':real,'next':'Termina el turno. La persona puede aceptar el cambio real desde su tarjeta.'}
    cookies = command('Storage.getCookies',{'browserContextId':context['context']}).get('cookies',[])
    session_hash = fingerprint(cookies,page_origin)
    errands.update(home,errand_id,cart_evidence={'origin':page_origin,'context':context['context'],'recipe':recipe,
        'qty':offer.get('qty',1),'line_cents':line_cents,'price_cents':amount[0],'currency':amount[1], 'at':now or time.time(),'session':session_hash})
    return {'ok':True,'price':real,'qty':offer.get('qty',1),'next':note}


def fresh_cart(home, entry, *, inspect=None, evaluate=None, now=None):
    evidence = entry.get('cart_evidence') or {}
    if not evidence or (now or time.time())-evidence.get('at',0) > TTL:
        return False
    access = module('errand_access')
    page_origin, context, command = (inspect or access.target)(entry)
    cookies = command('Storage.getCookies',{'browserContextId':context['context']}).get('cookies',[])
    session_hash = fingerprint(cookies,page_origin)
    ev = evaluate or access.page_evaluate
    recipe = evidence.get('recipe') or {}
    current = ev(context,'(()=>{const s=' + json.dumps(recipe) + ';const all=Array.from(document.querySelectorAll(s.all_lines||s.line));const e=document.querySelector(s.cart_quantity),p=document.querySelector(s.price),line=document.querySelector(s.line);return {count:all.length,qty:e?String(e.matches("input,select")?e.value:e.innerText).trim():null,price:p?.innerText.trim(),line:line?.innerText.trim()}})()')
    offer = entry.get('offer') or {}
    if (not isinstance(current,dict) or current.get('count')!=1 or current.get('qty')!=str(evidence['qty'])
        or offer.get('title','').casefold() not in str(current.get('line') or '').casefold()
        or str(offer.get('variant') or '').casefold() not in str(current.get('line') or '').casefold()
        or cart_amount(current.get('price'),evidence['currency'],evidence['qty'],recipe)!=(evidence['price_cents'],evidence['currency'])):
        return False
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


def payment_ready(home, entry, *, inspect=None, evaluate=None):
    return module('purchase_controller').ready(home,entry,inspect=inspect,evaluate=evaluate)


def verify_remaining(home, session, args, *, factory=Probe):
    data = _load(home)
    search = data['searches'][args['search_id']]
    done = {q['candidate_id'] for q in data['quotes'].values() if q['search_id']==search['id']}
    done.update(search['rejected'])
    done.update(search.get('failed', {}))
    quotes, failures = [], []
    deadline = time.monotonic() + 45
    for candidate in search['candidates']:
        if candidate['id'] in done:
            continue
        if time.monotonic() >= deadline or len(quotes) + len(failures) >= 8:
            break  # Checkpoint: a subsequent tool call resumes remaining candidates.
        if urlsplit(candidate['url']).netloc != urlsplit(args.get('url') or search['source']).netloc:
            continue
        try:
            quote = verify(home,session,{**args,'candidate_id':candidate['id'],'qty':args.get('qty',1)},factory=factory)
            quotes.append(quote)
        except Exception as exc:
            failures.append({'candidate_id':candidate['id'],'title':candidate['title'],
                             'why':str(exc) if isinstance(exc,ValueError) else 'No se pudo abrir la ficha en la cesta temporal.'})
    return {'other_formats':quotes,'unverified':failures}
