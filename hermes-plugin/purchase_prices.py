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
# The errand's own cart check is good for this long: every later step re-reads the amount on the
# page (checkout_request, the pay click), so the cart evidence only has to be recent, not fresh.
CART_TTL = 60 * 60
# More formats than this on one search page is a broad search, not one product's formats.
BROAD = 8
# Checking the remaining formats inside one tool call stops after this long; the rest is said.
REMAINING_BUDGET = 90

def fingerprint(cookies, origin):
    """The shop's own session cookie(s), not every cookie: analytics, CSRF and bot cookies change on
    every page and made the cart look like another session between the basket and the pay step."""
    host = urlsplit(origin).hostname
    cookies = [c for c in cookies if host == c.get('domain','').lstrip('.') or host.endswith('.' + c.get('domain','').lstrip('.'))]
    names = sorted(c.get('name','') for c in cookies if re.search(r'sess|sid|cart|basket|customer|token', c.get('name',''), re.I))
    return hashlib.sha256(json.dumps(names).encode()).hexdigest()


def _norm(text):
    """Shop text as it compares: no accents, one case, no punctuation, «500 g» and «500g» alike."""
    import unicodedata
    text = unicodedata.normalize('NFKD', str(text or ''))
    text = ''.join(c for c in text if not unicodedata.combining(c)).casefold()
    text = re.sub(r'(\d)\s+(?=(g|gr|kg|ml|l|cl|caps|capsulas|cápsulas|comprimidos|tabs|uds?|unidades)\b)', r'\1', text)
    return re.sub(r'[^0-9a-z]+', ' ', text).strip()


def names(line, *parts):
    """Whether a cart line names the product (and variant): every significant word of each part, in
    any order, after normalising. Listing titles and cart lines rarely match character for character."""
    line = _norm(line)
    for part in parts:
        words = [w for w in _norm(part).split() if len(w) > 1 or w.isdigit()]
        if words and not all(w in line.split() or w in line for w in words):
            return False
    return True


def same_site(a, b):
    """One shop with or without «www.»."""
    host = lambda u: (urlsplit(u).hostname or '').lower().removeprefix('www.')
    return host(a) == host(b)


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
        self.target = self.call('Target.createTarget', {'url': 'about:blank', 'browserContextId': self.context, 'background': True})['targetId']
        self.session = self.call('Target.attachToTarget', {'targetId': self.target, 'flatten': True})['sessionId']
        self.call('Page.enable', page=True)
        self.call('Emulation.setFocusEmulationEnabled', {'enabled': True}, page=True)

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
                if not same_site(current, url):
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
    path = _path(home)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (OSError, ValueError):
        # An unreadable file is set aside, not trusted and not overwritten: prices are checked again.
        try:
            path.rename(path.with_name(path.name + f'.corrupt-{int(time.time())}'))
        except OSError:
            pass
        data = {}
    if not isinstance(data, dict) or not isinstance(data.get('searches'), dict) or not isinstance(data.get('quotes'), dict):
        data = {'searches': {}, 'quotes': {}}
    data.setdefault('schema', 1)
    return data


EVIDENCE_DAYS = 30
EVIDENCE_MAX = 400


def _prune(data, now=None):
    """Searches and quotes older than a month, or past the newest few hundred, are dropped: nothing
    checks a price that old, and the file only grew (half a megabyte after a week)."""
    now = now or time.time()
    cutoff = now - EVIDENCE_DAYS * 86400
    for key in ('searches', 'quotes'):
        rows = data.get(key) or {}
        kept = sorted(((k, v) for k, v in rows.items()
                       if isinstance(v, dict) and float(v.get('at') or 0) >= cutoff),
                      key=lambda kv: float(kv[1].get('at') or 0))[-EVIDENCE_MAX:]
        data[key] = dict(kept)
    return data


def _save(home, data):
    data = _prune(data)
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(path)


