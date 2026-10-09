import importlib.util
import tempfile
import sys
import unittest
from pathlib import Path
from unittest import mock


class WatcherAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        path = Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py"
        spec = importlib.util.spec_from_file_location("watcher_api_test", path)
        cls.api = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.api
        spec.loader.exec_module(cls.api)
        app = FastAPI()
        app.include_router(cls.api.router, prefix=cls.api.PLUGIN_PREFIX)
        cls.client = TestClient(app)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        patch = mock.patch.object(self.api, "_hermes_root", return_value=Path(self.temp.name))
        patch.start()
        self.addCleanup(patch.stop)

    def test_setup_and_activation_fail_closed(self):
        root = "/api/plugins/alice/watchers"
        self.assertTrue(self.client.get(root).json()["setup_required"])
        response = self.client.post(root, json={"name": "Test", "source": "builtin", "config": {"kind": "follow_up"}, "created_by_request": "Remind me"})
        self.assertEqual(response.status_code, 200)
        ident = response.json()["watcher"]["id"]
        response = self.client.post(root + f"/{ident}/actions", json={"action": "activate"})
        self.assertEqual(response.status_code, 400)
        self.assertIn("Configure your cheap classifier", response.text)

    def test_unscoped_webhook_and_secret_config_are_rejected(self):
        root = "/api/plugins/alice/watchers"
        response = self.client.post(root + "/inbound?watcher=unknown&secret=x", json={"id": "e", "body": "test"})
        self.assertEqual(response.status_code, 401)
        response = self.client.put(root + "/route", json={"provider": "cheap", "model": "cheap", "base_url": "https://example.com/v1", "api_key": "must-not-store"})
        self.assertEqual(response.status_code, 422)

    def test_delete_from_dashboard_removes_watch_and_blocks_activation(self):
        root = "/api/plugins/alice/watchers"
        response = self.client.post(root, json={"name": "Remove me", "source": "builtin", "config": {"kind": "follow_up"}, "created_by_request": "Remind me"})
        ident = response.json()["watcher"]["id"]
        response = self.client.post(root + f"/{ident}/actions", json={"action": "delete"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["deleted"])
        self.assertEqual(self.client.get(root).json()["watchers"], [])
        self.assertEqual(self.client.post(root + f"/{ident}/actions", json={"action": "activate"}).status_code, 400)
        self.assertEqual(self.client.post(root + f"/{ident}/actions", json={"action": "delete"}).status_code, 200)

    def test_per_watcher_provider_rotation_and_scope(self):
        module = self.api._watcher_module()
        store = module.Store(Path(self.temp.name))
        self.addCleanup(store.close)
        ident = store.create("local", "Test", "builtin", {"kind": "birthday"}, "pass", "Notify birthdays")["id"]
        secret = store.rotate_webhook(ident)
        provider = self.api._watcher_provider_class()()
        principal = provider.verify_token(token=secret)
        self.assertEqual(principal.principal, ident)
        self.assertEqual(principal.scopes, ("alice-watcher-inbound",))
        store.rotate_webhook(ident, revoke=True)
        self.assertIsNone(provider.verify_token(token=secret))

    def test_morning_settings_are_validated_and_usage_has_daily_categories(self):
        root = "/api/plugins/alice/watchers"
        snapshot = self.client.get(root).json()
        self.assertEqual(snapshot['morning']['time'], '08:00')
        self.assertEqual(snapshot['morning']['timezone'], 'Europe/Madrid')
        self.assertEqual(snapshot['usage']['today']['total'], 0)
        with mock.patch.object(self.api, '_schedule_watchers') as schedule:
            changed = self.client.put(root + '/morning', json={'time':'09:15','timezone':'Europe/Madrid','enabled':True})
            self.assertEqual(changed.status_code, 200)
            schedule.assert_called_once()
        self.assertEqual(self.client.get(root).json()['morning']['time'], '09:15')
        self.assertEqual(self.client.put(root + '/morning', json={'time':'25:00'}).status_code, 400)
        self.assertEqual(self.client.put(root + '/morning', json={'time':'08:00','routine_type':'evening'}).status_code, 422)
