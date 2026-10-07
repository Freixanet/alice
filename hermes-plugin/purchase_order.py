"""Fixed DOM inventory and exact product identity for checkout approval.

Unknown cart structures fail closed. Model selectors may identify controls but
cannot narrow the inventory or turn surrounding prose into total evidence.
"""
import json
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def product_url(value):
    parts = urlsplit(value)
    tracking = {'gclid', 'fbclid', 'msclkid'}
    query = sorted((k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
                   if not k.lower().startswith('utm_') and k.lower() not in tracking)
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip('/') or '/', urlencode(query), ''))


def variant(value):
    return re.sub(r'\s+', ' ', str(value or '')).strip().casefold()


def script(locators, prozis=False):
    return '(()=>{const s=' + json.dumps(locators) + ';const prozis=' + json.dumps(prozis) + r''';
    const visible=e=>e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
    const text=e=>e&&String(e.matches('input,select,textarea')?e.value:e.innerText).trim();
    const one=selector=>{const es=Array.from(document.querySelectorAll(selector)).filter(visible);return es.length===1?es[0]:null};
    const read=k=>text(one(s[k]));
    const roots=Array.from(document.querySelectorAll(prozis?'#chkLists':'[data-order-items],[data-cart-items],#cart-items,.cart-items,.cart__items')).filter(visible);
    const root=roots.length===1?roots[0]:null;
    const rows=root?(prozis?Array.from(root.querySelectorAll('.chk-prod-card')):Array.from(root.children).filter(e=>!e.matches('script,style,template'))):[];
    const chosen=one(s.line), price=one(s.price), qty=one(s.cart_quantity);
    const inventory_verified=!!root&&rows.length>0&&rows.every(visible)&&rows.includes(chosen)&&!!price&&!!qty&&chosen.contains(price)&&chosen.contains(qty)&&!price.closest('s,del,strike')&&getComputedStyle(price).textDecorationLine!=='line-through';
    const lines=rows.map(e=>({text:text(e),links:[e.getAttribute('data-product-url'),...Array.from(e.querySelectorAll('a[href]')).map(a=>a.href)].filter(Boolean),
      variant:e.getAttribute('data-variant')||text(e.querySelector('[data-variant],.product-variant,.item-description,.variant'))||'',
      sku:e.getAttribute('data-sku')||e.getAttribute('data-product-id')||''}));
    const te=one(s.total_selector);const label=[te?.getAttribute('aria-label'),te?.previousElementSibling?.innerText].filter(Boolean);
    const bad=/(?:sub.?total|line.?total|unit.?price|item.?price)/i.test([te?.id,te?.className].join(' '));
    const total_verified=!!te&&!bad&&!root?.contains(te)&&(te.matches('[data-order-total],[data-grand-total]')||/^(?:total|grand[-_]total|order[-_]total)$/i.test(te.id)||label.some(t=>/^(?:grand total|order total|total a pagar|total del pedido|importe total|total)$/i.test(t.trim())));
    const totals=[...new Set([te,...Array.from(document.querySelectorAll('[data-order-total],[data-grand-total],#total,#grand-total,#order-total')).filter(visible)])].filter(Boolean).map(text);
    const charges=Array.from(document.querySelectorAll('[data-order-shipping],[data-order-tax],[data-order-fees],[data-order-discount]')).filter(visible).map(e=>({
      kinds:['shipping','tax','fees','discount'].filter(k=>e.hasAttribute('data-order-'+k)),amount:text(e)}));
    const cc=Array.from(document.querySelectorAll('input[autocomplete=cc-number],input[name*=card_number],input[name*=cardNumber]')).some(visible);
    const method=one('[data-payment-method],input[name*=payment]:checked,input[name*=Payment]:checked');
    const method_value=method?.getAttribute('data-payment-method')||method?.value||'';
    const method_label=method?.getAttribute('data-payment-label')||method?.labels?.[0]?.innerText||method_value;
    const method_kind=cc?'card':/^(?:card|credit.?card|debit.?card|bank.?card|redsys)$/i.test(method_value)?'bank_card':/^(?:cod|cash.?on.?delivery|contra.?reembolso)$/i.test(method_value)?'cod':/^(?:invoice|factura|bank.?transfer)$/i.test(method_value)?'invoice':'unknown';
    return {inventory_verified,lines,total_verified,totals,charges,payment_method:{kind:method_kind,label:method_label||'Tarjeta',requires_card:['card','bank_card','unknown'].includes(method_kind)},
      total:read('total_selector'),delivery:read('delivery_selector'),address:read('address_selector'),email:read('email_selector'),qty:read('cart_quantity'),price:read('price'),url:location.href,
      recurring:Array.from(document.querySelectorAll('input:checked,select option:checked')).some(e=>/suscri|subscription|recurr|mensual|monthly/i.test([e.innerText,e.name,e.id,e.value].join(' ')))};})()'''


