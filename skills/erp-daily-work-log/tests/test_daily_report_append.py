import io
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_daily_report import plan, report, leave, punch, SCRIPT


def existing(report_type='PROJECT', amount=4):
    return dict(id=80, reportType=report_type, hours=amount, subject='既有工作',
                description='既有內容', todos=None, projectId=70, projectModuleId=None,
                mandateCharterId=None, modifiedTime='2026-10-14T18:00:00',
                content='既有工作\n既有內容', newContent=None, delayDays=0,
                contentLengthValid=True)


def append_plan():
    value = plan()
    value['mode'] = 'append'
    value['context'].update(serverNow='2026-10-20T09:00:00+08:00', canReplace=False,
                            details=[existing(), dict(existing(), id=81, reportType='LEAVE',
                                                     projectId=None, hours=2, subject='請假')])
    value['rows'] = value['rows'][:1]
    value['rows'][0]['detail']['hours'] = 2
    return value


class AppendTests(unittest.TestCase):
    def test_append_keeps_leave_and_context_safety_gates_after_replace_deadline(self):
        value = append_plan()
        value['context'].update(leaves=[leave(8)], leaveHours=8)
        self.assertEqual(report.execute(value, authorized=True, contract_verified=True)['action'], 'stop')
        value = append_plan()
        value['context'].update(leaves=[], leaveHours=0, attendances=[punch('NONATTENDANCE')])
        self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                         {'action': 'ask', 'reason': 'leave_hours_unknown'})
        for field, update, reason in (
            ('expectedSnapshot', 'changed', 'snapshot_changed'),
            ('canReplace', None, 'invalid_replace_permission'),
            ('serverNow', '2026-10-20T09:00:00Z', 'invalid_server_timezone'),
            ('replaceDeadline', '2026-10-16T10:00:00+08:00', 'deadline_contract_mismatch'),
            ('reportDate', '2026-10-13', 'report_date_changed'),
        ):
            value = append_plan()
            value['context'][field] = update
            with self.subTest(field=field), self.assertRaisesRegex(report.ReportError, '^' + reason + '$'):
                report.execute(value, authorized=True, contract_verified=True)

    def test_append_requires_complete_combined_budget_idless_rows_and_current_authorization(self):
        for amount in (1, 3, 8):
            value = append_plan()
            value['rows'][0]['detail']['hours'] = amount
            with self.subTest(amount=amount), self.assertRaisesRegex(report.ReportError, '^hours_not_reconciled$'):
                report.execute(value, authorized=True, contract_verified=True)
        for extra in ({'id': 80}, {'modifiedTime': '2026-10-14T18:00:00'}):
            value = append_plan()
            value['rows'][0]['detail'].update(extra)
            with self.subTest(extra=extra), self.assertRaisesRegex(report.ReportError, '^invalid_new_detail$'):
                report.execute(value, authorized=True, contract_verified=True)
        value = append_plan()
        del value['expectedSnapshot']
        with self.assertRaisesRegex(report.ReportError, '^preview_snapshot_required$'):
            report.execute(value, authorized=True, contract_verified=True)
        with self.assertRaisesRegex(report.ReportError, '^official_contract_required$'):
            report.execute(append_plan(), authorized=True)
        self.assertEqual(report.execute(append_plan(), authorized='true')['action'], 'dry_run')

    def test_cli_sent_timeout_error_and_application_rejection_require_readback_and_consume_retry(self):
        for outcome in ('timeout', 'http500', 'application_error'):
            value = append_plan()
            value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                              'evidence': '官方確認原交易未持久化', 'retriesUsed': 0,
                              'originalIntent': report.execute(value)['intent']}
            requests = []

            class Opener:
                def open(self, request, timeout):
                    requests.append(request)
                    if outcome == 'timeout':
                        raise TimeoutError('fixture-only')
                    if outcome == 'http500':
                        raise report.urllib.error.HTTPError(request.full_url, 500, 'fixture-only', {},
                                                            io.BytesIO(b'fixture-only'))
                    response = io.BytesIO(b'{"messagesEmpty":false,"messages":[{"value":"fixture-only"}]}')
                    response.status = 200
                    return response

            with tempfile.TemporaryDirectory() as root:
                path, config = Path(root) / 'plan.json', Path(root) / 'config.json'
                path.write_text(json.dumps(value), encoding='utf-8')
                config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                                  encoding='utf-8')
                argv = [str(SCRIPT), '--plan', str(path), '--authorized', '--contract-verified',
                        '--config', str(config)]
                output = io.StringIO()
                with patch.object(sys, 'argv', argv), redirect_stdout(output), \
                        patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                    self.assertEqual(report.main(), 1)
                result = json.loads(output.getvalue())
                self.assertEqual(result['requestState'], 'unknown')
                self.assertEqual(result['retriesUsed'], 1)
                self.assertTrue(result['reason'].endswith('readback_required'))
                self.assertNotIn('fixture-only', output.getvalue())
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0].full_url, 'https://erp.example.test/backend/api/v2/daily-reports')
                value['retry'].update(outcome='unknown', retriesUsed=1)
                path.write_text(json.dumps(value), encoding='utf-8')
                output = io.StringIO()
                with patch.object(sys, 'argv', argv), redirect_stdout(output), \
                        patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                    self.assertEqual(report.main(), 0)
                self.assertEqual(json.loads(output.getvalue()),
                                 {'action': 'readback_required', 'reason': 'retry_outcome_unknown'})
                self.assertEqual(len(requests), 1)

    def test_cli_deep_json_response_after_post_is_unknown_and_does_not_retry(self):
        value = append_plan()
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                response = io.BytesIO(b'[' * 2000 + b'0' + b']' * 2000)
                response.status = 200
                return response

        with tempfile.TemporaryDirectory() as root:
            path, config = Path(root) / 'plan.json', Path(root) / 'config.json'
            path.write_text(json.dumps(value), encoding='utf-8')
            config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                              encoding='utf-8')
            argv = [str(SCRIPT), '--plan', str(path), '--authorized', '--contract-verified',
                    '--config', str(config)]
            output = io.StringIO()
            with patch.object(sys, 'argv', argv), redirect_stdout(output), \
                    patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                self.assertEqual(report.main(), 1)
            result = json.loads(output.getvalue())
            self.assertEqual(result, {'ok': False, 'reason': 'invalid_response_readback_required',
                                      'requestState': 'unknown', 'retriesUsed': 0})
            self.assertEqual(len(requests), 1)

            value['retry'] = {'outcome': 'unknown', 'trusted': True, 'evidence': '已讀回交易狀態',
                              'retriesUsed': 0, 'originalIntent': report.execute(value)['intent']}
            path.write_text(json.dumps(value), encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', argv), redirect_stdout(output), \
                    patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                self.assertEqual(report.main(), 0)
            self.assertEqual(json.loads(output.getvalue()),
                             {'action': 'readback_required', 'reason': 'retry_outcome_unknown'})
            self.assertEqual(len(requests), 1)

    def test_cli_pretransport_configuration_failure_is_not_sent_and_can_be_corrected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'plan.json'
            config = Path(root) / 'config.json'
            path.write_text(json.dumps(append_plan()), encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--plan', str(path),
                                     '--authorized', '--contract-verified', '--config', str(config)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout), {'ok': False, 'reason': 'external_config_unavailable',
                                                        'requestState': 'not_sent'})
            config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                              encoding='utf-8')
            response = io.BytesIO(b'{"reportDate":"2026-10-14","detailCount":1}')
            response.status = 200
            requests = []

            class Opener:
                def open(self, request, timeout):
                    requests.append(request)
                    return response

            with patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                result = report.execute(append_plan(), authorized=True, contract_verified=True, config_file=config)
            self.assertEqual(result['retriesUsed'], 0)
            self.assertEqual(json.loads(requests[0].data)['details'][0]['hours'], 2)
            self.assertEqual(len(requests), 1)

    def test_append_rejects_unusable_existing_references_and_hours(self):
        for update in ({'projectId': []}, {'projectId': None}, {'projectModuleId': {}},
                       {'reportType': 'RD', 'mandateCharterId': None},
                       {'hours': None}, {'hours': True}, {'reportType': 'UNKNOWN'}):
            value = append_plan()
            value['context']['details'][0].update(update)
            with self.subTest(update=update), self.assertRaises(report.ReportError):
                report.prepare(value)

    def test_project_and_rd_missing_references_are_rejected_before_transport(self):
        for mode in ('replace', 'append'):
            for report_type, reference in (('RD', 'mandateCharterId'), ('PROJECT', 'projectId')):
                for missing in (None, True, '901', {}):
                    value = plan()
                    value['mode'] = mode
                    value['rows'][0]['detail'].update(reportType=report_type)
                    value['rows'][0]['detail'][reference] = missing
                    with self.subTest(mode=mode, report_type=report_type, missing=missing), \
                            self.assertRaisesRegex(report.ReportError, 'missing_reference_id|invalid_reference_id'):
                        report.execute(value, authorized=True, contract_verified=True)

    def test_late_append_counts_existing_work_and_leave_without_replacing_them(self):
        value = append_plan()
        result = report.prepare(value)
        self.assertEqual(result, {'action': 'ready', 'payload': {
            'reportDate': '2026-10-14', 'details': [value['rows'][0]['detail']]}})
        self.assertEqual(value['context']['details'][0]['hours'], 4)

    def test_append_asks_on_existing_or_new_project_module_and_rd_uniqueness_conflicts(self):
        for report_type, references in (
            ('PROJECT', {'projectId': 70, 'projectModuleId': None}),
            ('RD', {'mandateCharterId': 901}),
        ):
            value = append_plan()
            value['context']['details'][0].update(reportType=report_type, **references)
            value['rows'][0]['detail'].update(reportType=report_type, **references)
            with self.subTest(report_type=report_type):
                self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                                 {'action': 'ask', 'reason': 'daily_uniqueness_conflict'})
        value = append_plan()
        value['rows'][0]['detail']['hours'] = 1
        value['rows'].append({'detail': dict(value['rows'][0]['detail'])})
        self.assertEqual(report.prepare(value), {'action': 'ask', 'reason': 'daily_uniqueness_conflict'})

    def test_append_never_adds_a_second_leave_row_even_when_hours_would_reconcile(self):
        value = append_plan()
        value['context']['details'][1]['hours'] = 1
        value['rows'].append({'detail': {'reportType': 'LEAVE', 'hours': 1, 'subject': '請假'}})
        self.assertEqual(report.prepare(value), {'action': 'ask', 'reason': 'existing_leave_conflict'})

    def test_authorized_late_append_sends_one_idless_submit_without_overwrite_or_snapshot(self):
        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, timeout):
                self.requests.append(request)
                response = io.BytesIO(b'{"reportDate":"2026-10-14","detailCount":1}')
                response.status = 200
                return response

        opener = Opener()
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'config.json'
            config.write_text(json.dumps({'baseUrl': 'https://erp.example.test/backend/',
                                          'apiTokenEnv': 'TEST_CORE_ERP_KEY'}), encoding='utf-8')
            with patch.dict(os.environ, {'TEST_CORE_ERP_KEY': 'fixture-only'}), \
                    patch.object(report.urllib.request, 'build_opener', return_value=opener):
                result = report.execute(append_plan(), authorized=True, contract_verified=True, config_file=config)
        self.assertEqual(result['action'], 'readback_required')
        self.assertEqual(len(opener.requests), 1)
        request = opener.requests[0]
        self.assertEqual(request.full_url, 'https://erp.example.test/backend/api/v2/daily-reports')
        self.assertEqual(request.get_method(), 'POST')
        self.assertEqual(json.loads(request.data), {
            'reportDate': '2026-10-14', 'details': [append_plan()['rows'][0]['detail']]})

    def test_unknown_timeout_or_blank_readback_does_not_authorize_another_post(self):
        for outcome in ('unknown', 'timeout', 'empty_readback'):
            value = append_plan()
            value['retry'] = {'outcome': outcome, 'trusted': True, 'evidence': '單次讀回空白',
                              'retriesUsed': 0, 'originalIntent': 'unproven'}
            self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                             {'action': 'readback_required', 'reason': 'retry_outcome_unknown'})

    def test_verified_applied_result_stops_instead_of_resending(self):
        value = append_plan()
        value['retry'] = {'outcome': 'applied'}
        self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                         {'action': 'stop', 'reason': 'already_applied'})

    def test_trusted_not_applied_allows_one_same_intent_retry_then_requires_authorization(self):
        value = append_plan()
        preview = report.execute(value)
        value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                          'evidence': '官方確認交易已終止且未持久化',
                          'retriesUsed': 0, 'originalIntent': preview['intent']}
        response = io.BytesIO(b'{"reportDate":"2026-10-14","detailCount":1}')
        response.status = 200
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                return response

        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'config.json'
            config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                              encoding='utf-8')
            with patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                result = report.execute(value, authorized=True, contract_verified=True, config_file=config)
                self.assertEqual(result['action'], 'readback_required')
                self.assertEqual(result['retriesUsed'], 1)
                self.assertEqual(json.loads(requests[0].data), preview['payload'])
                value['retry']['retriesUsed'] = 1
                self.assertEqual(report.execute(value, authorized=True, contract_verified=True, config_file=config),
                                 {'action': 'ask', 'reason': 'retry_authorization_required'})
        self.assertEqual(len(requests), 1)

    def test_retry_requires_trusted_evidence_and_unchanged_preview_intent(self):
        for update, reason in (
            ({'trusted': False}, 'retry_evidence_required'),
            ({'trusted': 'true'}, 'retry_evidence_required'),
            ({'evidence': ''}, 'retry_evidence_required'),
            ({'evidence': None}, 'retry_evidence_required'),
            ({'originalIntent': 'different'}, 'retry_intent_changed'),
            ({'retriesUsed': False}, 'retry_authorization_required'),
            ({'retriesUsed': 0.0}, 'retry_authorization_required'),
            ({'retriesUsed': '0'}, 'retry_authorization_required'),
            ({'retriesUsed': None}, 'retry_authorization_required'),
        ):
            value = append_plan()
            value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                              'evidence': '官方確認未持久化', 'retriesUsed': 0,
                              'originalIntent': report.execute(value)['intent']}
            value['retry'].update(update)
            self.assertEqual(report.execute(value), {'action': 'ask', 'reason': reason})
        for update in ({'subject': '新主旨'}, {'description': '新內容'}, {'projectId': 71},
                       {'projectModuleId': None}, {'hours': 2.0, 'todos': '新待辦'}):
            value = append_plan()
            value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                              'evidence': '官方確認未持久化', 'retriesUsed': 0,
                              'originalIntent': report.execute(value)['intent']}
            value['rows'][0]['detail'].update(update)
            self.assertEqual(report.execute(value), {'action': 'ask', 'reason': 'retry_intent_changed'})
        value = append_plan()
        value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                          'evidence': '官方確認未持久化', 'retriesUsed': 0,
                          'originalIntent': report.execute(value)['intent']}
        value['context']['expectedSnapshot'] = value['expectedSnapshot'] = 'snapshot-b'
        self.assertEqual(report.execute(value), {'action': 'ask', 'reason': 'retry_intent_changed'})


if __name__ == '__main__':
    unittest.main()
