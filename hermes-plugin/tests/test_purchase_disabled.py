"""The production kill switch closes purchase entry points without disabling reviews/watchers."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PurchaseDisabledTests(unittest.TestCase):
    def setUp(self):
        self.plugin = load(ROOT / '__init__.py', 'alice_disabled_test')
        self.feature = self.plugin._purchase_feature()
        self.assertFalse(self.feature.ENABLED)

    def test_tools_absent_and_reviews_watchers_present(self):
        ctx = mock.Mock()
        with mock.patch.object(self.plugin, '_start_feed'), mock.patch.object(self.plugin, '_pause_chat_goals'):
            self.plugin.register(ctx)
        names = {c.kwargs['name'] for c in ctx.register_tool.call_args_list}
        self.assertFalse(names & self.feature.TOOLS)
        self.assertTrue({'watchers', 'review_tasks', 'review_read'} <= names)
        for name in ('watchers', 'review_tasks', 'review_read'):
            self.assertIsNone(self.plugin._guard_purchase_disabled(name, {}))
        ctx.register_hook.assert_any_call('pre_tool_call', self.plugin._guard_review_task)
        self.assertEqual(ctx.register_hook.call_args_list[0].args,
                         ('pre_tool_call', self.plugin._guard_purchase_disabled))

    def test_stale_tools_and_payment_cards_block_before_execution(self):
        for name in self.feature.TOOLS:
            self.assertEqual(self.plugin._guard_purchase_disabled(name, {})['action'], 'block')
        with mock.patch.object(self.plugin, '_card_fill', return_value=mock.Mock(kind='payment')):
            self.assertEqual(self.plugin._guard_purchase_disabled('browser_vault_fill', {'handle': 'fake'})['action'], 'block')
        with mock.patch.object(self.plugin, '_card_fill', side_effect=OSError):
            self.assertEqual(self.plugin._guard_purchase_disabled('browser_vault_fill', {'handle': 'fake'})['action'], 'block')

    def test_existing_errand_cannot_act_in_browser_or_terminal(self):
        with mock.patch.object(self.plugin, '_hermes_root'), mock.patch.object(self.plugin, '_errands') as errands:
            errands.return_value.of_session.return_value = {'id': 'old'}
            for name in ('browser_exec', 'browser_click', 'terminal'):
                self.assertEqual(self.plugin._guard_purchase_disabled(name, {}, session_id='old')['action'], 'block')

    def test_http_approval_blocked_without_resume_or_payment(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        api = load(ROOT / 'dashboard/plugin_api.py', 'alice_disabled_api_test')
        app = FastAPI()
        app.include_router(api.router, prefix=api.PLUGIN_PREFIX)
        with mock.patch.object(api, '_errands_module') as errands:
            response = TestClient(app).post(api.PLUGIN_PREFIX + '/errands/old/checkout',
                                           json={'decision': 'allow', 'checkout_id': 'old'})
        self.assertEqual(response.status_code, 403)
        errands.assert_not_called()
