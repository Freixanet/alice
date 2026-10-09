"""Controller-owned UCP cart preparation, with the existing browser as fallback.

Only a persisted, same-session Shopify quote supplies the variant. No model-supplied
endpoint, account, price, payment instrument or command is accepted. This adapter
has no checkout-complete/payment operation. The browser rechecks its own basket
and final total through Alice's existing approval and payment guards.
"""
from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from urllib.parse import urlsplit

VERSION = '0.9.0'
VARIANT = re.compile(r'^gid://shopify/ProductVariant/[1-9][0-9]*$')


def module(name):
    from importlib.util import module_from_spec, spec_from_file_location
    import sys
    key = 'alice_' + name
    if key not in sys.modules:
        spec = spec_from_file_location(key, Path(__file__).with_name(name + '.py'))
        sys.modules[key] = module_from_spec(spec)
        spec.loader.exec_module(sys.modules[key])
    return sys.modules[key]


def origin(url):
    """Public HTTPS only; no credentials, IP literals, local domains or custom ports."""
    try:
        p = urlsplit(url)
        host = (p.hostname or '').lower()
        if p.scheme != 'https' or p.username or p.password or p.port not in (None, 443):
            return ''
        if not host or '.' not in host or host.endswith(('.localhost', '.local', '.internal')):
            return ''
        try:
            ipaddress.ip_address(host)
            return ''
        except ValueError:
            pass
        return 'https://' + host
    except (TypeError, ValueError):
        return ''


class CLI:
    def __init__(self, home):
        self.root = Path(home) / '.alice' / 'commerce-runtime'
        self.binary = self.root / 'node_modules/@shopify/ucp-cli/dist/bin.js'
        self.node = shutil.which('node') or next((str(p) for p in
                    (Path('/usr/local/bin/node'), Path('/opt/homebrew/bin/node')) if p.is_file()), '')
        # Separate configuration: never inherit CLI credentials, business defaults or hooks.
        self.env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'TMPDIR', 'LANG')}
        self.env['UCP_HOME'] = str(self.root / 'config')

    def installed(self):
        if not self.node or not self.binary.is_file():
            return False
        try:
            package = json.loads((self.binary.parent.parent / 'package.json').read_text())
            return package.get('version') == VERSION
        except (OSError, ValueError):
            return False

    def run(self, arguments):
        answer = subprocess.run([self.node, str(self.binary), *arguments, '--format', 'json'],
                                env=self.env, input='', capture_output=True, text=True, timeout=25)
        if answer.returncode or len(answer.stdout) > 1_000_000:
            raise ValueError('ucp_unavailable')
        result = json.loads(answer.stdout)
        if not isinstance(result, dict) or result.get('error'):
            raise ValueError('ucp_unsupported')
        return result

    def cart(self, business, variant, qty):
        self.run(['profile', 'init', '--name', 'alice', '--version', '2026-08-25'])
        return self.run(['cart', 'create', '--business', business, '--profile', 'alice',
                         '--input', json.dumps({'line_items': [{'item': {'id': variant}, 'quantity': qty}]})])


def validate(response, offer, variant):
    result = response.get('result')
    if not isinstance(result, dict):
        raise ValueError('invalid_cart')
    rows = result.get('line_items')
    if not isinstance(rows, list) or len(rows) != 1:
        raise ValueError('unexpected_lines')
    line = rows[0]
    if not isinstance(line, dict) or not isinstance(line.get('item'), dict):
        raise ValueError('invalid_line')
    quantity = line.get('quantity')
    if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity != offer['qty'] or line['item'].get('id') != variant:
        raise ValueError('wrong_variant_or_quantity')
    if result.get('currency') != offer['currency']:
        raise ValueError('wrong_currency')
    totals = [t.get('amount') for t in result.get('totals', []) if isinstance(t, dict) and t.get('type') == 'total']
    if len(totals) != 1 or isinstance(totals[0], bool) or not isinstance(totals[0], int) or totals[0] < 0:
        raise ValueError('invalid_total')
    url = result.get('continue_url') or ''
    if not origin(url) or origin(url) != origin(offer['url']):
        raise ValueError('unsafe_handoff')
    if not isinstance(result.get('id'), str) or not result['id']:
        raise ValueError('missing_cart_id')
    return {'status': 'ready', 'connector': 'shopify-ucp', 'cart_id': result['id'],
            'continue_url': url, 'currency': result['currency'], 'total_minor': totals[0]}


def prepare(home, errand_id, *, client=None, now=None):
    errands, prices = module('errands'), module('purchase_prices')
    # Serialize check + dispatch + recording with the same lock as other errand updates.
    # The network call is outside that lock; the durable pending marker prevents re-dispatch.
    with errands._locked(home) as path:
        entries = errands._read(path)
        entry = next((e for e in entries if e.get('id') == errand_id), None)
        if not entry or entry.get('status') != 'working' or entry.get('commerce'):
            return (entry or {}).get('commerce')
        offer = entry.get('offer') or {}
        quote = prices._load(home)['quotes'].get(offer.get('quote_ref')) or {}
        variant = quote.get('catalog_id') or ''
        qty = offer.get('qty')
        if (quote.get('session') != entry.get('origin_session') or quote.get('url') != offer.get('url')
                or not origin(offer.get('url')) or not VARIANT.fullmatch(variant)
                or (quote.get('recipe') or {}).get('platform') != 'shopify'
                or (now or time.time()) - float(quote.get('at') or 0) > prices.TTL
                or isinstance(qty, bool) or not isinstance(qty, int) or not 1 <= qty <= 20
                or quote.get('currency') != offer.get('currency')
                or quote.get('variant') != offer.get('variant')):
            return None
        cli = client or CLI(home)
        if not cli.installed():
            return None
        entry['commerce'] = {'status': 'pending', 'connector': 'shopify-ucp', 'at': now or time.time()}
        errands._write(path, entries)
    try:
        prepared = validate(cli.cart(origin(offer['url']), variant, qty), offer, variant)
    except Exception:
        # No payment can have happened here. Reuse browser flow; never retry a timed-out create.
        prepared = {'status': 'browser', 'connector': 'shopify-ucp', 'reason': 'cart_unavailable_or_unverified'}
    # A cancel while discovery/cart is in flight must never restart the errand.
    current = errands.get(home, errand_id)
    if current and current.get('status') == 'working':
        errands.update(home, errand_id, commerce=prepared)
    return prepared
