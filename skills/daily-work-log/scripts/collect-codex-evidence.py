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

UTC = dt.timezone.utc
SUPPORTED = '0.164.0-alpha.11.1'


class Gap(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def iso(value):
    return dt.datetime.fromtimestamp(value, UTC).isoformat()


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

    def gap(self, adapter, gap, scope='requested-range'):
        self.adapters[adapter].update(status=gap.status, reason=gap.reason)
        if gap.status == 'limited':
            self.sql['limitHits'].append(gap.reason)
            self.sql['unread'].append({'adapter': adapter, 'scope': scope, 'from': self.r['from'], 'to': self.r['to']})
        if gap.status == 'compatibility-error':
            # 草稿只使用固定原因代碼及核對過的版本字串，絕不插入 exception、路徑或原文。
            difference = gap.reason + '; missing required columns: ' + ','.join(self.adapters[adapter].get('missingRequiredColumns', []))
            if self.adapters[adapter].get('missingRequiredIndexes'):
                difference += '; missing required index: ' + ','.join(self.adapters[adapter]['missingRequiredIndexes'])
            self.drafts.append({'destination': 'https://github.com/openai/codex/issues', 'requiresExplicitConsent': True, 'published': False, 'title': 'Codex 本機 history 相容性缺口', 'body': '已核對 runtime 契約：' + SUPPORTED + '\n觀察版本：' + self.adapters['state'].get('runtime', 'unverified') + '\n必要 schema／時間差異：' + difference + '\n影響：有界工作證據可能不完整；改用 exact rollout／日期分區補證或停止該來源，缺口見 coverage。\n合成重現：在 state_5.sqlite／thread_history_1.sqlite 建立上述缺少必要欄位、時間或 item type 差異，再執行指定日期的 collector。未包含私人原文、路徑、URL、auth 或 config。\n此為草稿；僅於使用者本次明確同意後，才可向上述目的地發布。'})

    def add(self, sid, cwd, parent, event_time, typ, role, text, raw, provenance, turn=None, item=None):
        if event_time is None:
            self.unknown += 1
            return
        self.valid_events += 1
        if not self.start <= event_time <= self.end or not text or not sid or not cwd or not Path(cwd).is_absolute():
            return
        self.range_events += 1
        # 只合併相同來源識別／種類／角色／全文的鏡像；不同 task 的同名工具不能併成一筆。
        payload = raw.get('payload', raw)
        source_id = payload.get('call_id') or payload.get('callId') or item or provenance.get('callId') or str(provenance.get('line', provenance.get('ordinal')))
        # 訊息的 SQL item ID 可能是 projection 自造值；同 thread／turn／實際時間／全文才視為鏡像。
        # Tool 另保留 call/item identity，避免同時同名的不同呼叫被合併。
        key = (sid, turn, event_time, role, text) if role in ('user', 'assistant') else (sid, turn, source_id, typ, role, text)
        output = payload.get('aggregatedOutput', payload.get('output', payload.get('result')))
        if role == 'tool' and source_id and output is not None and typ in ('commandExecution', 'mcpToolCall', 'dynamicToolCall', 'function_call_output', 'custom_tool_call_output'):
            # SQL 與 rollout 的 wrapper 不同；只有同 thread/turn/call 的相同完整 output 才合併。
            key = (sid, turn, source_id, 'tool-output', json.dumps(output, ensure_ascii=False, sort_keys=True))
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
        if typ not in {'userMessage', 'agentMessage', 'plan', 'reasoning', 'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'collabAgentToolCall', 'webSearch', 'imageView', 'imageGeneration', 'enteredReviewMode', 'exitedReviewMode', 'contextCompaction', 'error'}:
            raise Gap('compatibility-error', 'unknown-history-item-type')
        role = 'user' if typ == 'userMessage' else 'assistant' if typ == 'agentMessage' else 'tool'
        text = raw.get('text') or raw.get('message')
        if not text and role in ('user', 'assistant') and isinstance(raw.get('content'), list):
            text = '\n'.join(p.get('text', '') for p in raw['content'] if isinstance(p, dict))
        if not isinstance(text, str):
            text = encoded(raw)
        value = row['created_at_ms']
        try:
            when = timestamp(value, 'ms')
        except Gap:
            when = None
        self.add(candidate['id'], candidate['cwd'], candidate.get('parent'), when, typ, role, text, raw, {'adapter': 'history', 'threadId': row['thread_id'], 'turnId': row['turn_id'], 'itemId': row['item_id'], 'ordinal': row['rollout_ordinal']}, row['turn_id'], row['item_id'])

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
        path = Path(candidate['rollout_path'])
        try:
            self.check()
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
                        spawn = ((source.get('subagent') or {}).get('thread_spawn') or {}) if isinstance(source, dict) else {}
                        parent = payload.get('forked_from_id') or payload.get('parent_session_id') or payload.get('previous_session_id') or spawn.get('parent_thread_id')
                        continue
                    if typ == 'turn_context':
                        turn = payload.get('turn_id', payload.get('id', turn))
                        context_turn = payload.get('turn_id', payload.get('id'))
                        context_cwd = payload.get('cwd')
                        if isinstance(context_turn, str) and context_turn and isinstance(context_cwd, str) and Path(context_cwd).is_absolute():
                            turn_contexts[context_turn] = {'path': context_cwd, 'sessionId': sid, 'turnId': context_turn, 'file': str(path), 'line': line_no, 'byteOffset': offset}
                        continue
                    pt = payload.get('type', typ)
                    if pt in ('task_started', 'turn_started'):
                        turn = payload.get('turn_id', turn)
                    if 'interop' in encoded(event).lower():
                        entry['interopDetected'] = True
                    role, text = None, None
                    if pt in ('user_message', 'agent_message'):
                        role = 'user' if pt == 'user_message' else 'assistant'
                        text = payload.get('message')
                    elif pt == 'message' and payload.get('role') in ('user', 'assistant'):
                        role = payload['role']
                        text = '\n'.join(p.get('text', '') for p in payload.get('content', []) if isinstance(p, dict))
                    elif typ == 'response_item' or 'interop' in str(pt).lower() or pt in ('error', 'warning', 'turn_aborted', 'task_complete'):
                        role = 'tool'
                        text = encoded(payload)
                    if role:
                        try:
                            when = timestamp(event.get('timestamp'))
                        except Gap:
                            self.unknown += 1
                            continue
                        event_turn = payload.get('turn_id', turn)
                        event_cwd = turn_contexts.get(event_turn, {}).get('path', cwd)
                        identity = hashlib.sha256(json.dumps(event, ensure_ascii=False, sort_keys=True).encode('utf-8')).hexdigest()
                        self.add(sid, event_cwd, parent, when, pt, role, text, event, {'adapter': 'exact-jsonl', 'file': str(path), 'line': line_no, 'byteOffset': offset, 'metadataThreadId': candidate['id'], 'callId': payload.get('call_id'), 'eventIdentity': identity}, event_turn, payload.get('id'))
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
                    entry['status'] = 'partial' if entry.get('invalidLines') or entry['lineageMatch'] is not True else 'success'
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
            state, columns = self.connect('state_5.sqlite', 'threads', {'id', 'rollout_path', 'cwd', 'created_at', 'updated_at', 'cli_version'})
            created = 'coalesce(created_at_ms,created_at*1000)' if 'created_at_ms' in columns else 'created_at*1000'
            updated = 'coalesce(updated_at_ms,updated_at*1000)' if 'updated_at_ms' in columns else 'updated_at*1000'
            # 候選只用 lifespan overlap，不限制建立日或 archived；不先列全歷史再篩選。
            source = 'source' if 'source' in columns else 'null'
            valid_created = f"typeof({created}) in ('integer','real') and {created} between 946684800000 and 4102444800000"
            valid_updated = f"typeof({updated}) in ('integer','real') and {updated} between 946684800000 and 4102444800000"
            fields = {'id': 'id', 'rollout_path': 'rollout_path', 'cwd': 'cwd', 'cli_version': 'cli_version', 'source': source}
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
                fallback = [(base, 1, ms + ' is null' if has_ms else '1')] if not has_ms or not columns[ms] else []
                for field, scale, guard in ([(ms, 1000, '1')] if has_ms else []) + fallback:
                    if field not in indexes:
                        self.adapters['state']['missingRequiredIndexes'] = [f'threads({field}, ...)']
                        self.adapters['state']['queryPlan'] = {'gate': 'indexed-range-search', 'rejection': 'missing-leading-column-index', 'branch': {'field': field}}
                        raise Gap('compatibility-error', 'date-index-required')
                    lo, hi = 946684800 * scale, 4102444800 * scale
                    conditions = [('below-known-unit', f'{field}<?', (lo,)), ('above-known-unit', f'{field}>?', (hi,))]
                    if field == base and not columns[field]:
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
                    row['parent'] = (((source.get('subagent') or {}).get('thread_spawn') or {}).get('parent_thread_id')) if isinstance(source, dict) else None
                except ValueError:
                    row['parent'] = None
                candidates.append(row)
            versions = sorted({c['cli_version'] for c in candidates if isinstance(c['cli_version'], str) and re.fullmatch(r'\d{1,3}\.\d{1,3}\.\d{1,3}(?:-alpha\.\d{1,4}\.\d{1,4})?', c['cli_version'])})[:8]
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
            if any(c['cli_version'] != SUPPORTED for c in candidates):
                raise Gap('compatibility-error', 'unsupported-runtime')
            history, _ = self.connect('thread_history_1.sqlite', 'thread_items', {'thread_id', 'turn_id', 'item_id', 'rollout_ordinal', 'created_at_ms', 'item_json', 'item_type'})
            # LIMIT 不能保護 history 全表 scan。先驗證實際計畫以 thread_id SEARCH 既有 index/PK；
            # 單一 thread 內的 ordinal 排序可以保留，不以固定 index 名稱限制支援的 schema。
            for candidate in candidates:
                query = "select thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,case when length(cast(item_json as blob))<=? then item_json else null end as item_json from thread_items where thread_id=? and (created_at_ms between ? and ? or created_at_ms is null or typeof(created_at_ms) not in ('integer','real') or created_at_ms not between 946684800000 and 4102444800000) order by rollout_ordinal,item_id limit ?"
                params = (self.r['payloadBytes'] - self.sql['payloadBytes'], candidate['id'], self.start * 1000, self.end * 1000)
                plan = [r[3] for r in history.execute('EXPLAIN QUERY PLAN ' + query, (*params, self.r['rows'] - self.sql['rows'] + 1))]
                if (not any(re.match(r'^SEARCH thread_items USING (?:(?:COVERING )?INDEX |PRIMARY KEY )', p) and 'thread_id=?' in p for p in plan)
                        or any('SCAN ' in p for p in plan)):
                    self.adapters['history']['missingRequiredIndexes'] = ['thread_items(thread_id, ...) indexed SEARCH']
                    raise Gap('compatibility-error', 'thread-items-thread_id-index-required')
                self.adapters['history']['queryPlan'] = {'gate': 'indexed-thread-search', 'scope': 'candidate-thread'}
                for row in self.rows(history, query, params, candidate['id']):
                    if row['item_json'] is None:
                        raise Gap('limited', 'payloadBytes')
                    self.adapters['history']['returnedItems'] = self.adapters['history'].get('returnedItems', 0) + 1
                    self.item(row, candidate)
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
