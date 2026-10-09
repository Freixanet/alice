"""Actual Seatbelt confinement, separate from fixture pipeline tests."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("watcher_runner_test", Path(__file__).resolve().parents[1] / "watcher_runner.py")
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class RunnerTests(unittest.TestCase):
    @unittest.skipUnless(r.Runner().available(), "macOS Seatbelt required")
    def test_matching_email_template_executes_classifier_notify_ack(self):
        from test_watchers import w
        calls = []
        def broker(name, args):
            calls.append(name)
            if name == 'classify':
                return {'action': {'key':'notify', 'confidence':1, 'probabilities':{'notify':1,'quiet':0}}}
            return True
        r.Runner().run(w.sibling('watcher_builtins.py').EMAIL_MATCH_CODE,
                       {'id':'email','from':'sender@example.com','subject':'Forwarded insurance','body':''}, {}, broker)
        self.assertEqual(calls, ['classify','notify','ack'])

    def test_language_rejects_ambient_tools_and_introspection(self):
        for code in ("import os", "x = event.__class__", "x = event.gi_frame", "x = state.__dict__"):
            with self.assertRaises(r.RunnerError):
                r.validate_code(code)

    @unittest.skipUnless(r.Runner().available(), "macOS Seatbelt required")
    def test_real_runner_brokers_only_allowed_capabilities(self):
        calls = []
        r.Runner().run('log(event["body"])', {"id": "e", "body": "test"}, {}, lambda name, args: calls.append((name, args)))
        self.assertEqual(calls, [("log", ["test"])])

    @unittest.skipUnless(r.Runner().available(), "macOS Seatbelt required")
    def test_os_denies_user_files_network_and_new_processes(self):
        with tempfile.TemporaryDirectory() as folder:
            sentinel = Path(folder) / "private-data"
            sentinel.write_text("test-only sentinel")
            # Trusted attack program bypasses the language guard deliberately: prove
            # that the OS profile is a second boundary, not just missing builtins.
            code = f'''
import json, socket, subprocess
results=[]
for attack in [lambda: open({str(sentinel)!r}).read(), lambda: socket.socket().bind(('127.0.0.1',0)), lambda: subprocess.run(['/bin/echo','escape'])]:
    try: attack(); results.append('escaped')
    except (PermissionError, OSError): results.append('denied')
print(json.dumps(results))
'''
            result = subprocess.run(["/usr/bin/sandbox-exec", "-p", r.profile(), r.executable(), "-I", "-S", "-c", code],
                                    cwd="/", env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), ["denied", "denied", "denied"])

    @unittest.skipUnless(r.Runner().available(), "macOS Seatbelt required")
    def test_timeout_kills_script(self):
        with self.assertRaisesRegex(r.RunnerError, "timed out"):
            r.Runner(timeout=0.25).run("while True: pass", {"id": "e"}, {}, lambda *_: None)


if __name__ == "__main__":
    unittest.main()
