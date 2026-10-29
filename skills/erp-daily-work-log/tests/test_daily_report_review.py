import copy
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_daily_report import plan, report, SCRIPT
from test_daily_report_append import append_plan


DESCRIPTION = 'acme/widget\n- 完成日期解析；PR #31 MERGED。\nacme/tools\n- 補上驗證案例；issue #44，PR #32 OPEN，待合併。'


class PreviewTests(unittest.TestCase):
    def test_preview_exposes_full_authorized_text_and_replace_scope_from_same_plan(self):
        value = plan()
        value['rows'][0]['detail']['description'] = DESCRIPTION
        value['context']['details'] = [{'id': 80, 'subject': '將被替換的舊列'}]
        before = copy.deepcopy(value)
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')), \
                patch.object(report, '_send_request', side_effect=AssertionError('network')):
            result = report.preview(value)
            dry_run = report.execute(value)
        self.assertEqual(result['action'], 'preview')
        self.assertEqual(result['mode'], 'replace')
        self.assertEqual(result['reportDate'], '2026-10-14')
        self.assertEqual(result['expectedSnapshot'], 'snapshot-a')
        self.assertEqual(result['intent'], dry_run['intent'])
        self.assertEqual(result['details'], [
            {'reportType': 'PROJECT', 'hours': 6, 'subject': '驗證 mapping', 'description': DESCRIPTION,
             'todos': '後續讀回', 'projectId': 7, 'projectModuleId': 9, 'mandateCharterId': None},
            {'reportType': 'LEAVE', 'hours': 2, 'subject': '請假', 'description': None, 'todos': None,
             'projectId': None, 'projectModuleId': None, 'mandateCharterId': None},
        ])
        self.assertEqual(result['details'], dry_run['payload']['details'])
        self.assertEqual(result['impact'], {'scope': 'replace_entire_day', 'preserved': [],
                                         'replaced': [{'id': 80, 'subject': '將被替換的舊列'}]})
        self.assertEqual(result['hours'], {'existing': 0, 'new': 8, 'work': 6, 'leave': 2, 'total': 8})
        self.assertEqual(value, before)
        result['details'][0]['description'] = '修改輸出不應修改 plan'
        self.assertEqual(value, before)

    def test_authorized_multiline_and_legal_nonbullet_text_are_not_rewritten(self):
        for text in (DESCRIPTION, '\r\n第一段\r\n\r\n  原縮排\n', '合法的單段描述'):
            value = plan()
            value['rows'][0]['detail']['description'] = text
            with self.subTest(text=text):
                self.assertEqual(report.execute(value)['payload']['details'][0]['description'], text)


    def test_append_preview_preserves_existing_and_changed_text_changes_intent(self):
        value = append_plan()
        result = report.preview(value)
        self.assertEqual(result['impact'], {'scope': 'append_new_only',
                                         'preserved': value['context']['details'], 'replaced': []})
        self.assertEqual(result['hours'], {'existing': 6, 'new': 2, 'work': 6, 'leave': 2, 'total': 8})
        for field, changed in (('description', DESCRIPTION), ('todos', '請重新核對'),
                               ('subject', '新主旨'), ('projectModuleId', 10)):
            altered = copy.deepcopy(value)
            altered['rows'][0]['detail'][field] = changed
            self.assertNotEqual(report.preview(altered)['intent'], result['intent'])
        value['context']['expectedSnapshot'] = 'fresh-but-different'
        with self.assertRaisesRegex(report.ReportError, '^snapshot_changed$'):
            report.preview(value)

    def test_shared_rd_charter_preview_keeps_both_repo_groups_and_selected_reference(self):
        value = plan()
        value['rows'][0]['detail'].update(reportType='RD', projectId=None, projectModuleId=None,
                                         mandateCharterId=81, description=DESCRIPTION)
        value['rows'][0]['expectedMandateCharterId'] = 81
        result = report.preview(value)
        self.assertEqual(result['details'][0]['description'], DESCRIPTION)
        self.assertEqual(result['details'][0]['mandateCharterId'], 81)
        self.assertEqual(result['details'][0]['reportType'], 'RD')
        self.assertNotIn('expectedMandateCharterId', result['details'][0])
        self.assertEqual(result['hours']['total'], 8)


