"""偏好公開 API／CLI 的離線行為測試；所有 config 均為合成暫存資料。"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'preferences', Path(__file__).resolve().parents[1] / 'scripts' / 'preferences.py')
preferences = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preferences)

SCOPE = {'githubRepo': 'Sevenflanks/skills', 'branch': 'feat/39-erp-worklog', 'topic': '偏好記憶'}
PROJECT = {'reportType': 'PROJECT', 'projectId': 101, 'projectModuleId': 202, 'mandateCharterId': None}
RD = {'reportType': 'RD', 'projectId': None, 'projectModuleId': None, 'mandateCharterId': 303}


def file_security(path):
    if os.name != 'nt':
        info = path.stat()
        return (info.st_mode & 0o777, info.st_uid, info.st_gid)
    import ctypes
    from ctypes import wintypes
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    get = advapi.GetFileSecurityW
    get.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p,
                    wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    get.restype = wintypes.BOOL
    size = wintypes.DWORD()
    get(str(path), 7, None, 0, ctypes.byref(size))
    descriptor = ctypes.create_string_buffer(size.value)
    if not get(str(path), 7, descriptor, size.value, ctypes.byref(size)):
        raise ctypes.WinError(ctypes.get_last_error())
    convert = advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW
    convert.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                        ctypes.POINTER(wintypes.LPWSTR), ctypes.POINTER(wintypes.DWORD)]
    convert.restype = wintypes.BOOL
    result = wintypes.LPWSTR()
    if not convert(descriptor, 1, 7, ctypes.byref(result), None):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return result.value
    finally:
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree(ctypes.cast(result, ctypes.c_void_p))


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / 'erp' / 'config.json'
        self.config.parent.mkdir()

    def seed(self, text='{"apiKey":"synthetic-secret","future":{"nested":[true,null]}}'):
        self.config.write_text(text, encoding='utf-8')
        if os.name != 'nt':
            self.config.chmod(0o600)

    def store(self):
        return preferences.PreferenceStore(config=self.config)

    def test_missing_or_old_config_is_disabled_without_creating_credentials(self):
        self.assertEqual(self.store().read(), {'enabled': False, 'choices': []})
        self.assertFalse(self.config.exists())
        self.seed()
        before = self.config.read_bytes()
        store = self.store()
        self.assertEqual(store.read(), {'enabled': False, 'choices': []})
        self.assertIsNone(store.choice(SCOPE))
        self.assertEqual(self.config.read_bytes(), before)

    def test_malformed_config_or_namespace_fails_closed_without_rewriting(self):
        cases = [
            '{broken', '{"apiKey":"first","apiKey":"second"}',
            '{"future":{"x":1,"x":2}}', '{"future":NaN}', '[]',
            '{"dailyWorkLog":null}', '{"dailyWorkLog":{"enabled":"false","choices":[]}}',
            '{"dailyWorkLog":{"enabled":true}}',
            '{"dailyWorkLog":{"enabled":false,"choices":[],"apiKey":"forbidden"}}',
            '{"dailyWorkLog":{"enabled":true,"choices":[{}]}}',
        ]
        for text in cases:
            with self.subTest(text=text):
                self.seed(text)
                before = self.config.read_bytes()
                with self.assertRaises(preferences.PreferenceError):
                    self.store()
                self.assertEqual(self.config.read_bytes(), before)

    def test_only_explicit_enable_consent_persists_confirmed_choices(self):
        missing = self.store()
        with self.assertRaises(preferences.PreferenceError):
            missing.set_enabled(True, consent=True)
        self.assertFalse(self.config.exists())
        self.seed()
        before = self.config.read_bytes()
        store = self.store()
        with self.assertRaises(preferences.PreferenceError):
            store.set_enabled(True)
        store.remember(SCOPE, PROJECT, confirmed=True)
        self.assertEqual(self.config.read_bytes(), before)
        store.set_enabled(True, consent=True)
        enabled = self.config.read_bytes()
        with self.assertRaises(preferences.PreferenceError):
            store.remember(SCOPE, PROJECT)
        self.assertEqual(self.config.read_bytes(), enabled)
        store.remember(SCOPE, PROJECT, confirmed=True)
        self.assertEqual(self.store().choice(SCOPE), PROJECT)
        self.assertIsNone(self.store().choice(dict(SCOPE, topic='另一主題')))
        self.assertIsNone(self.store().choice(dict(SCOPE, branch='main')))
        self.assertIsNone(self.store().choice(dict(SCOPE, githubRepo='Other/skills')))
        self.assertEqual(self.store().read(), {'enabled': True, 'choices': [
            {'scope': SCOPE, 'choice': PROJECT}]})

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, '-B', str(Path(__file__).resolve().parents[1] / 'scripts' / 'preferences.py'),
             '--config', str(self.config)] + list(args),
            capture_output=True, text=True, encoding='utf-8')

    def test_preview_override_and_only_this_time_cli_keep_secrets_and_numbers(self):
        self.seed('{"apiKey":900719925474099312345,"fraction":0.123456789012345678901234567890,'
                  '"future":{"nested":[true,null],"n":1e-9999}}')
        result = self.cli('enable', '--consent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'enabled': True, 'choices': []})
        self.store().remember(SCOPE, PROJECT, confirmed=True)
        result = self.cli('remember', '--scope', json.dumps(SCOPE), '--choice', json.dumps(RD), '--confirmed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'enabled': True, 'choices': [
            {'scope': SCOPE, 'choice': RD}]})
        self.assertEqual(self.store().choice(SCOPE), RD)
        before = self.config.read_bytes()
        result = self.cli('remember', '--scope', json.dumps(SCOPE), '--choice', json.dumps(PROJECT),
                          '--confirmed', '--only-this-time')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)
        for forbidden in ('apiKey', 'fraction', 'future', '900719925474099312345', str(self.config)):
            self.assertNotIn(forbidden, result.stdout + result.stderr)
        from decimal import Decimal
        stored = json.loads(before, parse_float=Decimal)
        self.assertEqual(stored['apiKey'], 900719925474099312345)
        self.assertEqual(stored['fraction'], Decimal('0.123456789012345678901234567890'))
        self.assertEqual(stored['future'], {'nested': [True, None], 'n': Decimal('1e-9999')})

    def test_scope_must_be_explicit_and_cannot_expand_to_wildcard_or_checkout_alias(self):
        self.seed()
        store = self.store()
        store.set_enabled(True, consent=True)
        before = self.config.read_bytes()
        scopes = [
            dict(SCOPE, githubRepo='skills'), dict(SCOPE, githubRepo='https://github.com/Sevenflanks/skills'),
            dict(SCOPE, branch='*'), dict(SCOPE, branch='HEAD'), dict(SCOPE, branch=''),
            dict(SCOPE, branch='refs/heads/../main'), dict(SCOPE, branch='bad.lock'),
            dict(SCOPE, branch='@'), dict(SCOPE, branch='main:other'), dict(SCOPE, topic='*'),
            {'githubRepo': 'Sevenflanks/skills', 'branch': 'main'},
        ]
        for scope in scopes:
            with self.subTest(scope=scope):
                with self.assertRaises(preferences.PreferenceError):
                    store.remember(scope, PROJECT, confirmed=True)
                self.assertEqual(self.config.read_bytes(), before)

    def test_choices_cannot_smuggle_auth_text_or_invalid_references(self):
        self.seed()
        store = self.store()
        store.set_enabled(True, consent=True)
        before = self.config.read_bytes()
        choices = [dict(PROJECT, apiKey='synthetic'), dict(PROJECT, description='private'),
                   dict(PROJECT, reportType='UNKNOWN'), dict(PROJECT, projectId=True),
                   dict(PROJECT, projectId=1.5), dict(PROJECT, projectId=9223372036854775808),
                   dict(PROJECT, projectId=None), dict(RD, mandateCharterId=None),
                   dict(RD, projectModuleId=202)]
        for choice in choices:
            with self.subTest(choice=choice):
                with self.assertRaises(preferences.PreferenceError):
                    store.remember(SCOPE, choice, confirmed=True)
                self.assertEqual(self.config.read_bytes(), before)

    def test_disable_retains_choices_and_cannot_silently_reenable_or_autosave(self):
        self.seed()
        store = self.store()
        store.set_enabled(True, consent=True)
        store.remember(SCOPE, PROJECT, confirmed=True)
        store.set_enabled(False)
        before = self.config.read_bytes()
        self.assertIsNone(self.store().choice(SCOPE))
        store.remember(SCOPE, RD, confirmed=True)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.store().read(), {'enabled': False, 'choices': [
            {'scope': SCOPE, 'choice': PROJECT}]})
        with self.assertRaises(preferences.PreferenceError):
            store.set_enabled(True)
        self.assertEqual(self.config.read_bytes(), before)

    def test_stale_caller_cannot_overwrite_other_writer_or_late_change(self):
        self.seed()
        stale = self.store()
        self.store().set_enabled(True, consent=True)
        before = self.config.read_bytes()
        with self.assertRaises(preferences.PreferenceError):
            stale.set_enabled(False)
        self.assertEqual(self.config.read_bytes(), before)
        store = self.store()
        real_fsync = os.fsync
        def concurrent_writer(fd):
            real_fsync(fd)
            self.config.write_text('{"apiKey":"new-synthetic-secret","external":42}', encoding='utf-8')
        # fsync 是實際 OS 邊界；同時保留真正 flush，只在替換前插入另一個 writer。
        with patch('os.fsync', side_effect=concurrent_writer):
            with self.assertRaises(preferences.PreferenceError):
                store.remember(SCOPE, RD, confirmed=True)
        self.assertEqual(self.config.read_text(encoding='utf-8'),
                         '{"apiKey":"new-synthetic-secret","external":42}')
        self.assertEqual(list(self.config.parent.glob('.preferences-*')), [])

    def test_hardlinked_config_is_rejected_without_touching_target(self):
        self.seed()
        alias = self.config.with_name('alias.json')
        os.link(str(self.config), str(alias))
        before = self.config.read_bytes()
        with self.assertRaises(preferences.PreferenceError):
            preferences.PreferenceStore(config=alias)
        self.assertEqual(self.config.read_bytes(), before)

    def test_symlinked_config_is_rejected_without_touching_target(self):
        self.seed()
        before = self.config.read_bytes()
        alias = self.config.with_name('alias.json')
        try:
            alias.symlink_to(self.config)
        except OSError as error:
            if os.name == 'nt' and getattr(error, 'winerror', None) == 1314:
                self.skipTest('此 Windows token 沒有建立 symlink 的權限')
            raise
        with self.assertRaises(preferences.PreferenceError):
            preferences.PreferenceStore(config=alias)
        self.assertEqual(self.config.read_bytes(), before)

    def test_failed_replace_keeps_original_and_removes_private_temp(self):
        self.seed()
        before = self.config.read_bytes()
        self.config.chmod(0o400)
        try:
            store = self.store()
            with self.assertRaises(preferences.PreferenceError):
                store.set_enabled(True, consent=True)
            self.assertEqual(self.config.read_bytes(), before)
            self.assertEqual(list(self.config.parent.glob('.preferences-*')), [])
        finally:
            self.config.chmod(0o600)

    def test_temp_name_collision_never_deletes_someone_elses_file(self):
        self.seed()
        before = self.config.read_bytes()
        from uuid import UUID
        fixed = UUID('00000000-0000-0000-0000-000000000039')
        unrelated = self.config.with_name('.preferences-' + fixed.hex + '.tmp')
        unrelated.write_bytes(b'synthetic-other-owner-content')
        with patch('uuid.uuid4', return_value=fixed):
            with self.assertRaises(preferences.PreferenceError):
                self.store().set_enabled(True, consent=True)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertTrue(unrelated.exists())
        self.assertEqual(unrelated.read_bytes(), b'synthetic-other-owner-content')

    def test_cli_errors_never_echo_input_secrets_or_config_location(self):
        self.seed('{"apiKey":"synthetic-secret","dailyWorkLog":{"enabled":"bad"}}')
        result = self.cli('show')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual(json.loads(result.stderr), {'error': 'invalid_preferences_namespace'})
        result = self.cli('unknown-' + str(self.config))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr), {'error': 'invalid_cli_arguments'})

    def test_unrepresentable_number_fails_closed_without_traceback(self):
        self.seed('{"apiKey":1e999999999999999999999999999}')
        before = self.config.read_bytes()
        result = self.cli('enable', '--consent')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual(json.loads(result.stderr), {'error': 'invalid_config_json'})
        self.assertEqual(self.config.read_bytes(), before)

    def test_temp_is_private_and_atomic_replacement_preserves_original_security(self):
        self.seed()
        security = file_security(self.config)
        real_fsync = os.fsync
        observed = []
        def inspect_private_temp(fd):
            files = list(self.config.parent.glob('.preferences-*'))
            self.assertEqual(len(files), 1)
            private = file_security(files[0])
            if os.name == 'nt':
                self.assertEqual(private.split('D:', 1)[1], 'P(A;;FA;;;OW)')
            else:
                self.assertEqual(private[0], 0o600)
            observed.append(True)
            real_fsync(fd)
        with patch('os.fsync', side_effect=inspect_private_temp):
            self.store().set_enabled(True, consent=True)
        self.assertTrue(observed)
        self.assertEqual(file_security(self.config), security)
        self.assertEqual(list(self.config.parent.glob('.preferences-*')), [])

    @unittest.skipUnless(os.name == 'nt', 'Windows volume capability boundary')
    def test_windows_volume_without_persistent_acls_refuses_before_any_rewrite(self):
        import ctypes
        from ctypes import wintypes
        self.seed()
        before = self.config.read_bytes()
        load = ctypes.WinDLL
        class NoPersistentAcls:
            def __init__(self, library):
                self.library = library
                def volume_info(root, label, label_size, serial, component_size, flags, fs, fs_size):
                    ctypes.cast(flags, ctypes.POINTER(wintypes.DWORD))[0] = 0
                    return True
                self.GetVolumeInformationW = volume_info
            def __getattr__(self, name):
                return getattr(self.library, name)
        def library(name, **kwargs):
            actual = load(name, **kwargs)
            return NoPersistentAcls(actual) if name == 'kernel32' else actual
        with patch('ctypes.WinDLL', side_effect=library):
            with self.assertRaises(preferences.PreferenceError):
                self.store().set_enabled(True, consent=True)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.config.parent.glob('.preferences-*')), [])


if __name__ == '__main__':
    unittest.main()
