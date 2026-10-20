"""日誌個人偏好；只保存提示，不提供 ERP 選項核對、提交或共用 mapping 授權。"""

import argparse
import copy
from decimal import Decimal, DecimalException
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid


class PreferenceError(Exception):
    """對外僅提供固定錯誤碼，避免洩漏完整 config 或路徑。"""


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PreferenceError('duplicate_config_key')
        result[key] = value
    return result


def _invalid_constant(value):
    raise PreferenceError('invalid_json_number')


def _decode(raw):
    try:
        return json.loads(raw, object_pairs_hook=_pairs, parse_float=Decimal,
                          parse_constant=_invalid_constant)
    except (ValueError, UnicodeError, RecursionError, DecimalException):
        raise PreferenceError('invalid_config_json') from None


def _scope(scope):
    if (not isinstance(scope, dict) or set(scope) != {'githubRepo', 'branch', 'topic'}
            or not all(isinstance(v, str) and v and v == v.strip() for v in scope.values())):
        raise PreferenceError('invalid_scope')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+', scope['githubRepo']):
        raise PreferenceError('invalid_canonical_repo')
    if (scope['githubRepo'].endswith('.git') or scope['githubRepo'].split('/')[1] in ('.', '..')
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 or c in '*?[\\:^~' for c in scope['branch'])
            or scope['branch'] in ('HEAD', 'unknown', '@')
            or scope['branch'].startswith('-') or scope['branch'].endswith('.')
            or '..' in scope['branch'] or '@{' in scope['branch']
            or any(not p or p.startswith('.') or p.endswith('.lock') for p in scope['branch'].split('/'))
            or len(scope['topic']) > 120
            or any(ord(c) < 32 or c in '*?' for c in scope['topic'])):
        raise PreferenceError('invalid_scope')


def _choice(choice):
    fields = {'reportType', 'projectId', 'projectModuleId', 'mandateCharterId'}
    if not isinstance(choice, dict) or set(choice) != fields:
        raise PreferenceError('invalid_choice')
    kind = choice['reportType']
    if kind not in ('COMPANY', 'PROJECT', 'RD', 'OTHER', 'LEAVE'):
        raise PreferenceError('invalid_choice')
    for name in fields - {'reportType'}:
        value = choice[name]
        if value is not None and (type(value) is not int or not 0 < value <= 9223372036854775807):
            raise PreferenceError('invalid_choice_id')
    project, module, charter = (choice[k] for k in ('projectId', 'projectModuleId', 'mandateCharterId'))
    # RD null 也能保存已確認的歷史選擇；日後套用前仍須由 agent fresh 核對官方 options。
    if ((kind == 'PROJECT' and (project is None or charter is not None))
            or (kind == 'RD' and (project is not None or module is not None))
            or (kind not in ('PROJECT', 'RD') and any(v is not None for v in (project, module, charter)))):
        raise PreferenceError('invalid_choice_references')


def _namespace(config):
    if not isinstance(config, dict):
        raise PreferenceError('invalid_config_object')
    block = config.get('dailyWorkLog', {'enabled': False, 'choices': []})
    if (not isinstance(block, dict) or set(block) != {'enabled', 'choices'}
            or type(block['enabled']) is not bool or not isinstance(block['choices'], list)):
        raise PreferenceError('invalid_preferences_namespace')
    seen = []
    for entry in block['choices']:
        if not isinstance(entry, dict) or set(entry) != {'scope', 'choice'}:
            raise PreferenceError('invalid_preferences_entry')
        _scope(entry['scope'])
        _choice(entry['choice'])
        if entry['scope'] in seen:
            raise PreferenceError('duplicate_preference_scope')
        seen.append(entry['scope'])
    return block


def _encode(value):
    # 不經 float，避免寫偏好時把未知 credential／未來欄位的小數精度洗掉。
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k, ensure_ascii=True) + ':' + _encode(v)
                              for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ','.join(_encode(v) for v in value) + ']'
    return json.dumps(value, ensure_ascii=True, allow_nan=False)


def _unlinked_path(path):
    # 拒絕所有祖先的 symlink／Windows reparse point，不將偏好改寫導向另一個 config。
    for part in (path,) + tuple(path.parents):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise PreferenceError('linked_config_path')


