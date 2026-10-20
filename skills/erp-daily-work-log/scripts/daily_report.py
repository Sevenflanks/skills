"""本人日誌新增／替換 gate；直接驗證正式 context 與實際 POST 工時。"""

from decimal import Decimal, InvalidOperation
from datetime import date, datetime, time, timedelta
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request


class ReportError(Exception):
    pass


def hours(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise ReportError('invalid_hours')
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise ReportError('invalid_hours') from None
    if not result.is_finite() or result < 0 or result > 9999 or result.as_tuple().exponent < -2:
        raise ReportError('invalid_hours')
    return result


def work_budget(leaves, attendances, total=8, confirmed_leave=None):
    if not isinstance(leaves, list) or not isinstance(attendances, list):
        raise ReportError('unknown_attendance_or_leave')
    for row in leaves:
        if (not isinstance(row, dict) or row.get('status') not in ('PROCESS', 'PASS')
                or not valid_id(row.get('detailId'))):
            raise ReportError('unknown_attendance_or_leave')
    if len({row['detailId'] for row in leaves}) != len(leaves):
        raise ReportError('duplicate_leave_detail')
    for row in attendances:
        if (not isinstance(row, dict) or row.get('classification') not in ('ATTENDANCE', 'NONATTENDANCE')
                or not valid_id(row.get('id')) or 'leaveType' not in row):
            raise ReportError('unknown_attendance_or_leave')
        classification, leave_type = row['classification'], row['leaveType']
        if ((classification == 'ATTENDANCE' and leave_type is not None)
                or (classification == 'NONATTENDANCE' and leave_type not in (
                    'ANNUAL', 'PERSONAL', 'SICK', 'LATE', 'MENSTRUAL', 'STATUTORY', 'FUNERAL', 'MARRIAGE',
                    'MATERNITY', 'PREGNANCY', 'PATERNITY', 'BABYCOVER', 'MISCARRIAGE', 'WORKINJURY',
                    'COMPENSATION', 'ABSENTEEISM', 'NURSING', 'LEAVEWITHOUTPAY', 'OTHER'))):
            raise ReportError('attendance_classification_conflict')
        try:
            record_time = row['recordTime']
            if not isinstance(record_time, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', record_time):
                raise ValueError()
            datetime.fromisoformat(record_time)
        except (ValueError, KeyError):
            raise ReportError('invalid_attendance_time') from None
    total = hours(total)
    if total == 0:
        raise ReportError('invalid_total')
    leave = sum((hours(row.get('hours')) for row in leaves), Decimal(0))
    usable = bool(leaves)
    if confirmed_leave is not None:
        confirmed = hours(confirmed_leave)
        if usable and confirmed != leave:
            raise ReportError('conflicting_leave_hours')
        leave = confirmed
    elif not usable and (not attendances or any(row['classification'] == 'NONATTENDANCE' for row in attendances)):
        return {'action': 'ask', 'reason': 'leave_hours_unknown'}
    if leave > total:
        return {'action': 'ask', 'reason': 'leave_exceeds_total'}
    return {'action': 'stop' if leave == total else 'continue', 'leaveHours': float(leave), 'workHours': float(total - leave)}


def valid_id(value):
    return isinstance(value, int) and not isinstance(value, bool) and -9223372036854775808 <= value <= 9223372036854775807


def java_length(value):
    # Java @Length 與合併內容使用 UTF-16 code units；emoji 不能以 Python code points 放寬上限。
    return len(value.encode('utf-16-le', errors='surrogatepass')) // 2


def validate_detail(detail):
    allowed = {'reportType', 'hours', 'subject', 'description', 'todos', 'projectId', 'projectModuleId', 'mandateCharterId'}
    if not isinstance(detail, dict) or not detail or set(detail) - allowed:
        raise ReportError('invalid_new_detail')
    report_type = detail.get('reportType')
    if report_type not in ('COMPANY', 'PROJECT', 'RD', 'OTHER', 'LEAVE'):
        raise ReportError('invalid_report_type')
    amount = hours(detail.get('hours'))
    subject = detail.get('subject')
    if not isinstance(subject, str) or not subject or java_length(subject) > 100:
        raise ReportError('invalid_subject')
    for field in ('description', 'todos'):
        value = detail.get(field)
        if value is not None and (not isinstance(value, str) or java_length(value) > 900):
            raise ReportError('invalid_' + field)
    description = (detail.get('description') or '').lstrip('\r\n')
    if java_length(subject) + (1 + java_length(description) if description else 0) > 1000:
        raise ReportError('content_too_long')
    validate_references(detail)
    return amount, 'LEAVE' if report_type == 'LEAVE' else 'WORK'


def validate_references(detail):
    for field in ('projectId', 'projectModuleId', 'mandateCharterId'):
        if detail.get(field) is not None and not valid_id(detail[field]):
            raise ReportError('invalid_reference_id')
    # 格式與必要欄位可在本地拒送；可用性與 module 必填性仍由 agent 核對當日官方 options。
    required_reference = {'PROJECT': 'projectId', 'RD': 'mandateCharterId'}.get(detail.get('reportType'))
    if required_reference and detail.get(required_reference) is None:
        raise ReportError('missing_reference_id')


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?\+08:00', value):
        raise ReportError('invalid_server_timezone')
    fraction = re.search(r'\.(\d+)\+08:00$', value)
    parse_value = value
    if fraction:
        digits = fraction.group(1)
        parse_value = value[:fraction.start(1)] + digits[:6].ljust(6, '0') + value[fraction.end(1):]
    try:
        parsed = datetime.fromisoformat(parse_value)
    except (ValueError, TypeError, AttributeError):
        raise ReportError('invalid_server_time') from None
    if parsed.utcoffset() is None:
        raise ReportError('missing_server_timezone')
    if fraction and any(digit != '0' for digit in fraction.group(1)[6:]):
        # 先正規化小數位再沿用標準庫的日期驗證；奈秒尾數非零時向上取整，避免逾期被截成期限內。
        parsed += timedelta(microseconds=1)
    return parsed


def context_gate(plan):
    if not isinstance(plan, dict) or not isinstance(plan.get('context'), dict):
        raise ReportError('invalid_plan_context')
    context = plan['context']
    if plan.get('mode', 'replace') not in ('replace', 'append'):
        raise ReportError('invalid_mode')
    required = {'reportDate', 'leaves', 'attendances', 'details', 'expectedSnapshot', 'serverNow', 'replaceDeadline', 'canReplace'}
    if not required <= set(context):
        raise ReportError('incomplete_context')
    report_date = plan.get('reportDate')
    try:
        day = date.fromisoformat(report_date)
    except (ValueError, TypeError):
        raise ReportError('invalid_report_date') from None
    if day.isoformat() != report_date or context['reportDate'] != report_date:
        raise ReportError('report_date_changed')
    now = timestamp(context['serverNow'])
    deadline = timestamp(context['replaceDeadline'])
    # 正式契約固定 +08:00；不可隨輸入 offset 改變次日 10:00 的界限。
    expected = datetime.combine(day + timedelta(days=1), time(10), deadline.tzinfo)
    if deadline != expected:
        raise ReportError('deadline_contract_mismatch')
    if context['canReplace'] is not True and context['canReplace'] is not False:
        raise ReportError('invalid_replace_permission')
    expired = now > deadline or context['canReplace'] is False
    snapshot = context['expectedSnapshot']
    if not isinstance(snapshot, str) or not snapshot.strip():
        raise ReportError('missing_snapshot')
    if not isinstance(context['details'], list) or any(not isinstance(detail, dict) for detail in context['details']):
        raise ReportError('invalid_existing_details')
    budget = work_budget(context['leaves'], context['attendances'], plan.get('totalHours', 8), plan.get('confirmedLeaveHours'))
    if 'leaveHours' in context and hours(context['leaveHours']) != sum((hours(row.get('hours')) for row in context['leaves']), Decimal(0)):
        raise ReportError('context_leave_hours_mismatch')
    if any(not row['recordTime'].startswith(report_date + 'T') for row in context['attendances']):
        raise ReportError('attendance_report_date_mismatch')
    # 整日請假優先；其他逾期只需證據摘要，不讓工時／mapping 問答卡住唯讀輸出。
    if budget['action'] == 'stop':
        return budget
    if expired and plan.get('mode', 'replace') == 'replace':
        return {'action': 'output_only', 'reason': 'deadline_passed'}
    if budget['action'] != 'continue':
        return budget
    if plan.get('expectedSnapshot', snapshot) != snapshot:
        raise ReportError('snapshot_changed')
    return budget


def unique_reference(detail):
    if detail.get('reportType') == 'PROJECT':
        return ('PROJECT', detail.get('projectId'), detail.get('projectModuleId'))
    if detail.get('reportType') == 'RD':
        return ('RD', detail.get('mandateCharterId'))
    return None


def prepare(plan):
    budget = context_gate(plan)
    if budget['action'] != 'continue':
        return budget
    context = plan['context']
    report_date, snapshot = plan['reportDate'], context['expectedSnapshot']
    rows = plan.get('rows')
    if not isinstance(rows, list) or not rows:
        raise ReportError('empty_replacement')
    totals = {'WORK': Decimal(0), 'LEAVE': Decimal(0)}
    references = set()
    existing_leave = False
    if plan.get('mode', 'replace') == 'append':
        # append 不重送既有列，但既有工時仍占當日預算，不能要求新列自行湊足全天。
        # 這是使用者工時預算，不是遲報豁免判定；context 沒有工作日／豁免欄位，仍需官方核對及 server validation。
        for detail in context['details']:
            if detail.get('reportType') not in ('COMPANY', 'PROJECT', 'RD', 'OTHER', 'LEAVE'):
                raise ReportError('invalid_existing_details')
            validate_references(detail)
            kind = 'LEAVE' if detail['reportType'] == 'LEAVE' else 'WORK'
            existing_leave = existing_leave or kind == 'LEAVE'
            totals[kind] += hours(detail.get('hours'))
            reference = unique_reference(detail)
            if reference is not None:
                references.add(reference)
    details = []
    for row in rows:
        if not isinstance(row, dict) or set(row) - {'detail', 'hours', 'kind'}:
            raise ReportError('invalid_new_detail')
        detail = row.get('detail')
        amount, kind = validate_detail(detail)
        if kind == 'LEAVE' and existing_leave:
            return {'action': 'ask', 'reason': 'existing_leave_conflict'}
        reference = unique_reference(detail)
        if reference is not None:
            if reference in references:
                return {'action': 'ask', 'reason': 'daily_uniqueness_conflict'}
            references.add(reference)
        # 預覽的舊 normalized 欄位若仍在，只能做交叉檢查，不能取代真正 POST 的值。
        if ('hours' in row and hours(row['hours']) != amount) or ('kind' in row and row['kind'] != kind):
            raise ReportError('normalized_row_mismatch')
        totals[kind] += amount
        details.append(detail)
    if totals['WORK'] != hours(budget['workHours']) or totals['LEAVE'] != hours(budget['leaveHours']):
        raise ReportError('hours_not_reconciled')
    payload = {'reportDate': report_date, 'details': details}
    if plan.get('mode', 'replace') == 'replace':
        payload['expectedSnapshot'] = snapshot
    return {'action': 'ready', 'payload': payload}


def safe_base(value):
    if not isinstance(value, str) or re.search(r'[\s\\%]', value):
        raise ReportError('unsafe_base_url')
    try:
        parts = urllib.parse.urlsplit(value)
        parts.port
    except ValueError:
        raise ReportError('unsafe_base_url') from None
    if (parts.scheme != 'https' or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.query or parts.fragment
            or not re.fullmatch(r'/[A-Za-z0-9._~/-]*', parts.path or '/')
            or any(segment in ('.', '..') for segment in parts.path.split('/'))):
        raise ReportError('unsafe_base_url')
    return value.rstrip('/') + '/'


def load_access(config_root=None, config_file=None, base_url=None):
    if config_file:
        path = Path(config_file).expanduser()
    else:
        root = Path(config_root).expanduser() if config_root else Path.home() / '.config' / 'softleader' / 'agent-skills'
        path = root / 'erp' / 'config.json'
    try:
        config = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise ReportError('external_config_unavailable') from None
    if not isinstance(config, dict) or ('apiToken' in config and 'apiTokenEnv' in config):
        raise ReportError('invalid_credential_config')
    base = safe_base(config['baseUrl'] if 'baseUrl' in config else base_url)
    if base_url and base != safe_base(base_url):
        raise ReportError('deployment_mismatch')
    if 'apiToken' in config:
        key = config['apiToken']
    else:
        variable = config.get('apiTokenEnv', 'ERP_API_TOKEN')
        if not isinstance(variable, str) or not variable:
            raise ReportError('invalid_credential_config')
        key = os.environ.get(variable)
    if not isinstance(key, str) or not key.strip() or '\r' in key or '\n' in key:
        raise ReportError('missing_or_invalid_api_key')
    return base, key


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def replace(base, key, payload):
    base = safe_base(base)
    # 固定 operation，不能改成帶任意 URL/method 的通用寫入工具。
    url = base + 'api/v2/daily-reports/replace'
    request = urllib.request.Request(url, data=json.dumps(payload, allow_nan=False).encode('utf-8'),
                                     headers={'X-API-KEY': key, 'Content-Type': 'application/json', 'Accept': 'application/json'},
                                     method='POST')
    return _send_request(request)


def append(base, key, payload):
    # submit 帶 id 會更新資料；此入口僅可新增，不提供任意 path 或更新既有列。
    base = safe_base(base)
    request = urllib.request.Request(base + 'api/v2/daily-reports',
                                     data=json.dumps(payload, allow_nan=False).encode('utf-8'),
                                     headers={'X-API-KEY': key, 'Content-Type': 'application/json', 'Accept': 'application/json'},
                                     method='POST')
    return _send_request(request)


def _send_request(request):
    # 只共用 transport；各 scoped helper 仍自行固定 method/path 與授權，不開放 CLI request。
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    try:
        with opener.open(request, timeout=30) as response:
            status = response.status
            body = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        raise ReportError('http_error_' + str(error.code) + '_readback_required') from None
    except (urllib.error.URLError, OSError, http.client.HTTPException):
        # Timeout 可能已提交；不重試，以 erp 唯讀 skill 查回來確認。
        raise ReportError('network_result_uncertain_readback_required') from None
    if not 200 <= status < 300 or len(body) > 1024 * 1024:
        raise ReportError('unexpected_response_readback_required')
    try:
        result = json.loads(body)
    except (ValueError, UnicodeError, RecursionError):
        raise ReportError('invalid_response_readback_required') from None
    if not isinstance(result, dict):
        raise ReportError('unexpected_response_readback_required')
    if result.get('messagesEmpty') is False or result.get('ok') is False or result.get('success') is False:
        raise ReportError('application_rejected_readback_required')
    # 不回傳 server body，也不以 HTTP 200 代替完整明細讀回驗證。
    return {'action': 'readback_required', 'httpStatus': status}


def execute(plan, authorized=False, overwrite=False, contract_verified=False, config_root=None, config_file=None, base_url=None):
    prepared = prepare(plan)
    if prepared['action'] != 'ready':
        return prepared
    # 只識別原授權的日期、完整內容、歸屬與快照；不是 server idempotency key 或持久重試紀錄。
    intent = hashlib.sha256(json.dumps({
        'mode': plan.get('mode', 'replace'), 'payload': prepared['payload'],
        'expectedSnapshot': plan['context']['expectedSnapshot'],
    }, sort_keys=True, ensure_ascii=True, allow_nan=False).encode('utf-8')).hexdigest()
    if 'retry' in plan:
        retry = plan['retry']
        if not isinstance(retry, dict):
            raise ReportError('invalid_retry')
        if retry.get('outcome') == 'applied':
            return {'action': 'stop', 'reason': 'already_applied'}
        # HTTP 狀態、timeout 或讀回空白都不能證明先前請求不會再提交。
        if retry.get('outcome') != 'definitely_not_applied':
            return {'action': 'readback_required', 'reason': 'retry_outcome_unknown'}
        if (retry.get('trusted') is not True or not isinstance(retry.get('evidence'), str)
                or not retry['evidence'].strip()):
            return {'action': 'ask', 'reason': 'retry_evidence_required'}
        if type(retry.get('retriesUsed')) is not int or retry['retriesUsed'] != 0:
            return {'action': 'ask', 'reason': 'retry_authorization_required'}
        if retry.get('originalIntent') != intent:
            return {'action': 'ask', 'reason': 'retry_intent_changed'}
    if authorized is not True:
        return {'action': 'dry_run', 'payload': prepared['payload'], 'intent': intent}
    if plan.get('mode', 'replace') == 'replace' and plan['context']['details'] and overwrite is not True:
        raise ReportError('overwrite_confirmation_required')
    if 'expectedSnapshot' not in plan:
        raise ReportError('preview_snapshot_required')
    if contract_verified is not True:
        raise ReportError('official_contract_required')
    base, key = load_access(config_root, config_file, base_url)
    operation = append if plan.get('mode', 'replace') == 'append' else replace
    result = operation(base, key, prepared['payload'])
    result.update(intent=intent, retriesUsed=1 if 'retry' in plan else 0)
    return result


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # 誤傳不支援的 credential 參數也不反射整條 argv。
        self.exit(2, 'invalid_arguments; use --help (credentials belong in external config/env)\n')


def main():
    parser = SafeParser(description='預設 dry-run；plan.mode 為 append 或 replace（預設），僅寫入已確認的本人單日日誌。')
    parser.add_argument('--plan', required=True)
    parser.add_argument('--authorized', action='store_true')
    parser.add_argument('--overwrite-confirmed', action='store_true')
    parser.add_argument('--contract-verified', action='store_true')
    parser.add_argument('--config-root')
    parser.add_argument('--config', dest='config_file')
    parser.add_argument('--base-url')
    args = parser.parse_args()
    try:
        plan = json.loads(Path(args.plan).read_text(encoding='utf-8'))
        result = execute(plan, args.authorized, args.overwrite_confirmed, args.contract_verified,
                         args.config_root, args.config_file, args.base_url)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except ReportError as error:
        reason = str(error)
        result = {'ok': False, 'reason': reason,
                  'requestState': 'unknown' if reason.endswith('readback_required') else 'not_sent'}
        if result['requestState'] == 'unknown':
            # 發出後失敗也消耗這次受控重試；caller 必須沿用回傳計數，不可重新使用舊 plan。
            result['retriesUsed'] = 1 if 'retry' in plan else 0
        print(json.dumps(result))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError):
        print(json.dumps({'ok': False, 'reason': 'invalid_local_input', 'requestState': 'not_sent'}))
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
