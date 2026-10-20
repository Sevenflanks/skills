import importlib.util
import io
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_daily_report import leave, plan as report_plan, punch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'project_repo_mapping.py'
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location('project_repo_mapping', SCRIPT)
mapping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapping)


def plan():
    source = report_plan()
    return {'reportDate': source['reportDate'], 'context': source['context'],
            'mapping': {'operation': 'create', 'projectId': 7, 'repo': 'acme/widget',
                        'branch': 'feature/billing'}}


class MappingTests(unittest.TestCase):
    def test_default_dates_are_frozen_in_dry_run_without_credentials(self):
        with patch.object(mapping.report, 'load_access', side_effect=AssertionError('credential read')):
            result = mapping.execute(plan())
        self.assertEqual(result, {'action': 'dry_run', 'method': 'POST',
                                 'path': 'api/v2/project-repo-mappings', 'payload': {
                                     'projectId': 7, 'repo': 'acme/widget', 'branch': 'feature/billing',
                                     'validFrom': '2026-10-14', 'validTo': None}})

    def test_update_preserves_readback_timestamp_and_never_sends_project_id(self):
        candidate = plan()
        candidate['mapping'].update(operation='update', mappingId=91,
                                    modifiedTime='2026-10-14T09:23:45.123456789',
                                    validFrom=None, validTo='2026-10-31')
        result = mapping.execute(candidate)
        self.assertEqual(result, {'action': 'dry_run', 'method': 'PUT',
                                 'path': 'api/v2/project-repo-mappings/91', 'payload': {
                                      'repo': 'acme/widget', 'branch': 'feature/billing',
                                      'validFrom': None, 'validTo': '2026-10-31',
                                      'modifiedTime': '2026-10-14T09:23:45.123456789'}})

    def test_modified_time_accepts_readback_iso_precision_and_rejects_legacy_space_seconds(self):
        for value in ('2026-10-14T09:23:45', '2026-10-14T09:23:45.1',
                      '2026-10-14T09:23:45.123456', '2026-10-14T09:23:45.123456789'):
            with self.subTest(value=value):
                self.assertEqual(mapping.modified_time(value), value)
        for value in ('2026-10-14 09:23:45', '2026-10-14 09:23:45.123456789'):
            with self.subTest(value=value), self.assertRaisesRegex(
                    mapping.report.ReportError, 'invalid_mapping_modified_time'):
                mapping.modified_time(value)

    def test_invalid_fields_ids_dates_and_arbitrary_operations_fail_before_access(self):
        variants = [
            {'operation': 'DELETE'}, {'method': 'PUT'}, {'path': '../daily-reports/replace'},
            {'url': 'https://invalid.example'}, {'id': 3}, {'projectModuleId': 1},
            {'projectId': True}, {'projectId': '7'}, {'projectId': 2**63},
            {'repo': 'https://example.invalid/a/b'}, {'repo': 'acme/widget\nX-API-KEY: leak'},
            {'repo': '../widget'}, {'branch': 'main\r\nInjected: x'}, {'branch': None},
            {'validFrom': '2026-02-29'}, {'validTo': '20261031'},
            {'validFrom': '2026-10-31', 'validTo': '2026-10-14'},
            {'mappingId': 1}, {'modifiedTime': '2026-10-14T12:00:00'}]
        with patch.object(mapping.report, 'load_access', side_effect=AssertionError('credential read')):
            for fields in variants:
                candidate = plan()
                candidate['mapping'].update(fields)
                with self.subTest(fields=fields), self.assertRaises(mapping.report.ReportError):
                    mapping.execute(candidate, mapping_confirmed=True, contract_verified=True)

    def test_update_requires_id_and_original_legal_local_timestamp(self):
        for fields in ({}, {'mappingId': '../1'}, {'mappingId': False}, {'mappingId': 2**63},
                       {'mappingId': 1}, {'mappingId': 1, 'modifiedTime': 'yesterday'},
                       {'mappingId': 1, 'modifiedTime': '2026-02-30T12:00:00'},
                       {'mappingId': 1, 'modifiedTime': '2026-10-14T12:00:00+08:00'}):
            candidate = plan()
            candidate['mapping'].update(operation='update', validFrom=None, validTo=None, **fields)
            with self.subTest(fields=fields), self.assertRaises(mapping.report.ReportError):
                mapping.execute(candidate)

    def test_mapping_confirmation_is_separate_from_contract_and_report_authorization(self):
        with patch.object(mapping.report, 'load_access', side_effect=AssertionError('credential read')):
            self.assertEqual(mapping.execute(plan(), contract_verified=True)['action'], 'dry_run')
            self.assertEqual(mapping.execute(plan(), mapping_confirmed='yes', contract_verified=True)['action'], 'dry_run')
            with self.assertRaisesRegex(mapping.report.ReportError, 'official_contract_required'):
                mapping.execute(plan(), mapping_confirmed=True)
            with self.assertRaises(TypeError):
                mapping.execute(plan(), authorized=True, contract_verified=True)

    def test_confirmed_create_and_update_send_exact_dry_run_payload_once(self):
        for updating in (False, True):
            candidate = plan()
            if updating:
                candidate['mapping'].update(operation='update', mappingId=91,
                                            modifiedTime='2026-10-14T09:23:45.123456',
                                            validFrom=None, validTo='2026-10-31')
            expected = mapping.execute(candidate)
            opener = MappingTransport()
            handlers = []
            def build(*args):
                handlers.extend(args)
                return opener
            with patch.object(mapping.report, 'load_access', return_value=(BASE, KEY)) as access:
                with patch.object(mapping.report.urllib.request, 'build_opener', side_effect=build):
                    result = mapping.execute(candidate, mapping_confirmed=True, contract_verified=True,
                                             config_root='fixture-config-root')
            access.assert_called_once_with('fixture-config-root', None, None)
            self.assertEqual(len(opener.requests), 1)
            request, timeout = opener.requests[0]
            self.assertEqual(request.full_url, BASE + expected['path'])
            self.assertEqual(request.get_method(), expected['method'])
            self.assertEqual(json.loads(request.data), expected['payload'])
            self.assertEqual(request.get_header('X-api-key'), KEY)
            self.assertEqual(timeout, 30)
            self.assertEqual(result, {'action': 'readback_required', 'httpStatus': 200})
            self.assertNotIn(KEY, json.dumps(result))
            tls = next(handler for handler in handlers if isinstance(handler, mapping.report.urllib.request.HTTPSHandler))
            self.assertTrue(tls._context.check_hostname)
            self.assertEqual(tls._context.verify_mode, ssl.CERT_REQUIRED)
            redirect = next(handler for handler in handlers if isinstance(handler, mapping.report.NoRedirect))
            self.assertIsNone(redirect.redirect_request(request, io.BytesIO(), 307, 'redirect', {},
                                                       'https://elsewhere.example.test/?key=' + KEY))

    def test_overlap_and_stale_application_errors_require_readback_without_retry(self):
        for message in ('period_overlap', 'stale_modifiedTime'):
            body = json.dumps({'messagesEmpty': False, 'messages': [message + KEY], 'data': None}).encode()
            opener = MappingTransport(body=body)
            with self.subTest(message=message), patch.object(mapping.report, 'load_access', return_value=(BASE, KEY)):
                with patch.object(mapping.report.urllib.request, 'build_opener', return_value=opener):
                    with self.assertRaisesRegex(mapping.report.ReportError, '^application_rejected_readback_required$'):
                        mapping.execute(plan(), mapping_confirmed=True, contract_verified=True)
            self.assertEqual(len(opener.requests), 1)
            request = opener.requests[0][0]
            self.assertEqual(json.loads(request.data)['validFrom'], '2026-10-14')
            self.assertEqual(request.get_method(), 'POST')

    def test_network_and_http_rejections_are_redacted_single_attempts(self):
        errors = [TimeoutError(KEY), mapping.report.urllib.error.URLError(KEY),
                  mapping.report.http.client.HTTPException(KEY)]
        for status in (302, 403, 404, 409, 500):
            errors.append(mapping.report.urllib.error.HTTPError(BASE, status, KEY, {}, io.BytesIO(KEY.encode())))
        for error in errors:
            opener = MappingTransport(error=error)
            with self.subTest(error=type(error).__name__), patch.object(mapping.report, 'load_access', return_value=(BASE, KEY)):
                with patch.object(mapping.report.urllib.request, 'build_opener', return_value=opener):
                    with self.assertRaises(mapping.report.ReportError) as caught:
                        mapping.execute(plan(), mapping_confirmed=True, contract_verified=True)
            self.assertNotIn(KEY, str(caught.exception))
            self.assertIn('readback_required', str(caught.exception))
            self.assertEqual(len(opener.requests), 1)

    def test_non_json_malformed_and_oversized_success_are_not_saved(self):
        for body in (b'<html>synthetic-mapping-key</html>', b'[]', b'x' * (1024 * 1024 + 1),
                     b'{"success":false,"data":"synthetic-mapping-key"}'):
            opener = MappingTransport(body=body)
            with patch.object(mapping.report, 'load_access', return_value=(BASE, KEY)):
                with patch.object(mapping.report.urllib.request, 'build_opener', return_value=opener):
                    with self.assertRaises(mapping.report.ReportError) as caught:
                        mapping.execute(plan(), mapping_confirmed=True, contract_verified=True)
            self.assertNotIn(KEY, str(caught.exception))
            self.assertIn('readback_required', str(caught.exception))
            self.assertEqual(len(opener.requests), 1)

    def test_independent_mapping_sends_despite_report_deadline_unknown_leave_or_full_leave(self):
        for state in ('expired_unknown_leave', 'unknown_leave', 'full_leave', 'no_report_context'):
            candidate = plan()
            candidate['context'].update(serverNow='2026-10-15T10:00:00.000000001+08:00',
                                        canReplace=False, leaves=[], leaveHours=0,
                                        attendances=[punch('NONATTENDANCE')])
            if state == 'full_leave':
                candidate['context'].update(serverNow='2026-10-14T18:00:00+08:00', canReplace=True,
                                            leaves=[leave(8, 'PROCESS')], leaveHours=8)
            elif state == 'unknown_leave':
                candidate['context'].update(serverNow='2026-10-14T18:00:00+08:00', canReplace=True)
            elif state == 'no_report_context':
                candidate.pop('context')
            opener = MappingTransport()
            with self.subTest(state=state), patch.object(mapping.report, 'load_access', return_value=(BASE, KEY)):
                with patch.object(mapping.report.urllib.request, 'build_opener', return_value=opener):
                    result = mapping.execute(candidate, mapping_confirmed=True, contract_verified=True)
            self.assertEqual(result, {'action': 'readback_required', 'httpStatus': 200})
            self.assertEqual(len(opener.requests), 1)
            request = opener.requests[0][0]
            self.assertEqual(request.get_method(), 'POST')
            self.assertEqual(json.loads(request.data), {
                'projectId': 7, 'repo': 'acme/widget', 'branch': 'feature/billing',
                'validFrom': '2026-10-14', 'validTo': None})

    def test_cli_dry_run_and_injected_flags_cannot_authorize_or_leak(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'plan.json'
            path.write_text(json.dumps(plan()), encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['action'], 'dry_run')
            for flag in ('--api-key', '--authorized', '--method', '--url'):
                result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path), flag, KEY],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(KEY, result.stdout + result.stderr)
            path.write_text('{"secret":"' + KEY + '"}', encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_mapping_date_is_validated_without_report_context_and_legacy_date_cannot_drift(self):
        variants = [None, False, '20261014', '2026-02-29', '2026-10-14T00:00:00']
        with patch.object(mapping.report, 'load_access', side_effect=AssertionError('credential read')):
            for value in variants:
                candidate = plan()
                candidate.pop('context')
                candidate['reportDate'] = value
                with self.subTest(value=value), self.assertRaisesRegex(
                        mapping.report.ReportError, '^invalid_report_date$'):
                    mapping.execute(candidate, True, True)
            candidate = plan()
            candidate['context']['reportDate'] = '2026-10-13'
            with self.assertRaisesRegex(mapping.report.ReportError, '^report_date_changed$'):
                mapping.execute(candidate, True, True)

    def test_update_cannot_silently_reset_omitted_old_period_to_new_defaults(self):
        for dates in ({}, {'validFrom': None}, {'validTo': None}):
            candidate = plan()
            candidate['mapping'].update(operation='update', mappingId=91,
                                        modifiedTime='2026-10-14T09:23:45.123456', **dates)
            with self.subTest(dates=dates), self.assertRaisesRegex(mapping.report.ReportError, 'mapping_update_dates_required'):
                mapping.execute(candidate)

    def test_dot_prefixed_repository_is_not_confused_with_traversal(self):
        candidate = plan()
        candidate['mapping']['repo'] = 'acme/.github'
        self.assertEqual(mapping.execute(candidate)['payload']['repo'], 'acme/.github')


BASE, KEY = 'https://erp.example.test/backend/', 'synthetic-mapping-key'


class MappingTransport:
    """只替換 network；含完整 mapping View 的 fixture，不接受重試或任意 endpoint。"""
    def __init__(self, body=None, error=None, status=200):
        self.requests = []
        self.error = error
        self.status = status
        self.body = body if body is not None else json.dumps({
            'messagesEmpty': True, 'messages': [], 'data': {
                'id': 91, 'projectId': 7, 'repo': 'acme/widget', 'branch': 'feature/billing',
                'validFrom': '2026-10-14', 'validTo': None,
                'modifiedBy': 'synthetic-user', 'modifiedTime': '2026-10-14T09:23:45.123456'}}).encode()

    def open(self, request, timeout):
        if self.requests:
            raise AssertionError('automatic retry')
        if (request.full_url not in (BASE + 'api/v2/project-repo-mappings',
                                    BASE + 'api/v2/project-repo-mappings/91')
                or request.get_method() not in ('POST', 'PUT')):
            raise AssertionError('unexpected operation')
        self.requests.append((request, timeout))
        if self.error is not None:
            raise self.error
        response = io.BytesIO(self.body)
        response.status = self.status
        return response


if __name__ == '__main__':
    unittest.main()