def official_detail(detail, detail_id):
    # 正式讀回保留 server-only 欄位；預期值由手工 plan fixture 提供，不用 comparator 生 oracle。
    return dict(detail, id=detail_id, modifiedTime='2026-10-14T18:00:00',
                content=detail['subject'] + ('\n' + detail['description'] if detail.get('description') else ''),
                newContent=None, delayDays=0, contentLengthValid=True)


class ReadbackTests(unittest.TestCase):
    def test_replace_matches_full_official_data_without_row_order_or_server_metadata_dependency(self):
        value = plan()
        value['rows'][0]['detail']['description'] = DESCRIPTION
        data = {'reportDate': '2026-10-14', 'details': [
            official_detail(value['rows'][1]['detail'], 102),
            official_detail(value['rows'][0]['detail'], 101),
        ]}
        before = copy.deepcopy((value, data))
        with patch.object(report, 'load_access', side_effect=AssertionError('credential read')), \
                patch.object(report, '_send_request', side_effect=AssertionError('network')):
            self.assertEqual(report.compare_readback(value, data), {
                'action': 'matched', 'mode': 'replace', 'reportDate': '2026-10-14',
                'preservedCount': 0, 'newCount': 2, 'differences': [],
            })
        self.assertEqual((value, data), before)

    def test_readback_reports_every_changed_business_field_and_missing_null_field(self):
        mutations = (
            ('reportType', 'OTHER'), ('projectId', 8), ('projectModuleId', 10),
            ('mandateCharterId', 81), ('subject', '錯誤主旨'), ('description', '遭截斷'),
            ('todos', '錯誤後續'), ('hours', 5), ('projectId', True), ('hours', '6'),
        )
        for field, changed in mutations:
            value = plan()
            data = {'reportDate': '2026-10-14', 'details': [
                official_detail(value['rows'][0]['detail'], 101),
                official_detail(value['rows'][1]['detail'], 102),
            ]}
            data['details'][0][field] = changed
            with self.subTest(field=field, changed=changed):
                result = report.compare_readback(value, data)
                self.assertEqual(result['action'], 'mismatch')
                self.assertEqual(result['differences'], [{
                    'scope': 'new', 'field': field, 'expected': value['rows'][0]['detail'][field],
                    'actual': changed, 'missing': False,
                }])
        del data['details'][1]['todos']
        self.assertIn({'scope': 'new', 'field': 'todos', 'expected': None,
                       'actual': None, 'missing': True}, report.compare_readback(value, data)['differences'])

    def test_append_matches_both_existing_ids_and_new_rows_in_any_order(self):
        value = append_plan()
        data = {'reportDate': '2026-10-14', 'details': [
            official_detail(value['rows'][0]['detail'], 101),
            copy.deepcopy(value['context']['details'][1]),
            copy.deepcopy(value['context']['details'][0]),
        ]}
        self.assertEqual(report.compare_readback(value, data), {
            'action': 'matched', 'mode': 'append', 'reportDate': '2026-10-14',
            'preservedCount': 2, 'newCount': 1, 'differences': [],
        })
        for field, changed in (('reportType', 'OTHER'), ('projectId', 8), ('projectModuleId', 10),
                               ('mandateCharterId', 81), ('subject', '舊列被改'),
                               ('description', '舊內容被改'), ('todos', '舊後續被改'), ('hours', 3)):
            altered = copy.deepcopy(data)
            altered['details'][2][field] = changed
            with self.subTest(field=field):
                self.assertEqual(report.compare_readback(value, altered)['differences'], [{
                    'scope': 'existing:80', 'field': field,
                    'expected': value['context']['details'][0][field], 'actual': changed, 'missing': False,
                }])
        for mutate in (
            lambda d: d['details'].pop(),
            lambda d: d['details'][2].update(id=999),
            lambda d: d['details'].append(copy.deepcopy(d['details'][0])),
            lambda d: d['details'].append(copy.deepcopy(d['details'][2])),
        ):
            altered = copy.deepcopy(data)
            mutate(altered)
            with self.subTest(data=altered):
                self.assertEqual(report.compare_readback(value, altered)['action'], 'mismatch')

    def test_wrong_date_partial_empty_and_extra_readback_never_prove_success_or_retry_safety(self):
        value = plan()
        good = {'reportDate': '2026-10-14', 'details': [
            official_detail(value['rows'][0]['detail'], 101),
            official_detail(value['rows'][1]['detail'], 102),
        ]}
        for mutate in (
            lambda d: d.update(reportDate='2026-10-13'),
            lambda d: d.pop('reportDate'),
            lambda d: d['details'].clear(),
            lambda d: d['details'].pop(),
            lambda d: d['details'].append(copy.deepcopy(d['details'][0])),
            lambda d: d['details'][0].update(reportDate='2026-10-13'),
            lambda d: d['details'][1].update(id=101),
        ):
            data = copy.deepcopy(good)
            mutate(data)
            with self.subTest(data=data):
                self.assertEqual(report.compare_readback(value, data)['action'], 'mismatch')
        for invalid in (None, [], {}, {'details': None}, {'details': ['partial']}, {'data': good}):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(report.ReportError, '^invalid_readback_data$'):
                report.compare_readback(value, invalid)

    def test_optional_expected_null_numeric_hours_and_exact_text_are_compared_semantically(self):
        value = plan()
        value['rows'][0]['detail']['description'] = '\r\n第一段\r\n\r\n  原縮排\n'
        del value['rows'][0]['detail']['mandateCharterId']
        data = {'reportDate': '2026-10-14', 'details': [
            official_detail(dict(value['rows'][0]['detail'], mandateCharterId=None, hours=6.0), 101),
            official_detail(value['rows'][1]['detail'], 102),
        ]}
        self.assertEqual(report.compare_readback(value, data)['action'], 'matched')
        for field, changed in (('description', '第一段\n原縮排'), ('projectId', 7.0),
                               ('mandateCharterId', 81), ('todos', None)):
            altered = copy.deepcopy(data)
            altered['details'][0][field] = changed
            with self.subTest(field=field):
                self.assertEqual(report.compare_readback(value, altered)['action'], 'mismatch')

    def test_duplicate_equal_new_rows_count_as_two_and_incomplete_append_baseline_is_rejected(self):
        value = plan()
        value['rows'][0]['detail'].update(reportType='COMPANY', hours=3, projectId=None, projectModuleId=None)
        value['rows'].insert(1, copy.deepcopy(value['rows'][0]))
        data = {'reportDate': '2026-10-14', 'details': [
            official_detail(value['rows'][2]['detail'], 102),
            official_detail(value['rows'][1]['detail'], 101),
            official_detail(value['rows'][0]['detail'], 103),
        ]}
        self.assertEqual(report.compare_readback(value, data)['action'], 'matched')
        data['details'].pop()
        self.assertEqual(report.compare_readback(value, data)['action'], 'mismatch')
        for mutate in (
            lambda p: p['context']['details'][0].pop('todos'),
            lambda p: p['context']['details'][0].pop('id'),
            lambda p: p['context']['details'][1].update(id=80),
        ):
            value = append_plan()
            mutate(value)
            with self.assertRaisesRegex(report.ReportError, '^incomplete_existing_readback_baseline$'):
                report.compare_readback(value, {'reportDate': '2026-10-14', 'details': []})


