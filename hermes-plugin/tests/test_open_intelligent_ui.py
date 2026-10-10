import importlib.util
import json
import re
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tested_open_ui', ROOT / 'open_intelligent_ui.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def sample():
    return dict(title='Cuenta', summary='Ejemplo: 20 euros entre dos personas, 10 euros cada una.',
                initialHeight=300, placeholderMessages=['Preparando la cuenta', 'Dibujando los controles'],
                css='', html='<p id="result">10 €</p>', jsFunctions='', jsExpressions='')


class InteractiveTests(unittest.TestCase):
    def test_selection_rules_are_in_registered_system_prompt_without_explicit_ui_request(self):
        plugin_spec = importlib.util.spec_from_file_location('tested_ui_selection_plugin', ROOT / '__init__.py')
        plugin = importlib.util.module_from_spec(plugin_spec)
        plugin_spec.loader.exec_module(plugin)
        sections = {}
        class Context:
            def register_system_prompt_section(self, name, fn, **kwargs): sections[name] = fn
            def __getattr__(self, name): return lambda *args, **kwargs: None
        plugin.register(Context())
        prompt = sections['alice.interactive']({'platform':'api_server'})
        for rule in ['text for facts', 'savings', 'budgets', 'comparisons', 'without an explicit UI request', 'skill openintelligentui', 'native cards']:
            self.assertIn(rule, prompt)
        for channel in ['sms', 'imessage', 'telegram', 'photon', 'bluebubbles']:
            self.assertEqual(sections['alice.interactive']({'platform':channel}), '')

    def test_agent_skill_example_obeys_the_strict_artifact_contract(self):
        skill = (ROOT/'skills/openintelligentui/SKILL.md').read_text()
        examples = re.findall(r'```alice-interactive\n(.*?)\n```', skill, re.S)
        self.assertEqual(len(examples), 1)
        self.assertEqual(ui.prepare(json.loads(examples[0]))['status'], 'prepared')

    def test_native_calculators_have_plain_summary_on_text_channels(self):
        payload = {'type': 'calculator', 'summary': 'Ejemplo: ahorro mensual de 1000 euros.', 'inputs': []}
        fence = '```alice-ui\n' + json.dumps(payload) + '\n```'
        self.assertEqual(ui.plain_fallback(fence), payload['summary'])
        self.assertNotIn('calculator', ui.plain_fallback('```alice-ui\n{"type":"calculator"}\n```'))
        other = '```alice-ui\n{"type":"places","items":[]}\n```'
        self.assertEqual(ui.plain_fallback(other), other)

    def test_artifact_preparation_bypasses_action_review_but_external_tools_do_not(self):
        guard_spec = importlib.util.spec_from_file_location('tested_open_ui_guard', ROOT / 'review_task_guard.py')
        guard = importlib.util.module_from_spec(guard_spec)
        guard_spec.loader.exec_module(guard)
        # Pure assembly must neither require nor consume a Task approval, even
        # when the host store is unavailable. The tool still validates payloads.
        with patch.object(guard, 'Store', side_effect=AssertionError('must not access approvals')):
            self.assertIsNone(guard.check('/unused', 'generateSandboxedUi', sample(), 'session', 'default'))
        self.assertEqual(ui.prepare(sample())['status'], 'prepared')
        with self.assertRaises(ValueError):
            ui.prepare(dict(sample(), html='<iframe src="https://example.com">'))
        for tool in ('generateSandboxedUi_external', 'send_email', 'gmail_send_draft', 'browser_click', 'purchase_pay'):
            with self.subTest(tool=tool):
                self.assertFalse(guard.preparation(tool, sample()))

    def test_order_fallback_and_no_success_claim(self):
        result = ui.prepare(sample())
        self.assertEqual(result['status'], 'prepared')
        payload = json.loads(result['reply_block'].split('\n')[1])
        self.assertEqual(list(payload), list(ui.FIELDS))
        self.assertEqual(ui.plain_fallback(result['reply_block']), sample()['summary'])

    def test_rejects_unknown_missing_and_bad_types(self):
        invalid = [dict(sample(), execute=True), {k:v for k,v in sample().items() if k!='summary'},
                   dict(sample(), initialHeight=True), dict(sample(), initialHeight=901),
                   dict(sample(), placeholderMessages=['one']), dict(sample(), html=' '),
                   dict(sample(), jsExpressions='```'), dict(sample(), title='x'*161)]
        for args in invalid:
            with self.subTest(args=args):
                with self.assertRaises(ValueError): ui.prepare(args)

    def test_forbidden_markup_credentials_and_fence_injection(self):
        for html in ['<script>alert(1)</script>', '<IFRAME src="file:///private">',
                     '<form><input></form>', '<meta http-equiv="refresh">', '<input type="password">',
                     '<style>body{}</style>', '<object data="x">', '```\nmalicious']:
            with self.subTest(html=html):
                with self.assertRaises(ValueError): ui.prepare(dict(sample(), html=html))

    def test_unicode_and_code_survive_assembly(self):
        args = dict(sample(), html='<p>España & 日本</p>', jsFunctions='function render(){console.log("</script>");}')
        result = ui.prepare(args)
        self.assertEqual(json.loads(result['reply_block'].split('\n')[1]), args)

    def test_invalid_artifact_plain_channel_does_not_leak_code(self):
        self.assertNotIn('secret', ui.plain_fallback('```alice-interactive\n{"secret":"x"}\n```'))

    def test_registration_supplies_a_real_skill_path(self):
        plugin_spec = importlib.util.spec_from_file_location('tested_open_ui_plugin', ROOT / '__init__.py')
        plugin = importlib.util.module_from_spec(plugin_spec)
        plugin_spec.loader.exec_module(plugin)
        found = {}
        class Context:
            def register_skill(self, name, path, **kwargs):
                self_path = Path(path)
                if not self_path.is_file():
                    raise AssertionError('Hermes requires a real SKILL.md path')
                found[name] = self_path
            def __getattr__(self, name):
                return lambda *args, **kwargs: None
        plugin.register(Context())
        self.assertEqual(found['openintelligentui'], ROOT/'skills/openintelligentui/SKILL.md')

    def test_skill_and_prompt_preserve_safety_and_local_controls(self):
        skill = (ROOT/'skills/openintelligentui/SKILL.md').read_text()
        for rule in ['NO CDN', 'Never collect secrets', 'local', 'zero divisors', 'reduced motion', 'explicitly sends', 'snapshot']:
            self.assertIn(rule, skill)
        self.assertIn('prepared does not mean displayed', ui.SCHEMA['description'])
