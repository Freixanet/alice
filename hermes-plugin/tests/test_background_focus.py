import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('focus_errands', root / 'errands.py')
errands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(errands)

class FocusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = Path(self.tmp.name) / 'context.json'
        self.calls = []
        self.tabs = {}
        self.switched = []
        self.ctx = 'owned'
        def cdp(method, **args):
            self.calls.append((method, args))
            if method == 'Target.getTargets': return {'targetInfos': [{'targetId': t} for t in self.tabs]}
            if method == 'Target.createBrowserContext': return {'browserContextId': self.ctx}
            if method == 'Target.getBrowserContexts': return {'browserContextIds': [self.ctx]}
            if method == 'Target.createTarget':
                self.assertTrue(args['background'])
                tid = 'tab' + str(len(self.tabs))
                self.tabs[tid] = args['browserContextId']
                return {'targetId': tid}
            if method == 'Target.getTargetInfo': return {'targetInfo': {'browserContextId': self.tabs.get(args['targetId'])}}
            return {}
        self.env = {'cdp': cdp, 'switch_tab': lambda t, activate=False: self.switched.append((t, activate)),
                    'capture_screenshot': lambda: 'fixture', 'goto_url': lambda u: None}
        with patch.object(errands, 'context_file', return_value=self.file):
            self.code = errands.context_preamble('fixture')
    def run_step(self):
        # Each browser_exec gets a fresh harness namespace.
        env = {**self.env}
        exec(self.code, env)
        return env
    def test_new_and_reused_steps_never_activate(self):
        self.run_step(); self.run_step()
        self.assertEqual(len(self.tabs), 1)
        self.assertNotIn('Target.activateTarget', [m for m, _ in self.calls])
        self.assertTrue(all(not active for _, active in self.switched))
        self.assertEqual(sum(m == 'Emulation.setFocusEmulationEnabled' for m, _ in self.calls), 2)
    def test_switch_and_new_tab_remain_background_even_when_activation_requested(self):
        env = self.run_step()
        env['switch_tab']('tab0', activate=True)
        env['new_tab']('https://example.test')
        self.assertTrue(all(not active for _, active in self.switched))
        self.assertNotIn('Target.activateTarget', [m for m, _ in self.calls])
        self.assertEqual(json.loads(self.file.read_text())['target'], 'tab1')
    def test_foreign_context_remains_rejected(self):
        env = self.run_step()
        self.tabs['foreign'] = 'another-agent'
        before = len(self.switched)
        with self.assertRaisesRegex(RuntimeError, 'no pertenece'): env['switch_tab']('foreign')
        self.assertEqual(len(self.switched), before)
    def test_focus_failure_stops_step_without_activating_window(self):
        original = self.env['cdp']
        def failed(method, **args):
            if method == 'Emulation.setFocusEmulationEnabled': raise RuntimeError('unsupported')
            return original(method, **args)
        self.env['cdp'] = failed
        with self.assertRaisesRegex(RuntimeError, 'No se pudo aislar'): self.run_step()
        self.assertNotIn('Target.activateTarget', [m for m, _ in self.calls])

if __name__ == '__main__': unittest.main()