def discover(home, session, args, *, factory=Probe, now=None):
    prozis = module('purchase_prozis')
    selector = str(args.get('selector') or '')
    source = str(args.get('url') or '')
    if not selector or not source:
        # The engine: the shop's own search (platform endpoint, search form, usual addresses) or the
        # listing page given, read for product links without a selector from the model.
        engine = module('shop_engine')
        shop, query = str(args.get('shop') or source or ''), str(args.get('query') or '')
        if not shop:
            raise ValueError('Di la tienda (dominio o dirección) y qué buscar.')
        with probe(home, factory) as browser:
            page = engine.Page.of(browser)
            if query:
                found = engine.search(page, shop, query)
                rows, source = found['links'], found['url']
            else:
                browser.goto(shop)
                engine.dismiss_cookies(page)
                rows, source = engine.product_links(page), shop
                if not rows and engine.product(page):
                    rows = [{'url': page.url or shop, 'title': (engine.product(page) or {}).get('name') or ''}]
        args = {**args, 'url': source}
        rows = [{'url': r['url'], 'title': r['title']} for r in rows if r.get('url') and r.get('title')]
        return _record_search(home, session, args, rows, now)
    if prozis.supports(source) and 'creapure' in selector.lower():
        # A narrower second query must not silently drop the 320-caps format.
        selector = 'a[href*="creapure"]'
    with probe(home, factory) as browser:
        browser.goto(source)
        rows = browser.evaluate('''Array.from(document.querySelectorAll(%s)).map(e=>{const a=e.matches('a')?e:e.querySelector('a[href]');return {url:a?.href||(e.matches('h1')?location.href:null),title:e.innerText.trim()}}).filter(r=>r.url&&r.title)''' % json.dumps(selector))
    return _record_search(home, session, args, rows, now)


def _record_search(home, session, args, rows, now):
    candidates = []
    seen = set()
    stems = [str(w).casefold()[:6] for w in args.get('keywords') or [] if str(w).strip()]
    named = lambda row: all(s in (row['url'] + ' ' + row['title']).casefold() for s in stems)
    if stems and not any(named(row) for row in rows or []):
        stems = []  # titles in another language («Peanut Butter»): the shop's search already chose
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
    if args.get('query'):
        search['query'] = str(args['query'])[:120]
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['searches'][search['id']] = search
        _save(home, data)
    return search


def verify(home, session, args, *, factory=Probe, now=None):
    try:
        return _verify_recipe(home, session, args, factory=factory, now=now)
    except ValueError as exc:
        # Legacy selector recipes cannot veto the generic page/cart reader for any shop.
        if str(exc) != 'La cesta no muestra un precio verificable en su moneda.':
            raise
        search = _load(home)['searches'].get(args.get('search_id')) or {}
        candidate = next((c for c in search.get('candidates', []) if c['id'] == args.get('candidate_id')), None)
        if not candidate:
            raise
        return _verify_engine(home, session, args, search, candidate, args.get('qty', 1), factory=factory, now=now)


