"""Product-local public promotions, shared by every shop engine and adapter.
Conditional advertised prices never replace the price verified in a basket.
"""
import importlib.util
import re
import sys
from pathlib import Path


def module(name):
    key = 'alice_' + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, Path(__file__).with_name(name + '.py'))
        value = importlib.util.module_from_spec(spec)
        sys.modules[key] = value
        spec.loader.exec_module(value)
    return sys.modules[key]


def advertised_coupon_price(blocks, codes, base_cents, currency):
    """A conditional offer from the product page, separate from cart evidence.
    Ambiguous ranges or several different discounts never become a display price."""
    from decimal import Decimal, ROUND_HALF_UP
    for code in codes:
        possible = set()
        for text in blocks if isinstance(blocks, list) else []:
            if not isinstance(text, str) or len(text) > 600 or not re.search(r'(?<![\w-])' + re.escape(code) + r'(?![\w-])', text):
                continue
            if re.search(r'\b(?:hasta|up to|desde|from)\b', text, re.I):
                continue
            rates = set(re.findall(r'(?<![\d.,])([0-9]{1,2}(?:[.,][0-9]+)?)\s*%', text))
            amounts = set()
            for token in re.findall(r'(?:[€$£]\s*\d+(?:[.,]\d{2})?|\d+(?:[.,]\d{2})?\s*(?:€|EUR|USD|GBP))', text):
                parsed = module('money').parse(token, currency)
                if parsed and parsed[1] == currency and 0 < parsed[0] < base_cents and (re.search(r'(?:precio|price|queda|now|por|for)\s*(?:con[^:]{0,50}:)?\s*' + re.escape(token), text, re.I) or re.fullmatch(re.escape(token) + r'\s+(?:con|with)\s+' + re.escape(code), text.strip(), re.I)):
                    amounts.add(parsed[0])
            if len(amounts) == 1:
                possible.update(amounts)
            elif not amounts and len(rates) == 1:
                rate = Decimal(next(iter(rates)).replace(',', '.'))
                if 0 < rate < 100:
                    possible.add(int((Decimal(base_cents) * (100 - rate) / 100).quantize(Decimal('1'), rounding=ROUND_HALF_UP)))
        if len(possible) == 1:
            return {'price': module('money').text(possible.pop(), currency), 'code': code}
    return None


def product_coupon_blocks(browser):
    """Read bounded visible offer blocks, excluding hidden text and unrelated page content."""
    try:
        result = browser.evaluate(r"""(()=>{const out=[];
const visible=e=>e.getClientRects().length>0&&getComputedStyle(e).display!=='none'&&getComputedStyle(e).visibility!=='hidden';
const explicit=Array.from(document.querySelectorAll('[class*=coupon i],[class*=discount i],[class*=promo i],[id*=coupon i],[id*=discount i],[id*=promo i],[data-coupon],[data-discount-code]'));
const labelled=Array.from(document.querySelectorAll('p,li,span,small')).filter(e=>/cup[oó]n|coupon|(?:promo|discount)\s*code|c[oó]digo/i.test(e.innerText||e.textContent||''));
for(const e of new Set([...explicit,...labelled])){
 if(!visible(e)||e.closest('header,footer,nav,[hidden],script,style'))continue;
 let p=e;for(let i=0;p&&i<3;i++,p=p.parentElement){if(p===document.body||p===document.documentElement)break;
 const t=(p.innerText||p.textContent||'').trim();if(t&&t.length<=600&&!out.includes(t))out.push(t);}}
return out.slice(0,40)})()""")
        return result if isinstance(result, list) else []
    except Exception:
        return []


def public_codes(blocks, supplied=()):
    """Codes must be identified by the shop's visible offer, not guessed by the model."""
    codes = [str(c).strip() for c in supplied if isinstance(c,str) and c.strip()]
    for text in blocks:
        if not isinstance(text,str): continue
        patterns = [r'(?:cup[oó]n|coupon|promo(?:tion)?\s*code|discount\s*code|c[oó]digo)\s*[:=]?\s*([A-Za-z0-9][A-Za-z0-9_-]{2,39})',
                    r'^\s*([A-Z0-9][A-Z0-9_-]{2,39})\s*(?:\n|\s)\s*\d{1,2}(?:[.,]\d+)?\s*%']
        # «Código identificativo de autenticidad HSN: 18HR11» is a product's own code, not a coupon.
        # A code is a coupon only where the shop speaks of a discount («Código 18HR11» on a quality
        # seal is not one).
        if not re.search(r'cup[oó]n|coupon|descuento|discount|promo|rebaja|ahorr|\boff\b|%', text, re.I):
            continue
        if re.search(r'identificativ|autenticidad|authenticity|referencia|\bref\b|\blote\b|\bsku\b|\bean\b|c[oó]digo (?:de )?barras|c[oó]digo postal|postal code', text, re.I):
            continue
        for pattern in patterns:
            codes.extend(c for c in re.findall(pattern,text, re.I if pattern==patterns[0] else 0)
                         if c.lower() not in {'para','with','code','codigo','coupon','cupón','descuento','discount','welcome','bienvenida','requires','requiere'}
                         and not c.islower())
    return list(dict.fromkeys(codes))[:5]


def fields(blocks, supplied, cents, currency, *, applied=False):
    if applied or not isinstance(cents,int) or cents <= 0 or not currency:
        return {}
    offer = advertised_coupon_price(blocks, public_codes(blocks,supplied), cents, currency)
    if not offer: return {}
    note = 'Con cupón ' + offer['code']
    matching = [t for t in blocks if isinstance(t,str) and re.search(r'(?<![\w-])' + re.escape(offer['code']) + r'(?![\w-])',t)]
    conditions = max(matching,key=len) if matching else note
    return {'promotional_price':offer['price'], 'promotion_code':offer['code'], 'price_note':note,
            'promotion_condition':conditions + '. Precio condicionado al cupón; se confirma en la cesta antes de pagar.'}
