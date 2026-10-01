"""Fixed errand routing: no request inherits the chat's model or an invalid setting."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("alice_errand_model_test", Path(__file__).resolve().parents[1] / "errands.py")
errands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(errands)


class ErrandModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def configure(self, value):
        path = self.home / ".alice" / "errand-model.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def test_new_errands_save_the_model_and_provider(self):
        with mock.patch.object(errands, "open_goal"), mock.patch.object(errands, "launch"):
            result = errands.start(self.home, {"task": "Reservar una mesa"})
        entry = errands.get(self.home, result["errand_id"])
        self.assertEqual((entry["model"], entry["provider"]), ("gpt-6-luna", "openai-codex"))

    def test_no_model_run_is_spent_until_the_browser_is_ready(self):
        entry = errands.create(self.home, "Preparar el pedido")
        gateway = mock.Mock()
        engine = errands.Engine(self.home, entry["id"], gateway=gateway)
        with mock.patch.object(errands, "prepare_browser", return_value=False):
            self.assertEqual(engine.run(), "stuck")
        gateway.start.assert_not_called()
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["runs"], 0)
        self.assertIn("navegador", saved["reason"])

    def test_failed_start_is_visible_and_can_be_retried(self):
        with mock.patch.object(errands, 'open_goal', side_effect=RuntimeError('offline')), \
                mock.patch.object(errands, 'launch') as launch:
            with self.assertRaises(RuntimeError):
                errands.start(self.home, {'task': 'Reservar una mesa'}, origin_session='chat-one')
            launch.assert_not_called()
        failed = errands.listing(self.home)[0]
        self.assertEqual(failed['status'], 'stuck')
        with mock.patch.object(errands, 'open_goal'), mock.patch.object(errands, 'launch'):
            result = errands.start(self.home, {'task': 'Reservar una mesa'}, origin_session='chat-one')
        self.assertNotEqual(result['errand_id'], failed['id'])

    def test_the_local_override_is_saved_only_for_new_errands(self):
        first = errands.create(self.home, "Primero")
        self.configure(json.dumps({"model": "other-model", "provider": "openai-codex"}))
        second = errands.create(self.home, "Segundo")
        self.assertEqual(first["model"], "gpt-6-luna")
        self.assertEqual(second["model"], "other-model")

    def test_invalid_configuration_never_starts_an_errand(self):
        for config in ("{", "[]", "{}", '{"model": "", "provider": "openai-codex"}',
                       '{"model": "gpt-6-luna", "provider": ""}',
                       '{"model": "two models", "provider": "openai-codex"}'):
            with self.subTest(config=config):
                self.configure(config)
                with mock.patch.object(errands, "launch") as launch, self.assertRaises(ValueError):
                    errands.start(self.home, {"task": "Reservar una mesa"})
                launch.assert_not_called()
                self.assertEqual(errands.listing(self.home), [])

    def test_every_gateway_request_names_both_model_and_provider(self):
        gateway = errands.Gateway(self.home)
        with mock.patch.object(gateway, "_call", return_value={"run_id": "run-1"}) as call:
            self.assertEqual(gateway.start("errand-one", "Continuar", model="gpt-6-luna", provider="openai-codex"), "run-1")
        call.assert_called_once_with("POST", "/v1/runs", {
            "input": "Continuar", "session_id": "errand-one", "model": "gpt-6-luna", "provider": "openai-codex"})
