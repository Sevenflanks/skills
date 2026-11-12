import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_daily_report import report, SCRIPT


FIXTURES = SCRIPT.parent.parent / 'evals' / 'fixtures'


def example():
    return json.loads((FIXTURES / 'topic-routing-plan.json').read_text(encoding='utf-8'))


def options():
    return {
        'projects': [{'id': 7, 'value': '7', 'code': 'P-7', 'label': '營運系統'}],
        'modules': {'7': [{'id': 71, 'value': '71', 'code': None, 'label': '帳務'},
                          {'id': 72, 'value': '72', 'code': None, 'label': '出勤'}]},
        'mandateCharters': [{'id': 81, 'value': '81', 'code': 'RC-81', 'label': '工具研發'}],
    }


class MarkdownPreviewTests(unittest.TestCase):
    def run_cli(self, value, display, *flags):
        with tempfile.TemporaryDirectory() as root:
            plan_path, options_path = Path(root) / 'plan.json', Path(root) / 'options.json'
            plan_path.write_text(json.dumps(value), encoding='utf-8')
            options_path.write_text(json.dumps(display), encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', [str(SCRIPT), '--plan', str(plan_path),
                                            '--display-options', str(options_path), *flags]), \
                    redirect_stdout(output), \
                    patch.object(report, 'load_access', side_effect=AssertionError('credential read')), \
                    patch.object(report, '_send_request', side_effect=AssertionError('network')):
                code = report.main()
            self.assertEqual(json.loads(plan_path.read_text(encoding='utf-8')), value)
            return code, output.getvalue()

    def test_submit_preview_shows_all_rows_scope_and_hours_without_machine_metadata(self):
        value = example()
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 0)
        self.assertIn('正式提交預覽', text)
        self.assertIn('| 研發 | 工具研發（RC-81） | 不適用 | 3h |', text)
        self.assertIn('| 專案 | 營運系統（P-7） | 帳務 | 2h |', text)
        self.assertIn('| 專案 | 營運系統（P-7） | 出勤 | 1h |', text)
        self.assertIn('既有 1h ＋ 新增 7h ＝ 當日合計 8h', text)
        self.assertIn('工作 7h／請假 1h', text)
        for row in value['rows'] + [{'detail': value['context']['details'][0]}]:
            detail = row['detail']
            self.assertIn(detail['subject'], text)
            for field in ('description', 'todos'):
                for line in (detail.get(field) or '').splitlines():
                    self.assertIn(line, text)
        self.assertIn('未填待辦', text)
        for index, row in enumerate(value['rows'], 1):
            section = text.split(f'**第 {index} 列｜', 1)[1].split('\n---', 1)[0]
            self.assertIn('**主旨**\n\n' + row['detail']['subject'], section)
            self.assertIn('**待辦全文**\n\n' + (row['detail'].get('todos') or '未填待辦'), section)
        self.assertIn('確認提交', text)
        for hidden in ('expectedSnapshot', 'synthetic-topic-routing-snapshot', 'mandateCharterId'):
            self.assertNotIn(hidden, text)
        self.assertNotIn(report.preview(value)['intent'], text)

    def test_layout_acceptance_cannot_be_mistaken_for_submission_and_does_not_change_intent(self):
        value = example()
        before = report.execute(value)
        code, text = self.run_cli(value, options(), '--preview-markdown', 'layout')
        self.assertEqual(code, 0)
        self.assertIn('版型試稿', text)
        self.assertIn('不構成提交授權', text)
        self.assertIn('請確認版型是否接受', text)
        self.assertNotIn('確認提交', text)
        self.assertEqual(report.execute(value), before)
        changed = copy.deepcopy(value)
        changed['rows'][0]['detail']['todos'] = '修正後必須重新確認'
        self.assertNotEqual(report.execute(changed)['intent'], before['intent'])

    def test_replace_shows_the_complete_old_rows_and_only_counts_replacement_hours(self):
        value = example()
        value['mode'] = 'replace'
        old = {k: v for k, v in value['context']['details'][0].items() if k != 'id'}
        value['rows'].append({'detail': old})
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 0)
        self.assertIn('替換當日全部日誌；原有 1 列將被以下 5 列取代', text)
        self.assertIn('將被替換的既有日誌全文', text)
        self.assertEqual(text.count('完成合成操作演練。'), 2)
        self.assertIn('既有 0h ＋ 新增 8h ＝ 當日合計 8h', text)

    def test_null_references_and_empty_text_have_readable_meanings(self):
        value = example()
        value['rows'][0]['detail']['mandateCharterId'] = None
        value['rows'][0]['expectedMandateCharterId'] = None
        value['rows'][1]['detail']['projectModuleId'] = None
        value['rows'][1]['detail']['description'] = ''
        del value['rows'][2]
        value['rows'][1]['detail']['hours'] = 3
        display = options()
        display['modules']['7'] = []
        code, text = self.run_cli(value, display, '--preview-markdown', 'submit')
        self.assertEqual(code, 0)
        self.assertIn('| 研發 | 未選立案書 | 不適用 | 3h |', text)
        self.assertIn('| 專案 | 營運系統（P-7） | 無模組 | 3h |', text)
        self.assertIn('未填工作內容', text)
        self.assertIn('| 請假 | 不適用 | 不適用 | 1h |', text)

    def test_display_lookup_rejects_missing_ambiguous_or_foreign_references(self):
        variants = []
        missing = options(); missing['mandateCharters'] = []
        variants.append((missing, 'display_option_missing'))
        duplicate = options(); duplicate['projects'] *= 2
        variants.append((duplicate, 'invalid_display_options'))
        foreign = options(); foreign['modules']['7'][0].update(id=99, value='99')
        variants.append((foreign, 'display_option_missing'))
        wrong_value = options(); wrong_value['modules']['7'][0]['value'] = '99'
        variants.append((wrong_value, 'invalid_display_options'))
        hidden_label = options(); hidden_label['projects'][0]['label'] = '營運\n錯列'
        variants.append((hidden_label, 'invalid_display_options'))
        missing_modules = options(); missing_modules['modules'] = {}
        variants.append((missing_modules, 'display_option_missing'))
        for display, reason in variants:
            with self.subTest(reason=reason):
                code, text = self.run_cli(example(), display, '--preview-markdown', 'submit')
                self.assertEqual(code, 1)
                self.assertEqual(json.loads(text), {'ok': False, 'reason': reason, 'requestState': 'not_sent'})
        value = example(); value['rows'][1]['detail']['projectModuleId'] = None
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(text)['reason'], 'display_module_required')
        value = example(); value['rows'][0]['detail']['projectId'] = 7
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(text)['reason'], 'invalid_display_references')

    def test_markup_is_displayed_as_text_without_changing_the_payload(self):
        value = example()
        original = '# 原標題\n<!-- 必須看見 -->\n[原連結](https://example.test)\n```\n---\n= = ='
        value['rows'][0]['detail']['description'] = original
        before = report.execute(value)
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 0)
        self.assertIn('\\# 原標題', text)
        self.assertIn('&lt;!-- 必須看見 --&gt;', text)
        self.assertIn('\\[原連結\\](https://example.test)', text)
        self.assertIn('\\`\\`\\`', text)
        self.assertIn('\\---', text)
        self.assertEqual(report.execute(value), before)
        self.assertEqual(before['payload']['details'][0]['description'], original)

    def test_markdown_modes_reject_write_flags_and_keep_nonready_gates(self):
        for stage in ('layout', 'submit'):
            for flags in (['--authorized'], ['--contract-verified'], ['--overwrite-confirmed'],
                          ['--config', 'never-read.json'], ['--base-url', 'https://example.test/']):
                code, text = self.run_cli(example(), options(), '--preview-markdown', stage, *flags)
                self.assertEqual(code, 1)
                self.assertEqual(json.loads(text)['reason'], 'local_mode_conflicting_flags')
        value = example(); value['context']['expectedSnapshot'] = 'changed'
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(text)['reason'], 'snapshot_changed')
        value = example(); value['context']['attendances'] = []; value['context']['leaves'] = []
        value['context']['leaveHours'] = 0
        code, text = self.run_cli(value, options(), '--preview-markdown', 'submit')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(text), {'action': 'ask', 'reason': 'leave_hours_unknown'})


if __name__ == '__main__':
    unittest.main()
