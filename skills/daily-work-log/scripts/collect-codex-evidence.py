"""Task-local, read-only Codex adapter. One JSON request/result; stdlib only."""
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import time
from urllib.parse import unquote, urlsplit

UTC = dt.timezone.utc
SUPPORTED = '0.164.0-alpha.11.1'
ITEM_TYPES = {'userMessage', 'agentMessage', 'hookPrompt', 'functionCallOutput', 'plan', 'reasoning', 'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'collabAgentToolCall', 'subAgentActivity', 'webSearch', 'imageView', 'imageGeneration', 'sleep', 'enteredReviewMode', 'exitedReviewMode', 'contextCompaction', 'error'}


class Gap(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def iso(value):
    return dt.datetime.fromtimestamp(value, UTC).isoformat()


def spawn_parent(source):
    subagent = source.get('subagent') if isinstance(source, dict) else None
    spawn = subagent.get('thread_spawn') if isinstance(subagent, dict) else None
    parent = spawn.get('parent_thread_id') if isinstance(spawn, dict) else None
    return parent if isinstance(parent, str) else None


def timestamp(value, unit=None):
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        # 單位由已核對欄位契約指定；JSONL 數值只接受明確秒／毫秒的有效範圍。
        if unit == 'ms' or (unit is None and 946684800000 <= value <= 4102444800000):
            value /= 1000
        if not math.isfinite(value) or not 946684800 <= value <= 4102444800:
            raise Gap('compatibility-error', 'unknown-time-unit')
        return value
    if unit:
        raise Gap('compatibility-error', 'non-numeric-time')
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.timestamp()
    except (ValueError, OverflowError):
        raise Gap('compatibility-error', 'unknown-event-time') from None


class Collector:
    def __init__(self, request):
        self.r = request
        self.root = Path(os.path.abspath(request['root']))
        self.start, self.end = timestamp(request['from']), timestamp(request['to'])
        self.deadline = time.monotonic() + request['deadlineSeconds']
        self.adapters = {k: {'status': 'not-read'} for k in ('state', 'history', 'exact')}
        self.adapters['exact']['sessions'] = []
        self.sql = {'rows': 0, 'payloadBytes': 0, 'limits': {'rows': request['rows'], 'payloadBytes': request['payloadBytes'], 'deadlineSeconds': request['deadlineSeconds']}, 'limitHits': [], 'unread': [], 'accounting': 'returned-row serialized UTF-8 payload; not physical I/O or tokens'}
        self.coverage = {'complete': False, 'strategy': 'state-history-exact-no-cache', 'archive': 'exact-candidates', 'limits': {'days': 32, 'entries': 2048, 'files': 128, 'totalBytes': request['totalBytes'], 'fileBytes': request['fileBytes'], 'lineBytes': 65536, 'pathComponents': 64}, 'daysConsidered': 0, 'visitedEntries': 0, 'candidateFiles': 0, 'openedFiles': 0, 'readBytes': 0, 'enumerationFailures': 0, 'selectedDays': [], 'candidateDays': [], 'visitedDays': [], 'unvisitedDays': [], 'stopReason': 'exact-candidates-exhausted', 'oversizedLines': 0, 'fileCapStops': 0, 'oversizedDiscardBytes': 0, 'filesWithRangeEvents': 0, 'readBytesDistribution': {'count': 0, 'totalBytes': 0, 'minBytes': None, 'maxBytes': None, 'buckets': dict.fromkeys(('zero', 'upTo256KiB', 'upTo1MiB', 'upTo8MiB', 'over8MiB'), 0)}, 'limitHits': [], 'skipped': [], 'exactFallback': {'lineBytes': request['exactLineBytes'], 'recoveredOversizedLines': 0, 'unread': []}}
        self.evidence, self.seen, self.drafts = [], {}, []
        self.unknown, self.errors, self.valid_events, self.range_events = 0, 0, 0, 0

    def check(self):
        if time.monotonic() >= self.deadline:
            raise Gap('limited', 'deadline')

    def connect(self, name, table, required):
        path = self.root / name
        db = None
        try:
            self.safe_path(path)
            path.stat()
            db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.1)
            db.row_factory = sqlite3.Row
            db.execute('pragma query_only=on')
            # 同時限制 SQLite 與 Python 邊界；CASE 投影不能單獨限制 SQLite 解碼大 row 的記憶體。
            db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, max(16384, self.r['payloadBytes']))
            db.set_progress_handler(lambda: int(time.monotonic() >= self.deadline), 1000)
            columns = {r[1]: bool(r[3]) for r in db.execute('pragma table_info(' + table + ')')}
            if not required <= columns.keys():
                self.adapters['state' if table == 'threads' else 'history']['missingRequiredColumns'] = sorted(required - columns.keys())
                db.close()
                raise Gap('compatibility-error', 'required-' + table + '-columns-missing')
            return db, columns
        except FileNotFoundError:
            raise Gap('missing', 'database-not-found') from None
        except PermissionError:
            raise Gap('permission', 'database-access-denied') from None
        except sqlite3.Error as error:
            if db is not None:
                db.close()
            raise self.sqlite_gap(error) from None

    def safe_path(self, path):
        if not path.is_absolute() or not Path(os.path.abspath(path)).is_relative_to(self.root):
            raise Gap('failed', 'unsafe-rollout-path')
        # 必須檢查 root 以上的 ancestors；resolve() 先行會抹去 symlink／junction 證據。
        current = path
        for _ in range(64):
            try:
                metadata = current.lstat()
                if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, 'st_file_attributes', 0) & 0x400:
                    raise Gap('failed', 'reparse-rollout-path')
            except FileNotFoundError:
                pass
            if current.parent == current:
                return
            current = current.parent
        raise Gap('failed', 'pathComponents')

    def sqlite_gap(self, error):
        code = getattr(error, 'sqlite_errorcode', 0) & 255
        if code in (sqlite3.SQLITE_PERM, sqlite3.SQLITE_AUTH, sqlite3.SQLITE_CANTOPEN):
            return Gap('permission', 'database-access-denied')
        if code in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED, sqlite3.SQLITE_INTERRUPT, sqlite3.SQLITE_TOOBIG):
            return Gap('limited', 'payloadBytes' if code == sqlite3.SQLITE_TOOBIG else 'deadline' if code == sqlite3.SQLITE_INTERRUPT else 'database-busy')
        return Gap('compatibility-error', 'sqlite-' + str(code))

    def rows(self, db, sql, params, scope):
        self.check()
        cursor = db.execute(sql, (*params, self.r['rows'] - self.sql['rows'] + 1))
        try:
            for row in cursor:
                self.check()
                if self.sql['rows'] >= self.r['rows']:
                    raise Gap('limited', 'rows')
                data = dict(row)
                if data.pop('_payload_limited', False):
                    raise Gap('limited', 'payloadBytes')
                size = len(encoded(data).encode('utf-8'))
                if self.sql['payloadBytes'] + size > self.r['payloadBytes']:
                    raise Gap('limited', 'payloadBytes')
                self.sql['rows'] += 1
                self.sql['payloadBytes'] += size
                yield data
        finally:
            cursor.close()

    def gap(self, adapter, gap, scope='requested-range', time_fields=()):
        self.adapters[adapter].update(status=gap.status, reason=gap.reason)
        if gap.status == 'limited':
            self.sql['limitHits'].append(gap.reason)
            self.sql['unread'].append({'adapter': adapter, 'scope': scope, 'from': self.r['from'], 'to': self.r['to']})
        if gap.status == 'compatibility-error':
            # 能力缺口先交本機 adapter 維護者判讀；schema 差異本身不是 upstream bug 證據。
            # 草稿只用程式產生的 reason/必要欄位，絕不插入 exception、未知 type 或原文。
            if gap.reason.startswith('required-'):
                category, reproduce = 'schema-capability', '建立缺少列出必要欄位的合成 threads／thread_items table。'
            elif 'index' in gap.reason or 'query' in gap.reason:
                category, reproduce = 'query-capability', '建立完整合成 table，但移除列出的 leading-column index；確認 collector 拒絕非 SEARCH 計畫。'
            elif 'time' in gap.reason:
                category = 'time-capability'
                if adapter == 'state' and gap.reason == 'unknown-metadata-time':
                    # threads 的 lifespan 與 item 時間是不同層；按本次可用欄位重現，不能誤導去改 item。
                    assignments = ','.join(field + '=NULL' for field in time_fields)
                    reproduce = '建立相同時間欄位的合成 threads（允許 NULL），保留可讀 rollout 與有效 item；_ms 欄位是毫秒，其餘是秒。只在合成 state_5.sqlite 執行：\n```sql\nUPDATE threads SET ' + assignments + ';\n```\n'
                elif adapter == 'history':
                    value = 'NULL' if gap.reason == 'unknown-history-item-time' else "'synthetic-invalid'" if gap.reason == 'non-numeric-time' else '17'
                    reproduce = '在合成 thread_history_1.sqlite 的 thread_items 建立已選 thread 下 item_id=bad 的有效訊息與另一筆有效時間訊息。created_at_ms 是毫秒；只修改合成 item：\n```sql\nUPDATE thread_items SET created_at_ms=' + value + " WHERE item_id='bad';\n```\n"
                elif adapter == 'exact':
                    event = {'type': 'event_msg', 'timestamp': None if gap.reason == 'unknown-event-time' else 17,
                             'payload': {'type': 'user_message', 'message': 'synthetic time reproduction'}}
                    if gap.reason == 'non-numeric-time':
                        event = {'type': 'event_msg', 'timestamp': '2026-05-29T02:00:00Z', 'payload': {
                            'type': 'item_completed', 'thread_id': 'old', 'turn_id': 'turn-a',
                            'item': {'type': 'AgentMessage', 'id': 'bad-time', 'content': [{'type': 'Text', 'text': 'synthetic time reproduction'}]},
                            'started_at_ms': 'synthetic-invalid', 'completed_at_ms': 1780020001000}}
                    reproduce = '建立合成 rollout，session_meta.id=old 且 cwd 指向合成 repo；保留一筆指定日期內有效訊息，再加入此 event。canonical started_at_ms 有值時是權威毫秒，否則採 envelope timestamp：\n```json\n' + encoded(event) + '\n```\n'
                else:
                    reproduce = '在隔離合成資料中核對對應 adapter 的時間欄位與單位，保留一筆有效時間的訊息供對照。'
            elif 'item' in gap.reason or 'message' in gap.reason:
                category, reproduce = 'content-capability', '在已選合成 thread 放入未知 type 或無效 item JSON，並在其後放一筆有效訊息。'
            elif gap.reason.startswith('python-'):
                category, reproduce = 'runtime-capability', '在低於 Python 3.11 的隔離環境執行合成 collector request。'
            else:
                category, reproduce = 'database-capability', '以不可解碼的合成 SQLite 檔案執行 collector；不使用本機資料副本。'
            difference = gap.reason + '; missing required columns: ' + ','.join(self.adapters[adapter].get('missingRequiredColumns', []))
            if self.adapters[adapter].get('missingRequiredIndexes'):
                difference += '; missing required index: ' + ','.join(self.adapters[adapter]['missingRequiredIndexes'])
            draft = {'destination': 'https://github.com/Sevenflanks/skills/issues', 'requiresExplicitConsent': True, 'published': False,
                     'title': 'Codex 本機 adapter ' + category + ' 缺口',
                     'body': '待確認：本機 adapter 是否需支援此資料形狀。尚無證據判定為 Codex upstream bug。\n觀察 adapter：' + adapter + '\n實際原因：' + difference + '\n影響：已成功證據保留；未讀範圍與限制見 coverage。\n合成重現：' + reproduce + ' 執行指定日期的 collector，核對 readStatus、adapter reason 與保留證據。\n資料限制：不附私人原文、路徑、URL、auth 或 config。\n此為草稿；取得本次明確同意後才可發布。'}
            if draft not in self.drafts:
                self.drafts.append(draft)

    def add(self, sid, cwd, parent, event_time, typ, role, text, raw, provenance, turn=None, item=None, normalized=None):
        if event_time is None:
            self.unknown += 1
            return
        self.valid_events += 1
        if not self.start <= event_time <= self.end or not text or not isinstance(sid, str) or not sid or not isinstance(cwd, str) or not Path(cwd).is_absolute():
            return
        self.range_events += 1
        # 只合併相同來源識別／種類／角色／全文的鏡像；不同 task 的同名工具不能併成一筆。
        payload = normalized if normalized is not None else raw.get('payload', raw)
        canonical = normalized is not None or (provenance['adapter'] == 'history' and payload.get('id') is not None)
        source_id = payload.get('call_id') or payload.get('callId') or item or provenance.get('callId') or str(provenance.get('line', provenance.get('ordinal')))
        # 訊息的 SQL item ID 可能是 projection 自造值；同 thread／turn／實際時間／全文才視為鏡像。
        # Tool 另保留 call/item identity，避免同時同名的不同呼叫被合併。
        key = (sid, turn, event_time, role, text) if role in ('user', 'assistant') else (sid, turn, source_id, typ, role, text)
        if role in ('user', 'assistant') and canonical:
            # Canonical item ID 是真實 identity；legacy 投影自造 ID 才沿用時間／全文去重。
            key = (sid, turn, item, event_time, role, text)
        elif role == 'tool' and canonical:
            # JSON object 欄位順序不是內容差異；只正規化已識別的 canonical payload，不改 legacy 原文。
            key = (sid, turn, item, source_id, event_time, typ, role, json.dumps(payload, ensure_ascii=False, sort_keys=True))
        output = payload.get('aggregatedOutput', payload.get('output', payload.get('result', payload.get('contentItems'))))
        if role == 'tool' and source_id and (output is not None or canonical) and typ in ('commandExecution', 'mcpToolCall', 'dynamicToolCall', 'functionCallOutput', 'function_call_output', 'custom_tool_call_output'):
            # SQL 與 rollout 的 wrapper 不同；只有同 thread/turn/call 的相同完整 output 才合併。
            key = (sid, turn, source_id, 'tool-output', json.dumps(output, ensure_ascii=False, sort_keys=True))
            if canonical:
                key += (typ, payload.get('status'), payload.get('exitCode'), json.dumps(payload.get('error'), ensure_ascii=False, sort_keys=True), payload.get('success'))
            existing = self.seen.get(key)
            exit_code = payload.get('exit_code', payload.get('exitCode'))
            if existing and exit_code is not None and existing.get('tool', {}).get('exitCode') not in (None, exit_code):
                key += (exit_code,)
        if key in self.seen:
            evidence = self.seen[key]
            evidence['provenance'].append(provenance)
            if raw != evidence['detail']:
                evidence.setdefault('mirrorDetails', []).append(raw)
            if 'file' in provenance and provenance['file'] not in evidence['files']:
                evidence['files'].append(provenance['file'])
            if iso(event_time) not in evidence['timestamps']:
                evidence['timestamps'].append(iso(event_time))
            return
        evidence = {'source': 'codex', 'agent': 'codex', 'path': cwd, 'sessionId': sid, 'sessionIds': [sid], 'parentSessionId': parent, 'files': [provenance['file']] if 'file' in provenance else [], 'timestamps': [iso(event_time)], 'title': text[:240], 'text': text, 'role': role, 'eventType': typ, 'turnId': turn, 'itemId': item, 'sourceId': source_id, 'provenance': [provenance], 'detail': raw}
        if role == 'tool':
            output = payload.get('output')
            result = output if isinstance(output, dict) else payload
            evidence['tool'] = {'name': payload.get('name', payload.get('tool')), 'status': result.get('status'), 'exitCode': result.get('exit_code', result.get('exitCode')), 'error': result.get('error'), 'callId': payload.get('call_id', item)}
        self.evidence.append(evidence)
        self.seen[key] = evidence

    def item(self, row, candidate):
        raw = json.loads(row['item_json'])
        if not isinstance(raw, dict):
            raise Gap('compatibility-error', 'invalid-history-item-shape')
        typ = raw.get('type', row['item_type'])
        if typ not in ITEM_TYPES:
            raise Gap('compatibility-error', 'unknown-history-item-type')
        role = 'user' if typ == 'userMessage' else 'assistant' if typ == 'agentMessage' else 'tool'
        text = raw.get('text')
        if text is None:
            text = raw.get('message')
        if role in ('user', 'assistant'):
            if text is None and 'content' in raw:
                content = raw['content']
                if not isinstance(content, list) or any(not isinstance(p, dict) or ('text' in p and not isinstance(p['text'], str)) for p in content):
                    raise Gap('compatibility-error', 'invalid-history-message-content')
                text = '\n'.join(p.get('text', '') for p in content)
            if not isinstance(text, str):
                raise Gap('compatibility-error', 'invalid-history-message-content')
        if not isinstance(text, str):
            text = encoded(raw)
        value = row['created_at_ms']
        try:
            when = timestamp(value, 'ms')
        except Gap:
            self.unknown += 1
            raise
        if when is None:
            self.unknown += 1
            raise Gap('compatibility-error', 'unknown-history-item-time')
        self.add(candidate['id'], candidate['cwd'], candidate.get('parent'), when, typ, role, text, raw, {'adapter': 'history', 'threadId': row['thread_id'], 'turnId': row['turn_id'], 'itemId': row['item_id'], 'ordinal': row['rollout_ordinal']}, row['turn_id'], row['item_id'])

    def review_text(self, output):
        if output is None:
            return 'Reviewer failed to output a response.'
        if not isinstance(output, dict) or not isinstance(output.get('overall_explanation'), str) or not isinstance(output.get('findings'), list):
            raise Gap('compatibility-error', 'invalid-canonical-item-review')
        sections, findings = [], output['findings']
        if output['overall_explanation'].strip():
            sections.append(output['overall_explanation'].strip())
        if findings:
            lines = ['Full review comments:' if len(findings) > 1 else 'Review comment:']
            for finding in findings:
                location = finding.get('code_location') if isinstance(finding, dict) else None
                bounds = location.get('line_range') if isinstance(location, dict) else None
                if not isinstance(bounds, dict) or any(not isinstance(finding.get(k), str) for k in ('title', 'body')) or not isinstance(location.get('absolute_file_path'), str) or any(not isinstance(bounds.get(k), int) for k in ('start', 'end')):
                    raise Gap('compatibility-error', 'invalid-canonical-item-review')
                lines.extend(['', f"- {finding['title']} — {location['absolute_file_path']}:{bounds['start']}-{bounds['end']}"])
                # Rust str::lines 只使用 LF／CRLF，不把內容中的其他 Unicode 字元當換行。
                body_lines = finding['body'].split('\n')
                if body_lines[-1] == '':
                    body_lines.pop()
                lines.extend('  ' + line.removesuffix('\r') for line in body_lines)
            sections.append('\n'.join(lines).strip())
        return '\n\n'.join(sections) if sections else 'Reviewer failed to output a response.'

    def canonical_item(self, payload):
        raw = payload.get('item')
        if not isinstance(raw, dict) or not isinstance(raw.get('id'), str) or not raw['id']:
            raise Gap('compatibility-error', 'invalid-canonical-item-shape')
        typ = raw.get('type')
        projected_type = typ[0].lower() + typ[1:] if isinstance(typ, str) and typ else None
        if projected_type not in ITEM_TYPES or typ == 'Error':
            raise Gap('compatibility-error', 'unknown-canonical-item-type')
        # 只正規化對照用欄位，原始 canonical event 仍完整保留於 detail/mirrorDetails。
        normalized = {re.sub(r'_([a-z])', lambda m: m[1].upper(), k): v for k, v in raw.items()}
        normalized['type'] = projected_type
        if typ == 'HookPrompt':
            fragments = raw.get('fragments')
            if not isinstance(fragments, list) or any(not isinstance(f, dict) or not isinstance(f.get('text'), str) or not isinstance(f.get('hook_run_id'), str) for f in fragments):
                raise Gap('compatibility-error', 'invalid-canonical-item-hook-prompt')
            normalized = {'type': projected_type, 'id': raw['id'], 'fragments': [
                {'text': f['text'], 'hookRunId': f['hook_run_id']} for f in fragments]}
        elif typ == 'Reasoning':
            summary, content = raw.get('summary_text'), raw.get('raw_content', [])
            if not isinstance(summary, list) or not isinstance(content, list) or any(not isinstance(s, str) for s in summary + content):
                raise Gap('compatibility-error', 'invalid-canonical-item-reasoning')
            normalized = {'type': projected_type, 'id': raw['id'], 'summary': summary, 'content': content}
        elif typ in ('CommandExecution', 'DynamicToolCall'):
            statuses = ('in_progress', 'completed', 'failed', 'declined') if typ == 'CommandExecution' else ('in_progress', 'completed', 'failed')
            if raw.get('status') not in statuses:
                raise Gap('compatibility-error', 'invalid-canonical-item-tool-status')
            # Core 的 snake_case enum 值也需投影；command 空 output 在 ThreadItem 中是 null。
            if normalized.get('status') == 'in_progress':
                normalized['status'] = 'inProgress'
            if typ == 'CommandExecution':
                if raw.get('aggregated_output') is not None and not isinstance(raw['aggregated_output'], str):
                    raise Gap('compatibility-error', 'invalid-canonical-item-command-output')
                if normalized.get('aggregatedOutput') == '':
                    normalized['aggregatedOutput'] = None
            else:
                content = raw.get('content_items')
                if raw.get('success') is not None and not isinstance(raw['success'], bool):
                    raise Gap('compatibility-error', 'invalid-canonical-item-dynamic-output')
                if content is not None:
                    if not isinstance(content, list):
                        raise Gap('compatibility-error', 'invalid-canonical-item-dynamic-output')
                    fields = {'inputText': 'text', 'inputImage': 'imageUrl', 'inputAudio': 'audioUrl'}
                    for part in content:
                        if not isinstance(part, dict) or part.get('type') not in tuple(fields) or not isinstance(part.get(fields[part['type']]), str):
                            raise Gap('compatibility-error', 'invalid-canonical-item-dynamic-output')
        elif typ == 'McpToolCall':
            result = raw.get('result')
            if result is not None:
                if not isinstance(result, dict) or not isinstance(result.get('content'), list) or result.get('isError') is not None and not isinstance(result['isError'], bool):
                    raise Gap('compatibility-error', 'invalid-canonical-item-mcp')
                # ThreadItem 的 MCP result 不含 isError；status/error 仍各自參與鏡像識別。
                normalized['result'] = {'content': result['content'], 'structuredContent': result.get('structuredContent'), '_meta': result.get('_meta')}
                if result.get('isError') is True:
                    # SQL projection 已捨棄 true error flag，不能據此證明它與成功 output 是鏡像。
                    normalized['result']['isError'] = True
        elif typ == 'CollabAgentToolCall':
            states, converted = raw.get('agents_states', {}), {}
            if not isinstance(states, dict) or raw.get('tool') not in ('spawn_agent', 'send_input', 'resume_agent', 'wait', 'close_agent', 'send_message', 'followup_task', 'interrupt_agent', 'list_agents') or raw.get('status') not in ('in_progress', 'completed', 'failed', 'interrupted'):
                raise Gap('compatibility-error', 'invalid-canonical-item-collab')
            for thread, state in states.items():
                if isinstance(state, str) and state in ('pending_init', 'running', 'interrupted', 'shutdown', 'not_found'):
                    status, message = re.sub(r'_([a-z])', lambda m: m[1].upper(), state), None
                elif isinstance(state, dict) and len(state) == 1 and next(iter(state)) in ('completed', 'errored'):
                    status, message = next(iter(state.items()))
                    if message is not None and not isinstance(message, str) or status == 'errored' and message is None:
                        raise Gap('compatibility-error', 'invalid-canonical-item-collab')
                else:
                    raise Gap('compatibility-error', 'invalid-canonical-item-collab')
                converted[thread] = {'status': status, 'message': message}
            normalized = {'type': projected_type, 'id': raw['id'], 'tool': re.sub(r'_([a-z])', lambda m: m[1].upper(), raw['tool']),
                          'status': 'inProgress' if raw['status'] == 'in_progress' else raw['status'],
                          'senderThreadId': raw.get('sender_thread_id'), 'receiverThreadIds': raw.get('receiver_thread_ids', []),
                          'prompt': raw.get('prompt'), 'model': raw.get('model'), 'reasoningEffort': raw.get('reasoning_effort'), 'agentsStates': converted}
        elif typ == 'SubAgentActivity':
            if raw.get('kind') not in ('started', 'interacted', 'interrupted', 'completed') or any(not isinstance(raw.get(field), str) for field in ('agent_thread_id', 'agent_path')):
                raise Gap('compatibility-error', 'invalid-canonical-item-subagent-activity')
            normalized = {'type': projected_type, 'id': raw['id'], 'kind': raw['kind'], 'agentThreadId': raw['agent_thread_id'],
                          'agentPath': raw['agent_path'], 'model': raw.get('model'), 'reasoningEffort': raw.get('reasoning_effort')}
        elif typ == 'ImageView':
            path = raw.get('path')
            if not isinstance(path, str):
                raise Gap('compatibility-error', 'invalid-canonical-item-image-view-path')
            if path.startswith('file:'):
                uri = urlsplit(path)
                parts = [unquote(part) for part in uri.path.split('/')[1:]]
                if any('\0' in part for part in parts) or not uri.path.startswith('/'):
                    raise Gap('compatibility-error', 'invalid-canonical-item-image-view-path')
                # 僅轉換 wire spelling，不解析磁碟路徑或讀取影像；native convention 由 URI 決定。
                if uri.netloc and uri.netloc != 'localhost':
                    path = '\\\\' + uri.netloc + '\\' + '\\'.join(parts)
                elif parts and re.fullmatch('[A-Za-z]:', parts[0]):
                    path = '\\'.join(parts) + ('\\' if len(parts) == 1 else '')
                else:
                    path = '/' + '/'.join(parts)
            normalized = {'type': projected_type, 'id': raw['id'], 'path': path}
        elif typ == 'ImageGeneration':
            if any(not isinstance(raw.get(field), str) for field in ('status', 'result')) or raw.get('revised_prompt') is not None and not isinstance(raw['revised_prompt'], str):
                raise Gap('compatibility-error', 'invalid-canonical-item-image-generation')
            normalized = {'type': projected_type, 'id': raw['id'], 'status': raw['status'], 'result': raw['result'],
                          'revisedPrompt': raw.get('revised_prompt'), 'transparentBackground': None, 'failure': None}
            if raw.get('saved_path') is not None:
                if not isinstance(raw['saved_path'], str):
                    raise Gap('compatibility-error', 'invalid-canonical-item-image-generation')
                normalized['savedPath'] = raw['saved_path']
        elif typ in ('EnteredReviewMode', 'ExitedReviewMode'):
            review = raw.get('user_facing_hint') if typ == 'EnteredReviewMode' else self.review_text(raw.get('review_output'))
            if not isinstance(review, str):
                raise Gap('compatibility-error', 'invalid-canonical-item-review')
            normalized = {'type': projected_type, 'id': raw['id'], 'review': review}
        elif typ == 'WebSearch':
            action = raw.get('action')
            if not isinstance(action, dict) or action.get('type') not in ('search', 'open_page', 'find_in_page', 'other'):
                raise Gap('compatibility-error', 'invalid-canonical-item-web-search')
            kind = action['type']
            fields = {'search': ('query', 'queries'), 'open_page': ('url',), 'find_in_page': ('url', 'pattern'), 'other': ()}[kind]
            normalized = {'type': projected_type, 'id': raw['id'], 'query': raw.get('query'), 'results': raw.get('results'),
                          'action': {'type': re.sub(r'_([a-z])', lambda m: m[1].upper(), kind), **{field: action.get(field) for field in fields}}}
        elif typ == 'FileChange':
            changes, status = raw.get('changes'), raw.get('status')
            if not isinstance(changes, dict) or status is not None and status not in ('completed', 'failed', 'declined'):
                raise Gap('compatibility-error', 'invalid-canonical-item-file-change')
            converted = []
            # 官方 convert_patch_changes 依 path 排序；move_path 同時影響 kind 與 diff 尾註。
            # 只投影 ThreadItem 保留的欄位；stdout/auto_approved 等原文仍留在 mirrorDetails。
            for path, change in sorted(changes.items()):
                if not isinstance(change, dict):
                    raise Gap('compatibility-error', 'invalid-canonical-item-file-change')
                action = change.get('type')
                if action in ('add', 'delete'):
                    diff, kind = change.get('content'), {'type': action}
                elif action == 'update':
                    diff, move_path = change.get('unified_diff'), change.get('move_path')
                    if move_path is not None and not isinstance(move_path, str):
                        raise Gap('compatibility-error', 'invalid-canonical-item-file-change')
                    kind = {'type': 'update', 'move_path': move_path}
                    if isinstance(diff, str) and move_path is not None:
                        diff += '\n\nMoved to: ' + move_path
                else:
                    raise Gap('compatibility-error', 'invalid-canonical-item-file-change')
                if not isinstance(diff, str):
                    raise Gap('compatibility-error', 'invalid-canonical-item-file-change')
                converted.append({'path': path, 'kind': kind, 'diff': diff})
            normalized = {'type': projected_type, 'id': raw['id'], 'changes': converted,
                          'status': status if status is not None else 'inProgress'}
        if typ not in ('UserMessage', 'AgentMessage'):
            return projected_type, 'tool', encoded(normalized), normalized
        content = raw.get('content')
        if not isinstance(content, list) or any(not isinstance(p, dict) or ('text' in p and not isinstance(p['text'], str)) or (typ == 'AgentMessage' and (p.get('type') != 'Text' or not isinstance(p.get('text'), str))) for p in content):
            raise Gap('compatibility-error', 'invalid-canonical-message-content')
        # AgentMessage 在官方 ThreadItem::from 收斂為 collect::<String>()，不插入換行。
        text = ('' if typ == 'AgentMessage' else '\n').join(p['text'] for p in content if isinstance(p.get('text'), str))
        return ('userMessage' if typ == 'UserMessage' else 'agentMessage',
                'user' if typ == 'UserMessage' else 'assistant', text,
                {'id': raw['id'], 'text': text})

    def lines(self, stream, budget, accounting):
        # 單次 Read 仍最多 4 KiB；只對 exact 候選保留較大的有界行，不改 legacy 64 KiB reader。
        pending, offset, line_size, discard = bytearray(), 0, 0, False
        while accounting['bytes'] < budget:
            self.check()
            chunk = stream.read(min(4096, budget - accounting['bytes']))
            if not chunk:
                if line_size:
                    yield None if discard else bytes(pending), offset, True
                return
            accounting['bytes'] += len(chunk)
            self.coverage['readBytes'] += len(chunk)
            start = 0
            while start < len(chunk):
                end = chunk.find(b'\n', start)
                complete = end >= 0
                end = end + 1 if complete else len(chunk)
                segment = chunk[start:end]
                previous_size = line_size
                line_size += len(segment)
                raw_size = line_size - int(complete)
                if previous_size <= 65536 < raw_size:
                    self.coverage['oversizedLines'] += 1
                if not discard and raw_size > self.r['exactLineBytes']:
                    self.coverage['oversizedDiscardBytes'] += len(pending)
                    pending.clear()
                    discard = True
                    self.coverage['limitHits'].append('exactLineBytes')
                if discard:
                    self.coverage['oversizedDiscardBytes'] += len(segment)
                else:
                    pending.extend(segment)
                if complete:
                    yield None if discard else bytes(pending), offset, True
                    offset += line_size
                    pending.clear()
                    line_size, discard = 0, False
                start = end
        if line_size:
            yield None if discard else bytes(pending), offset, stream.tell() == os.fstat(stream.fileno()).st_size

    def exact(self, candidate):
        cov = self.coverage
        entry = {'sessionId': candidate['id'], 'reason': 'projection-not-completeness-proof', 'status': 'not-read', 'projectionComplete': False, 'lineageMatch': None, 'interopDetected': False, 'unreadFromByte': None}
        self.adapters['exact']['sessions'].append(entry)
        used, eof, line_no = 0, False, 0
        range_before = self.range_events
        accounting = {'bytes': 0}
        budget = min(self.r['fileBytes'], self.r['totalBytes'] - cov['readBytes'])
        if budget <= 0 or cov['candidateFiles'] >= 128:
            entry.update(status='limited', unreadFromByte=0)
            cov['exactFallback']['unread'].append(entry.copy())
            cov['limitHits'].append('totalBytes' if budget <= 0 else 'files')
            return
        cov['candidateFiles'] += 1
        # rollout 可能已被另一 thread 取代；自己的 session_meta 才能授予 repo／parent 歸屬。
        sid, cwd, parent, turn = None, None, None, None
        turn_contexts = {}
        path = None
        try:
            self.check()
            if not isinstance(candidate['rollout_path'], str) or not candidate['rollout_path']:
                raise Gap('failed', 'invalid-rollout-path')
            path = Path(candidate['rollout_path'])
            if path.suffix.lower() != '.jsonl':
                raise Gap('failed', 'unsafe-rollout-path')
            self.safe_path(path)
            with path.open('rb', buffering=0) as stream:
                cov['openedFiles'] += 1
                for line, offset, complete in self.lines(stream, budget, accounting):
                    used = accounting['bytes']
                    line_no += 1
                    if line is None:
                        entry.update(status='limited', unreadFromByte=entry['unreadFromByte'] if entry['unreadFromByte'] is not None else offset)
                        entry.setdefault('skippedLineOffsets', []).append(offset)
                        continue
                    raw_size = len(line.rstrip(b'\n'))
                    if not complete:
                        entry.update(status='limited', unreadFromByte=offset)
                        break
                    if raw_size > 65536:
                        cov['exactFallback']['recoveredOversizedLines'] += 1
                    try:
                        event = json.loads(line.decode('utf-8-sig'))
                        if not isinstance(event, dict) or not isinstance(event.get('payload'), dict):
                            raise ValueError()
                    except (ValueError, UnicodeError):
                        entry['invalidLines'] = entry.get('invalidLines', 0) + 1
                        continue
                    payload = event.get('payload') or {}
                    typ = event.get('type')
                    if typ == 'session_meta':
                        actual = payload.get('id')
                        entry['lineageMatch'] = actual == candidate['id']
                        if not entry['lineageMatch']:
                            entry['reason'] = 'lineage-mismatch'
                        sid = actual
                        cwd = payload.get('cwd')
                        turn, turn_contexts = None, {}
                        source = payload.get('source')
                        parent = payload.get('forked_from_id') or payload.get('parent_session_id') or payload.get('previous_session_id') or spawn_parent(source)
                        continue
                    if typ == 'turn_context':
                        turn = payload.get('turn_id', payload.get('id', turn))
                        context_turn = payload.get('turn_id', payload.get('id'))
                        context_cwd = payload.get('cwd')
                        if isinstance(context_turn, str) and context_turn and isinstance(context_cwd, str) and Path(context_cwd).is_absolute():
                            turn_contexts[context_turn] = {'path': context_cwd, 'sessionId': sid, 'turnId': context_turn, 'file': str(path), 'line': line_no, 'byteOffset': offset}
                        continue
                    # Legacy 與 canonical 的解析、驗證和去重都屬於單筆 item；壞內容不能中止後續取材。
                    try:
                        pt = payload.get('type', typ)
                        if pt in ('task_started', 'turn_started'):
                            turn = payload.get('turn_id', turn)
                        if 'interop' in encoded(event).lower():
                            entry['interopDetected'] = True
                        role, text = None, None
                        normalized = None
                        if pt == 'item_completed':
                            pt, role, text, normalized = self.canonical_item(payload)
                            if not isinstance(payload.get('turn_id'), str) or not payload['turn_id'] or payload.get('thread_id') != sid:
                                raise Gap('compatibility-error', 'invalid-canonical-item-identity')
                        elif pt in ('user_message', 'agent_message'):
                            role = 'user' if pt == 'user_message' else 'assistant'
                            text = payload.get('message')
                        elif pt == 'message' and payload.get('role') in ('user', 'assistant'):
                            role = payload['role']
                            content = payload.get('content', [])
                            if not isinstance(content, list) or any(not isinstance(p, dict) or not isinstance(p.get('text', ''), str) for p in content):
                                raise Gap('compatibility-error', 'invalid-event-message-content')
                            text = '\n'.join(p.get('text', '') for p in content)
                        elif typ == 'response_item' or 'interop' in str(pt).lower() or pt in ('error', 'warning', 'turn_aborted', 'task_complete'):
                            role = 'tool'
                            text = encoded(payload)
                        if role:
                            event_turn = payload.get('turn_id', turn)
                            if event_turn is not None and not isinstance(event_turn, str):
                                raise Gap('compatibility-error', 'invalid-event-item-identity')
                            if not isinstance(text, str):
                                raise Gap('compatibility-error', 'invalid-event-message-content')
                            # 官方 materializer：started_at_ms 有值時不採 envelope timestamp。
                            when = timestamp(payload['started_at_ms'], 'ms') if normalized is not None and payload.get('started_at_ms') is not None else timestamp(event.get('timestamp'))
                            if when is None:
                                raise Gap('compatibility-error', 'unknown-event-time')
                            event_cwd = turn_contexts.get(event_turn, {}).get('path', cwd)
                            identity = hashlib.sha256(json.dumps(event, ensure_ascii=False, sort_keys=True).encode('utf-8')).hexdigest()
                            self.add(sid, event_cwd, parent, when, pt, role, text, event, {'adapter': 'exact-jsonl', 'file': str(path), 'line': line_no, 'byteOffset': offset, 'metadataThreadId': candidate['id'], 'callId': payload.get('call_id'), 'eventIdentity': identity}, event_turn, normalized['id'] if normalized is not None else payload.get('id'), normalized)
                    except (Gap, TypeError, ValueError) as error:
                        if isinstance(error, Gap) and error.status != 'compatibility-error':
                            raise
                        error = error if isinstance(error, Gap) else Gap('compatibility-error', 'invalid-event-item')
                        if 'time' in error.reason:
                            self.unknown += 1
                        entry['semanticGaps'] = entry.get('semanticGaps', 0) + 1
                        entry['reason'] = error.reason
                        self.gap('exact', error, 'event-item')
                used = accounting['bytes']
                eof = eof or stream.tell() == os.fstat(stream.fileno()).st_size
                if not eof and entry['status'] != 'limited':
                    entry.update(status='limited', unreadFromByte=used)
                if used >= self.r['fileBytes'] and not eof:
                    cov['fileCapStops'] += 1
                    cov['limitHits'].append('fileBytes')
                if cov['readBytes'] >= self.r['totalBytes']:
                    cov['limitHits'].append('totalBytes')
                if entry['status'] != 'limited':
                    entry['status'] = 'partial' if entry.get('invalidLines') or entry.get('semanticGaps') or entry['lineageMatch'] is not True else 'success'
                entry['projectionComplete'] = eof and entry['status'] == 'success'
                if entry['lineageMatch'] is True:
                    entry['parentSessionId'] = parent
        except FileNotFoundError:
            entry.update(status='missing', reason='exact-rollout-not-found')
        except PermissionError:
            entry.update(status='permission', reason='exact-rollout-access-denied')
        except (Gap, OSError, ValueError, UnicodeError) as error:
            entry.update(status=error.status if isinstance(error, Gap) else 'failed', reason=error.reason if isinstance(error, Gap) else 'exact-rollout-invalid-or-unreadable', unreadFromByte=used)
            if isinstance(error, Gap) and error.status == 'limited':
                cov['limitHits'].append(error.reason)
        finally:
            used = accounting['bytes']
            sql_events = [e for e in self.evidence if e['sessionId'] == candidate['id'] and any(p['adapter'] == 'history' for p in e['provenance'])]
            exact_events = [e for e in self.evidence if any(p['adapter'] == 'exact-jsonl' and p['file'] == str(path) for p in e['provenance'])]
            signature = lambda e: (e['sourceId'], e['eventType'], e['role'], e['text'])
            sql_keys, exact_keys = {signature(e) for e in sql_events}, {signature(e) for e in exact_events}
            entry.update(sqlEvents=len(sql_events), exactEvents=len(exact_events), exactOnlyEvents=len(exact_keys - sql_keys), sqlOnlyEvents=len(sql_keys - exact_keys), reconciliation='exact-identity-shape-only; EOF is not interop completeness')
            for event in sql_events:
                if parent and sid == candidate['id']:
                    event['parentSessionId'] = parent
                # SQL cwd 只是 thread 候選值；同 thread／turn 的明確 context 才能校正鏡像及 SQL-only。
                context = turn_contexts.get(event['turnId'])
                if entry['lineageMatch'] is True and sid == candidate['id'] and context:
                    event['path'] = context['path']
                    event['repoContext'] = context
                event['lineageVerified'] = entry['lineageMatch']
            if entry['status'] not in ('success',):
                cov['exactFallback']['unread'].append(entry.copy())
            if self.range_events > range_before:
                cov['filesWithRangeEvents'] += 1
            if cov['openedFiles'] > cov['readBytesDistribution']['count']:
                d = cov['readBytesDistribution']
                d['count'] += 1
                d['totalBytes'] += used
                d['minBytes'] = used if d['minBytes'] is None else min(used, d['minBytes'])
                d['maxBytes'] = used if d['maxBytes'] is None else max(used, d['maxBytes'])
                bucket = 'zero' if used == 0 else 'upTo256KiB' if used <= 262144 else 'upTo1MiB' if used <= 1048576 else 'upTo8MiB' if used <= 8388608 else 'over8MiB'
                d['buckets'][bucket] += 1

    def merge_replays(self):
        # 先完成逐 session SQL/exact 歸屬校正，再合併可信祖先鏈的原始事件重播。
        # family/text 相同不夠：cwd、turn、時間、role、全文及完整原始事件 identity 也須一致。
        parents = {s['sessionId']: s.get('parentSessionId') for s in self.adapters['exact']['sessions']
                   if s['status'] == 'success' and s['lineageMatch'] is True}
        ancestors = {}
        for sid in parents:
            chain, current = set(), sid
            while current in parents:
                if current in chain:
                    chain = set()  # 循環 metadata 不能授予跨 session 合併權。
                    break
                chain.add(current)
                current = parents[current]
            ancestors[sid] = chain - {sid}
        groups, result = {}, []
        for event in self.evidence:
            self.check()
            sid = event['sessionId']
            identities = {p['eventIdentity'] for p in event['provenance']
                          if p['adapter'] == 'exact-jsonl' and p['metadataThreadId'] == sid
                          and sid in parents and 'eventIdentity' in p}
            keys = [(event['path'], event['turnId'], tuple(event['timestamps']), event['role'], event['text'], identity)
                    for identity in identities]
            target = next((other for key in keys for other in groups.get(key, [])
                           if any(sid != old and (old in ancestors.get(sid, set()) or sid in ancestors.get(old, set()))
                                  for old in other['sessionIds'])), None)
            if target is None:
                target = event
                result.append(event)
            else:
                for field in ('sessionIds', 'files', 'timestamps', 'provenance'):
                    target[field].extend(value for value in event[field] if value not in target[field])
                for raw in [event['detail'], *event.get('mirrorDetails', [])]:
                    if raw != target['detail'] and raw not in target.get('mirrorDetails', []):
                        target.setdefault('mirrorDetails', []).append(raw)
            for key in keys:
                if not any(other is target for other in groups.get(key, [])):
                    groups.setdefault(key, []).append(target)
        self.evidence = result

    def run(self):
        candidates, state, history = [], None, None
        try:
            state, columns = self.connect('state_5.sqlite', 'threads', {'id', 'rollout_path', 'cwd'})
            missing_times = [base + ' or ' + base + '_ms' for base in ('created_at', 'updated_at') if base not in columns and base + '_ms' not in columns]
            if missing_times:
                self.adapters['state']['missingRequiredColumns'] = missing_times
                raise Gap('compatibility-error', 'required-threads-time-columns-missing')
            created = 'coalesce(created_at_ms,created_at*1000)' if {'created_at_ms', 'created_at'} <= columns.keys() else 'created_at_ms' if 'created_at_ms' in columns else 'created_at*1000'
            updated = 'coalesce(updated_at_ms,updated_at*1000)' if {'updated_at_ms', 'updated_at'} <= columns.keys() else 'updated_at_ms' if 'updated_at_ms' in columns else 'updated_at*1000'
            # 候選只用 lifespan overlap，不限制建立日或 archived；不先列全歷史再篩選。
            source = 'source' if 'source' in columns else 'null'
            valid_created = f"typeof({created}) in ('integer','real') and {created} between 946684800000 and 4102444800000"
            valid_updated = f"typeof({updated}) in ('integer','real') and {updated} between 946684800000 and 4102444800000"
            # 建立 thread 的版本不是共用 DB 的 schema；只作診斷，不可作讀取 gate。
            version = 'case when typeof(cli_version)=\'text\' and length(cast(cli_version as blob))<=64 then cli_version else null end' if 'cli_version' in columns else 'null'
            fields = {'id': 'id', 'rollout_path': 'rollout_path', 'cwd': 'cwd', 'cli_version': version, 'source': source}
            remaining = self.r['payloadBytes'] - self.sql['payloadBytes']
            lengths = '+'.join(f'coalesce(length(cast({field} as blob)),0)' for field in fields.values())
            projection = ','.join(f'case when ({lengths})<={remaining} then {field} else null end as {name}' for name, field in fields.items())
            select = f'select {projection},({lengths})>{remaining} as _payload_limited,{created} as created_ms,{updated} as updated_ms from threads'
            overlap = f'(({created}<=? and {updated}>=?) or not ({valid_created}) or not ({valid_updated}) or {created} is null or {updated} is null)'
            # LIMIT 只限制回傳量，不能阻止 coalesce/OR 掃全歷史。每個日期分支必須先通過
            # 既有 leading-column index + EXPLAIN SEARCH gate；不可建 index 或賭 planner 選 NULL index。
            indexes = {}
            for index in state.execute("pragma index_list('threads')"):
                if index[4]:
                    continue
                quoted = '"' + index[1].replace('"', '""') + '"'
                info = list(state.execute(f'pragma index_info({quoted})'))
                if info:
                    indexes.setdefault(info[0][2], quoted)
            branches = []
            for base in ('created_at', 'updated_at'):
                ms = base + '_ms'
                has_ms = ms in columns
                # 只省略 schema 保證不可能的 NULL；nullable 的未知時間仍須進 exact 補證。
                fallback = [(base, 1, ms + ' is null' if has_ms else '1')] if base in columns and (not has_ms or not columns[ms]) else []
                for field, scale, guard in ([(ms, 1000, '1')] if has_ms else []) + fallback:
                    if field not in indexes:
                        self.adapters['state']['missingRequiredIndexes'] = [f'threads({field}, ...)']
                        self.adapters['state']['queryPlan'] = {'gate': 'indexed-range-search', 'rejection': 'missing-leading-column-index', 'branch': {'field': field}}
                        raise Gap('compatibility-error', 'date-index-required')
                    lo, hi = 946684800 * scale, 4102444800 * scale
                    conditions = [('below-known-unit', f'{field}<?', (lo,)), ('above-known-unit', f'{field}>?', (hi,))]
                    if not columns[field] and (field == base or base not in columns):
                        conditions.append(('unknown-null', f'{field} is null', ()))
                    if base == 'updated_at':
                        conditions.append(('overlap-updated', f'{field} between ? and ?', (self.start * scale, hi)))
                    for condition, predicate, params in conditions:
                        query = f'{select} indexed by {indexes[field]} where ({predicate}) and ({guard}) and {overlap} limit ?'
                        args = (*params, self.end * 1000, self.start * 1000)
                        plan = [r[3] for r in state.execute('EXPLAIN QUERY PLAN ' + query, (*args, self.r['rows'] + 1))]
                        if not any(re.match(r'^SEARCH threads USING (?:COVERING )?INDEX ', p) for p in plan) or any(re.match(r'^(?:SCAN\b|USE TEMP B-TREE\b)', p) for p in plan):
                            # Index 名稱是使用者資料；只輸出固定 plan 類型與程式產生的分支標籤。
                            safe_plan = [match.group() if (match := re.match(r'^(?:SEARCH threads USING (?:COVERING )?INDEX|SCAN threads|USE TEMP B-TREE)\b', p)) else 'OTHER' for p in plan]
                            self.adapters['state']['queryPlan'] = {'gate': 'indexed-range-search', 'rejection': 'unsafe-query-plan', 'branch': {'field': field, 'condition': condition, 'guard': guard}, 'plan': safe_plan}
                            raise Gap('compatibility-error', 'date-query-not-indexed')
                        branches.append((query, args))
            self.adapters['state']['queryPlan'] = {'gate': 'indexed-range-search', 'branches': len(branches), 'unknownTimes': 'indexed-null-or-outside-known-unit; never inferred'}
            selected = set()
            for row in (row for query, args in branches for row in self.rows(state, query, args, 'state-overlap')):
                if row['id'] in selected:
                    continue
                selected.add(row['id'])
                for field in ('created_ms', 'updated_ms'):
                    try:
                        known = timestamp(row[field], 'ms') is not None
                    except Gap:
                        known = False
                    if not known:
                        self.adapters['state']['unknownMetadataTimes'] = self.adapters['state'].get('unknownMetadataTimes', 0) + 1
                try:
                    source = json.loads(row['source']) if isinstance(row['source'], str) else row['source']
                    row['parent'] = spawn_parent(source)
                except ValueError:
                    row['parent'] = None
                candidates.append(row)
            versions = sorted({c['cli_version'] for c in candidates if isinstance(c['cli_version'], str) and re.fullmatch(r'\d{1,3}\.\d{1,3}\.\d{1,3}(?:-alpha\.\d{1,4}\.\d{1,4})?', c['cli_version'])})[:8]
            if self.adapters['state'].get('unknownMetadataTimes'):
                self.gap('state', Gap('compatibility-error', 'unknown-metadata-time'), time_fields=tuple(field for field in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms') if field in columns))
            self.adapters['state'].update(status='partial' if self.adapters['state'].get('unknownMetadataTimes') else 'success' if candidates else 'valid-empty', candidates=len(candidates), runtime=','.join(versions) if versions else 'unverified')
        except (Gap, sqlite3.Error) as error:
            self.gap('state', error if isinstance(error, Gap) else self.sqlite_gap(error))
        finally:
            if state:
                state.close()
        if not candidates:
            # 有效空投影沒有 exact ID 可定位；仍需以原有日期／byte 限額補證 JSONL。
            return self.result(fallback=self.adapters['state']['status'] in ('valid-empty', 'missing', 'permission', 'compatibility-error'))
        try:
            history, _ = self.connect('thread_history_1.sqlite', 'thread_items', {'thread_id', 'turn_id', 'item_id', 'rollout_ordinal', 'created_at_ms', 'item_json', 'item_type'})
            # LIMIT 不能保護 history 全表 scan。先驗證實際計畫以 thread_id SEARCH 既有 index/PK；
            # 單一 thread 內的 ordinal 排序可以保留，不以固定 index 名稱限制支援的 schema。
            for candidate in candidates:
                # 真實 NULL 是單筆壞資料；不可與 CASE 為限額隱去的大 payload 混為一談。
                query = "select thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,length(cast(item_json as blob))>? as _payload_limited,case when length(cast(item_json as blob))<=? then item_json else null end as item_json from thread_items where thread_id=? and (created_at_ms between ? and ? or created_at_ms is null or typeof(created_at_ms) not in ('integer','real') or created_at_ms not between 946684800000 and 4102444800000) order by rollout_ordinal,item_id limit ?"
                remaining = self.r['payloadBytes'] - self.sql['payloadBytes']
                params = (remaining, remaining, candidate['id'], self.start * 1000, self.end * 1000)
                plan = [r[3] for r in history.execute('EXPLAIN QUERY PLAN ' + query, (*params, self.r['rows'] - self.sql['rows'] + 1))]
                if (not any(re.match(r'^SEARCH thread_items USING (?:(?:COVERING )?INDEX |PRIMARY KEY )', p) and 'thread_id=?' in p for p in plan)
                        or any('SCAN ' in p for p in plan)):
                    self.adapters['history']['missingRequiredIndexes'] = ['thread_items(thread_id, ...) indexed SEARCH']
                    raise Gap('compatibility-error', 'thread-items-thread_id-index-required')
                self.adapters['history']['queryPlan'] = {'gate': 'indexed-thread-search', 'scope': 'candidate-thread'}
                for row in self.rows(history, query, params, candidate['id']):
                    self.adapters['history']['returnedItems'] = self.adapters['history'].get('returnedItems', 0) + 1
                    # 單筆壞內容不代表共用 DB 不能讀；延續同一 row/payload/deadline 預算。
                    try:
                        self.item(row, candidate)
                    except (Gap, ValueError, TypeError) as error:
                        if isinstance(error, Gap) and error.status != 'compatibility-error':
                            raise
                        self.adapters['history']['rejectedItems'] = self.adapters['history'].get('rejectedItems', 0) + 1
                        self.gap('history', error if isinstance(error, Gap) else Gap('compatibility-error', 'invalid-history-item'), 'history-item')
            if self.adapters['history']['status'] == 'compatibility-error':
                if any(p['adapter'] == 'history' for e in self.evidence for p in e['provenance']):
                    self.adapters['history']['status'] = 'partial'
            else:
                self.adapters['history']['status'] = 'partial' if self.unknown else 'success' if self.adapters['history'].get('returnedItems') else 'valid-empty'
        except (Gap, sqlite3.Error, ValueError, TypeError) as error:
            self.gap('history', error if isinstance(error, Gap) else self.sqlite_gap(error) if isinstance(error, sqlite3.Error) else Gap('compatibility-error', 'invalid-history-item'), 'remaining-exact-candidates')
        finally:
            if history:
                history.close()
        for candidate in candidates:
            self.exact(candidate)
        self.merge_replays()
        return self.result()

    def result(self, fallback=False):
        sessions = self.adapters['exact']['sessions']
        gaps = [s for s in sessions if s['status'] != 'success' or s['lineageMatch'] is False]
        self.adapters['exact']['status'] = 'partial' if gaps else 'success' if sessions else 'not-read'
        self.coverage['limitHits'] = sorted(set(self.coverage['limitHits']))
        if 'totalBytes' in self.coverage['limitHits']:
            self.coverage['stopReason'] = 'totalBytes'
        elif 'files' in self.coverage['limitHits']:
            self.coverage['stopReason'] = 'files'
        elif 'deadline' in self.coverage['limitHits'] or 'deadline' in self.sql['limitHits']:
            self.coverage['stopReason'] = 'deadline'
        unavailable = any(a['status'] not in ('success', 'valid-empty', 'not-read') for a in self.adapters.values())
        # 正常 byte/line/file cap 的空結果沿用 legacy empty；不能把尚未讀到的 lineage
        # 當成損壞，也不能用限額掩蓋已觀察到的 malformed/unknown/permission/compatibility。
        # History DB 不存在是支援的 exact 補證路徑；保留 missing/coverage 缺口而非當作損壞。
        history = self.adapters['history']
        history_nondamaging = (history['status'] in ('success', 'valid-empty')
                              or (history['status'] == 'missing' and history.get('reason') == 'database-not-found'))
        cap_only = (bool(sessions) and bool(self.coverage['limitHits'])
                    and set(self.coverage['limitHits']) <= {'totalBytes', 'fileBytes', 'files', 'exactLineBytes'}
                    and all(s['status'] in ('success', 'limited') and not s.get('invalidLines')
                            and s['lineageMatch'] is not False and s['reason'] == 'projection-not-completeness-proof' for s in sessions)
                    and self.adapters['state']['status'] in ('success', 'valid-empty') and history_nondamaging
                    and not self.unknown and not self.sql['limitHits'] and not self.drafts)
        # 缺 history 但所有可信 exact 候選無損讀至 EOF，可回報已選資料無活動；
        # missing 診斷及 complete=false 仍保留，不能延伸成完整歷史查無活動。
        exact_empty = (bool(sessions) and all(s['projectionComplete'] and s['lineageMatch'] is True for s in sessions)
                       and self.adapters['state']['status'] in ('success', 'valid-empty') and history_nondamaging
                       and not self.unknown and not self.sql['limitHits'] and not self.drafts)
        status = 'partial' if self.evidence and (gaps or self.unknown or self.sql['limitHits'] or self.drafts or unavailable) else 'success' if self.evidence else 'empty' if cap_only or exact_empty else 'failed' if gaps or self.drafts or unavailable or self.unknown else 'empty'
        return {'fallback': fallback, 'readStatus': status, 'evidence': self.evidence, 'coverage': self.coverage, 'adapters': self.adapters, 'sqliteResources': self.sql, 'unknownTimeEvents': self.unknown, 'compatibilityIssues': self.drafts, 'runtime': {'python': '.'.join(map(str, sys.version_info[:3])), 'sqlite': sqlite3.sqlite_version, 'codexContract': SUPPORTED}}


if __name__ == '__main__':
    collector = None
    try:
        collector = Collector(json.load(sys.stdin))
        if sys.version_info < (3, 11):
            collector.gap('state', Gap('compatibility-error', 'python-3.11-required'))
            result = collector.result(fallback=True)
        else:
            result = collector.run()
        print(encoded(result))
    except Exception:
        # 私有 exception／SQL 值不寫入 stdout/stderr。
        if collector is not None:
            collector.gap('state', Gap('failed', 'adapter-failed'))
            print(encoded(collector.result()))
        else:
            print(encoded({'fallback': False, 'readStatus': 'failed', 'evidence': [], 'coverage': {'complete': False, 'strategy': 'adapter-stopped', 'accountingKnown': False}, 'adapters': {'state': {'status': 'failed', 'reason': 'adapter-failed'}}, 'compatibilityIssues': []}))
