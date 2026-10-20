"""共用 repo mapping 的 scoped 寫入；查詢與寫後核對由外部 erp 唯讀工具負責。"""

from datetime import date, datetime
import json
from pathlib import Path
import re
import urllib.request

import daily_report as report


def period_date(value):
    if value is None:
        return None
    try:
        if not isinstance(value, str) or date.fromisoformat(value).isoformat() != value:
            raise ValueError()
    except (ValueError, TypeError):
        raise report.ReportError('invalid_mapping_date') from None
    return value


def modified_time(value):
    if not isinstance(value, str) or not re.fullmatch(
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?', value):
        raise report.ReportError('invalid_mapping_modified_time')
    # 僅驗證日期時間；傳給 PUT 的仍是讀回原字串，避免截精度破壞樂觀鎖。
    try:
        datetime.fromisoformat(value[:19])
    except ValueError:
        raise report.ReportError('invalid_mapping_modified_time') from None
    return value


def prepare(plan):
    if not isinstance(plan, dict) or set(plan) - {'reportDate', 'context', 'totalHours', 'confirmedLeaveHours', 'mapping'}:
        raise report.ReportError('invalid_mapping_plan')
    report_date = plan.get('reportDate')
    if report_date is None:
        raise report.ReportError('invalid_report_date')
    try:
        period_date(report_date)
    except report.ReportError:
        raise report.ReportError('invalid_report_date') from None
    # 共用 mapping 可獨立維護；舊 plan 的 context／工時欄位保留相容，日誌期限及請假不代表維護權限。
    if 'context' in plan:
        if not isinstance(plan['context'], dict):
            raise report.ReportError('invalid_plan_context')
        if plan['context'].get('reportDate') != report_date:
            raise report.ReportError('report_date_changed')
    item = plan.get('mapping')
    if not isinstance(item, dict) or item.get('operation') not in ('create', 'update'):
        raise report.ReportError('invalid_mapping_operation')
    updating = item['operation'] == 'update'
    allowed = {'operation', 'projectId', 'repo', 'branch', 'validFrom', 'validTo'}
    if updating:
        allowed |= {'mappingId', 'modifiedTime'}
        # 更新必須表明保留或改動舊期間，不能套新增預設而悄悄裁切原 mapping。
        if not {'validFrom', 'validTo'} <= set(item):
            raise report.ReportError('mapping_update_dates_required')
    if set(item) - allowed or not report.valid_id(item.get('projectId')):
        raise report.ReportError('invalid_mapping_fields')
    repo, branch = item.get('repo'), item.get('branch')
    if (not isinstance(repo, str) or report.java_length(repo) > 255
            or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo)
            or any(segment in ('.', '..') for segment in repo.split('/'))
            or repo.lower().endswith('.git')):
        raise report.ReportError('invalid_mapping_repo')
    if (not isinstance(branch, str) or not branch or report.java_length(branch) > 255
            or re.search(r'[\s\x00-\x1f\x7f]', branch)):
        raise report.ReportError('invalid_mapping_branch')
    payload = {'repo': repo, 'branch': branch,
               'validFrom': item.get('validFrom', plan['reportDate']), 'validTo': item.get('validTo')}
    for field in ('validFrom', 'validTo'):
        period_date(payload[field])
    if payload['validFrom'] and payload['validTo'] and payload['validFrom'] > payload['validTo']:
        raise report.ReportError('invalid_mapping_period')
    path = 'api/v2/project-repo-mappings'
    if updating:
        if not report.valid_id(item.get('mappingId')):
            raise report.ReportError('invalid_mapping_id')
        path += '/' + str(item['mappingId'])
        payload['modifiedTime'] = modified_time(item.get('modifiedTime'))
    else:
        payload['projectId'] = item['projectId']
    return {'action': 'ready', 'method': 'PUT' if updating else 'POST', 'path': path, 'payload': payload}


def execute(plan, mapping_confirmed=False, contract_verified=False,
            config_root=None, config_file=None, base_url=None):
    prepared = prepare(plan)
    if prepared['action'] != 'ready':
        return prepared
    if mapping_confirmed is not True:
        return dict(prepared, action='dry_run')
    if contract_verified is not True:
        raise report.ReportError('official_contract_required')
    base, key = report.load_access(config_root, config_file, base_url)
    request = urllib.request.Request(
        report.safe_base(base) + prepared['path'],
        data=json.dumps(prepared['payload'], allow_nan=False).encode('utf-8'),
        headers={'X-API-KEY': key, 'Content-Type': 'application/json', 'Accept': 'application/json'},
        method=prepared['method'])
    return report._send_request(request)


def main():
    parser = report.SafeParser(description='預設 dry-run；只有明確同意永久儲存的 mapping 可寫入。')
    parser.add_argument('--plan', required=True)
    parser.add_argument('--mapping-confirmed', action='store_true')
    parser.add_argument('--contract-verified', action='store_true')
    parser.add_argument('--config-root')
    parser.add_argument('--config', dest='config_file')
    parser.add_argument('--base-url')
    args = parser.parse_args()
    try:
        plan = json.loads(Path(args.plan).read_text(encoding='utf-8'))
        result = execute(plan, args.mapping_confirmed, args.contract_verified,
                         args.config_root, args.config_file, args.base_url)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except report.ReportError as error:
        print(json.dumps({'ok': False, 'reason': str(error)}))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError):
        print(json.dumps({'ok': False, 'reason': 'invalid_local_input'}))
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
