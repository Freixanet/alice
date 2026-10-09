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
