"""Exercise Hermes' registered hook entry point without a live agent or provider."""
import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

class ReviewHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location('review_hook_test_plugin', Path(__file__).resolve().parents[1] / '__init__.py')
        self.plugin = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.plugin)
        patches = [mock.patch.dict(sys.modules, {'hermes_constants': types.SimpleNamespace(get_hermes_home=lambda: self.home)}),
                   mock.patch.object(self.plugin, '_hermes_root', return_value=self.home)]
        for p in patches: p.start(); self.addCleanup(p.stop)
        self.store = self.plugin._module('review_tasks.py', 'review_hook_store').Store(self.home)
        self.addCleanup(self.store.close)
    def test_trusted_session_and_profile_are_required_for_single_use_approval(self):
        self.store.configure('draft_only')
        t = self.store.create('Send reply', 'Prepare then send this reply', 'original', 'default')
        t = self.store.update(t['id'], t['version'], 'needs_review', session='original', profile='default',
            summary='Ready', checks=['Checked recipient'], decision='send',
            proposal={'tool':'send_email', 'args':{'id':'draft'}, 'description':'Send the prepared reply'})
        self.store.respond(t['id'], t['version'], 'accept')
        hook = self.plugin._guard_review_task
        self.assertEqual(hook('send_email', {'id':'draft'}, 'other')['action'], 'block')
        self.assertIsNone(hook('send_email', {'id':'draft'}, 'original'))
        self.assertEqual(hook('send_email', {'id':'draft'}, 'original')['action'], 'block')
    def test_storage_or_policy_error_blocks_instead_of_allowing(self):
        with mock.patch.object(self.plugin, '_module', side_effect=RuntimeError('fixture')):
            self.assertEqual(self.plugin._guard_review_task('send_email', {}, 'original')['action'], 'block')

    def test_interactive_assembly_allowed_in_draft_only_and_tracked_tasks(self):
        self.store.configure('draft_only')
        self.store.create('Calculator', 'Split the bill locally', 'original', 'default')
        for session in ('original', 'untracked'):
            self.assertIsNone(self.plugin._guard_review_task('generateSandboxedUi', {}, session))
            self.assertEqual(self.plugin._guard_review_task('send_email', {}, session)['action'], 'block')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM approvals').fetchone()[0], 0)
