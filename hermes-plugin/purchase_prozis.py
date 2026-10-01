"""Observed Prozis DOM contract for the restricted, disposable price service.

No API calls, account access or payment controls. Product names, SKUs, discounts
and amounts always come from the current page, never from this adapter.
"""
import json
import re
import time
from urllib.parse import urlsplit


def supports(url):
    parsed = urlsplit(str(url))
    return parsed.scheme == 'https' and parsed.netloc == 'www.prozis.com'


# Words of a request that do not name the product.
FILLER = re.compile(r"^(compra(r|me)?|pide|pedir|quiero|necesito|busca(r|me)?|encarga(r)?|me|mi|un|una|unos|unas|el|la|"
                    r"los|las|de|del|en|y|o|con|para|por|que|prozis|tienda|web|online|porfa|favor)$", re.I)


def keywords(request):
    """The product words, as six-letter stems: «creatina» and the English slug «creatine» both match."""
    words = re.findall(r"[^\W\d_]+", request.casefold())
    return list(dict.fromkeys(w[:6] for w in words if len(w) > 2 and not FILLER.match(w)))[:4]


def search_request(request, country):
    """Prozis' own search for what was asked; every listed format that names those words is a candidate."""
    if country != 'ES' or not re.search(r'\bprozis\b', request, re.I):
        return None
    words = keywords(request)
    if not words:
        return None
    query = ' '.join(re.sub(r'(?i)^(compra(r|me)?|quiero|necesito)\s+', '', request).split())
    query = ' '.join(w for w in re.findall(r"[^\W_]+", query) if not FILLER.match(w)) or ' '.join(words)
    from urllib.parse import quote
    return {'url': 'https://www.prozis.com/es/es/search?text=' + quote(query),
            'selector': 'a[href*="/prozis/"]', 'keywords': words}


def wait_read(browser, selector):
    deadline = time.monotonic() + 8
    while True:
        result = browser.read(selector)
        if result:
            return result
        if time.monotonic() >= deadline:
            raise ValueError('Prozis no terminó de cargar el control comprobado: ' + selector)
        time.sleep(.2)


def product_recipe(browser, supplied):
    wait_read(browser, 'h1.product-name')
    # Necessary cookies only, in this disposable context.
    browser.evaluate("document.querySelector('#CybotCookiebotDialogBodyButtonDecline')?.click()")
    options = browser.evaluate("Array.from(document.querySelectorAll('#addToCartSection .snap-slider-item')).map(e=>({id:e.dataset.id,label:e.innerText.trim()}))") or []
    variant = None
    if options:
        requested = supplied.get('prozis_variant_id')
        title = browser.read('h1.product-name')
        pack = re.findall(r'\d+', title)
        numbered = [o for o in options if re.search(r'\d+', o['label'])]
        if requested:
            chosen = next((o for o in options if o['id'] == requested), None)
        elif numbered:
            chosen = next((o for o in numbered if re.findall(r'\d+', o['label']) == pack), None)
        else:
            chosen = next((o for o in options if re.fullmatch(r'neutro|natural|unflavou?red', o['label'], re.I)), options[0])
        if not chosen or not re.fullmatch(r'[0-9]+', chosen['id']):
            raise ValueError('Ese sabor no se encontró en la ficha de Prozis.')
        selector = '#addToCartSection .snap-slider-item[data-id=' + json.dumps(chosen['id']) + ']'
        browser.click(selector, action='variant')
        variant = '#addToCartSection .snap-slider-item.option-active .item-description'
        if wait_read(browser, variant) != chosen['label']:
            raise ValueError('La ficha no confirmó la variante seleccionada.')
        if numbered:
            # The cart names the package in its title ("80 cápsulas"), not
            # the picker's abbreviated label ("80 cápsulas veg.").
            variant = 'h1.product-name'
    cart_url = browser.evaluate("document.querySelector('a[aria-label=\"Prozis cart summary\"]')?.href")
    if not supports(cart_url) or urlsplit(cart_url).path != urlsplit(browser.evaluate('location.href')).path.split('/prozis/')[0] + '/checkout/index':
        raise ValueError('No se encontró el enlace observado de cesta de Prozis.')
    codes = browser.evaluate("Array.from(document.querySelectorAll('[class*=coupon], [class*=code]')).map(e=>e.innerText.trim()).filter(t=>/^[A-Z0-9_-]{3,20}$/.test(t))") or []
    return {'adapter': 'prozis', 'title': 'h1.product-name', 'variant': variant,
            'quantity': '#addToCartSection .quantity-picker-wrapper .item-qty',
            'add': 'button.cart-buy-button', 'cart_url': cart_url,
            'line': '#chkLists .chk-prod-card', 'price': '#chkLists .chk-prod-card .item-price-info .price',
            'cart_quantity': '#chkLists .chk-prod-card .item-qty', 'price_basis': 'line_total',
            'coupon': '#promoCode', 'apply': 'form.coupon-code button[type=submit]',
            'shipping': '.step-summary .summary-list .summary-item:nth-child(2)',
            'condition': '.login-popup-container', 'prozis_variant_id': chosen['id'] if options else None,
            'package_variant': bool(options and numbered),
            'public_codes': list(dict.fromkeys(codes))[:5]}


def cart_recipe(evaluate):
    full = evaluate("!!document.querySelector('#chkLists .chk-prod-card')")
    if full:
        return {'line': '#chkLists .chk-prod-card', 'price': '#chkLists .chk-prod-card .item-price-info .price',
                'cart_quantity': '#chkLists .chk-prod-card .item-qty', 'price_basis': 'line_total'}
    return {'line': '.top-mini-cart-container .cart-item',
            'price': '.top-mini-cart-container .cart-item .price-labels > .item-label',
            'cart_quantity': '.top-mini-cart-container .cart-item .item-qty', 'price_basis': 'line_total'}


def wait_added(browser, title, variant, qty):
    deadline = time.monotonic() + 8
    while True:
        line = browser.read('.top-mini-cart-container .cart-item') or ''
        units = browser.read('.top-mini-cart-container .cart-item .item-qty')
        if title.casefold() in line.casefold() and variant.casefold() in line.casefold() and units == str(qty):
            return
        if time.monotonic() >= deadline:
            raise ValueError('Prozis no confirmó el artículo y sus unidades antes de abrir la cesta temporal.')
        time.sleep(.2)
