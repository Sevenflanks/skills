import importlib.util
import io
import json
import os
import tempfile
import subprocess
import sys
import ssl
from unittest.mock import patch
import urllib.error
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'daily_report.py'
spec = importlib.util.spec_from_file_location('daily_report', SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def punch(classification='ATTENDANCE'):
    return {'id': 41, 'recordTime': '2026-10-14T09:00:00', 'classification': classification,
            'leaveType': None if classification == 'ATTENDANCE' else 'PERSONAL'}


def leave(amount, status='PASS', detail_id=31):
    return {'detailId': detail_id, 'status': status, 'hours': amount}


class BudgetTests(unittest.TestCase):
    def test_full_process_leave_stops_without_creating_leave_row(self):
        result = report.work_budget([leave(8, 'PROCESS')], [punch('NONATTENDANCE')])
        self.assertEqual(result, {'action': 'stop', 'leaveHours': 8.0, 'workHours': 0.0})

    def test_pass_and_process_official_daily_hours_count(self):
        result = report.work_budget([
            leave(2), leave(1, 'PROCESS', 32),
        ], [punch(), punch('NONATTENDANCE')])
        self.assertEqual(result, {'action': 'continue', 'leaveHours': 3.0, 'workHours': 5.0})

    def test_nonattendance_and_mixed_without_daily_hours_ask(self):
        for attendance in ([], [punch('NONATTENDANCE')], [punch(), punch('NONATTENDANCE')]):
            self.assertEqual(report.work_budget([], attendance)['action'], 'ask')
        self.assertEqual(report.work_budget([], [punch('NONATTENDANCE')], confirmed_leave=2)['workHours'], 6.0)

    def test_override_total_and_conflict_never_invent_hours(self):
        self.assertEqual(report.work_budget([leave(8)], [punch()], total=10)['workHours'], 2.0)
        self.assertEqual(report.work_budget([leave(9)], [punch()])['action'], 'ask')
        with self.assertRaises(report.ReportError):
            report.work_budget([leave(2)], [punch()], confirmed_leave=1)
        for invalid in (True, -1, 'NaN', 'Infinity', None):
            with self.assertRaises(report.ReportError):
                report.work_budget([], [punch()], total=invalid)

    def test_unknown_attendance_enum_cannot_be_assumed_zero_leave(self):
        with self.assertRaisesRegex(report.ReportError, 'unknown_attendance_or_leave'):
            report.work_budget([], [punch('unknown')])

    def test_unknown_leave_state_or_malformed_official_attendance_stops(self):
        for status in ('CANCEL', 'REJECT', 'UNKNOWN', None):
            with self.assertRaisesRegex(report.ReportError, 'unknown_attendance_or_leave'):
                report.work_budget([leave(2, status)], [punch()])
        for item in ('attend', {}, punch('UNKNOWN'), dict(punch(), leaveType='PERSONAL'),
                     dict(punch('NONATTENDANCE'), leaveType=None),
                     dict(punch('NONATTENDANCE'), leaveType='UNKNOWN'),
                     dict(punch(), recordTime='2026-13-14T09:00:00')):
            with self.assertRaises(report.ReportError):
                report.work_budget([], [item])


def plan():
    # fixture 依正式 Java DTO；保留完整 context 葉節點，不讀真實本人資料。
    return {
        'reportDate': '2026-10-14',
        'expectedSnapshot': 'snapshot-a',
        'context': {
            'reportDate': '2026-10-14', 'details': [], 'expectedSnapshot': 'snapshot-a',
            'serverNow': '2026-10-15T09:59:59+08:00',
            'replaceDeadline': '2026-10-15T10:00:00+08:00', 'canReplace': True,
            'leaves': [leave(2)], 'leaveHours': 2, 'attendances': [punch()],
        },
        'rows': [
            {'detail': {'reportType': 'PROJECT', 'hours': 6, 'subject': '驗證 mapping', 'description': '完成日期解析',
                        'todos': '後續讀回', 'projectId': 7, 'projectModuleId': 9, 'mandateCharterId': None}},
            {'detail': {'reportType': 'LEAVE', 'hours': 2, 'subject': '請假', 'description': None, 'todos': None,
                        'projectId': None, 'projectModuleId': None, 'mandateCharterId': None}},
        ],
    }


class PrepareTests(unittest.TestCase):
    def test_partial_leave_payload_and_exact_deadline_are_allowed(self):
        value = plan()
        value['context']['serverNow'] = '2026-10-15T10:00:00+08:00'
        result = report.prepare(value)
        self.assertEqual(result['action'], 'ready')
        self.assertEqual(result['payload'], {
            'reportDate': '2026-10-14', 'expectedSnapshot': 'snapshot-a',
            'details': [
                {'reportType': 'PROJECT', 'hours': 6, 'subject': '驗證 mapping', 'description': '完成日期解析',
                 'todos': '後續讀回', 'projectId': 7, 'projectModuleId': 9, 'mandateCharterId': None},
                {'reportType': 'LEAVE', 'hours': 2, 'subject': '請假', 'description': None, 'todos': None,
                 'projectId': None, 'projectModuleId': None, 'mandateCharterId': None},
            ],
        })

    def test_expired_uses_server_clock_and_returns_no_payload(self):
        value = plan()
        value['context']['serverNow'] = '2026-10-15T10:00:01+08:00'
        self.assertEqual(report.prepare(value), {'action': 'output_only', 'reason': 'deadline_passed'})

    def test_expired_unknown_leave_no_attendance_or_mapping_outputs_without_rows(self):
        for attendances in ([], [punch('NONATTENDANCE')], [punch(), punch('NONATTENDANCE')]):
            value = plan()
            value['context'].update(serverNow='2026-10-15T10:00:01+08:00', canReplace=False,
                                    leaves=[], leaveHours=0, attendances=attendances, details=[{'id': 8}])
            del value['rows']
            del value['expectedSnapshot']
            with self.subTest(attendances=attendances), patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
                self.assertEqual(report.execute(value, authorized=True),
                                 {'action': 'output_only', 'reason': 'deadline_passed'})

    def test_expired_known_full_leave_stops_before_collection_or_overwrite(self):
        for status in ('PROCESS', 'PASS'):
            value = plan()
            value['context'].update(serverNow='2026-10-15T10:00:01+08:00', canReplace=False,
                                    leaves=[leave(8, status)], leaveHours=8, details=[{'id': 8}])
            del value['rows']
            with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
                self.assertEqual(report.execute(value, authorized=True),
                                 {'action': 'stop', 'leaveHours': 8.0, 'workHours': 0.0})
        value['totalHours'] = 10
        self.assertEqual(report.prepare(value)['action'], 'output_only')

    def test_expiry_does_not_bypass_unknown_context_state_or_contract_gaps(self):
        for mutate in (
            lambda p: p['context']['attendances'][0].update(classification='UNKNOWN'),
            lambda p: p['context']['leaves'][0].update(status='UNKNOWN'),
            lambda p: p['context'].update(leaveHours=3),
            lambda p: p['context'].update(replaceDeadline='2026-10-15T02:00:00+00:00'),
            lambda p: p['context'].update(details=None),
        ):
            value = plan()
            value['context'].update(serverNow='2026-10-15T10:00:01+08:00', canReplace=False)
            mutate(value)
            with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
                with self.assertRaises(report.ReportError):
                    report.execute(value, authorized=True)

    def test_unexpired_unknown_leave_still_requires_hours(self):
        value = plan()
        value['context'].update(leaves=[], leaveHours=0, attendances=[punch('NONATTENDANCE')])
        del value['rows']
        self.assertEqual(report.prepare(value), {'action': 'ask', 'reason': 'leave_hours_unknown'})

    def test_full_leave_stops_even_with_work_evidence_rows(self):
        value = plan()
        value['context'].update(leaves=[leave(8, 'PROCESS')], leaveHours=8)
        self.assertEqual(report.prepare(value)['action'], 'stop')

    def test_shape_or_hours_cannot_silently_change_date_clear_day_or_reuse_id(self):
        for mutate in (
            lambda p: p['context'].update(reportDate='2026-10-13'),
            lambda p: p.update(rows=[]),
            lambda p: p['rows'][0]['detail'].update(id=99),
            lambda p: p['rows'][0].update(hours=5),
            lambda p: p['context'].update(expectedSnapshot=''),
            lambda p: p['context'].update(replaceDeadline='2026-10-16T10:00:00+08:00'),
            lambda p: p['context'].update(serverNow='2026-10-15T09:59:59'),
        ):
            value = plan()
            mutate(value)
            with self.assertRaises(report.ReportError):
                report.prepare(value)

    def test_actual_post_hours_and_type_control_reconciliation(self):
        for update in ({'hours': 9}, {'reportType': 'LEAVE'}):
            value = plan()
            value['rows'][0].update(hours=6, kind='WORK')
            value['rows'][0]['detail'].update(update)
            with self.assertRaisesRegex(report.ReportError, 'normalized_row_mismatch'):
                report.prepare(value)
        value = plan()
        value['rows'][0]['detail']['hours'] = 5
        with self.assertRaisesRegex(report.ReportError, 'hours_not_reconciled'):
            report.prepare(value)

    def test_official_context_leave_total_and_identifiers_cannot_disagree(self):
        for mutate in (
            lambda p: p['context'].update(leaveHours=3),
            lambda p: p['context'].update(leaveHours=None),
            lambda p: p['context']['leaves'].append(leave(0)),
            lambda p: p['context']['leaves'][0].update(detailId=True),
        ):
            value = plan()
            mutate(value)
            with self.assertRaises(report.ReportError):
                report.prepare(value)
        value = plan()
        del value['context']['leaveHours']
        self.assertEqual(report.prepare(value)['action'], 'ready')

    def test_detail_required_enum_amount_and_reference_types_are_validated(self):
        for update in (
            {'reportType': 'WORK'}, {'reportType': None}, {'reportType': []},
            {'subject': ''}, {'subject': None}, {'subject': 1},
            {'hours': 6.001}, {'hours': 10000}, {'hours': -1}, {'hours': True}, {'hours': '6'}, {'hours': None},
            {'projectId': {'id': 7}}, {'projectModuleId': True}, {'mandateCharterId': '9'},
            {'projectId': 9223372036854775808}, {'modifiedTime': '2026-10-14T12:00:00'},
            {'description': 1}, {'todos': []}, {'dailyReportId': 8}, {'reportId': 8},
        ):
            value = plan()
            value['rows'][0]['detail'].update(update)
            with self.subTest(update=update), self.assertRaises(report.ReportError):
                report.prepare(value)
        for field in ('reportType', 'hours', 'subject'):
            value = plan()
            del value['rows'][0]['detail'][field]
            with self.assertRaises(report.ReportError):
                report.prepare(value)
        for report_type in ('COMPANY', 'PROJECT', 'RD', 'OTHER'):
            value = plan()
            value['rows'][0]['detail']['reportType'] = report_type
            self.assertEqual(report.prepare(value)['action'], 'ready')

    def test_text_limits_include_join_separator_leading_linebreaks_and_utf16(self):
        value = plan()
        value['rows'][0]['detail'].update(subject='s' * 100, description='d' * 899, todos='t' * 900)
        self.assertEqual(report.prepare(value)['action'], 'ready')
        for field, text in (('subject', 's' * 101), ('description', 'd' * 900),
                            ('description', 'd' * 901), ('todos', 't' * 901),
                            ('subject', '\U0001f600' * 51)):
            invalid = plan()
            invalid['rows'][0]['detail'].update(subject='s' * 100, description='d' * 899, todos='t' * 900)
            invalid['rows'][0]['detail'][field] = text
            with self.subTest(field=field, length=len(text)), self.assertRaises(report.ReportError):
                report.prepare(invalid)
        value['rows'][0]['detail']['description'] = '\n' + 'd' * 899
        self.assertEqual(report.prepare(value)['action'], 'ready')
        value['rows'][0]['detail'].update(subject='\U0001f600' * 50, description=None)
        self.assertEqual(report.prepare(value)['action'], 'ready')

    def test_wrong_offset_even_equivalent_instant_cannot_extend_deadline(self):
        for field, text in (
            ('serverNow', '2026-10-15T01:59:59Z'),
            ('replaceDeadline', '2026-10-15T02:00:00+00:00'),
            ('replaceDeadline', '2026-10-15T10:00:00+09:00'),
        ):
            value = plan()
            value['context'][field] = text
            with self.assertRaisesRegex(report.ReportError, 'invalid_server_timezone'):
                report.prepare(value)

    def test_server_nanosecond_after_deadline_is_not_truncated_into_permission(self):
        value = plan()
        value['context']['serverNow'] = '2026-10-15T10:00:00.000000001+08:00'
        self.assertEqual(report.prepare(value), {'action': 'output_only', 'reason': 'deadline_passed'})

    def test_decimal_post_hours_reconcile_without_normalized_fields(self):
        value = plan()
        value['context'].update(leaves=[leave(1.75)], leaveHours=1.75)
        value['rows'][0]['detail']['hours'] = 6.25
        value['rows'][1]['detail']['hours'] = 1.75
        result = report.prepare(value)
        self.assertEqual(result['payload']['details'][0]['hours'], 6.25)
        self.assertEqual(result['payload']['details'][1]['hours'], 1.75)

    def test_same_day_context_and_reference_format_do_not_invent_reference_legality(self):
        value = plan()
        value['rows'][0]['detail']['projectId'] = -1
        self.assertEqual(report.prepare(value)['action'], 'ready')
        value['context']['attendances'][0]['recordTime'] = '2026-10-13T09:00:00'
        with self.assertRaisesRegex(report.ReportError, 'attendance_report_date_mismatch'):
            report.prepare(value)


class WriterTests(unittest.TestCase):
    def test_default_dry_run_never_reads_credentials_or_opens_network(self):
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
            self.assertEqual(report.execute(plan())['action'], 'dry_run')

    def test_existing_requires_separate_overwrite_and_stale_preview_cannot_write(self):
        value = plan()
        value['context']['details'] = [{'id': 8}]
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
            with self.assertRaisesRegex(report.ReportError, 'overwrite_confirmation_required'):
                report.execute(value, authorized=True, contract_verified=True)
            value['expectedSnapshot'] = 'old-snapshot'
            with self.assertRaisesRegex(report.ReportError, 'snapshot_changed'):
                report.execute(value, authorized=True, overwrite=True, contract_verified=True)

    def test_expired_and_full_leave_never_enter_transport_even_authorized(self):
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
            value = plan()
            value['context']['serverNow'] = '2026-10-15T10:00:01+08:00'
            self.assertEqual(report.execute(value, authorized=True)['action'], 'output_only')
            value['context'].update(leaves=[leave(8)], leaveHours=8)
            self.assertEqual(report.execute(value, authorized=True)['action'], 'stop')

    def test_contract_check_required_before_credentials(self):
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')):
            with self.assertRaisesRegex(report.ReportError, 'official_contract_required'):
                report.execute(plan(), authorized=True)

    def test_shared_external_config_and_env_credentials_are_read_only(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'erp' / 'config.json'
            config.parent.mkdir()
            original = '{"apiTokenEnv":"TEST_ERP_KEY"}'
            config.write_text(original, encoding='utf-8')
            with patch.dict(os.environ, {'TEST_ERP_KEY': 'fixture-key'}):
                self.assertEqual(report.load_access(config_root=root, base_url='https://erp.example.test/backend/'),
                                 ('https://erp.example.test/backend/', 'fixture-key'))
            self.assertEqual(config.read_text(encoding='utf-8'), original)

    def test_inline_and_default_env_contract_rejects_ambiguous_or_missing_key(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'config.json'
            base = 'https://erp.example.test/backend/'
            for data, environment, expected in (
                ({'baseUrl': base, 'apiToken': 'inline-fixture'}, {}, 'inline-fixture'),
                ({'baseUrl': base}, {'ERP_API_TOKEN': 'env-fixture'}, 'env-fixture'),
            ):
                config.write_text(json.dumps(data), encoding='utf-8')
                with patch.dict(os.environ, environment, clear=True):
                    self.assertEqual(report.load_access(config_file=config), (base, expected))
            for data in ({'baseUrl': base, 'apiToken': 'fixture', 'apiTokenEnv': 'TEST_KEY'},
                         {'baseUrl': base}, {'baseUrl': base, 'apiToken': 'fixture\nkey'}):
                config.write_text(json.dumps(data), encoding='utf-8')
                with patch.dict(os.environ, {}, clear=True):
                    with self.assertRaises(report.ReportError):
                        report.load_access(config_file=config)

    def test_invalid_selected_base_never_silently_falls_back_to_another_deployment(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'config.json'
            for configured in ('', None, 'https://other.example.test/'):
                config.write_text(json.dumps({'baseUrl': configured, 'apiToken': 'fixture-key'}), encoding='utf-8')
                with self.assertRaises(report.ReportError):
                    report.load_access(config_file=config, base_url='https://erp.example.test/backend/')

    def test_authorized_overwrite_sends_one_complete_payload_with_verified_tls(self):
        value = plan()
        value['context']['details'] = [{'id': 8}]
        response = io.BytesIO(b'{"messagesEmpty":true}')
        response.status = 200
        class Opener:
            calls = 0
            def open(self, request, timeout):
                self.calls += 1
                self.body = json.loads(request.data)
                return response
        opener = Opener()
        handlers = []
        def build(*args):
            handlers.extend(args)
            return opener
        with patch.object(report, 'load_access', return_value=('https://erp.example.test/backend/', 'fixture-key')):
            with patch.object(report.urllib.request, 'build_opener', side_effect=build):
                result = report.execute(value, authorized=True, overwrite=True, contract_verified=True)
        self.assertEqual(opener.calls, 1)
        self.assertEqual(len(opener.body['details']), 2)
        self.assertNotIn('id', opener.body['details'][0])
        self.assertEqual(result['action'], 'readback_required')
        tls = next(handler for handler in handlers if isinstance(handler, report.urllib.request.HTTPSHandler))
        self.assertTrue(tls._context.check_hostname)
        self.assertEqual(tls._context.verify_mode, ssl.CERT_REQUIRED)

    def test_cli_dry_run_and_malformed_or_token_arguments_do_not_echo_secrets(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'plan.json'
            path.write_text(json.dumps(plan()), encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)['action'], 'dry_run')
            path.write_text('{"reflected":"fixture-key"}', encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('fixture-key', result.stdout + result.stderr)
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path), '--api-token', 'fixture-key'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('fixture-key', result.stdout + result.stderr)

    def test_unsafe_base_or_reflected_credential_never_reaches_request(self):
        for base in ('http://erp.example.test/', 'https://user@erp.example.test/',
                     'https://erp.example.test/a/../', 'https://erp.example.test/%2e%2e/',
                     'https://erp.example.test/?q=1', 'https://erp.example.test/#x',
                     'https://erp.example.test/\\other/'):
            with self.assertRaises(report.ReportError):
                report.replace(base, 'fixture-key', {'details': [{}]})

    def test_post_is_scoped_and_auth_only_in_header_and_requires_readback(self):
        response = io.BytesIO(b'{"messagesEmpty":true}')
        response.status = 200
        class Opener:
            def open(self, request, timeout):
                self.request = request
                return response
        opener = Opener()
        with patch.object(report.urllib.request, 'build_opener', return_value=opener):
            result = report.replace('https://erp.example.test/backend/', 'fixture-key', report.prepare(plan())['payload'])
        request = opener.request
        self.assertEqual(request.full_url, 'https://erp.example.test/backend/api/v2/daily-reports/replace')
        self.assertEqual(request.get_method(), 'POST')
        self.assertEqual(request.get_header('X-api-key'), 'fixture-key')
        self.assertEqual(json.loads(request.data)['expectedSnapshot'], 'snapshot-a')
        self.assertNotIn('fixture-key', str(result))
        self.assertEqual(result['action'], 'readback_required')

    def test_redirect_does_not_make_a_second_request(self):
        handler = report.NoRedirect()
        request = report.urllib.request.Request('https://erp.example.test/backend/', headers={'X-API-KEY': 'fixture-key'})
        for code in (301, 302, 303, 307, 308):
            self.assertIsNone(handler.redirect_request(request, io.BytesIO(), code, 'redirect', {},
                                                      'https://other.example.test/?reflected=fixture-key'))

    def test_network_failure_or_reflected_http_error_is_sanitized_without_retry(self):
        for error in (TimeoutError('fixture-key'), urllib.error.URLError('fixture-key'),
                      report.http.client.HTTPException('fixture-key'),
                      urllib.error.HTTPError('https://erp.example.test/', 403, 'fixture-key', {}, io.BytesIO(b'fixture-key'))):
            class Opener:
                calls = 0
                def open(self, request, timeout):
                    self.calls += 1
                    raise error
            opener = Opener()
            with patch.object(report.urllib.request, 'build_opener', return_value=opener):
                with self.assertRaises(report.ReportError) as caught:
                    report.replace('https://erp.example.test/', 'fixture-key', report.prepare(plan())['payload'])
            self.assertEqual(opener.calls, 1)
            self.assertNotIn('fixture-key', str(caught.exception))

    def test_http_200_application_error_or_html_is_not_reported_complete(self):
        for body in (b'{"messagesEmpty":false,"message":"fixture-key"}', b'<html>fixture-key</html>'):
            response = io.BytesIO(body)
            response.status = 200
            class Opener:
                def open(self, request, timeout):
                    return response
            with patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                with self.assertRaises(report.ReportError) as caught:
                    report.replace('https://erp.example.test/', 'fixture-key', report.prepare(plan())['payload'])
            self.assertNotIn('fixture-key', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