def _verify_recipe(home, session, args, *, factory=Probe, now=None):
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
    if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 20:
        raise ValueError('La cantidad debe estar entre 1 y 20.')
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
    if adapted or recipe.get('engine') or not all(recipe.get(k) for k in ('title', 'add', 'line', 'price', 'cart_quantity')):
        return _verify_engine(home, session, args, search, candidate, qty, factory=factory, now=now)
    with probe(home, factory) as browser:
        browser.goto(candidate['url'])
        if adapted:
            recipe = prozis.product_recipe(browser, recipe)
        else:
            recipe.pop('price_basis', None)
        coupon_blocks = product_coupon_blocks(browser)
        if not recipe.get('cart_quantity'):
            raise ValueError('Falta el selector de unidades comprobadas en la cesta.')
        title = browser.read(recipe['title'])
        # Without a variant control the page has one format: the listing's own words are not a
        # second thing the cart line must spell out letter by letter.
        variant = browser.read(recipe['variant']) if recipe.get('variant') else ''
        if adapted and recipe.get('package_variant') and variant:
            variant = re.sub(r'^.*?(?=\d)', '', variant)
        if not title or (recipe.get('variant') and not variant):
            raise ValueError('El producto y la variante no son verificables (selectores ' + recipe['title'] + ' / ' + str(recipe.get('variant')) + ').')
        variant = variant or ''
        if recipe.get('quantity'):
            browser.units(recipe['quantity'], qty)
        elif qty != 1:
            raise ValueError('Falta el selector de cantidad para revalidar.')
        browser.click(recipe['add'])
        if adapted:
            prozis.wait_added(browser, title, variant, qty)
        inline_line = browser.read(recipe['line'])
        inline_cart = (inline_line and names(inline_line, title, variant if recipe.get('variant') else '')
            and browser.read(recipe['cart_quantity']) == str(qty)
            and browser.evaluate('(()=>{const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!e && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden"})()'))
        if recipe.get('cart_url') and (adapted or not inline_cart):
            if urlsplit(recipe['cart_url']).netloc != urlsplit(candidate['url']).netloc:
                raise ValueError('La cesta no pertenece a esta tienda.')
            browser.goto(recipe['cart_url'])
        if adapted:
            prozis.wait_read(browser, recipe['line'])
        line = browser.read(recipe['line'])
        if not line or not names(line, title, variant if recipe.get('variant') else ''):
            raise ValueError('El producto no aparece en la cesta temporal (selector ' + recipe['line'] + '): ' + title + ' / ' + variant + '. Línea observada: ' + str(line or '')[:300])
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
        best = current = parsed
        codes = list(dict.fromkeys((args.get('coupons') or []) + recipe.get('public_codes', []) + module('purchase_promotions').public_codes(coupon_blocks)))[:5]
        advertised_codes = list(codes)
        if codes and not (recipe.get('coupon') and recipe.get('apply')):
            coupon_results = [{'code': str(c), 'applied': False, 'price': module('money').text(*parsed),
                               'why': 'sin campo de descuento observado en la cesta'} for c in codes]
            codes = []
        for code in codes:
            browser.coupon(recipe['coupon'], str(code))
            browser.click(recipe['apply'], action='coupon')
            if adapted:
                time.sleep(1.5)
            current = cart_amount(browser.read(recipe['price']), args['currency'], qty, recipe)
            if not current:
                raise ValueError('El cupón dejó el precio sin comprobar.')
            coupon_results.append({'code':str(code), 'applied':current[0] < parsed[0], 'price':module('money').text(*current)})
            if current[0] < best[0]:
                best = current
        if coupon_results and current != best:
            best_code = next(r['code'] for r in coupon_results if module('money').parse(r['price'],args['currency']) == best)
            browser.coupon(recipe['coupon'], best_code)
            browser.click(recipe['apply'], action='coupon')
            if cart_amount(browser.read(recipe['price']),args['currency'],qty,recipe) != best:
                raise ValueError('El descuento público ya no se aplica.')
        parsed = best
        # The public code the quoted price rests on, if any: the errand applies it in its own basket.
        applied_code = next((r['code'] for r in coupon_results if r['applied']
                             and module('money').parse(r['price'], args['currency']) == best), '')
        shipping = browser.read(recipe['shipping']) if recipe.get('shipping') else None
        condition = browser.read(recipe['condition']) if recipe.get('condition') else None
        if (adapted and recipe.get('public_codes') and not any(r['applied'] for r in coupon_results)
                and browser.evaluate('Array.from(document.querySelectorAll("input[type=email]")).some(e=>e.getClientRects().length>0)')):
            condition = 'Cupón ' + ', '.join(codes) + ': requiere iniciar sesión. No se ha aplicado. Su precio con descuento se comprobará en tu cesta antes de pagar.'
        promotion_fields = module('purchase_promotions').fields(coupon_blocks, advertised_codes, parsed[0], parsed[1], applied=bool(applied_code))
        if promotion_fields:
            condition = ' '.join(filter(None, [condition, promotion_fields.pop('promotion_condition')]))
        quote = {'id': 'pq-' + secrets.token_hex(16), 'search_id': search['id'], 'candidate_id': candidate['id'],
                 'session': session, 'url': candidate['url'], 'title': title, 'variant': variant,
                 'qty': qty, 'price_cents': parsed[0], 'currency': parsed[1],
                 'price': module('money').text(*parsed), 'shipping': shipping, 'condition': condition,
                 'coupons':codes, 'coupon_results':coupon_results, 'coupon': applied_code,
                 'origin': module('errand_access').origin(candidate['url']), 'at': now or time.time(), 'recipe': recipe,
                 **promotion_fields}
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['quotes'][quote['id']] = quote
        _save(home, data)
    return {k:v for k,v in quote.items() if k != 'recipe'}


PAGE_BASIS = ('Precio de la ficha: la cesta de prueba no se pudo leer en esta tienda. El recado lo confirma en '
              'su cesta antes de pedirte aprobación.')