def validate(raw, offer, recipe, money):
    if not raw.get('inventory_verified') or len(raw.get('lines') or []) != 1:
        raise ValueError('No se puede comprobar la cesta completa y sus controles; no se aprueba el pedido.')
    line = raw['lines'][0]
    if raw.get('qty') != str(offer.get('qty', 1)):
        raise ValueError('Corrige las unidades de la cesta antes de pedir aprobación.')
    identity = offer.get('product_identity') or {}
    expected = product_url(identity.get('url') or offer['url'])
    if expected not in {product_url(url) for url in line.get('links') or []}:
        raise ValueError('Falta el enlace exacto del producto elegido, incluidos sus parámetros de variante.')
    if variant(line.get('variant')) != variant(identity.get('variant') or offer.get('variant')):
        raise ValueError('La cesta no confirma exactamente la variante elegida.')
    sku = identity.get('sku') or recipe.get('prozis_variant_id')
    if sku and str(line.get('sku') or '') != str(sku):
        raise ValueError('La referencia del artículo no coincide con la variante verificada.')
    amount = money.parse(raw.get('total'), offer.get('currency') or '')
    price = money.parse(raw.get('price'), offer.get('currency') or '')
    if not raw.get('total_verified') or not amount or not amount[1] or not price:
        raise ValueError('Falta un total final o un precio de línea inequívoco.')
    if not raw.get('totals') or any(money.parse(t, amount[1]) != amount for t in raw['totals']):
        raise ValueError('La página muestra totales contradictorios o ambiguos.')
    line_cents = price[0] if recipe.get('price_basis') == 'line_total' else price[0] * int(raw['qty'])
    expected_total = line_cents
    breakdown = []
    for charge in raw.get('charges') or []:
        kinds = charge.get('kinds') or []
        value = str(charge.get('amount') or '')
        labels = {'shipping':r'(?:env[ií]o|portes|shipping|delivery)',
                  'tax':r'(?:impuestos?|iva|tax(?:es)?)',
                  'fees':r'(?:cargos?|fees?)',
                  'discount':r'(?:descuento|discount|cup[oó]n)'}
        if len(kinds) == 1 and kinds[0] in labels:
            value = re.sub(r'^' + labels[kinds[0]] + r'\s*:?\s*', '', value, flags=re.I)
            if kinds == ['shipping'] and value.casefold() in ('gratis', 'free'):
                value = '0'
        if kinds == ['discount']:
            value = value.lstrip('−- ')
        parsed = money.parse(value, amount[1])
        if len(kinds) != 1 or not parsed or parsed[1] != amount[1]:
            raise ValueError('El desglose del pedido es ambiguo.')
        expected_total += -parsed[0] if kinds == ['discount'] else parsed[0]
        breakdown.append({'kind':kinds[0], 'cents':parsed[0]})
    if not any(c['kind'] == 'shipping' for c in breakdown) or expected_total != amount[0]:
        raise ValueError('El total no coincide con artículos, envío, impuestos, cargos y descuentos comprobados.')
    return amount, line_cents, breakdown
