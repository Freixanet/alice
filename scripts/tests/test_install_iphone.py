import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[1] / 'install-iphone.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class InstallerTests(unittest.TestCase):

    def scenario(self, *, race=False, build_fail=False, build_only=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ios').mkdir()
            (root / 'ios/project.yml').write_text('name: Alice\n')
            product = root / 'ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app'
            product.mkdir(parents=True)
            (product / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': m.BUNDLE, 'CFBundleVersion': '107'}))
            calls = []
            reads = 0
            installed = 107

            def run(args, **kwargs):
                calls.append(args)
                if args[0] == 'xcodebuild':
                    if build_fail:
                        raise RuntimeError('build failed')
                    app = root / 'ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app'
                    app.mkdir(parents=True, exist_ok=True)
                    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': m.BUNDLE, 'CFBundleVersion': '108'}))
                return ''

            def device(args, path):
                nonlocal reads, installed
                calls.append(args)
                if args[:2] == ['list', 'devices']:
                    return {'devices': [{'identifier': 'fixture-phone', 'hardwareProperties': {'deviceType': 'iPhone'}, 'connectionProperties': {'pairingState': 'paired'}}]}
                if args[:3] == ['device', 'info', 'apps']:
                    reads += 1
                    version = 109 if race and reads == 2 else installed
                    return {'apps': [{'bundleIdentifier': m.BUNDLE, 'bundleVersion': str(version)}]}
                if args[:3] == ['device', 'install', 'app']:
                    installed = 108
                return {}
            with patch.object(m.tempfile, 'gettempdir', return_value=tmp), patch.object(m, 'run', side_effect=run), patch.object(m, 'device_json', side_effect=device), patch.object(m, 'source_identity', return_value=('abc123', 'fixture')):
                opts = ['--repo', str(root)] + (['--build-only'] if build_only else [])
                if race or build_fail:
                    with self.assertRaises(RuntimeError):
                        m.main(opts)
                else:
                    m.main(opts)
            return calls

    def test_incremental_build_install_verify(self):
        calls = self.scenario()
        build = next((c for c in calls if c[0] == 'xcodebuild'))
        self.assertIn('CURRENT_PROJECT_VERSION=108', build)
        self.assertIn('Debug', build)
        self.assertIn('generic/platform=iOS', build)
        self.assertIn('/ios/.build/DeviceData', build[build.index('-derivedDataPath') + 1])
        self.assertNotIn('clean', build)
        self.assertNotIn('archive', build)
        self.assertEqual(sum((c[:3] == ['device', 'info', 'apps'] for c in calls)), 3)
        self.assertTrue(any((c[:3] == ['device', 'install', 'app'] for c in calls)))

    def test_concurrent_install_preserved(self):
        calls = self.scenario(race=True)
        self.assertFalse(any((c[:3] == ['device', 'install', 'app'] for c in calls)))

    def test_compile_failure_never_installs(self):
        calls = self.scenario(build_fail=True)
        self.assertFalse(any((c[:3] == ['device', 'install', 'app'] for c in calls)))

    def test_build_only_never_installs(self):
        calls = self.scenario(build_only=True)
        self.assertFalse(any((c[:2] == ['list', 'devices'] or c[:3] == ['device', 'info', 'apps'] for c in calls)))
        self.assertFalse(any((c[:3] == ['device', 'install', 'app'] for c in calls)))

    def test_unpublished_source_rejected(self):
        with patch.object(m, 'run', side_effect=['abc', 'branch', '', '', '']):
            with self.assertRaisesRegex(RuntimeError, 'remota'):
                m.source_identity(Path('.'))
if __name__ == '__main__':
    unittest.main()
