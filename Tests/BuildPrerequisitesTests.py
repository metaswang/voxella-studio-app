"""Build dependency regressions; no Apple authentication or downloads."""
import contextlib
import io
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from build_prerequisites import BuildPrerequisites, PrerequisiteError, load_environment


class BuildPrerequisitesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = 'test profile; literal'
        self.commands = []
        self.notary_state = 'valid'
        self.metal_available = True
        self.installer_works = True
        self.version = 'Xcode 27\nBuild version TEST1\n'
        self.ignored_key = True
        self.env = {'NOTARY_PROFILE': self.profile}
        plist = self.root / 'Sources/VoxstudioPro/Resources/Info.plist'
        plist.parent.mkdir(parents=True)
        with plist.open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': 'org.example.test'}, stream)
        self.key = self.root / '.secrets/AuthKey_TESTKEY.p8'
        self.key.parent.mkdir()
        self.key.write_text('PRIVATE KEY CONTENT MUST NOT BE LOGGED')

    def fake_run(self, args, **kwargs):
        self.commands.append(args)
        code, output, error = 0, '', ''
        if 'history' in args:
            if self.notary_state == 'missing':
                code, error = 1, 'No Keychain password item found for profile'
            elif self.notary_state == 'network':
                code, error = 1, 'Unable to connect to Apple: network is offline'
        elif 'store-credentials' in args:
            self.notary_state = 'valid'
        elif args[0] == 'git':
            code = 0 if self.ignored_key else 1
        elif args[0] == 'xcode-select':
            output = '/Applications/TestXcode.app/Contents/Developer\n'
        elif args == ['xcodebuild', '-version']:
            output = self.version
        elif 'metal' in args:
            code = 0 if self.metal_available else 1
            output = 'Apple metal version test' if self.metal_available else ''
        elif '-importComponent' in args or '-downloadComponent' in args:
            self.metal_available = self.installer_works
        return subprocess.CompletedProcess(args, code, output, error)

    def prerequisites(self, **kwargs):
        instance = BuildPrerequisites(self.root, self.env, **kwargs)
        instance.run = self.fake_run
        return instance

    def configure_key(self):
        self.env.update(
            APP_STORE_CONNECT_API_KEY_ID='TESTKEY',
            APP_STORE_CONNECT_API_ISSUER_ID='test-issuer',
            APP_STORE_CONNECT_API_PRIVATE_KEY_PATH=str(self.key),
        )

    def test_valid_profile_is_reused_and_only_its_name_is_saved(self):
        self.configure_key()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.prerequisites().prepare('dist')
        self.assertFalse(any('store-credentials' in args for args in self.commands))
        cached = self.root / '.secrets/notary-profile.env'
        self.assertEqual(shlex.split(cached.read_text().split('=', 1)[1]), [self.profile])
        self.assertEqual(cached.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('PRIVATE KEY', output.getvalue() + cached.read_text())
        self.assertNotIn('test-issuer', output.getvalue() + cached.read_text())

    def test_debug_and_mas_builds_skip_notarization(self):
        self.env.clear()
        self.notary_state = 'missing'
        for mode in ('sign', 'fast', 'dev', 'mas'):
            self.prerequisites().prepare(mode)
        self.assertFalse(any('notarytool' in args for args in self.commands))
        self.assertFalse((self.root / '.secrets/notary-profile.env').exists())

    def test_missing_profile_is_restored_once_from_existing_asc_configuration(self):
        self.configure_key()
        self.notary_state = 'missing'
        self.prerequisites().prepare('dist')
        store = [args for args in self.commands if 'store-credentials' in args]
        self.assertEqual(len(store), 1)
        self.assertIn('--validate', store[0])
        self.assertIn(str(self.key), store[0])
        self.assertEqual(sum('history' in args for args in self.commands), 2)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)

    def test_missing_env_profile_reuses_the_saved_name(self):
        first = self.prerequisites()
        first.save_profile(self.profile)
        self.env.clear()
        later = self.prerequisites()
        later.prepare('dist')
        history = next(args for args in self.commands if 'history' in args)
        self.assertEqual(history[history.index('--keychain-profile') + 1], self.profile)
        self.assertEqual(later.env['NOTARY_PROFILE'], self.profile)

    def test_partial_notary_configuration_never_mixes_with_asc_configuration(self):
        self.configure_key()
        self.env['NOTARY_API_KEY_ID'] = 'DIFFERENTKEY'
        self.notary_state = 'missing'
        self.prerequisites().prepare('dist')
        store = next(args for args in self.commands if 'store-credentials' in args)
        self.assertEqual(store[store.index('--key-id') + 1], 'TESTKEY')
        self.assertEqual(store[store.index('--issuer') + 1], 'test-issuer')

    def test_complete_notary_configuration_takes_precedence_as_a_group(self):
        self.configure_key()
        self.env.update(NOTARY_API_KEY_ID='NOTARYKEY', NOTARY_API_ISSUER='notary-issuer', NOTARY_API_KEY_PATH=str(self.key))
        self.notary_state = 'missing'
        self.prerequisites().prepare('dist')
        store = next(args for args in self.commands if 'store-credentials' in args)
        self.assertEqual(store[store.index('--key-id') + 1], 'NOTARYKEY')
        self.assertEqual(store[store.index('--issuer') + 1], 'notary-issuer')

    def test_first_time_name_comes_from_bundle_id_and_key_path_can_be_inferred(self):
        self.configure_key()
        self.env.pop('NOTARY_PROFILE')
        self.env.pop('APP_STORE_CONNECT_API_PRIVATE_KEY_PATH')
        self.notary_state = 'missing'
        instance = self.prerequisites()
        instance.prepare('dist')
        self.assertEqual(instance.env['NOTARY_PROFILE'], 'org.example.test.notary')
        self.assertIn(str(self.key), next(args for args in self.commands if 'store-credentials' in args))

    def test_missing_credentials_do_not_start_component_download_or_notarization(self):
        self.notary_state = 'missing'
        self.metal_available = False
        with self.assertRaisesRegex(PrerequisiteError, 'Team API key'):
            self.prerequisites().prepare('dist')
        self.assertFalse(any('store-credentials' in args or '-downloadComponent' in args for args in self.commands))

    def test_network_failure_never_overwrites_an_existing_profile(self):
        self.configure_key()
        self.notary_state = 'network'
        with self.assertRaisesRegex(PrerequisiteError, 'credentials were not changed'):
            self.prerequisites().prepare('dist')
        self.assertFalse(any('store-credentials' in args for args in self.commands))

    def test_tracked_private_key_is_rejected_before_keychain_mutation(self):
        self.configure_key()
        self.notary_state = 'missing'
        self.ignored_key = False
        with self.assertRaisesRegex(PrerequisiteError, 'Git-ignored'):
            self.prerequisites().prepare('dist')
        self.assertFalse(any('store-credentials' in args for args in self.commands))

    def test_ready_metal_does_not_download_or_import(self):
        self.prerequisites().ensure_metal()
        self.assertFalse(any(args[0] == 'xcodebuild' for args in self.commands))

    def test_missing_metal_reuses_a_matching_offline_export(self):
        self.metal_available = False
        instance = self.prerequisites()
        cache = instance.metal_cache()
        (cache / 'MetalToolchain.exportedBundle').mkdir(parents=True)
        instance.ensure_metal()
        self.assertTrue(any('-importComponent' in args for args in self.commands))
        self.assertFalse(any('-downloadComponent' in args for args in self.commands))

    def test_xcode_change_never_imports_the_previous_xcode_export(self):
        self.metal_available = False
        instance = self.prerequisites()
        old_cache = instance.metal_cache()
        (old_cache / 'MetalToolchain.exportedBundle').mkdir(parents=True)
        self.version = 'Xcode 27.1\nBuild version TEST2\n'
        instance.ensure_metal()
        self.assertTrue(any('-downloadComponent' in args for args in self.commands))
        self.assertFalse(any('-importComponent' in args for args in self.commands))

    def test_successful_installer_exit_is_not_enough_without_a_working_compiler(self):
        self.metal_available = False
        self.installer_works = False
        with self.assertRaisesRegex(PrerequisiteError, 'compiler is unavailable'):
            self.prerequisites().ensure_metal()

    def test_check_only_does_not_store_credentials_install_or_write_profile_cache(self):
        self.prerequisites(check_only=True).prepare('dist')
        self.assertFalse((self.root / '.secrets/notary-profile.env').exists())
        self.notary_state = 'missing'
        with self.assertRaises(PrerequisiteError):
            self.prerequisites(check_only=True).ensure_notary()
        self.metal_available = False
        with self.assertRaises(PrerequisiteError):
            self.prerequisites(check_only=True).ensure_metal()
        self.assertFalse(any('store-credentials' in args or '-downloadComponent' in args for args in self.commands))

    def test_release_and_debug_load_the_correct_environment_without_logging_values(self):
        (self.root / '.env').write_text('export NOTARY_PROFILE="debug profile"\n')
        (self.root / '.env.prod').write_text('NOTARY_PROFILE="release profile"\n')
        with patch.dict(os.environ, {'NOTARY_PROFILE': 'inherited profile'}):
            self.assertEqual(load_environment(self.root, 'debug')['NOTARY_PROFILE'], 'debug profile')
            self.assertEqual(load_environment(self.root, 'release')['NOTARY_PROFILE'], 'release profile')


if __name__ == '__main__':
    unittest.main()
