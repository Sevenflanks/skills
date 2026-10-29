"""Synthetic SQLite/rollout regressions at the published collector/formatter CLI."""
import json
import datetime as dt
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
PWSH = shutil.which('pwsh')


@unittest.skipUnless(PWSH, 'PowerShell 7 is required for collector CLI integration')
class CodexCollection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dwl49-', dir=Path(tempfile.gettempdir()) / 'opencode' if os.name == 'nt' else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'codex'
        self.home.mkdir()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.env = dict(os.environ)
        # No external CLI or personal history may participate in a fixture verdict.
        self.env['PATH'] = os.pathsep.join({str(Path(PWSH).parent), str(Path(shutil.which('python')).parent), str(Path(shutil.which('git')).parent)})
        self.env['GIT_CONFIG_GLOBAL'] = os.devnull
        self.env['GIT_CONFIG_NOSYSTEM'] = '1'
        subprocess.run([shutil.which('git'), 'init', '-q', str(self.repo)], check=True, capture_output=True, timeout=5)
        self.state = sqlite3.connect(self.home / 'state_5.sqlite')
        self.addCleanup(self.state.close)
        self.state.execute('create table threads(id text primary key, rollout_path text, cwd text, created_at integer, updated_at integer, created_at_ms integer, updated_at_ms integer, archived integer, cli_version text, source text)')
        for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
            self.state.execute(f'create index idx_threads_{column} on threads({column},id)')
        self.history = sqlite3.connect(self.home / 'thread_history_1.sqlite')
        self.addCleanup(self.history.close)
        self.history.execute('create table thread_items(thread_id text, turn_id text, item_id text, rollout_ordinal integer, created_at_ms integer, item_json text, item_type text, updated_at_ordinal integer, started_at_ms integer, completed_at_ms integer)')
        self.history.execute('create index idx_items_thread on thread_items(thread_id,rollout_ordinal,item_id)')

    def rollout(self, sid='old', archived=True, messages=None, parent=None):
        path = self.home / ('archived_sessions' if archived else 'sessions/2020/01/01') / (sid + '.jsonl')
        path.parent.mkdir(parents=True, exist_ok=True)
        meta = {'id': sid, 'cwd': str(self.repo)}
        if parent:
            meta['source'] = {'subagent': {'thread_spawn': {'parent_thread_id': parent}}}
        records = [{'type': 'session_meta', 'payload': meta}]
        records += messages or []
        path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
        self.state.execute('insert into threads values(?,?,?,?,?,?,?,?,?,?)', (sid, str(path), str(self.repo), 1577836800, 1780070399, None, None, int(archived), '0.164.0-alpha.11.1', 'cli'))
        self.state.commit()
        return path

    def event(self, text, time='2026-05-29T02:00:00Z', role='user', **extra):
        return {'timestamp': time, 'type': 'event_msg', 'payload': {'type': 'user_message' if role == 'user' else 'agent_message', 'message': text, **extra}}

    def item(self, text, time=1780020000000, sid='old', iid='sql1', turn='turn-a', **extra):
        data = {'type': 'agentMessage', 'text': text, **extra}
        self.history.execute('insert into thread_items values(?,?,?,?,?,?,?,?,?,?)', (sid, turn, iid, 1, time, json.dumps(data), 'agentMessage', 1, time, time))
        self.history.commit()

    def collect(self, *extra, unavailable_commands=()):
        args = [PWSH, '-NoProfile', '-File', str(SCRIPTS / 'collect-daily-work-log.ps1'), '-From', '2026-05-29T00:00:00+08:00', '-To', '2026-05-29T23:59:59+08:00', '-CodexRoot', str(self.home), '-OpenCodeLogRoot', str(self.root / 'logs'), '-OpenCodeStorageRoot', str(self.root / 'storage'), '-ScanRoots', str(self.repo), *extra]
        if unavailable_commands:
            # Replace only external discovery; the published collector and legacy reader still run.
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            blocked = ','.join(quote(name) for name in unavailable_commands)
            command = ("function Get-Command { [CmdletBinding()] param([string]$Name) "
                       f"if ($Name -in @({blocked})) {{ return }}; "
                       "Microsoft.PowerShell.Core\\Get-Command @PSBoundParameters }; & "
                       + quote(args[3]) + ' ' + ' '.join(arg if arg.startswith('-') and arg[1:].isalnum() else quote(arg) for arg in args[4:]))
            args = [PWSH, '-NoProfile', '-Command', command]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, text=True, encoding='utf-8')
        try:
            out, err = process.communicate(timeout=45)
        finally:
            if process.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=5)
                else:
                    process.kill()
                process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, err)
        data = json.loads(out)
        self.assertEqual(data['errors'], [])
        return data

    def test_archived_old_thread_keeps_multiple_missions_and_sql_nonempty_fallback(self):
        texts = ['目標甲早期需求', '目標甲中段修正', '目標甲結果', '目標乙需求', '目標乙決策', '目標乙完成']
        self.rollout(messages=[self.event(t, role='user' if i % 2 == 0 else 'assistant') for i, t in enumerate(texts)])
        self.item('SQL 中間訊息')
        data = self.collect()
        self.assertTrue(data['repos'], json.dumps(data, ensure_ascii=False))
        evidence = data['repos'][0]['sessionEvidence']
        self.assertEqual({e['text'] for e in evidence}, set(texts + ['SQL 中間訊息']))
        self.assertEqual(data['meta']['sources']['codex']['adapters']['state']['status'], 'success')
        self.assertFalse(data['meta']['sources']['codex']['coverage']['complete'])
        self.assertEqual(data['meta']['sources']['codex']['adapters']['exact']['sessions'][0]['reason'], 'projection-not-completeness-proof')

    def test_json_pipe_ignores_non_utf8_locale_and_io_override_for_unicode_root_and_text(self):
        self.state.close()
        self.history.close()
        self.home = self.home.rename(self.root / '中文來源🧪')
        self.repo = self.repo.rename(self.root / '中文專案🧪')
        self.state = sqlite3.connect(self.home / 'state_5.sqlite')
        self.history = sqlite3.connect(self.home / 'thread_history_1.sqlite')
        self.addCleanup(self.state.close)
        self.addCleanup(self.history.close)
        self.env.update(PYTHONUTF8='0', PYTHONCOERCECLOCALE='0', LC_ALL='C')
        self.rollout(messages=[self.event('中文 JSONL 證據🧪')])
        self.item('中文 SQL 證據🧪')
        for override in (None, 'cp950:strict'):
            with self.subTest(PYTHONIOENCODING=override):
                if override is None:
                    self.env.pop('PYTHONIOENCODING', None)
                else:
                    self.env['PYTHONIOENCODING'] = override
                data = self.collect()
                self.assertEqual(data['meta']['sources']['codex']['readStatus'], 'success')
                evidence = data['repos'][0]['sessionEvidence']
                self.assertEqual({e['text'] for e in evidence}, {'中文 JSONL 證據🧪', '中文 SQL 證據🧪'})
                self.assertEqual({e['path'] for e in evidence}, {str(self.repo)})

    def test_tool_readback_failure_nested_mcp_and_parent_chain_survive_formatter(self):
        output = {'structuredContent': {'result': {'state': 'MERGED', 'readback': '成功讀回'}}, '_meta': {'trace': {'receipt': 'receipt-42'}}}
        events = [self.event('x' * 300 + '完整需求尾端', id='req')]
        for turn, result in [('mission-a', output), ('mission-b', {'exit_code': 1, 'error': 'verification failed'})]:
            events += [{'type': 'turn_context', 'payload': {'id': turn}}, {'timestamp': '2026-05-29T03:00:00Z', 'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': turn + '-tool', 'name': 'same-tool', 'output': result}}]
        self.rollout(sid='child', messages=events, parent='parent')
        self.item('中段結果', sid='child', structuredContent=output)
        data = self.collect()
        evidence = data['repos'][0]['sessionEvidence']
        tools = [e for e in evidence if e['eventType'] == 'function_call_output']
        self.assertEqual(len(tools), 2)
        self.assertEqual(tools[0]['parentSessionId'], 'parent')
        self.assertEqual(tools[0]['tool']['name'], 'same-tool')
        self.assertEqual(tools[1]['tool']['exitCode'], 1)
        raw = json.dumps(data, ensure_ascii=False)
        for view in ('summary', 'erp'):
            result = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'format-daily-work-log-evidence.ps1'), '-View', view], input=raw, capture_output=True, text=True, encoding='utf-8', timeout=15)
            formatted = json.loads(result.stdout)
            rendered = formatted['repos'][0]['sessionEvidence']
            if view == 'erp':
                self.assertEqual(rendered, evidence)
            else:
                # Critical success readback and failure keep full nested payload and call identity.
                for tool in tools:
                    kept = next(e for e in rendered if e.get('sourceId') == tool['sourceId'])
                    self.assertEqual(kept['detail'], tool['detail'])
                    self.assertEqual(kept['tool'], tool['tool'])
                    self.assertEqual(kept['provenance'], tool['provenance'])
                self.assertTrue(any(e['text'].endswith('完整需求尾端') for e in rendered))
            self.assertEqual(formatted['meta']['sources'], data['meta']['sources'])
        self.assertTrue(any(e['text'].endswith('完整需求尾端') for e in evidence))

    def test_summary_compacts_routine_large_output_but_expands_critical_success_and_failure(self):
        body = 'routine-output-' * 6000
        self.rollout(messages=[{'type': 'turn_context', 'payload': {'id': 'turn-a'}}])
        self.item(None, iid='routine', type='commandExecution', command='list', status='completed', exitCode=0, aggregatedOutput=body)
        self.item(None, iid='verify', type='commandExecution', command='python -m unittest', status='completed', exitCode=0, aggregatedOutput='Ran 9 tests; OK; full verification result')
        self.item(None, iid='delivery', type='commandExecution', command='gh pr view 49 --json state', status='completed', exitCode=0, aggregatedOutput='{"state":"MERGED","receipt":"delivered-49"}')
        # Known-success opaque tool: structured readback must survive without name/keyword hints.
        self.item(None, iid='opaque', type='mcpToolCall', name='same-tool', status='completed', exitCode=0, result={'structuredContent': {'state': 'MERGED', 'number': 49}, '_meta': {'trace': {'id': 'opaque-49'}}})
        self.item(None, iid='failed', type='commandExecution', command='list', status='failed', exitCode=1, error={'message': '完整失敗原因', '_meta': {'receipt': 'error-49'}}, aggregatedOutput='full failure output')
        data = self.collect()
        raw = json.dumps(data, ensure_ascii=False)
        result = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'format-daily-work-log-evidence.ps1'), '-View', 'summary'], input=raw, capture_output=True, text=True, encoding='utf-8', timeout=15, check=True)
        formatted = json.loads(result.stdout)
        self.assertEqual(formatted['errors'], [])
        for key, value in data['meta'].items():
            if key in ('from', 'to', 'generatedAt'):
                self.assertEqual(dt.datetime.fromisoformat(formatted['meta'][key]), dt.datetime.fromisoformat(value))
            else:
                self.assertEqual(formatted['meta'][key], value)
        original = data['repos'][0]['sessionEvidence']
        rendered = formatted['repos'][0]['sessionEvidence']
        self.assertEqual(len(rendered), 5)
        routine = next(e for e in rendered if e['sourceId'] == 'routine')
        self.assertLess(len(result.stdout.encode('utf-8')), 25000)
        self.assertNotIn(body, result.stdout)
        self.assertNotIn('detail', routine)
        self.assertEqual(routine['tool']['status'], 'completed')
        self.assertEqual(routine['tool']['exitCode'], 0)
        # Resolve the JSON pointer against the raw collector document, not a formatter helper.
        referred = data
        for token in routine['detailRef']['jsonPointer'].strip('/').split('/'):
            referred = referred[int(token)] if isinstance(referred, list) else referred[token]
        self.assertEqual(referred['detail']['aggregatedOutput'], body)
        self.assertEqual(routine['provenance'], referred['provenance'])
        for iid in ('verify', 'delivery', 'opaque', 'failed'):
            self.assertEqual(next(e for e in rendered if e['sourceId'] == iid)['detail'], next(e for e in original if e['sourceId'] == iid)['detail'])

    def test_sql_tool_output_mirror_keeps_both_sources_and_other_call_separate(self):
        self.rollout(messages=[{'type': 'turn_context', 'payload': {'id': 'turn-a'}},
            {'timestamp': '2026-05-29T02:00:00Z', 'type': 'response_item', 'payload':
                {'type': 'function_call_output', 'call_id': 'call-1', 'output': 'readback OK'}}])
        for iid in ('call-1', 'call-2'):
            self.item(None, iid=iid, type='commandExecution', command='verify', status='completed', exitCode=0, aggregatedOutput='readback OK')
        data = self.collect()
        evidence = data['repos'][0]['sessionEvidence']
        self.assertEqual(len(evidence), 2)
        merged = next(e for e in evidence if e['sourceId'] == 'call-1')
        self.assertEqual({p['adapter'] for p in merged['provenance']}, {'history', 'exact-jsonl'})
        self.assertEqual(merged['tool']['exitCode'], 0)
        self.assertEqual(merged['tool']['status'], 'completed')

    def test_trusted_parent_replays_merge_after_sql_mirror_context_reconciliation(self):
        events = [
            {'type': 'turn_context', 'payload': {'id': 'turn-a', 'cwd': str(self.repo)}},
            self.event('原始需求無自造ID'),
            self.event('同一結果', role='assistant', id='answer-1'),
            {'timestamp': '2026-05-29T02:00:00Z', 'type': 'response_item', 'payload':
                {'type': 'function_call_output', 'call_id': 'call-1', 'output': 'readback OK'}},
        ]
        paths = []
        for sid, parent in (('parent', None), ('child', 'parent')):
            paths.append(str(self.rollout(sid=sid, parent=parent, messages=events)))
            self.item('同一結果', sid=sid, iid='sql-' + sid)
            self.item(None, sid=sid, iid='call-1', type='commandExecution', command='verify',
                      status='completed', exitCode=0, aggregatedOutput='readback OK')
        # The index cwd is stale: exact turn context must correct SQL mirrors before merging.
        self.state.execute('update threads set cwd=?', (str(self.root / 'stale-index'),))
        self.state.commit()
        data = self.collect()
        evidence = [e for repo in data['repos'] for e in repo['sessionEvidence']]
        self.assertEqual(len(evidence), 3)
        for event in evidence:
            self.assertEqual(set(event['sessionIds']), {'parent', 'child'})
            self.assertEqual(set(event['files']), set(paths))
            self.assertEqual(len(event['timestamps']), 1)
            self.assertEqual(dt.datetime.fromisoformat(event['timestamps'][0]), dt.datetime(2026, 5, 29, 2, tzinfo=dt.timezone.utc))
            self.assertEqual(event['turnId'], 'turn-a')
            self.assertEqual(event['path'], str(self.repo))
            exact = [p for p in event['provenance'] if p['adapter'] == 'exact-jsonl']
            self.assertEqual({p['metadataThreadId'] for p in exact}, {'parent', 'child'})
            self.assertEqual({p['file'] for p in exact}, set(paths))
            if event['role'] != 'user':
                sql = [p for p in event['provenance'] if p['adapter'] == 'history']
                self.assertEqual({p['threadId'] for p in sql}, {'parent', 'child'})
                self.assertEqual(len(event['provenance']), 4)
                self.assertTrue(event['lineageVerified'])
                self.assertEqual(event['repoContext']['path'], str(self.repo))
        tool = next(e for e in evidence if e['role'] == 'tool')
        self.assertEqual(tool['sourceId'], 'call-1')
        self.assertEqual(tool['tool']['exitCode'], 0)
        self.assertEqual(tool['tool']['status'], 'completed')
        self.assertEqual(tool['tool']['callId'], 'call-1')
        for session in data['meta']['sources']['codex']['adapters']['exact']['sessions']:
            self.assertEqual(session['sqlEvents'], 2)
            self.assertEqual(session['exactEvents'], 3)

    def test_raw_parent_replay_without_item_or_turn_id_merges_verified_ancestor_chain(self):
        paths = []
        # Descendants are selected before their ancestors; lineage must be resolved after all exact reads.
        for sid, parent, field in (('leaf', 'child', None), ('child', 'parent', 'previous_session_id'),
                                   ('parent', 'root', 'forked_from_id'), ('root', None, None)):
            path = self.rollout(sid=sid, parent=parent, messages=[self.event('完整相同原始事件')])
            if field:
                lines = path.read_text(encoding='utf-8').splitlines()
                meta = json.loads(lines[0])
                meta['payload'].pop('source')
                meta['payload'][field] = parent
                path.write_text('\n'.join([json.dumps(meta), *lines[1:]]), encoding='utf-8')
            paths.append(str(path))
        evidence = self.collect()['repos'][0]['sessionEvidence']
        self.assertEqual(len(evidence), 1)
        self.assertEqual(set(evidence[0]['sessionIds']), {'leaf', 'child', 'parent', 'root'})
        self.assertEqual(set(evidence[0]['files']), set(paths))
        self.assertEqual(len(evidence[0]['provenance']), 4)
        self.assertIsNone(evidence[0]['turnId'])
        self.assertEqual(evidence[0]['text'], '完整相同原始事件')

    def test_parent_replay_requires_same_identity_context_and_actual_trusted_link(self):
        other_repo = self.root / 'other-repo'
        other_repo.mkdir()
        subprocess.run([shutil.which('git'), 'init', '-q', str(other_repo)], check=True, capture_output=True, timeout=5)
        for difference in ('turn', 'call', 'text', 'time', 'role', 'item-id', 'raw-shape', 'cwd',
                           'no-lineage', 'state-only-lineage', 'mismatch', 'siblings', 'cycle', 'sql-only', 'malformed'):
            with self.subTest(difference=difference):
                self.state.execute('delete from threads')
                self.history.execute('delete from thread_items')
                self.history.commit()
                context = {'type': 'turn_context', 'payload': {'id': 'turn-a', 'cwd': str(self.repo)}}
                original = self.event('相同工作結果', role='assistant', id='answer-1')
                changed = json.loads(json.dumps(original))
                child_context = json.loads(json.dumps(context))
                child_parent = None if difference in ('no-lineage', 'state-only-lineage') else 'shared' if difference == 'siblings' else 'parent'
                parent_parent = 'child' if difference == 'cycle' else 'shared' if difference == 'siblings' else None
                if difference == 'turn':
                    child_context['payload']['id'] = 'turn-b'
                elif difference == 'cwd':
                    child_context['payload']['cwd'] = str(other_repo)
                elif difference == 'text':
                    changed['payload']['message'] = '另一個工作結果'
                elif difference == 'time':
                    changed['timestamp'] = '2026-05-29T02:00:01Z'
                elif difference == 'role':
                    changed['payload']['type'] = 'user_message'
                elif difference == 'item-id':
                    changed['payload']['id'] = 'answer-2'
                elif difference == 'raw-shape':
                    changed = {'timestamp': original['timestamp'], 'type': 'response_item', 'payload':
                               {'type': 'message', 'role': 'assistant', 'content': [{'text': '相同工作結果'}]}}
                elif difference == 'call':
                    original = {'timestamp': original['timestamp'], 'type': 'response_item', 'payload':
                                {'type': 'function_call_output', 'call_id': 'call-1', 'output': 'same'}}
                    changed = json.loads(json.dumps(original))
                    changed['payload']['call_id'] = 'call-2'
                self.rollout(sid='parent', parent=parent_parent, messages=[context, original])
                path = self.rollout(sid='child', parent=child_parent,
                                    messages=[child_context] if difference == 'sql-only' else [child_context, changed])
                if difference == 'state-only-lineage':
                    self.state.execute('update threads set source=? where id=?',
                                       (json.dumps({'subagent': {'thread_spawn': {'parent_thread_id': 'parent'}}}), 'child'))
                    self.state.commit()
                elif difference == 'mismatch':
                    path.write_text(path.read_text(encoding='utf-8').replace('"id": "child"', '"id": "untrusted"'), encoding='utf-8')
                elif difference == 'malformed':
                    path.write_text(path.read_text(encoding='utf-8') + '\nnot-json', encoding='utf-8')
                elif difference == 'sql-only':
                    self.item('相同工作結果', sid='parent', iid='answer-1')
                    self.item('相同工作結果', sid='child', iid='answer-1')
                data = self.collect()
                evidence = [e for repo in data['repos'] for e in repo['sessionEvidence']]
                self.assertEqual(len(evidence), 2)
                self.assertTrue(all(len(e['sessionIds']) == 1 for e in evidence))

    def test_matching_turn_context_corrects_mirrors_and_sql_only_without_other_turn_pollution(self):
        repos = {}
        for name in ('B', 'C'):
            repos[name] = self.root / ('repo-' + name)
            repos[name].mkdir()
            subprocess.run([shutil.which('git'), 'init', '-q', str(repos[name])], check=True, capture_output=True, timeout=5)
        messages = []
        for name in ('B', 'C'):
            messages += [
                {'type': 'turn_context', 'payload': {'turn_id': 'turn-' + name, 'cwd': str(repos[name])}},
                self.event('鏡像' + name, role='assistant'),
                {'timestamp': '2026-05-29T02:00:00Z', 'type': 'response_item', 'payload':
                    {'type': 'function_call_output', 'call_id': 'call-1', 'output': 'same output'}},
            ]
            self.item('鏡像' + name, iid='mirror-' + name, turn='turn-' + name)
            self.item('僅SQL' + name, iid='sql-only-' + name, turn='turn-' + name)
            for call in ('call-1', 'call-2'):
                self.item(None, iid=call, turn='turn-' + name, type='commandExecution', command='verify', status='completed', exitCode=0, aggregatedOutput='same output')
        # An explicit event turn must not borrow the last turn-C context either.
        messages += [self.event('不同turn', role='assistant', turn_id='other-turn'),
                     self.event('獨立exact不同turn', role='assistant', turn_id='other-turn')]
        path = self.rollout(messages=messages)
        self.item('不同turn', iid='other', turn='other-turn')
        self.item('無turn', iid='no-turn', turn=None)
        data = self.collect()
        evidence = [e for repo in data['repos'] for e in repo['sessionEvidence']]
        self.assertEqual(len(evidence), 11)
        for name in ('B', 'C'):
            with self.subTest(turn=name):
                events = [e for e in evidence if e['turnId'] == 'turn-' + name]
                self.assertEqual(len(events), 4)
                self.assertEqual({e['path'] for e in events}, {str(repos[name])})
                for event in events:
                    self.assertEqual(event['repoContext']['file'], str(path))
                    self.assertEqual(event['repoContext']['sessionId'], 'old')
                    self.assertEqual(event['repoContext']['turnId'], 'turn-' + name)
                    self.assertTrue(event['lineageVerified'])
                mirror = next(e for e in events if e['text'] == '鏡像' + name)
                self.assertEqual({p['adapter'] for p in mirror['provenance']}, {'history', 'exact-jsonl'})
                self.assertEqual(mirror['detail'], {'type': 'agentMessage', 'text': '鏡像' + name})
                self.assertEqual(mirror['mirrorDetails'][0]['payload']['message'], '鏡像' + name)
                sql_only = next(e for e in events if e['text'] == '僅SQL' + name)
                self.assertEqual({p['adapter'] for p in sql_only['provenance']}, {'history'})
                tools = [e for e in events if e['role'] == 'tool']
                self.assertEqual({e['sourceId'] for e in tools}, {'call-1', 'call-2'})
                merged_tool = next(e for e in tools if e['sourceId'] == 'call-1')
                self.assertEqual({p['adapter'] for p in merged_tool['provenance']}, {'history', 'exact-jsonl'})
        for event in [e for e in evidence if e['turnId'] in ('other-turn', None)]:
            self.assertEqual(event['path'], str(self.repo))
            self.assertNotIn('repoContext', event)

    def test_mismatched_thread_turn_context_cannot_reassign_sql_even_with_same_turn(self):
        other = self.root / 'other-repo'
        other.mkdir()
        subprocess.run([shutil.which('git'), 'init', '-q', str(other)], check=True, capture_output=True, timeout=5)
        path = self.rollout(messages=[{'type': 'turn_context', 'payload': {'id': 'turn-a', 'cwd': str(other)}}, self.event('同文不同thread', role='assistant')])
        records = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        records[0]['payload']['id'] = 'different-thread'
        path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
        self.item('同文不同thread')
        data = self.collect()
        evidence = [e for repo in data['repos'] for e in repo['sessionEvidence']]
        self.assertEqual(len(evidence), 2)
        sql = next(e for e in evidence if e['sessionId'] == 'old')
        exact = next(e for e in evidence if e['sessionId'] == 'different-thread')
        self.assertEqual(sql['path'], str(self.repo))
        self.assertFalse(sql['lineageVerified'])
        self.assertNotIn('repoContext', sql)
        self.assertEqual({p['adapter'] for p in sql['provenance']}, {'history'})
        self.assertEqual(exact['path'], str(other))
        self.assertEqual({p['adapter'] for p in exact['provenance']}, {'exact-jsonl'})

    def test_actual_event_boundaries_seconds_milliseconds_null_unknown_not_turn_dates(self):
        self.rollout(messages=[self.event('起點秒', 1779984000), self.event('終點毫秒', 1780070399000), self.event('太早', '2026-05-28T15:59:59Z'), self.event('太晚', '2026-05-29T16:00:00Z'), self.event('未知', None), self.event('未知單位', 17)])
        # Turn IDs do not carry time authority; one turn crosses both boundaries.
        for text, iso in [('SQL起點', '2026-05-28T16:00:00+00:00'), ('SQL終點', '2026-05-29T15:59:59+00:00'), ('SQL太早', '2026-05-28T15:59:59+00:00'), ('SQL太晚', '2026-05-29T16:00:00+00:00')]:
            self.item(text, int(dt.datetime.fromisoformat(iso).timestamp() * 1000), iid=text, turn='crossing-turn')
        self.item('SQL未知', None, iid='null')
        data = self.collect()
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']}, {'起點秒', '終點毫秒', 'SQL起點', 'SQL終點'})
        self.assertEqual(data['meta']['sources']['codex']['unknownTimeEvents'], 3)
        self.assertEqual(data['meta']['sources']['codex']['readStatus'], 'partial')

    def test_unknown_metadata_and_item_dates_do_not_hide_later_dated_work(self):
        self.rollout(messages=[self.event('exact當日')])
        self.state.execute('update threads set created_at=null,updated_at=null')
        self.state.commit()
        self.item('未知時間不可猜', 17, iid='unknown')
        self.item('後續日期確定的SQL', iid='valid')
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']}, {'exact當日', '後續日期確定的SQL'})
        self.assertEqual(source['adapters']['state']['unknownMetadataTimes'], 2)
        self.assertEqual(source['unknownTimeEvents'], 1)
        self.assertEqual(source['readStatus'], 'partial')
        self.assertEqual(source['adapters']['history']['status'], 'partial')

    def test_not_null_seconds_keep_indexed_archive_candidates_without_date_fallback(self):
        self.state.execute('drop table threads')
        self.state.execute('create table threads(id text primary key, rollout_path text, cwd text, created_at integer not null, updated_at integer not null, created_at_ms integer, updated_at_ms integer, archived integer, cli_version text, source text)')
        for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
            self.state.execute(f'create index idx_threads_{column} on threads({column},id)')
        self.rollout(messages=[self.event('archived exact after NOT NULL gate')])
        self.item('SQL after NOT NULL gate')
        files = [self.home / 'state_5.sqlite', self.home / 'thread_history_1.sqlite']
        before = [(p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'success')
        self.assertEqual(source['coverage']['strategy'], 'state-history-exact-no-cache')
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']},
                         {'archived exact after NOT NULL gate', 'SQL after NOT NULL gate'})
        self.assertEqual(before, [(p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()) for p in files])

    def test_covering_date_indexes_keep_sql_and_archived_exact_evidence(self):
        fields = ('id', 'rollout_path', 'cwd', 'created_at', 'updated_at', 'created_at_ms', 'updated_at_ms', 'cli_version', 'source')
        for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
            self.state.execute(f'drop index idx_threads_{column}')
            covering = ','.join((column, *(field for field in fields if field != column)))
            self.state.execute(f'create index idx_threads_{column} on threads({covering})')
        self.rollout(messages=[self.event('archived through covering index')])
        self.item('SQL through covering index')
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'success')
        self.assertEqual(source['coverage']['strategy'], 'state-history-exact-no-cache')
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']},
                         {'archived through covering index', 'SQL through covering index'})

    def test_not_null_milliseconds_do_not_require_unreachable_seconds_indexes(self):
        self.rollout(messages=[self.event('authoritative ms archived exact')])
        self.item('authoritative ms SQL')
        self.state.execute('alter table threads rename to previous_threads')
        self.state.execute('create table threads(id text primary key, rollout_path text, cwd text, created_at integer, updated_at integer, created_at_ms integer not null, updated_at_ms integer not null, archived integer, cli_version text, source text)')
        self.state.execute('insert into threads select id,rollout_path,cwd,null,null,created_at*1000,updated_at*1000,archived,cli_version,source from previous_threads')
        self.state.execute('drop table previous_threads')
        for column in ('created_at_ms', 'updated_at_ms'):
            self.state.execute(f'create index idx_threads_{column} on threads({column},id)')
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'success')
        self.assertEqual(source['coverage']['strategy'], 'state-history-exact-no-cache')
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']},
                         {'authoritative ms archived exact', 'authoritative ms SQL'})

    def test_unsafe_date_index_scan_reports_safe_branch_plan_and_keeps_bounded_fallback(self):
        text = 'synthetic private work must not enter plan diagnostics'
        path = self.rollout(messages=[self.event(text)])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        self.state.execute('drop index idx_threads_created_at_ms')
        self.state.execute('create index "private index name" on threads(created_at_ms collate nocase,id)')
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        state = source['adapters']['state']
        self.assertEqual(state['status'], 'compatibility-error')
        self.assertEqual(state['reason'], 'date-query-not-indexed')
        self.assertEqual(source['sqliteResources']['rows'], 0)
        self.assertEqual(state['queryPlan']['rejection'], 'unsafe-query-plan')
        self.assertEqual(state['queryPlan']['branch'],
                         {'field': 'created_at_ms', 'condition': 'below-known-unit', 'guard': '1'})
        self.assertEqual(state['queryPlan']['plan'], ['SCAN threads'])
        diagnostics = json.dumps([state, source['compatibilityIssues']], ensure_ascii=False)
        for private in ('private index name', text, str(self.home), str(self.repo)):
            self.assertNotIn(private, diagnostics)
        self.assertEqual(source['coverage']['strategy'], 'date-partitions-no-cache')
        self.assertEqual([e['title'] for e in data['repos'][0]['sessionEvidence']], [text])

    def test_lineage_mismatch_interop_and_missing_sql_items_are_explicit(self):
        path = self.rollout(messages=[self.event('中間需求'), {'timestamp': '2026-05-29T04:00:00Z', 'type': 'response_item', 'payload': {'type': 'interop_message', 'message': '協作代理必要修正', '_meta': {'source': 'child'}}}])
        content = path.read_text(encoding='utf-8').replace('"id": "old"', '"id": "reused"')
        path.write_text(content, encoding='utf-8')
        self.item('SQL非空結果')
        data = self.collect()
        source = data['meta']['sources']['codex']
        exact = source['adapters']['exact']['sessions'][0]
        self.assertFalse(exact['lineageMatch'])
        self.assertTrue(exact['interopDetected'])
        self.assertEqual(exact['reason'], 'lineage-mismatch')
        self.assertEqual(source['readStatus'], 'partial')
        evidence = data['repos'][0]['sessionEvidence']
        self.assertEqual({e['sessionId'] for e in evidence}, {'old', 'reused'})
        self.assertTrue(any('協作代理必要修正' in e['text'] for e in evidence))

    def test_lineage_mismatch_never_inherits_metadata_repo_or_parent(self):
        path = self.rollout(parent='wrong-parent', messages=[self.event('不可錯歸舊 repo')])
        records = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        records[0]['payload'] = {'id': 'different-session'}
        path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
        self.item('SQL仍屬原始thread')
        data = self.collect()
        evidence = data['repos'][0]['sessionEvidence']
        self.assertEqual([e['text'] for e in evidence], ['SQL仍屬原始thread'])
        self.assertFalse(evidence[0]['lineageVerified'])

    def test_row_payload_caps_report_remaining_scope_and_keep_exact_evidence(self):
        self.rollout(messages=[self.event('補證仍保留')])
        self.item('SQL小筆')
        self.item('z' * 8000, iid='big')
        for args, hit in [(('-CodexSqlRows', '1'), 'rows'), (('-CodexSqlPayloadBytes', '1024'), 'payloadBytes')]:
            with self.subTest(hit=hit):
                data = self.collect(*args)
                source = data['meta']['sources']['codex']
                self.assertIn(hit, source['sqliteResources']['limitHits'])
                self.assertTrue(source['sqliteResources']['unread'])
                self.assertTrue(any(e['text'] == '補證仍保留' for e in data['repos'][0]['sessionEvidence']))
                self.assertLessEqual(source['sqliteResources']['payloadBytes'], source['sqliteResources']['limits']['payloadBytes'])

    def test_sql_and_jsonl_mirrors_merge_provenance_not_distinct_turns(self):
        self.rollout(messages=[
            {'type': 'turn_context', 'payload': {'id': 'turn-a'}},
            self.event('同一修正結果', role='assistant'),
            {'timestamp': '2026-05-29T02:00:00Z', 'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': '同一修正結果'}]}},
            {'type': 'turn_context', 'payload': {'id': 'turn-b'}},
            self.event('同一修正結果', role='assistant'),
        ])
        self.item('同一修正結果')
        data = self.collect()
        evidence = data['repos'][0]['sessionEvidence']
        self.assertEqual(len(evidence), 2)
        self.assertEqual({e['turnId'] for e in evidence}, {'turn-a', 'turn-b'})
        merged = next(e for e in evidence if e['turnId'] == 'turn-a')
        self.assertEqual({p['adapter'] for p in merged['provenance']}, {'history', 'exact-jsonl'})
        self.assertEqual(len(merged['provenance']), 3)

    def test_exact_large_line_recovers_full_output_and_caps_expose_unread_offset(self):
        path = self.rollout(messages=[self.event('關鍵輸出:' + 'v' * 70000)])
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertTrue(data['repos'][0]['sessionEvidence'][0]['text'].endswith('v' * 70000))
        self.assertEqual(source['coverage']['limits']['lineBytes'], 65536)
        self.assertEqual(source['coverage']['exactFallback']['recoveredOversizedLines'], 1)
        self.assertEqual(source['coverage']['readBytes'], path.stat().st_size)
        for args in [('-CodexExactLineBytes', '65536'), ('-CodexFileBytes', '1024'), ('-CodexTotalBytes', '1024')]:
            data = self.collect(*args)
            source = data['meta']['sources']['codex']
            self.assertTrue(source['coverage']['exactFallback']['unread'])
            self.assertFalse(source['coverage']['complete'])
            self.assertLessEqual(source['coverage']['readBytes'], source['coverage']['limits']['totalBytes'])

    def test_byte_cap_empty_is_no_activity_but_never_hides_damage_or_unknown(self):
        path = self.rollout(messages=[self.event('bounded but unread')])
        data = self.collect('-CodexTotalBytes', '1')
        source = data['meta']['sources']['codex']
        self.assertEqual(source['readStatus'], 'empty')
        self.assertEqual(data['meta']['collectionStatus'], 'no-activity')
        self.assertEqual(data['repos'], [])
        self.assertEqual(source['coverage']['readBytes'], 1)
        self.assertIn('totalBytes', source['coverage']['limitHits'])
        self.assertTrue(source['coverage']['exactFallback']['unread'])
        for damage in ('malformed', 'unknown', 'compatibility', 'unsafe'):
            with self.subTest(damage=damage):
                self.history.execute('delete from thread_items')
                self.history.commit()
                self.state.execute('update threads set cli_version=?,rollout_path=?', ('9.9.9' if damage == 'compatibility' else '0.164.0-alpha.11.1', str(self.root / 'escape.jsonl') if damage == 'unsafe' else str(path)))
                self.state.commit()
                if damage in ('malformed', 'unknown'):
                    self.item('not dated evidence', time=17 if damage == 'unknown' else 1780020000000)
                    if damage == 'malformed':
                        self.history.execute("update thread_items set item_json='not-json'")
                        self.history.commit()
                data = self.collect('-CodexTotalBytes', '1')
                self.assertEqual(data['meta']['sources']['codex']['readStatus'], 'failed')
                self.assertEqual(data['meta']['collectionStatus'], 'read-failed')

    def test_oversized_exact_line_discards_bounded_bytes_then_keeps_later_evidence(self):
        path = self.rollout(messages=[self.event('前段需求'), self.event('z' * 200000), self.event('後段修正')])
        data = self.collect('-CodexExactLineBytes', '65536')
        source = data['meta']['sources']['codex']
        self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']}, {'前段需求', '後段修正'})
        self.assertEqual(source['coverage']['readBytes'], path.stat().st_size)
        self.assertEqual(source['coverage']['oversizedLines'], 1)
        self.assertGreater(source['coverage']['oversizedDiscardBytes'], 200000)
        self.assertEqual(source['readStatus'], 'partial')
        self.assertIn('exactLineBytes', source['coverage']['limitHits'])

    def test_missing_history_byte_cap_is_empty_but_keeps_gap_and_observed_damage(self):
        path = self.rollout(messages=[self.event('bounded unread exact fallback')])
        meta_line = path.read_text(encoding='utf-8').splitlines()[0]
        self.history.close()
        history_path = self.home / 'thread_history_1.sqlite'
        history_path.unlink()
        data = self.collect('-CodexTotalBytes', '1')
        source = data['meta']['sources']['codex']
        self.assertEqual(source['readStatus'], 'empty')
        self.assertEqual(data['meta']['collectionStatus'], 'no-activity')
        self.assertEqual(data['repos'], [])
        self.assertEqual(source['adapters']['history']['status'], 'missing')
        self.assertFalse(source['coverage']['complete'])
        self.assertEqual(source['coverage']['readBytes'], 1)
        self.assertIn('totalBytes', source['coverage']['limitHits'])
        self.assertTrue(source['coverage']['exactFallback']['unread'])
        for damage in ('malformed', 'unknown'):
            with self.subTest(damage=damage):
                event = 'not-json' if damage == 'malformed' else json.dumps(self.event('undated', time=17))
                path.write_text(meta_line + '\n' + event + '\n' + 'x' * 10000, encoding='utf-8')
                data = self.collect('-CodexTotalBytes', '512')
                source = data['meta']['sources']['codex']
                self.assertIn('totalBytes', source['coverage']['limitHits'])
                self.assertEqual(source['readStatus'], 'failed')
                self.assertEqual(data['meta']['collectionStatus'], 'read-failed')
        # A schema failure must not be reclassified as a supported absent history database.
        db = sqlite3.connect(history_path)
        try:
            db.execute('create table thread_items(incompatible text)')
            db.commit()
        finally:
            db.close()
        data = self.collect('-CodexTotalBytes', '1')
        self.assertEqual(data['meta']['sources']['codex']['adapters']['history']['status'], 'compatibility-error')
        self.assertEqual(data['meta']['collectionStatus'], 'read-failed')

    def test_missing_history_lossless_exact_eof_without_range_activity_is_empty(self):
        path = self.rollout()
        meta = path.read_text(encoding='utf-8')
        self.history.close()
        (self.home / 'thread_history_1.sqlite').unlink()
        for records in ([], [self.event('outside range', time='2026-05-28T15:59:59Z')]):
            for ending in ('', '\n'):
                with self.subTest(records=len(records), ending=repr(ending)):
                    path.write_text('\n'.join([meta] + [json.dumps(r) for r in records]) + ending, encoding='utf-8')
                    data = self.collect()
                    source = data['meta']['sources']['codex']
                    self.assertEqual(source['readStatus'], 'empty')
                    self.assertEqual(data['meta']['collectionStatus'], 'no-activity')
                    self.assertFalse(data['meta']['canGenerateLog'])
                    self.assertEqual(data['repos'], [])
                    self.assertEqual(source['adapters']['history']['status'], 'missing')
                    self.assertEqual(source['adapters']['history']['reason'], 'database-not-found')
                    self.assertTrue(source['adapters']['exact']['sessions'][0]['projectionComplete'])
                    self.assertEqual(source['coverage']['limitHits'], [])
                    self.assertFalse(source['coverage']['complete'])

    def test_missing_history_exact_eof_never_hides_damage(self):
        path = self.rollout()
        meta = path.read_text(encoding='utf-8')
        self.history.close()
        (self.home / 'thread_history_1.sqlite').unlink()
        for damage in ('malformed', 'unknown', 'lineage', 'compatibility', 'missing-exact'):
            with self.subTest(damage=damage):
                self.state.execute('update threads set cli_version=?', ('9.9.9' if damage == 'compatibility' else '0.164.0-alpha.11.1',))
                self.state.commit()
                content = meta.replace('"id": "old"', '"id": "wrong"') if damage == 'lineage' else meta
                if damage == 'malformed':
                    content += '\nnot-json'
                elif damage == 'unknown':
                    content += '\n' + json.dumps(self.event('undated', time=17))
                path.write_text(content, encoding='utf-8')
                if damage == 'missing-exact':
                    path.unlink()
                data = self.collect()
                self.assertEqual(data['meta']['sources']['codex']['readStatus'], 'failed')
                self.assertEqual(data['meta']['collectionStatus'], 'read-failed')
                self.assertEqual(data['repos'], [])

    def test_missing_history_valid_empty_and_compatibility_draft_consent_gate(self):
        self.rollout(messages=[self.event('exact有證據')])
        self.history.close()
        history_path = self.home / 'thread_history_1.sqlite'
        history_path.unlink()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['history']['status'], 'missing')
        self.assertNotIn('compatibilityIssues', source)
        self.state.execute("update threads set cli_version='9.9-private-token-https://internal.example/C:/private'")
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['history']['status'], 'compatibility-error')
        draft = source['compatibilityIssues'][0]
        self.assertTrue(draft['requiresExplicitConsent'])
        self.assertFalse(draft['published'])
        self.assertEqual(draft['destination'], 'https://github.com/openai/codex/issues')
        self.assertNotIn('internal.example', draft['body'])
        self.assertNotIn(str(self.home), draft['body'])
        self.assertNotIn('exact有證據', draft['body'])
        self.state.execute('delete from threads')
        self.state.commit()
        data = self.collect()
        self.assertEqual(data['meta']['sources']['codex']['adapters']['state']['status'], 'valid-empty')
        self.assertEqual(data['meta']['collectionStatus'], 'no-activity')

    def test_unknown_sql_item_contract_is_not_reported_as_successful_tool(self):
        self.rollout(messages=[self.event('可用exact材料')])
        self.item('unverified-shape', type='futurePrivateType')
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['history']['status'], 'compatibility-error')
        self.assertEqual([e['text'] for e in data['repos'][0]['sessionEvidence']], ['可用exact材料'])
        self.assertEqual(source['readStatus'], 'partial')
        self.assertIn('unknown-history-item-type', source['compatibilityIssues'][0]['body'])
        self.assertNotIn('futurePrivateType', source['compatibilityIssues'][0]['body'])

    def test_probe_does_not_open_locked_database_or_run_python(self):
        self.rollout()
        self.state.execute('begin exclusive')
        data = self.collect('-ProbeOnly')
        source = data['meta']['sources']['codex']
        self.assertTrue(source['available'])
        self.assertNotIn('adapters', source)
        self.assertEqual(source['probeWork']['readBytes'], 0)
        self.assertEqual(data['repos'], [])
        self.state.rollback()

    def test_schema_gap_falls_back_to_date_partition_without_private_issue_fields(self):
        path = self.rollout(archived=False, messages=[self.event('日期補證')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        self.state.execute('alter table threads rename column rollout_path to unexpected_private_column')
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'compatibility-error')
        self.assertEqual(source['coverage']['strategy'], 'date-partitions-no-cache')
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['title'], '日期補證')
        self.assertNotIn('unexpected_private_column', source['compatibilityIssues'][0]['body'])

    def test_empty_state_still_reads_bounded_dated_jsonl_without_compatibility_draft(self):
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        records = [{'type': 'session_meta', 'payload': {'id': 'unindexed', 'cwd': str(self.repo)}}, self.event('空DB日期補證')]
        dated.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'valid-empty')
        self.assertNotIn('compatibilityIssues', source)
        self.assertEqual(source['coverage']['strategy'], 'date-partitions-no-cache')
        self.assertEqual(source['coverage']['readBytes'], dated.stat().st_size)
        self.assertEqual(source['readStatus'], 'success')
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['title'], '空DB日期補證')
        self.assertLessEqual(source['coverage']['daysConsidered'], 32)
        self.assertLessEqual(source['coverage']['readBytes'], source['coverage']['limits']['totalBytes'])
        dated.write_text('', encoding='utf-8')
        empty = self.collect()
        self.assertEqual(empty['meta']['sources']['codex']['adapters']['state']['status'], 'valid-empty')
        self.assertEqual(empty['meta']['sources']['codex']['readStatus'], 'empty')
        self.assertNotIn('compatibilityIssues', empty['meta']['sources']['codex'])
        self.assertEqual(empty['meta']['collectionStatus'], 'no-activity')
        self.assertEqual(empty['repos'], [])

    def test_no_python_keeps_legacy_jsonl_available_without_cli(self):
        path = self.rollout(messages=[self.event('無Python仍可讀')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        # Keep a discoverable Python, as on Linux where pwsh/python share /usr/bin.
        self.assertIsNotNone(shutil.which('python', path=self.env['PATH']))
        data = self.collect(unavailable_commands=('python', 'codex', 'opencode', 'gh'))
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'runtime-unavailable')
        self.assertEqual(source['readStatus'], 'success')
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['title'], '無Python仍可讀')

    @unittest.skipUnless(os.name == 'nt', 'Windows executable launch failure fixture')
    def test_adapter_process_failure_stops_without_fresh_legacy_budget(self):
        path = self.rollout(messages=[self.event('子程序失敗不可另開預算')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'python.exe').write_bytes(b'fixture-invalid-executable')
        self.env['PATH'] = str(bin_dir) + os.pathsep + self.env['PATH']
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['readStatus'], 'failed')
        self.assertEqual(source['coverage']['strategy'], 'adapter-stopped')
        self.assertFalse(source['coverage']['accountingKnown'])
        self.assertEqual(data['meta']['collectionStatus'], 'read-failed')
        self.assertEqual(data['repos'], [])

    def test_outside_history_does_not_change_selected_payload_or_write_databases(self):
        path = self.rollout(messages=[self.event('唯一當日材料')])
        self.item('當日SQL')
        first = self.collect()
        self.state.executemany('insert into threads values(?,?,?,?,?,?,?,?,?,?)', [(f'outside-{i}', '/outside/private.jsonl', str(self.repo), 1577836800, 1577836801, None, None, 0, 'unknown', 'cli') for i in range(3000)])
        self.history.executemany('insert into thread_items values(?,?,?,?,?,?,?,?,?,?)', [('outside', 'turn', str(i), i, 1577836800000, 'not JSON outside selection', 'unknown', i, None, None) for i in range(3000)])
        self.state.commit()
        self.history.commit()
        files = [self.home / 'state_5.sqlite', self.home / 'thread_history_1.sqlite', path]
        before = [(p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
        second = self.collect()
        after = [(p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
        self.assertEqual(before, after)
        self.assertEqual(first['repos'], second['repos'])
        self.assertEqual(first['meta']['sources']['codex']['sqliteResources']['rows'], second['meta']['sources']['codex']['sqliteResources']['rows'])
        self.assertEqual(first['meta']['sources']['codex']['coverage']['readBytes'], second['meta']['sources']['codex']['coverage']['readBytes'])

    def test_indexed_metadata_work_does_not_grow_with_outside_history(self):
        spec = importlib.util.spec_from_file_location('codex_adapter', SCRIPTS / 'collect-codex-evidence.py')
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        original_connect = sqlite3.connect
        counts = []

        class CountConnection(sqlite3.Connection):
            def set_progress_handler(self, callback, n):
                def counted():
                    counts[-1] += 1
                    return callback()
                super().set_progress_handler(counted, 1)

        self.rollout(messages=[self.event('indexed archived lifespan')])
        # Both seconds fallback and authoritative milliseconds include the exact boundary.
        self.rollout(sid='ms', messages=[self.event('milliseconds boundary')])
        self.state.execute("update threads set created_at_ms=1779984000000,updated_at_ms=1779984000000 where id='ms'")
        self.state.commit()
        request = dict(root=str(self.home), **{'from': '2026-05-29T00:00:00+08:00', 'to': '2026-05-29T23:59:59+08:00'}, rows=10000, payloadBytes=16777216, deadlineSeconds=15, totalBytes=67108864, fileBytes=8388608, exactLineBytes=1048576)
        for outside in (0, 3000):
            if outside:
                self.state.executemany('insert into threads values(?,?,?,?,?,?,?,?,?,?)', [(f'outside-{i}', '/not-read.jsonl', str(self.repo), 1577836800, 1577836801, None, None, 0, adapter.SUPPORTED, 'cli') for i in range(outside)])
                self.state.commit()
            counts.append(0)
            with patch.object(adapter.sqlite3, 'connect', lambda *a, **kw: original_connect(*a, **kw, factory=CountConnection)):
                result = adapter.Collector(request).run()
            self.assertEqual({e['text'] for e in result['evidence']}, {'indexed archived lifespan', 'milliseconds boundary'})
        self.assertLess(counts[1] - counts[0], 5000, f'SQLite VM work grew with outside history: {counts}')

    def test_no_date_index_declares_gap_and_uses_only_bounded_date_fallback(self):
        path = self.rollout(messages=[self.event('safe date fallback')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
            self.state.execute(f'drop index idx_threads_{column}')
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'compatibility-error')
        self.assertEqual(source['adapters']['state']['reason'], 'date-index-required')
        self.assertEqual(source['adapters']['state']['missingRequiredIndexes'], ['threads(created_at_ms, ...)'])
        self.assertEqual(source['adapters']['state']['queryPlan']['rejection'], 'missing-leading-column-index')
        self.assertEqual(source['adapters']['state']['queryPlan']['branch'], {'field': 'created_at_ms'})
        self.assertEqual(source['sqliteResources']['rows'], 0)
        self.assertEqual(source['coverage']['strategy'], 'date-partitions-no-cache')
        self.assertTrue(source['compatibilityIssues'])
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['title'], 'safe date fallback')

    def test_history_without_thread_index_never_scans_unrelated_items_and_keeps_exact(self):
        spec = importlib.util.spec_from_file_location('codex_history_gate', SCRIPTS / 'collect-codex-evidence.py')
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        original_connect = sqlite3.connect
        counts, results = [], []

        class CountConnection(sqlite3.Connection):
            def set_progress_handler(self, callback, n):
                def counted():
                    counts[-1] += 1
                    return callback()
                super().set_progress_handler(counted, 1)

        path = self.rollout(messages=[self.event('bounded exact survives rejected history')])
        self.item('SQL must not execute without a safe thread plan')
        self.history.execute('drop index idx_items_thread')
        self.history.commit()
        request = dict(root=str(self.home), **{'from': '2026-05-29T00:00:00+08:00', 'to': '2026-05-29T23:59:59+08:00'}, rows=10000, payloadBytes=16777216, deadlineSeconds=15, totalBytes=67108864, fileBytes=8388608, exactLineBytes=1048576)
        for outside in (0, 3000):
            if outside:
                self.history.executemany('insert into thread_items values(?,?,?,?,?,?,?,?,?,?)', [('outside', 't', str(i), i, 1577836800000, 'unselected malformed JSON', 'unknown', i, None, None) for i in range(outside)])
                self.history.commit()
            counts.append(0)
            with patch.object(adapter.sqlite3, 'connect', lambda *a, **kw: original_connect(*a, **kw, factory=CountConnection)):
                results.append(adapter.Collector(request).run())
        self.assertLess(counts[1] - counts[0], 2000, f'Unindexed history scanned unrelated items: {counts}')
        for result in results:
            self.assertEqual(result['adapters']['history']['status'], 'compatibility-error')
            self.assertEqual(result['adapters']['history'].get('returnedItems', 0), 0)
            self.assertIn('index', result['compatibilityIssues'][0]['body'])
            self.assertIn('thread_id', result['compatibilityIssues'][0]['body'])
            self.assertEqual([e['text'] for e in result['evidence']], ['bounded exact survives rejected history'])
            self.assertEqual({p['adapter'] for e in result['evidence'] for p in e['provenance']}, {'exact-jsonl'})
            self.assertEqual(result['coverage']['readBytes'], path.stat().st_size)
            self.assertEqual(result['readStatus'], 'partial')
            self.assertFalse(result['fallback'])

    def test_indexed_query_deadline_stops_without_fresh_fallback_budget(self):
        spec = importlib.util.spec_from_file_location('codex_adapter_deadline', SCRIPTS / 'collect-codex-evidence.py')
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        self.rollout(messages=[self.event('deadline unread')])
        request = dict(root=str(self.home), **{'from': '2026-05-29T00:00:00+08:00', 'to': '2026-05-29T23:59:59+08:00'}, rows=10000, payloadBytes=16777216, deadlineSeconds=15, totalBytes=67108864, fileBytes=8388608, exactLineBytes=1048576)
        # Own the time input: deadline expires before query work, not after an idle sleep.
        with patch.object(adapter.time, 'monotonic', side_effect=[0] + [20] * 1000):
            result = adapter.Collector(request).run()
        self.assertFalse(result['fallback'])
        self.assertEqual(result['adapters']['state']['status'], 'limited')
        self.assertIn('deadline', result['sqliteResources']['limitHits'])
        self.assertTrue(result['sqliteResources']['unread'])
        self.assertEqual(result['coverage']['readBytes'], 0)
        self.assertEqual(result['evidence'], [])

    def test_history_gate_accepts_independent_thread_index_and_primary_key(self):
        self.rollout(messages=[self.event('exact counterpart')])
        self.item('target SQL evidence')
        self.history.executemany('insert into thread_items values(?,?,?,?,?,?,?,?,?,?)', [('outside', 't', str(i), i, 1577836800000, 'unselected malformed JSON', 'unknown', i, None, None) for i in range(3000)])
        self.history.execute('drop index idx_items_thread')
        self.history.execute('create index "independent projection lookup" on thread_items(thread_id)')
        self.history.commit()
        for shape in ('independent-name', 'primary-key'):
            with self.subTest(shape=shape):
                if shape == 'primary-key':
                    self.history.execute('alter table thread_items rename to previous_items')
                    self.history.execute('create table thread_items(thread_id text, turn_id text, item_id text, rollout_ordinal integer, created_at_ms integer, item_json text, item_type text, updated_at_ordinal integer, started_at_ms integer, completed_at_ms integer, primary key(thread_id,turn_id,item_id)) without rowid')
                    self.history.execute('insert into thread_items select * from previous_items')
                    self.history.execute('drop table previous_items')
                    self.history.commit()
                data = self.collect()
                source = data['meta']['sources']['codex']
                self.assertEqual(source['adapters']['history']['status'], 'success')
                self.assertEqual(source['adapters']['history']['returnedItems'], 1)
                self.assertEqual({e['text'] for e in data['repos'][0]['sessionEvidence']}, {'target SQL evidence', 'exact counterpart'})
                sql = next(e for e in data['repos'][0]['sessionEvidence'] if e['text'] == 'target SQL evidence')
                self.assertEqual({p['adapter'] for p in sql['provenance']}, {'history'})

    def test_exact_path_escape_is_rejected_without_reading_other_transcripts(self):
        path = self.rollout(messages=[self.event('不得讀取root外原文')])
        outside = self.root / 'outside.jsonl'
        shutil.copyfile(path, outside)
        self.state.execute('update threads set rollout_path=?', (str(outside),))
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['coverage']['openedFiles'], 0)
        self.assertEqual(source['coverage']['readBytes'], 0)
        self.assertEqual(source['adapters']['exact']['sessions'][0]['reason'], 'unsafe-rollout-path')
        self.assertEqual(data['repos'], [])

    @unittest.skipUnless(os.name == 'nt', 'Windows junction fixture')
    def test_exact_junction_ancestor_is_rejected_before_transcript_open(self):
        path = self.rollout(messages=[self.event('不得透過junction讀原文')])
        target = self.root / 'junction-target'
        target.mkdir()
        shutil.copyfile(path, target / 'rollout.jsonl')
        junction = self.home / 'linked'
        process = subprocess.run([os.environ.get('COMSPEC', 'cmd.exe'), '/c', 'mklink', '/J', str(junction), str(target)], capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.addCleanup(junction.rmdir)
        self.state.execute('update threads set rollout_path=?', (str(junction / 'rollout.jsonl'),))
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['coverage']['openedFiles'], 0)
        self.assertEqual(source['coverage']['readBytes'], 0)
        self.assertEqual(source['adapters']['exact']['sessions'][0]['reason'], 'reparse-rollout-path')
        self.assertEqual(data['repos'], [])

    def test_unindexed_view_is_rejected_before_expensive_query_and_uses_safe_fallback(self):
        path = self.rollout(messages=[self.event('安全日期補證')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        self.state.execute('alter table threads rename to fixture_threads')
        self.state.execute('create view threads as with recursive n(x) as (values(1) union all select x+1 from n where x<1000000000) select id||x as id,rollout_path,cwd,created_at,updated_at,created_at_ms,updated_at_ms,archived,cli_version,source from fixture_threads,n')
        self.state.commit()
        data = self.collect()
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'compatibility-error')
        self.assertEqual(source['sqliteResources']['rows'], 0)
        self.assertEqual(source['coverage']['strategy'], 'date-partitions-no-cache')
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['title'], '安全日期補證')

    def test_metadata_payload_limit_stops_without_starting_fresh_legacy_budget(self):
        path = self.rollout(messages=[self.event('不得在耗額後另開日期補讀')])
        dated = self.home / 'sessions/2026/05/29/dated.jsonl'
        dated.parent.mkdir(parents=True)
        shutil.copyfile(path, dated)
        self.state.execute('update threads set source=?', ('x' * 2000000,))
        self.state.commit()
        data = self.collect('-CodexSqlPayloadBytes', '1024')
        source = data['meta']['sources']['codex']
        self.assertEqual(source['adapters']['state']['status'], 'limited')
        self.assertEqual(source['coverage']['strategy'], 'state-history-exact-no-cache')
        self.assertEqual(source['coverage']['readBytes'], 0)
        self.assertEqual(data['repos'], [])
        self.assertLessEqual(source['sqliteResources']['payloadBytes'], 1024)
        self.assertTrue(source['sqliteResources']['unread'])

    @unittest.skipUnless(os.name == 'nt', 'Windows sharing denial fixture')
    def test_permission_is_not_empty_or_compatibility(self):
        import ctypes
        from ctypes import wintypes
        path = self.rollout(messages=[self.event('permission補證')])
        self.history.close()
        api = ctypes.WinDLL('kernel32', use_last_error=True)
        api.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
        api.CreateFileW.restype = wintypes.HANDLE
        handle = api.CreateFileW(str(self.home / 'thread_history_1.sqlite'), 0x80000000, 0, None, 3, 0, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        try:
            data = self.collect()
            source = data['meta']['sources']['codex']
            self.assertEqual(source['adapters']['history']['status'], 'permission')
            self.assertNotIn('compatibilityIssues', source)
            self.assertTrue(data['repos'])
            capped = self.collect('-CodexTotalBytes', '1')
            self.assertEqual(capped['meta']['sources']['codex']['adapters']['history']['status'], 'permission')
            self.assertEqual(capped['meta']['sources']['codex']['readStatus'], 'failed')
            self.assertEqual(capped['meta']['collectionStatus'], 'read-failed')
            path.write_text(path.read_text(encoding='utf-8').splitlines()[0], encoding='utf-8')
            empty_exact = self.collect()
            source = empty_exact['meta']['sources']['codex']
            self.assertTrue(source['adapters']['exact']['sessions'][0]['projectionComplete'])
            self.assertEqual(source['adapters']['history']['status'], 'permission')
            self.assertEqual(source['readStatus'], 'failed')
            self.assertEqual(empty_exact['meta']['collectionStatus'], 'read-failed')
        finally:
            api.CloseHandle.argtypes = (wintypes.HANDLE,)
            api.CloseHandle(handle)


if __name__ == '__main__':
    unittest.main()
