"""已確認的 RD 選擇必須與實際送出內容一致；只用離線 transport 與暫存 config。"""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_daily_report import plan, report, SCRIPT
from test_daily_report_append import existing


def rd_plan(mode='replace', charter=901):
    value = plan()
    value['mode'] = mode
    value['rows'][0].update(expectedMandateCharterId=charter)
    value['rows'][0]['detail'].update(reportType='RD', projectId=None,
                                     projectModuleId=None, mandateCharterId=charter)
    return value


class SelectionTests(unittest.TestCase):
    def test_selection_changes_invalidate_original_retry_intent_and_require_new_preview(self):
        for mode in ('replace', 'append'):
            for old, new in ((None, 901), (901, 902), (901, None)):
                value = rd_plan(mode, old)
                preview = report.execute(value)
                value['rows'][0]['expectedMandateCharterId'] = new
                value['rows'][0]['detail']['mandateCharterId'] = new
                revised = report.execute(value)
                self.assertNotEqual(preview['intent'], revised['intent'])
                self.assertEqual(revised['payload']['details'][0]['mandateCharterId'], new)
                value['retry'] = {'outcome': 'definitely_not_applied', 'trusted': True,
                                  'evidence': '官方確認原交易未持久化', 'retriesUsed': 0,
                                  'originalIntent': preview['intent']}
                with self.subTest(mode=mode, old=old, new=new), \
                        patch.object(Path, 'read_text', side_effect=AssertionError('credential read')), \
                        patch.object(report.urllib.request, 'build_opener', side_effect=AssertionError('network')):
                    self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                                     {'action': 'ask', 'reason': 'retry_intent_changed'})

    def test_absent_selection_is_unknown_even_when_detail_has_no_charter(self):
        for mode in ('replace', 'append'):
            for omitted in (False, True):
                value = rd_plan(mode, None)
                del value['rows'][0]['expectedMandateCharterId']
                if omitted:
                    del value['rows'][0]['detail']['mandateCharterId']
                with self.subTest(mode=mode, omitted=omitted), \
                        patch.object(Path, 'read_text', side_effect=AssertionError('credential read')), \
                        patch.object(report.urllib.request, 'build_opener', side_effect=AssertionError('network')), \
                        self.assertRaisesRegex(report.ReportError, '^selection_required$'):
                    report.execute(value, authorized=True, contract_verified=True)

    def test_selected_ids_use_existing_java_long_contract_without_defaulting(self):
        for charter in (-9223372036854775808, 0, 9223372036854775807):
            with self.subTest(charter=charter):
                prepared = report.prepare(rd_plan(charter=charter))
                self.assertEqual(prepared['action'], 'ready')
                self.assertEqual(prepared['payload']['details'][0]['mandateCharterId'], charter)

    def test_null_charters_coexist_with_each_other_and_existing_rows_but_still_reconcile(self):
        for mode, existing_count in (('replace', 0), ('append', 0), ('append', 1), ('append', 2)):
            value = rd_plan(mode, None)
            value['context']['details'] = [dict(existing('RD', 1), id=80 + index, projectId=None)
                                           for index in range(existing_count)]
            # 6 小時工作預算：既有 0/1/2 小時，其餘平均分給兩筆無立案書新列。
            new_hours = (6 - existing_count) / 2
            value['rows'][0]['detail']['hours'] = new_hours
            second = {'expectedMandateCharterId': None, 'detail': dict(value['rows'][0]['detail'])}
            del second['detail']['mandateCharterId']
            value['rows'].insert(1, second)
            with self.subTest(mode=mode, existing_count=existing_count):
                result = report.prepare(value)
                self.assertEqual(result['action'], 'ready')
                self.assertEqual(len(result['payload']['details']), 3)
                self.assertIsNone(result['payload']['details'][0]['mandateCharterId'])
                self.assertNotIn('mandateCharterId', result['payload']['details'][1])
                self.assertEqual(result['payload']['details'][0]['hours'], new_hours)
                self.assertEqual(result['payload']['details'][1]['hours'], new_hours)
                value['rows'][0]['detail']['hours'] += 1
                with self.assertRaisesRegex(report.ReportError, '^hours_not_reconciled$'):
                    report.prepare(value)

    def test_same_nonnull_charter_still_asks_for_existing_or_new_duplicates(self):
        for mode, with_existing in (('replace', False), ('append', False), ('append', True)):
            value = rd_plan(mode)
            value['rows'][0]['detail']['hours'] = 3
            if with_existing:
                value['context']['details'] = [dict(existing('RD', 3), projectId=None, mandateCharterId=901)]
            else:
                value['rows'].insert(1, {'expectedMandateCharterId': 901,
                                         'detail': dict(value['rows'][0]['detail'])})
            with self.subTest(mode=mode, with_existing=with_existing):
                self.assertEqual(report.execute(value, authorized=True, contract_verified=True),
                                 {'action': 'ask', 'reason': 'daily_uniqueness_conflict'})

    def test_none_applicable_sends_absent_or_null_without_inventing_a_charter(self):
        for mode in ('replace', 'append'):
            for omitted in (False, True):
                value = rd_plan(mode, None)
                if omitted:
                    del value['rows'][0]['detail']['mandateCharterId']
                requests = []

                class Opener:
                    def open(self, request, timeout):
                        requests.append(request)
                        response = io.BytesIO(b'{"messagesEmpty":true}')
                        response.status = 200
                        return response

                with self.subTest(mode=mode, omitted=omitted), tempfile.TemporaryDirectory() as root:
                    config = Path(root) / 'config.json'
                    config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                                      encoding='utf-8')
                    preview = report.execute(value)
                    self.assertEqual(preview['action'], 'dry_run')
                    with patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                        result = report.execute(value, authorized=True, contract_verified=True, config_file=config)
                    self.assertEqual(result['action'], 'readback_required')
                    self.assertEqual(len(requests), 1)
                    payload = json.loads(requests[0].data)
                    expected_rd = {'reportType': 'RD', 'hours': 6, 'subject': '驗證 mapping',
                                   'description': '完成日期解析', 'todos': '後續讀回',
                                   'projectId': None, 'projectModuleId': None}
                    if not omitted:
                        expected_rd['mandateCharterId'] = None
                    self.assertEqual(payload['details'][0], expected_rd)
                    self.assertEqual(payload, preview['payload'])

    def test_explicit_null_selection_cannot_hide_a_nonnull_detail_id(self):
        for mode in ('replace', 'append'):
            value = rd_plan(mode, None)
            value['rows'][0]['detail']['mandateCharterId'] = 901
            with self.subTest(mode=mode), \
                    patch.object(Path, 'read_text', side_effect=AssertionError('credential read')), \
                    patch.object(report.urllib.request, 'build_opener', side_effect=AssertionError('network')), \
                    self.assertRaisesRegex(report.ReportError, '^mandate_charter_selection_mismatch$'):
                report.execute(value, authorized=True, contract_verified=True)

    def test_selected_id_mismatch_or_invalid_detail_never_reads_credentials_or_network(self):
        for mode in ('replace', 'append'):
            for fields, reason in (
                ({}, 'missing_reference_id|mandate_charter_selection_mismatch'),
                ({'mandateCharterId': None}, 'missing_reference_id|mandate_charter_selection_mismatch'),
                ({'mandateCharterId': 902}, 'mandate_charter_selection_mismatch'),
                ({'mandateCharterId': True}, 'invalid_reference_id'),
                ({'mandateCharterId': '901'}, 'invalid_reference_id'),
                ({'mandateCharterId': 901.0}, 'invalid_reference_id'),
                ({'mandateCharterId': {}}, 'invalid_reference_id'),
                ({'mandateCharterId': 9223372036854775808}, 'invalid_reference_id'),
            ):
                value = rd_plan(mode)
                del value['rows'][0]['detail']['mandateCharterId']
                value['rows'][0]['detail'].update(fields)
                with self.subTest(mode=mode, fields=fields), \
                        patch.object(Path, 'read_text', side_effect=AssertionError('credential read')), \
                        patch.object(report.urllib.request, 'build_opener', side_effect=AssertionError('network')), \
                        self.assertRaisesRegex(report.ReportError, '^(' + reason + ')$'):
                    report.execute(value, authorized=True, contract_verified=True)

    def test_missing_invalid_or_non_rd_selection_metadata_never_reaches_access(self):
        for mode in ('replace', 'append'):
            for fields, report_type, reason in (
                ({}, 'RD', 'selection_required'),
                *[({'expectedMandateCharterId': invalid}, 'RD', 'invalid_reference_id')
                  for invalid in (True, False, '901', 901.0, [], {}, 9223372036854775808, -9223372036854775809)],
                ({'expectedMandateCharterId': 901}, 'PROJECT', 'invalid_new_detail'),
                ({'expectedMandateCharterId': None}, 'PROJECT', 'invalid_new_detail'),
            ):
                value = rd_plan(mode)
                value['rows'][0].pop('expectedMandateCharterId')
                value['rows'][0].update(fields)
                value['rows'][0]['detail']['reportType'] = report_type
                if report_type == 'PROJECT':
                    value['rows'][0]['detail'].update(projectId=7, mandateCharterId=None)
                with self.subTest(mode=mode, fields=fields, report_type=report_type), \
                        patch.object(Path, 'read_text', side_effect=AssertionError('credential read')), \
                        patch.object(report.urllib.request, 'build_opener', side_effect=AssertionError('network')), \
                        self.assertRaisesRegex(report.ReportError, '^' + reason + '$'):
                    report.execute(value, authorized=True, contract_verified=True)

    def test_selected_charter_cli_sends_exact_id_without_local_metadata(self):
        for mode, endpoint in (('replace', 'daily-reports/replace'), ('append', 'daily-reports')):
            requests = []

            class Opener:
                def open(self, request, timeout):
                    requests.append(request)
                    response = io.BytesIO(b'{"messagesEmpty":true}')
                    response.status = 200
                    return response

            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as root:
                path, config = Path(root) / 'plan.json', Path(root) / 'config.json'
                path.write_text(json.dumps(rd_plan(mode)), encoding='utf-8')
                config.write_text('{"apiToken":"fixture-only","baseUrl":"https://erp.example.test/backend/"}',
                                  encoding='utf-8')
                argv = [str(SCRIPT), '--plan', str(path), '--authorized', '--contract-verified',
                        '--config', str(config)]
                output = io.StringIO()
                with patch.object(sys, 'argv', argv), redirect_stdout(output), \
                        patch.object(report.urllib.request, 'build_opener', return_value=Opener()):
                    self.assertEqual(report.main(), 0)
                self.assertEqual(json.loads(output.getvalue())['action'], 'readback_required')
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0].get_method(), 'POST')
                self.assertEqual(requests[0].full_url, 'https://erp.example.test/backend/api/v2/' + endpoint)
                expected = {'reportDate': '2026-10-14', 'details': [
                    {'reportType': 'RD', 'hours': 6, 'subject': '驗證 mapping', 'description': '完成日期解析',
                     'todos': '後續讀回', 'projectId': None, 'projectModuleId': None, 'mandateCharterId': 901},
                    {'reportType': 'LEAVE', 'hours': 2, 'subject': '請假', 'description': None, 'todos': None,
                     'projectId': None, 'projectModuleId': None, 'mandateCharterId': None},
                ]}
                if mode == 'replace':
                    expected['expectedSnapshot'] = 'snapshot-a'
                self.assertEqual(json.loads(requests[0].data), expected)


if __name__ == '__main__':
    unittest.main()
