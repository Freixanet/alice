"""Public access states produced by real services with fictional page/vault metadata."""
import json
import importlib.util
import sys
import tempfile
import types
from pathlib import Path
from unittest import mock

PLUGIN = Path(__file__).resolve().parents[1]


def load(name):
    key = 'alice_' + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, PLUGIN / (name + '.py'))
        module = importlib.util.module_from_spec(spec)
        sys.modules[key] = module
        spec.loader.exec_module(module)
    return sys.modules[key]


def access_states():
    errands, access, notices = load('errands'), load('errand_access'), load('fallback_notices')
    with tempfile.TemporaryDirectory(prefix='alice-qa-contract-') as folder:
        home = Path(folder)
        with mock.patch.object(errands, 'open_goal'), mock.patch.object(errands, '_default_home', return_value=home):
            entry = errands.create(home, 'Compra este producto', title='Comprar producto',
                                   offer={'url': 'https://tienda.example/producto'}, profile='default')
            context = {'context': 'fixture-context', 'target': 'fixture-target'}
            errands.context_file(entry['id'], home).write_text(json.dumps(context))
            inspect = lambda _: ('https://tienda.example', context, None)
            with mock.patch.object(access, 'page_evaluate', return_value=True):
                access.request(home, entry['id'], inspect=inspect, replace=True)
            notices.record(types.SimpleNamespace(session_id=entry['session_id']),
                           'Model fallback: test via test unavailable (rate limit); using backup via test.', errands)
            states = {'needs_login_metadata': errands.public(errands.get(home, entry['id']))}
            errands.update(home, entry['id'], saved_login={'handle': 'fixture-login', 'origin': 'https://tienda.example'})
            backend = types.SimpleNamespace(get_meta=lambda _: types.SimpleNamespace(
                kind='login', origin='https://tienda.example', identifier='cuenta@example.test'))
            original = access.code_delivery
            def delivery(entry, context):
                return original(entry, context, backend=backend, evaluate=lambda *_: [
                    'Código de verificación enviado por correo a c***@example.test'])
            with mock.patch.object(access, 'code_delivery', side_effect=delivery):
                access.request(home, entry['id'], kind='vault.code', inspect=inspect)
            states['needs_code_metadata'] = errands.public(errands.get(home, entry['id']))
            errands.update(home, entry['id'], status='working', secure_request=None,
                           user_login_provided=True, login_attempt={'stage':'credentials'})
            with mock.patch.object(access, 'login_result', return_value='authentication_rejected'), \
                 mock.patch.object(access, 'guest_available', return_value=False):
                access.request(home, entry['id'], inspect=inspect, replace=True)
            states['needs_login_rejected'] = errands.public(errands.get(home, entry['id']))
            return states