def _verify_engine(home, session, args, search, candidate, qty, *, factory=Probe, now=None):
    """Any shop: the engine opens the product, picks the variant, puts the units in a disposable
    basket and reads the line (shop_engine.quote). When no basket can be read, the page's own price
    is the quote, said as such; the errand confirms it in its basket before any approval."""
    engine = module('shop_engine')
    money = module('money')
    variant = str(args.get('variant') or '')
    with probe(home, factory) as browser:
        read = engine.quote(engine.Page.of(browser), candidate['url'], variant=variant, qty=qty,
                            currency=str(args.get('currency') or ''), coupons=list(args.get('coupons') or []),
                            title_hint=candidate.get('title') or '')
    currency = (read.get('currency') or str(args.get('currency') or '')).upper()
    if read.get('price_cents') is None or not currency:
        raise ValueError('No se pudo leer un precio en su moneda: ' + str(read.get('unverified') or candidate['title']))
    if args.get('currency') and currency != str(args['currency']).upper():
        raise ValueError('La tienda cobra en ' + currency + ', no en ' + str(args['currency']).upper() + '.')
    basis = read.get('basis') or 'page'
    quote = {'id': 'pq-' + secrets.token_hex(16), 'search_id': search['id'], 'candidate_id': candidate['id'],
             'session': session, 'url': candidate['url'], 'title': read['title'], 'variant': read.get('variant') or '',
             'qty': qty, 'price_cents': int(read['price_cents']), 'currency': currency,
             'price': money.text(int(read['price_cents']), currency), 'shipping': None,
             'condition': PAGE_BASIS if basis == 'page' else None, 'basis': basis,
             'coupons': [r['code'] for r in read.get('coupon_results') or []],
             'coupon_results': read.get('coupon_results') or [], 'coupon': read.get('coupon') or '',
             'origin': module('errand_access').origin(candidate['url']), 'at': now or time.time(),
             'recipe': {'engine': read.get('how') or {}, 'platform': read.get('platform') or ''},
             'catalog_id': read.get('catalog_id') or '',
             'image': read.get('image') or '',
             **{k: read.get(k) or '' for k in ('price_note','promotional_price','promotion_code')}}
    if read.get('promotion_condition'):
        quote['condition'] = ' '.join(filter(None, [quote['condition'], read['promotion_condition']]))
    with module('purchase_flow')._locked(home):
        data = _load(home)
        data['quotes'][quote['id']] = quote
        _save(home, data)
    return {k: v for k, v in quote.items() if k != 'recipe'}