def _snapshot(path):
    _unlinked_path(path)
    try:
        flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(str(path), flags)
    except FileNotFoundError:
        return None, None
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise PreferenceError('unsupported_config_file')
        raw = stream.read()
    return raw, info


def _identity(info):
    if info is None:
        return None
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            info.st_mode, info.st_uid, info.st_gid)


def _windows_temp(path):
    import ctypes
    from ctypes import wintypes
    import msvcrt

    class SecurityAttributes(ctypes.Structure):
        _fields_ = [('nLength', wintypes.DWORD), ('lpSecurityDescriptor', ctypes.c_void_p),
                    ('bInheritHandle', wintypes.BOOL)]

    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    volume_path = kernel.GetVolumePathNameW
    volume_path.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]
    volume_path.restype = wintypes.BOOL
    volume_info = kernel.GetVolumeInformationW
    volume_info.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD,
                            ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                            ctypes.POINTER(wintypes.DWORD), wintypes.LPWSTR, wintypes.DWORD]
    volume_info.restype = wintypes.BOOL
    root = ctypes.create_unicode_buffer(32768)
    flags = wintypes.DWORD()
    # FAT 等檔案系統可能忽略 security descriptor；建立前先確認能持久保護 DACL。
    if (not volume_path(str(path.parent), root, len(root))
            or not volume_info(root.value, None, 0, None, None, ctypes.byref(flags), None, 0)
            or not flags.value & 0x8):
        raise PreferenceError('private_temp_unavailable')
    convert = advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW
    convert.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p),
                        ctypes.POINTER(wintypes.DWORD)]
    convert.restype = wintypes.BOOL
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                       ctypes.POINTER(SecurityAttributes), wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    descriptor = ctypes.c_void_p()
    # Protected owner-rights DACL：暫存檔從建立那一刻起只給 owner，不繼承寬鬆目錄 ACL。
    if not convert('D:P(A;;FA;;;OW)', 1, ctypes.byref(descriptor), None):
        raise PreferenceError('private_temp_unavailable')
    try:
        attrs = SecurityAttributes(ctypes.sizeof(SecurityAttributes), descriptor, False)
        handle = create(str(path), 0x40000000, 0, ctypes.byref(attrs), 1, 0x80, None)
        if handle == ctypes.c_void_p(-1).value:
            raise PreferenceError('private_temp_unavailable')
        try:
            return msvcrt.open_osfhandle(handle, os.O_WRONLY | os.O_BINARY)
        except OSError:
            kernel.CloseHandle(handle)
            try:
                path.unlink()
            except OSError:
                raise PreferenceError('private_temp_cleanup_failed') from None
            raise
    finally:
        kernel.LocalFree(descriptor)


def _replace(path, temporary):
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        replace = ctypes.WinDLL('kernel32', use_last_error=True).ReplaceFileW
        replace.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR,
                            wintypes.DWORD, ctypes.c_void_p, ctypes.c_void_p]
        replace.restype = wintypes.BOOL
        # flags=0 保留目標 DACL；不可用 ignore-ACL-errors，否則可能把原權限擴大。
        if not replace(str(path), str(temporary), None, 0, None, None):
            raise PreferenceError('safe_replace_failed')
    else:
        os.replace(str(temporary), str(path))