class LocalCliTests(unittest.TestCase):
    def test_mixed_topic_plan_cli_preview_keeps_all_fields_and_both_impact_scopes(self):
        # seam 是 CLI 保真；topic 歸屬的語意判斷由 eval 54 驗收，不由 helper 推論。
        fixture = SCRIPT.parent.parent / 'evals' / 'fixtures' / 'topic-routing-plan.json'
        value = json.loads(fixture.read_text(encoding='utf-8'))
        existing = copy.deepcopy(value['context']['details'])
        expected_details = [copy.deepcopy(row['detail']) for row in value['rows']]
        business_fields = {'reportType', 'projectId', 'projectModuleId', 'mandateCharterId',
                           'subject', 'description', 'todos', 'hours'}
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'plan.json'
            for mode in ('append', 'replace'):
                if mode == 'replace':
                    value['mode'] = mode
                    retained = {key: item for key, item in existing[0].items() if key != 'id'}
                    value['rows'].append({'detail': retained})
                    expected_details.append(copy.deepcopy(retained))
                original = json.dumps(value, ensure_ascii=False)
                path.write_text(original, encoding='utf-8')
                command = [sys.executable, '-B', str(SCRIPT), '--plan', str(path)]
                environment = dict(os.environ, PYTHONIOENCODING='utf-8')
                with self.subTest(mode=mode):
                    preview = subprocess.run(command + ['--preview'], capture_output=True, text=True,
                                             encoding='utf-8', env=environment, timeout=15)
                    dry_run = subprocess.run(command, capture_output=True, text=True,
                                             encoding='utf-8', env=environment, timeout=15)
                    self.assertEqual(preview.returncode, 0, preview.stderr)
                    self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
                    result, prepared = json.loads(preview.stdout), json.loads(dry_run.stdout)
                    self.assertRegex(result['intent'], r'^[0-9a-f]{64}$')
                    self.assertEqual(result, {
                        'action': 'preview', 'mode': mode, 'reportDate': '2026-10-14',
                        'expectedSnapshot': 'synthetic-topic-routing-snapshot', 'intent': prepared['intent'],
                        'details': expected_details,
                        'impact': {'scope': 'append_new_only' if mode == 'append' else 'replace_entire_day',
                                   'preserved': existing if mode == 'append' else [],
                                   'replaced': existing if mode == 'replace' else []},
                        'hours': {'existing': 1 if mode == 'append' else 0,
                                  'new': 7 if mode == 'append' else 8, 'work': 7, 'leave': 1, 'total': 8},
                    })
                    self.assertEqual(result['details'], prepared['payload']['details'])
                    for detail in result['details']:
                        self.assertEqual(set(detail), business_fields)
                    self.assertEqual(path.read_text(encoding='utf-8'), original)

    def test_cli_preview_and_readback_have_actionable_exit_codes(self):
        value = plan()
        value['rows'][0]['detail']['description'] = DESCRIPTION
        data = {'reportDate': '2026-10-14', 'details': [
            official_detail(value['rows'][1]['detail'], 102),
            official_detail(value['rows'][0]['detail'], 101),
        ]}
        with tempfile.TemporaryDirectory() as root:
            plan_path, data_path = Path(root) / 'plan.json', Path(root) / 'data.json'
            plan_path.write_text(json.dumps(value), encoding='utf-8')
            data_path.write_text(json.dumps(data), encoding='utf-8')
            environment = dict(os.environ, PYTHONIOENCODING='utf-8')
            command = [sys.executable, '-B', str(SCRIPT), '--plan', str(plan_path)]
            result = subprocess.run(command + ['--preview'], capture_output=True, text=True,
                                    encoding='utf-8', env=environment, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['details'][0]['description'], DESCRIPTION)
            result = subprocess.run(command + ['--readback', str(data_path)], capture_output=True, text=True,
                                    encoding='utf-8', env=environment, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['action'], 'matched')
            data['details'][1]['todos'] = '錯誤後續'
            data_path.write_text(json.dumps(data), encoding='utf-8')
            result = subprocess.run(command + ['--readback', str(data_path)], capture_output=True, text=True,
                                    encoding='utf-8', env=environment, timeout=15)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)['differences'], [{
                'scope': 'new', 'field': 'todos', 'expected': '後續讀回', 'actual': '錯誤後續', 'missing': False,
            }])

    def test_local_modes_reject_write_access_flags_before_credentials_or_network(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'plan.json'
            path.write_text(json.dumps(plan()), encoding='utf-8')
            for mode in (['--preview'], ['--readback', 'not-opened.json'], ['--readback', '']):
                for flags in (['--authorized'], ['--overwrite-confirmed'], ['--contract-verified'],
                              ['--authorized', '--contract-verified', '--overwrite-confirmed'],
                              ['--config', 'not-opened-config.json'], ['--config-root', 'not-opened-root'],
                              ['--config', ''],
                              ['--base-url', 'https://erp.example.test/']):
                    output = io.StringIO()
                    with self.subTest(mode=mode, flags=flags), \
                            patch.object(sys, 'argv', [str(SCRIPT), '--plan', str(path)] + mode + flags), \
                            redirect_stdout(output), \
                            patch.object(report, 'load_access', side_effect=AssertionError('credential read')), \
                            patch.object(report, '_send_request', side_effect=AssertionError('network')):
                        self.assertEqual(report.main(), 1)
                    self.assertEqual(json.loads(output.getvalue()), {
                        'ok': False, 'reason': 'local_mode_conflicting_flags', 'requestState': 'not_sent',
                    })


if __name__ == '__main__':
    unittest.main()