def cart_amount(text, currency, qty, recipe):
    amount = module('money').parse(text, currency)
    if amount and recipe.get('price_basis') == 'line_total':
        if amount[0] % qty:
            raise ValueError('El total de la línea no permite comprobar el precio por unidad en céntimos.')
        amount = (amount[0] // qty, amount[1])
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
    if len(search['candidates']) > BROAD:
        return search  # a broad search: the agent narrows it or shows the best, not every listing
    omitted = [r for r in search['candidates'] if r['id'] not in shown and r['id'] not in search['rejected']
               and r['id'] not in search.get('failed', {})]
    if omitted:
        raise ValueError('Presenta o descarta con motivo estos formatos: ' + '; '.join(r['title'] for r in omitted))
    return search


def _quotes_of(data, session, search_id):
    """The newest quote per format of a search, in the order the shop listed them."""
    search = data['searches'].get(search_id)
    if not search or search['session'] != session:
        return None, []
    newest = {}
    for quote in data['quotes'].values():
        if quote['search_id'] == search_id and quote['session'] == session:
            if quote['candidate_id'] not in newest or quote['at'] > newest[quote['candidate_id']]['at']:
                newest[quote['candidate_id']] = quote
    return search, [newest[c['id']] for c in search['candidates'] if c['id'] in newest]


def advertised_coupon_price(blocks, codes, base_cents, currency):
    return module('purchase_promotions').advertised_coupon_price(blocks, codes, base_cents, currency)


def product_coupon_blocks(browser):
    return module('purchase_promotions').product_coupon_blocks(browser)


def _row(quote):
    host = (urlsplit(quote['url']).hostname or '').removeprefix('www.')
    return {**{k: quote[k] for k in ('title','variant','qty','url','price','currency')},
            'merchant': host.split('.')[0].capitalize() if host else '', 'in_stock': True, 'channel': 'browser',
            'quote_ref': quote['id'], 'verified_at': quote['at'], 'shipping': quote['shipping'],
            'condition': quote['condition'], 'coupon': quote.get('coupon') or '',
            'image': quote.get('image') or '', 'price_note': quote.get('price_note') or '',
            'promotional_price': quote.get('promotional_price') or '', 'promotion_code': quote.get('promotion_code') or ''}


def auto_present(home, session, search_id, *, currency="", picture=None, request="", now=None):
    """The cards, from the evidence alone: once every format of a search is quoted, rejected or
    noted as uncheckable, the plugin shows them itself. Whether the model then calls
    `purchase_options` (to mark its recommendation) or only writes about them, the person has
    cards to tap. Shown once per search; None while formats are still unchecked."""
    data = _load(home)
    search, quotes = _quotes_of(data, session, search_id)
    if not search or not quotes:
        return None
    done = {q['candidate_id'] for q in quotes} | set(search['rejected']) | set(search.get('failed', {}))
    if len(search['candidates']) <= BROAD and any(c['id'] not in done for c in search['candidates']):
        return None
    flow = module('purchase_flow')
    for existing in flow._read(flow._path(home)):
        if (existing.get('session') == session and existing.get('search_id') == search_id and existing.get('auto')
                and (now or time.time()) - float(existing.get('at') or 0) < flow.KEEP
                and {o.get('quote_ref') for o in existing.get('options') or []} == {q['id'] for q in quotes}):
            return {'ok': True, 'set': existing['key'], 'key': existing['key'], 'already': True,
                    'options': [{'id':o['id'],'title':o['title'],'price':o['price']} for o in existing['options']]}
    rows = [_row(q) for q in quotes]
    cheapest = min(rows, key=lambda r: module('money').parse(r['price'], r['currency'])[0] if module('money').parse(r['price'], r['currency']) else 10**12)
    cheapest['recommended'] = True
    cheapest['why'] = 'El precio más bajo comprobado en la cesta.'
    result = present(home, session, {'search_id': search_id, 'options': rows}, currency=currency, picture=picture,
                     request=request, now=now)
    if result.get('ok'):
        with flow._locked(home) as path:
            sets = flow._read(path)
            for found in sets:
                if found.get('key') == result['set'] and found.get('session') == session:
                    found['auto'] = True
            flow._write(path, sets)
    return result


def _adopt(home, session, args, raw, now):
    """The model's `purchase_options` for a search whose cards the plugin already shows: its
    recommendation and words go onto those cards, and the key it will be read back under (the one
    the app computes from these arguments) becomes an alias of the set. One set, never two."""
    flow = module('purchase_flow')
    refs = [o.get('quote_ref') for o in raw]
    with flow._locked(home) as path:
        sets = flow._read(path)
        for found in sets:
            if (found.get('session') != session or not found.get('auto') or found.get('chosen')
                    or (now or time.time()) - float(found.get('at') or 0) >= flow.KEEP):
                continue
            shown = {o.get('quote_ref'): o for o in found.get('options') or []}
            if not refs or not all(r in shown for r in refs):
                continue
            if any(bool(o.get('recommended')) for o in raw):
                for option in found['options']:
                    option['recommended'] = False
                    option['why'] = ''
                for row in raw:
                    option = shown[row['quote_ref']]
                    if row.get('recommended') and not any(o['recommended'] for o in found['options']):
                        option['recommended'] = True
                    if row.get('why'):
                        option['why'] = flow._clean(row.get('why'), 200)
                if not any(o['recommended'] for o in found['options']):
                    found['options'][0]['recommended'] = True
            alias = flow.set_key(raw[:flow.MAX_OPTIONS])
            if alias != found['key'] and alias not in found.setdefault('aliases', []):
                found['aliases'].append(alias)
            flow._write(path, sets)
            best = next(o for o in found['options'] if o['recommended'])
            return {'ok': True, 'set': found['key'], 'key': found['key'], 'alias': alias,
                    'options': [{'id':o['id'],'title':o['title'],'price':o['price']} for o in found['options']],
                    'next': ('La persona ya ve las tarjetas (las enseñó el plugin al comprobar). La marcada «Recomendada» es «'
                             + f"{best['title']} · {best['variant']} · {best['price']}".replace(' ·  · ', ' · ')
                             + '»; recomienda esa y ninguna otra, en una o dos líneas, y no prepares nada hasta que elija.')}
    return None


def present(home, session, args, *, currency="", picture=None, request="", now=None, factory=Probe):
    raw = [o for o in args.get('options', []) if isinstance(o, dict) and o.get('quote_ref')]
    data = _load(home)
    # The search these quotes belong to, whatever search_id the model wrote (a second, narrower
    # discover once left the first search's quotes orphaned and the cards never appeared).
    search_ids = [data['quotes'][o['quote_ref']]['search_id'] for o in raw if o['quote_ref'] in data['quotes']]
    search_id = args.get('search_id') if args.get('search_id') in data['searches'] else (search_ids[0] if search_ids else None)
    if not raw and search_id:
        _search, quotes = _quotes_of(data, session, search_id)
        raw = [{'quote_ref': q['id']} for q in quotes]
    if not raw:
        return {'ok': False, 'error': 'Busca y comprueba los formatos antes de mostrarlos (purchase_discover, purchase_verify).'}
    adopted = _adopt(home, session, args, raw, now)
    if adopted:
        return adopted
    try:
        search, shown_quotes = _quotes_of(data, session, search_id)
        if not search:
            raise ValueError('Falta el registro de formatos encontrados.')
        # Every verified format of the search is shown, the ones the model left out included; an
        # unchecked one is said as such, never a reason to show nothing.
        given = {o['quote_ref'] for o in raw}
        raw = raw + [{'quote_ref': q['id']} for q in shown_quotes if q['id'] not in given
                     and q['candidate_id'] not in {data['quotes'][r]['candidate_id'] for r in given if r in data['quotes']}]
        unchecked = [c['title'] for c in search['candidates'] if c['id'] not in {q['candidate_id'] for q in shown_quotes}
                     and c['id'] not in search['rejected'] and c['id'] not in search.get('failed', {})]
        options = []
        candidates = set()
        for row in raw:
            try:
                quote = resolve(home, session, row.get('quote_ref'), now=now, factory=factory)
            except ValueError:
                stale = data['quotes'].get(row.get('quote_ref'))
                if not stale or stale['session'] != session:
                    raise
                quote = stale  # the re-check failed (a slow shop): the errand checks its own basket anyway
            if quote['candidate_id'] in candidates:
                continue
            candidates.add(quote['candidate_id'])
            options.append({**row, **{k: quote[k] for k in ('title','variant','qty','url','price','currency')},
                            'in_stock': True, 'channel':'browser', 'quote_ref': quote['id'],
                            'verified_at': quote['at'], 'shipping': quote['shipping'], 'condition': quote['condition'],
                            'coupon': quote.get('coupon') or '', 'image': quote.get('image') or row.get('image') or '',
                            'price_note': quote.get('price_note') or '', 'promotional_price': quote.get('promotional_price') or '',
                            'promotion_code': quote.get('promotion_code') or ''})
        try:
            known = {}
            for option in options:
                url = option['url'].split('?')[0].rstrip('/')
                newer = module('errands').basket_prices(home, now=now, after=option['verified_at'], offer=option)
                if url in newer:
                    known[url] = newer[url]
        except Exception:  # noqa: BLE001 — a nicety, never a reason not to show the options
            known = {}
        result = module('purchase_flow').present(home, session, {'options':options}, currency=currency,
                                               picture=picture, request=request, now=now, exact_item=True,
                                               known_prices=known)
        if result.get('ok'):
            # The quote, rather than any model-supplied price, remains the offer's authority.
            flow = module('purchase_flow')
            with flow._locked(home) as path:
                sets = flow._read(path)
                found = next(s for s in sets if s['key']==result['set'] and s['session']==session)
                for option in found['options']:
                    source = options[int(option['id'].rsplit('-',1)[1])-1]
                    option.update({k:source.get(k) for k in ('quote_ref','verified_at','shipping','condition','coupon')})
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
            if unchecked:
                result['unchecked'] = unchecked
                result['next'] = result.get('next', '') + ' Sin comprobar (dilo en una línea): ' + '; '.join(unchecked) + '.'
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
    elif not all((recipe or {}).get(k) for k in ('line', 'price', 'cart_quantity')):
        return _check_cart_engine(home, errand_id, entry, offer, page_origin, context, command, ev, now)
    else:
        recipe = {k:v for k,v in recipe.items() if k != 'price_basis'}
    def read(selector):
        result = ev(context,'(()=>{let e;try{e=document.querySelector(' + json.dumps(selector) + ')}catch{return {invalid_selector:true}};return e ? String(e.matches("input,select,textarea") ? e.value : e.innerText).trim() : null})()')
        if isinstance(result,dict) and result.get('invalid_selector'):
            raise ValueError('Usa selectores CSS de la página para line, price y cart_quantity, no nombres de producto, importes o cantidades. Lee los controles y vuelve a comprobar la cesta.')
        return result
    line = read(recipe['line'])
    if not line or not names(line, offer['title'], offer.get('variant') or ''):
        raise ValueError('La cesta no contiene el formato elegido (selector ' + recipe['line'] + '; línea: ' + str(line or '')[:200] + ').')
    if read(recipe['cart_quantity']) != str(offer.get('qty',1)):
        raise ValueError('La cesta tiene otra cantidad. Corrígela antes de pedir aprobación.')
    if not ev(context,'(()=>{const line=document.querySelector(' + json.dumps(recipe['line']) + ');const e=document.querySelector(' + json.dumps(recipe['price']) + ');return !!line && !!e && line.contains(e) && e.getClientRects().length>0 && getComputedStyle(e).visibility!=="hidden" && !e.closest("del,s,strike") && getComputedStyle(e).textDecorationLine!=="line-through"})()'):
        raise ValueError('No hay un precio actual verificable de ese artículo en la cesta.')
    amount = cart_amount(read(recipe['price']),offer['currency'],offer.get('qty',1),recipe)
    if not amount:
        raise ValueError('La cesta no tiene un precio verificable.')
    return _cart_verdict(home, errand_id, entry, offer, page_origin, context, command, amount, recipe, now)


def _cart_verdict(home, errand_id, entry, offer, page_origin, context, command, amount, recipe, now):
    errands = module('errands')
    real = module('money').text(*amount)
    note = 'El precio sigue coincidiendo. Prepara el envío y el resumen final sin volver a pedir aceptar el mismo precio.'
    old_price = module('money').parse(offer['price'], offer['currency'])
    try:
        cookies = command('Storage.getCookies',{'browserContextId':context['context']}).get('cookies',[])
    except Exception:  # noqa: BLE001 — the session cookie is a hint, the context is the binding
        cookies = []
    evidence = {'origin':page_origin,'context':context['context'],'recipe':recipe,
        'qty':offer.get('qty',1),'price_cents':amount[0],'currency':amount[1], 'at':now or time.time(),
        'session':fingerprint(cookies,page_origin)}
    if old_price and amount[0] < old_price[0]:
        # Cheaper in the basket (a member discount after login): the person's choice only got
        # better, and the final total is approved before paying anyway.
        errands.update(home, errand_id, offer={**offer, 'price': real}, cart_evidence=evidence)
        note = ('La cesta cobra ' + real + ', menos que los ' + offer['price'] + ' elegidos: sigue con ese precio '
                'sin preguntar y menciónalo en el resumen final.')
        return {'ok':True,'price':real,'qty':offer.get('qty',1),'next':note}
    coupon = str(offer.get('coupon') or '')
    tries = int(entry.get('coupon_checks') or 0)
    if coupon and old_price and amount[0] > old_price[0] and tries < 2:
        # The coupon price was chosen and the basket shows more: most often the coupon is simply not
        # in yet (34,99 € before IMBACK, 27,99 € after). That is a step to do, never a price for the
        # person to accept (06-10); only after it was tried does a higher total stop the errand.
        errands.update(home, errand_id, coupon_checks=tries + 1)
        return {'ok': False, 'coupon_pending': True, 'price': real,
                'next': (f"La cesta cobra {real} porque aún no tiene el cupón {coupon}. Escríbelo en el campo de "
                         "cupón o código promocional de la cesta o del checkout, aplícalo, espera a que se "
                         "actualice el total y vuelve a llamar a `purchase_check_cart`. Si la tienda solo acepta el "
                         "cupón con la sesión iniciada, inicia sesión con `login_fill` y el acceso guardado y vuelve a "
                         "aplicarlo. No pares ni lo cuentes como un cambio de precio.")}
    if not module('money').same(real,offer['price'],offer['currency']):
        # The evidence is kept with the real price: when the person accepts it, this cart is
        # already checked and the errand goes straight on to the checkout.
        errands.update(home,errand_id,status='stuck',blocked={'kind':'price','price':real},cart_evidence=evidence,
                       reason='La cesta cobra ' + real + ' por el formato elegido, frente a ' + offer['price']
                       + (' con el cupón ' + coupon + ', que la tienda no ha aplicado.' if coupon else '.'))
        return {'ok':False,'price_changed':True,'old':offer['price'],'price':real,'next':'Termina el turno. La persona puede aceptar el cambio real desde su tarjeta.'}
    errands.update(home,errand_id,cart_evidence=evidence)
    return {'ok':True,'price':real,'qty':offer.get('qty',1),'next':note}


def _check_cart_engine(home, errand_id, entry, offer, page_origin, context, command, ev, now):
    """The errand's basket read by the engine: the line naming the chosen product, its units and
    unit price, on the page the errand has open (its cart page or drawer)."""
    errands, money = module('errands'), module('money')
    expected = money.parse(offer['price'], offer['currency'])
    read = module('shop_engine').errand_cart(lambda code: ev(context, code), offer['title'], offer.get('variant') or '',
                                             int(offer.get('qty', 1)), offer['currency'], expected[0] if expected else None)
    if str(read['qty']) != str(offer.get('qty', 1)):
        raise ValueError('La cesta tiene ' + str(read['qty']) + ' unidades, no ' + str(offer.get('qty', 1))
                         + '. Corrígela antes de pedir aprobación.')
    amount = (read['price_cents'], read['currency'])
    return _cart_verdict(home, errand_id, entry, offer, page_origin, context, command, amount,
                         {'engine': read.get('how') or 'dom'}, now)


def fresh_cart(home, entry, *, inspect=None, now=None):
    """The errand's cart was checked recently, in this same browser context, for the offer as it
    stands (units and price). The page it is on now does not matter: between the basket and the pay
    step the errand goes through login, address, delivery and the bank, and the amount is read
    again on each of those that counts (checkout_request, the pay click)."""
    evidence = entry.get('cart_evidence') or {}
    if not evidence or (now or time.time())-float(evidence.get('at') or 0) > CART_TTL:
        return False
    access = module('errand_access')
    _page_origin, context, _command = (inspect or access.target)(entry)
    offer = entry.get('offer') or {}
    return (context['context']==evidence['context']
            and evidence['qty']==offer.get('qty',1)
            and module('money').parse(offer.get('price'),evidence['currency']) == (evidence['price_cents'],evidence['currency']))


def checkout_amount(entry, selector, *, inspect=None, evaluate=None):
    """The final total on the errand's checkout page: at ``selector`` when the agent gave one, else
    the amount the engine finds next to «Total» (shop_engine.order_total)."""
    access = module('errand_access')
    page_origin, context, _ = (inspect or access.target)(entry)
    if not same_site(page_origin, entry['offer']['url']):
        raise ValueError('El resumen no pertenece a la tienda elegida.')
    ev = evaluate or access.page_evaluate
    if not selector:
        found = module('shop_engine').errand_total(lambda code: ev(context, code))
        if not found or not found.get('text'):
            raise ValueError('No se encontró el total del pedido en esta página: llega al resumen final (donde dice «Total») y vuelve a llamar.')
        result = found['text']
    else:
        result = ev(context,
        '(()=>{const e=document.querySelector(' + json.dumps(selector) + ');if(!e||!e.getClientRects().length||getComputedStyle(e).visibility==="hidden"||e.closest("del,s,strike"))return null;return e.innerText.trim()})()')
    amount = module('money').parse(result,entry['offer']['currency'])
    if not amount or amount[0] < module('money').parse(entry['offer']['price'],entry['offer']['currency'])[0] * entry['offer'].get('qty',1):
        raise ValueError('El total final no cubre los artículos comprobados.')
    return module('money').text(*amount)


def payment_ready(home, entry, *, inspect=None, evaluate=None, gateways=None):
    """Whether the card may be filled or the pay button pressed now: the person approved this
    checkout, the cart it came from is the one checked, and the page is either the shop's own
    summary still showing that exact total, or the payment page the shop sent the errand to (a
    bank or provider: Redsys, Stripe, Adyen…), where the shop's total is no longer on screen."""
    errands, access = module('errands'), module('errand_access')
    approved = errands.approved_checkout(entry)
    evidence = entry.get('checkout_evidence') or {}
    if not approved or evidence.get('checkout_id') != approved['id'] or not (evidence.get('selector') or evidence.get('engine')):
        return False
    if not fresh_cart(home,entry,inspect=inspect):
        return False
    page_origin, context, _ = (inspect or access.target)(entry)
    if same_site(page_origin, entry['offer']['url']):
        actual = checkout_amount(entry,evidence.get('selector') or '',inspect=inspect,evaluate=evaluate)
        return module('money').same(actual,approved['total'],approved['currency'])
    host = (urlsplit(page_origin).hostname or '').lower()
    if gateways is None:
        gateways = module('vault_cards').PAYMENT_GATEWAYS
    if host in set(gateways):
        return True
    # An unknown origin: it is the payment page only if it shows one (card fields, a provider's frame
    # or a choice of payment method). Anything else is not where the approved order is paid.
    try:
        return bool((evaluate or access.page_evaluate)(context, errands.PAYMENT_STEP_JS))
    except Exception:  # noqa: BLE001 — unreadable: not a payment page we can vouch for
        return False


def verify_remaining(home, session, args, *, factory=Probe, budget=REMAINING_BUDGET, clock=time.monotonic):
    """The other formats of the same search, checked the same way, inside the time one tool call can
    take. Formats left unchecked for lack of time are said as such (and noted, so the cards can be
    shown) — the agent checks them one by one if it wants them on the cards."""
    data = _load(home)
    search = data['searches'][args['search_id']]
    done = {q['candidate_id'] for q in data['quotes'].values() if q['search_id']==search['id']}
    done.update(search['rejected'])
    quotes, failures = [], []
    started = clock()
    for candidate in search['candidates']:
        if candidate['id'] in done:
            continue
        if clock() - started > budget:
            why = 'sin tiempo en esta llamada: llama a purchase_verify con este candidate_id para incluirlo'
            _note_failure(home, session, {'search_id': search['id'], 'candidate_id': candidate['id']}, why)
            failures.append({'candidate_id':candidate['id'],'title':candidate['title'],'why':why})
            continue
        try:
            others = {k: v for k, v in args.items() if k != 'variant'}  # another format: its own default variant
            quote = verify(home,session,{**others,'candidate_id':candidate['id'],'qty':1},factory=factory)
            quotes.append(quote)
        except Exception as exc:
            failures.append({'candidate_id':candidate['id'],'title':candidate['title'],
                             'why':str(exc) if isinstance(exc,ValueError) else 'No se pudo abrir la ficha en la cesta temporal.'})
    return {'other_formats':quotes,'unverified':failures}