class PreferenceStore:
    def __init__(self, config=None, config_root=None):
        if config is not None and config_root is not None:
            raise PreferenceError('conflicting_config_location')
        root = Path(config_root) if config_root is not None else Path.home() / '.config' / 'softleader' / 'agent-skills'
        self.path = (Path(config) if config is not None else root / 'erp' / 'config.json').absolute()
        try:
            self._raw, self._info = _snapshot(self.path)
        except OSError:
            raise PreferenceError('config_read_failed') from None
        self._config = _decode(self._raw) if self._raw is not None else {}
        _namespace(self._config)

    def read(self):
        return copy.deepcopy(_namespace(self._config))

    def choice(self, scope):
        _scope(scope)
        block = self.read()
        if block['enabled']:
            for entry in block['choices']:
                if entry['scope'] == scope:
                    return entry['choice']
        return None

    def set_enabled(self, enabled, consent=False):
        if type(enabled) is not bool:
            raise PreferenceError('invalid_enabled')
        if enabled and consent is not True:
            raise PreferenceError('enable_consent_required')
        block = self.read()
        block['enabled'] = enabled
        return self._save(block)

    def remember(self, scope, choice, confirmed=False, only_this_time=False):
        _scope(scope)
        _choice(choice)
        block = self.read()
        if only_this_time or not block['enabled']:
            return block
        if confirmed is not True:
            raise PreferenceError('confirmed_choice_required')
        for entry in block['choices']:
            if entry['scope'] == scope:
                entry['choice'] = copy.deepcopy(choice)
                break
        else:
            block['choices'].append({'scope': copy.deepcopy(scope), 'choice': copy.deepcopy(choice)})
        return self._save(block)

    def _check_fresh(self):
        raw, info = _snapshot(self.path)
        if raw != self._raw or _identity(info) != _identity(self._info):
            raise PreferenceError('config_changed_reload_required')

    def _save(self, block):
        if self._raw is None:
            raise PreferenceError('existing_access_config_required')
        temporary = self.path.with_name('.preferences-' + uuid.uuid4().hex + '.tmp')
        created = False
        try:
            self._check_fresh()
            if os.name != 'nt':
                parent = self.path.parent.stat()
                if (self._info.st_uid != os.geteuid() or parent.st_uid != os.geteuid()
                        or not self._info.st_mode & stat.S_IWUSR
                        or stat.S_IMODE(self._info.st_mode) & ~0o600 or parent.st_mode & 0o022
                        or (hasattr(os, 'listxattr') and os.listxattr(str(self.path)))):
                    raise PreferenceError('unsupported_config_permissions')
            config = copy.deepcopy(self._config)
            config['dailyWorkLog'] = block
            data = (_encode(config) + '\n').encode('utf-8')
            fd = (_windows_temp(temporary) if os.name == 'nt' else
                   os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
            created = True
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                if os.name != 'nt':
                    os.fchmod(stream.fileno(), stat.S_IMODE(self._info.st_mode))
                os.fsync(stream.fileno())
            # 最小 fresh-read compare：攔住 caller 舊 snapshot；不是跨程序 atomic CAS。
            self._check_fresh()
            _replace(self.path, temporary)
            self._raw, self._info = _snapshot(self.path)
            self._config = _decode(self._raw)
            return self.read()
        except OSError:
            raise PreferenceError('config_write_failed') from None
        finally:
            # exclusive create 失敗時不擁有該路徑；不可清除其他 writer 的同名檔。
            if created:
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass
                except OSError:
                    raise PreferenceError('private_temp_cleanup_failed') from None


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise PreferenceError('invalid_cli_arguments')


def main(argv=None):
    try:
        parser = _Parser(description='只讀寫 dailyWorkLog 個人偏好；不呼叫 ERP。')
        location = parser.add_mutually_exclusive_group()
        location.add_argument('--config-root', help='外部 ERP access 已解析的共用 config root')
        location.add_argument('--config', help='外部 ERP access 已解析的 config 檔案')
        sub = parser.add_subparsers(dest='command', required=True, parser_class=_Parser)
        sub.add_parser('show')
        enable = sub.add_parser('enable')
        enable.add_argument('--consent', action='store_true', help='使用者明確同意啟用記憶')
        sub.add_parser('disable')
        remember = sub.add_parser('remember')
        remember.add_argument('--scope', required=True, help='精確 githubRepo／branch／topic JSON')
        remember.add_argument('--choice', required=True, help='四個分類／參照欄位 JSON')
        remember.add_argument('--confirmed', action='store_true', help='使用者已確認本選擇')
        remember.add_argument('--only-this-time', action='store_true')
        args = parser.parse_args(argv)
        store = PreferenceStore(config=args.config, config_root=args.config_root)
        if args.command == 'enable':
            result = store.set_enabled(True, consent=args.consent)
        elif args.command == 'disable':
            result = store.set_enabled(False)
        elif args.command == 'remember':
            result = store.remember(_decode(args.scope), _decode(args.choice),
                                    confirmed=args.confirmed, only_this_time=args.only_this_time)
        else:
            result = store.read()
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return 0
    except PreferenceError as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
