"""Issue #57: public collector CLI, synthetic files and real child-process seams."""
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import unittest


COLLECTOR = Path(__file__).resolve().parents[1] / 'scripts' / 'collect-daily-work-log.ps1'
ARTIFACTS = Path(os.environ.get('TEMP', tempfile.gettempdir())) / 'opencode'
PWSH = shutil.which('pwsh')


@unittest.skipUnless(PWSH, 'PowerShell 7 is required for collector CLI integration')
class CollectorEfficiency(unittest.TestCase):
    def setUp(self):
        ARTIFACTS.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='collector-57-', dir=ARTIFACTS)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('bin', 'repo-a', 'repo-b', 'aggregate', 'empty'):
            (self.root / name).mkdir()
        self.env = os.environ.copy()
        self.env.update(DWL57_ROOT=str(self.root), PATH=os.pathsep.join(
            [str(self.root / 'bin'), str(Path(PWSH).parent), str(Path(shutil.which('python')).parent)]))
        self.codex_root = self.root / 'missing-codex'
        self.fixture = dict(rows=[self.row('s1', 'repo-a')], commits=[self.commit()], prs=[], exact={}, associated=[])
        self.write('bin/opencode.ps1', r'''
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$f = Get-Content "$env:DWL57_ROOT/fixture.json" -Raw | ConvertFrom-Json
if ($f.PSObject.Properties['flood']) {
  [Console]::Out.Write(' ' * 262144)
  [Console]::Error.Write('synthetic-error-' + ('e' * 262144))
}
if ($f.PSObject.Properties['dbFail']) { [Console]::Error.Write('synthetic-db-error'); exit 7 }
if ($f.PSObject.Properties['dbMalformed']) { '{invalid'; exit 0 }
if ($Arguments[-1] -match 'join session') { '[]' } else { ConvertTo-Json -InputObject @($f.rows) -Depth 20 -Compress }
exit 0
''')
        self.write('bin/git.ps1', r'''
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$f = Get-Content "$env:DWL57_ROOT/fixture.json" -Raw | ConvertFrom-Json
$repo = $PWD.Path -in @('repo-a','repo-b','aggregate/repo-a' | ForEach-Object { [IO.Path]::GetFullPath("$env:DWL57_ROOT/$_") })
switch ($Arguments[0]) {
 'rev-parse' { if (-not $repo) { exit 1 }; if ($Arguments[-1] -eq '--show-toplevel') { $PWD.Path } else { 'true' } }
 'config' { if ($Arguments[-1] -eq 'user.name') { 'synthetic-user' } else { 'synthetic@example.invalid' } }
 'remote' { 'https://github.com/synthetic/project.git' }
 'log' { foreach ($c in $f.commits) { @($c.hash,$c.hash.Substring(0,7),'2026-10-08T10:00:00+08:00',$c.author,'synthetic@example.invalid',$c.subject,$c.refs,'__DWL_END__') -join [char]31; [Console]::Out.Write([char]30) } }
 default { exit 3 }
}
exit 0
''')
        self.write('bin/gh.ps1', r'''
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::AppendAllText("$env:DWL57_ROOT/gh.jsonl", (ConvertTo-Json -InputObject @($Arguments) -Compress) + "`n")
$f = Get-Content "$env:DWL57_ROOT/fixture.json" -Raw | ConvertFrom-Json
if ($Arguments[0] -eq 'api' -and $Arguments[1] -eq 'user') { '{"login":"synthetic-user","name":"Synthetic"}'; exit 0 }
if ($Arguments[0] -eq 'api' -and $Arguments[1] -match '/commits/[^/]+/pulls$') { ConvertTo-Json -InputObject @($f.associated) -Compress; exit 0 }
if ($Arguments[1] -eq 'list') {
 if ($f.PSObject.Properties['listFail']) { [Console]::Error.Write('synthetic-list-error'); exit 8 }
 ConvertTo-Json -InputObject @($f.prs) -Depth 20 -Compress; exit 0
}
if ($Arguments[1] -eq 'view') {
 $n = $Arguments[2]; $p = @($f.prs | Where-Object number -eq $n)
 if ($f.exact.PSObject.Properties[$n]) { $p = @($f.exact.$n) }
 if (-not $p.Count) { [Console]::Error.Write('synthetic-not-found'); exit 9 }
 if ($p[0].PSObject.Properties['fail']) { [Console]::Error.Write('synthetic-details-error'); exit 9 }
 if ($p[0].PSObject.Properties['invalid']) { '{invalid'; exit 0 }
 $p[0] | ConvertTo-Json -Depth 20 -Compress; exit 0
}
exit 4
''')
        self.write('bin/rg.ps1', r'''
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::AppendAllText("$env:DWL57_ROOT/rg.jsonl", (ConvertTo-Json -InputObject @($Arguments) -Compress) + "`n")
[Console]::Error.Write('synthetic-rg-failure'); exit 2
''')

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def row(self, sid, path, title='synthetic session'):
        return dict(id=sid, directory=str(self.root / path), path=None, title=title,
                    time_created=1791424800000, time_updated=1791424800000)

    @staticmethod
    def commit(subject='synthetic work', refs='HEAD -> feature/one', hash='a' * 40, author='synthetic-user'):
        return dict(subject=subject, refs=refs, hash=hash, author=author)

    @staticmethod
    def pr(number, branch='unrelated', oid='0' * 40, updated='2026-10-08T04:00:00Z'):
        return dict(number=number, title='synthetic PR', url=f'https://github.com/synthetic/project/pull/{number}',
                    updatedAt=updated, mergedAt='2026-10-09T04:00:00Z', closedAt=None, state='MERGED',
                    isDraft=False, headRefName=branch, baseRefName='main', closingIssuesReferences=[dict(number=99)],
                    author=dict(login='synthetic-user'), commits=[dict(oid=oid)])

    def collect(self, *extra, expect_error=False):
        self.write('fixture.json', json.dumps(self.fixture))
        for file in ('gh.jsonl', 'rg.jsonl'):
            (self.root / file).unlink(missing_ok=True)
        # Only the runner has a deadline; collection itself has no new timeout contract.
        command = [PWSH, '-NoProfile', '-File', str(COLLECTOR),
                                 '-From', '2026-10-08T00:00:00+08:00', '-To', '2026-10-08T23:59:59.999+08:00',
                                 '-OpenCodeLogRoot', str(self.root / 'missing-log'),
                                 '-OpenCodeStorageRoot', str(self.root / 'missing-storage'),
                                 '-CodexRoot', str(self.codex_root), *extra]
        with subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, encoding='utf-8', start_new_session=(os.name != 'nt')) as child:
            try:
                stdout, stderr = child.communicate(timeout=int(os.environ.get('DWL57_TEST_DEADLINE', '180')))
            except subprocess.TimeoutExpired:
                if os.name == 'nt':
                    taskkill = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'taskkill.exe'
                    try:
                        subprocess.run([str(taskkill), '/PID', str(child.pid), '/T', '/F'],
                                       capture_output=True, timeout=5, check=False)
                    except (OSError, subprocess.TimeoutExpired):
                        child.kill()
                else:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                stdout, stderr = child.communicate()
                self.fail(f'collector stdout/stderr completion deadline expired; stdout={stdout!r}; stderr={stderr!r}')
        result = subprocess.CompletedProcess(command, child.returncode, stdout, stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(bool(data['errors']), expect_error)
        if os.environ.get('DWL57_EVIDENCE_ROOT'):
            evidence = Path(os.environ['DWL57_EVIDENCE_ROOT'])
            evidence.mkdir(parents=True, exist_ok=True)
            summary = dict(test=self.id(), command='python -B -m unittest discover -s skills/daily-work-log/tests -p test_collector_efficiency.py -v',
                           diagnostics=data['meta']['diagnostics'], collectionStatus=data['meta'].get('collectionStatus'),
                           prs=[[p['number'] for p in r['prs']] for r in data['repos']],
                           ghCalls=self.calls(), rgCalls=len(self.calls('rg')), exitCode=result.returncode)
            (evidence / (self.id().split('.')[-1] + '.json')).write_text(json.dumps(summary, indent=2), encoding='utf-8')
        return data

    def calls(self, name='gh'):
        path = self.root / f'{name}.jsonl'
        return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()] if path.exists() else []

    def test_cheap_matches_keep_fallback_and_errors(self):
        self.fixture['rows'].append(self.row('s2', 'repo-b'))
        self.fixture['commits'] = [self.commit('synthetic work (#1)')]
        self.fixture['prs'] = [self.pr(1), self.pr(2, branch='feature/one'), self.pr(3, oid='a' * 40),
                               self.pr(4), dict(self.pr(5), fail=True)]
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [1, 2, 3])
        views = [int(c[2]) for c in self.calls() if c[:2] == ['pr', 'view']]
        self.assertEqual(views, [3, 4, 5], 'explicit number/branch must avoid details; unresolved still probes hashes')
        self.assertTrue(any('gh pr view failed' in w for w in data['repos'][0]['warnings']))
        self.assertEqual([p['number'] for p in data['repos'][1]['prs']], [1, 2, 3])
        self.assertEqual(len([c for c in self.calls() if c[:2] == ['api', 'user']]), 1)
        self.assertEqual(len([c for c in self.calls() if c[:2] == ['pr', 'list']]), 1)
        self.assertEqual(data['meta']['diagnostics']['stages']['github']['cacheHits'], 4)
        self.assertEqual(data['meta']['diagnostics']['stages']['github']['calls'], 9)

    def test_session_only_without_explicit_pr_only_queries_viewer(self):
        self.fixture['commits'] = []
        self.fixture['prs'] = [self.pr(90)]
        data = self.collect()
        self.assertEqual(data['repos'][0]['commits'], [])
        self.assertEqual(data['repos'][0]['prs'], [])
        self.assertEqual(self.calls(), [['api', 'user']],
                         'session-only without explicit PR evidence must not query list, details or associations')

    def test_later_state_and_exact_session_only(self):
        self.fixture['commits'] = []
        self.fixture['rows'][0]['title'] = 'Review https://github.com/synthetic/project/pull/17; issue #88'
        self.fixture['prs'] = [self.pr(90, updated='2026-10-09T04:00:00Z')]
        self.fixture['exact'] = {'17': self.pr(17, updated='2026-10-09T04:00:00Z')}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [17])
        self.assertEqual(data['meta']['from'], '2026-10-08T00:00:00.0000000+08:00')
        self.assertEqual(data['repos'][0]['prs'][0]['updatedAt'], '2026-10-09T04:00:00Z')
        self.assertEqual(data['repos'][0]['prs'][0]['reportEvidence'], 'session-reference')
        self.assertIn('stateObservedAt', data['repos'][0]['prs'][0])
        self.assertEqual([c[:3] for c in self.calls()], [['api', 'user'], ['pr', 'view', '17']],
                         'explicit session reference must use exact lookup without a recent PR list')
        self.assertFalse(any('/commits/' in c[1] for c in self.calls() if c[0] == 'api'))

    def test_exact_commit_lookup_covers_missing_updated_pr(self):
        self.fixture['associated'] = [dict(number=23)]
        self.fixture['exact'] = {'23': self.pr(23, oid='a' * 40, updated='2026-10-09T04:00:00Z')}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [23])
        exact = [c for c in self.calls() if c[0] == 'api' and '/commits/' in c[1]]
        self.assertEqual(len(exact), 1)
        self.assertIn('a' * 40, exact[0][1])
        self.assertNotIn('--paginate', exact[0])

    def test_codex_full_event_reference_is_not_lost_to_title_preview(self):
        self.fixture.update(rows=[], commits=[], exact={'17': self.pr(17, updated='2026-10-09T04:00:00Z')})
        self.codex_root = self.root / 'codex'
        rollout = self.codex_root / 'sessions/2026/10/08/one.jsonl'
        text = ('synthetic background ' * 20) + 'https://github.com/synthetic/project/pull/17'
        self.write('codex/sessions/2026/10/08/one.jsonl', '\n'.join(json.dumps(event) for event in [
            dict(type='session_meta', payload=dict(id='codex-reference', cwd=str(self.root / 'repo-a'))),
            dict(type='event_msg', timestamp='2026-10-08T03:00:00Z',
                 payload=dict(type='user_message', message=text))]))
        with closing(sqlite3.connect(self.codex_root / 'state_5.sqlite')) as db:
            db.execute('create table threads(id text primary key, rollout_path text, cwd text, created_at integer, updated_at integer, created_at_ms integer, updated_at_ms integer, archived integer, cli_version text, source text)')
            for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
                db.execute(f'create index idx_threads_{column} on threads({column},id)')
            db.execute('insert into threads values(?,?,?,?,?,?,?,?,?,?)',
                       ('codex-reference', str(rollout), str(self.root / 'repo-a'), 1791424800,
                        1791424800, None, None, 0, '0.164.0-alpha.11.1', 'cli'))
            db.commit()
        data = self.collect()
        self.assertEqual(data['repos'][0]['sessionEvidence'][0]['text'], text)
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [17])
        self.assertEqual([c[2] for c in self.calls() if c[:2] == ['pr', 'view']], ['17'])

    def test_expansion_reuse_retains_sessions_and_empty_warning(self):
        (self.root / 'aggregate/repo-a/.git').mkdir(parents=True)
        self.fixture['rows'] = [self.row('s1', 'aggregate'), self.row('s2', 'aggregate/.'),
                                self.row('s3', 'empty'), self.row('s4', 'empty/.')]
        self.codex_root = self.root / 'codex'
        self.write('codex/sessions/2026/10/08/one.jsonl', '\n'.join(json.dumps(event) for event in [
            dict(type='session_meta', timestamp='2026-10-08T03:00:00Z',
                 payload=dict(id='codex-synthetic', cwd=str(self.root / 'aggregate'))),
            dict(type='event_msg', timestamp='2026-10-08T03:00:00Z',
                 payload=dict(type='user_message', message='synthetic work'))]))
        data = self.collect()
        self.assertEqual([e['sessionId'] for e in data['repos'][0]['sessionEvidence']], ['s1', 's2', 'codex-synthetic'])
        self.assertEqual(data['repos'][0]['source'], ['codex', 'session-expanded'])
        self.assertEqual(len(self.calls('rg')), 2, 'exact normalized aggregate, including empty results, expands once')
        self.assertEqual(data['meta']['sources']['opencode']['discovery']['expansion']['candidates'], 4)
        self.assertEqual(data['meta']['sources']['opencode']['discovery']['expansion']['notResolvedCandidates'], 2)
        self.assertEqual(sum('rg git marker discovery failed' in w for w in data['warnings']), 2)
        self.assertGreaterEqual(data['meta']['diagnostics']['stages']['repoDiscovery']['cacheHits'], 3)

    def test_late_explicit_commit_and_list_failure_preserve_evidence(self):
        self.fixture['listFail'] = True
        self.fixture['commits'] = [self.commit('synthetic (#28)')]
        self.fixture['exact'] = {'28': self.pr(28, updated='2026-10-09T04:00:00Z')}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [28])
        self.assertEqual(data['repos'][0]['prs'][0]['reportEvidence'], 'commit-reference')
        self.assertTrue(any('gh pr list failed' in w for w in data['repos'][0]['warnings']))

    def test_session_reference_requires_time_and_exact_repository(self):
        self.fixture['commits'] = []
        self.fixture['rows'] = [self.row('good', 'repo-a', 'PR #17, issue #88'),
                                self.row('foreign', 'repo-a', 'https://github.com/foreign/project/pull/18'),
                                self.row('spanning', 'repo-a', 'PR #19')]
        self.fixture['rows'][2].update(time_created=1791302400000, time_updated=1791561600000)
        self.fixture['exact'] = {str(n): self.pr(n) for n in (17, 18, 19, 88)}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [17])
        self.assertEqual([c[2] for c in self.calls() if c[:2] == ['pr', 'view']], ['17'])

    def test_exact_lookup_parse_and_exit_errors_remain_warnings(self):
        self.fixture['commits'] = []
        self.fixture['rows'][0]['title'] = 'PR #7, PR #8, PR #9'
        self.fixture['exact'] = {'7': self.pr(7), '8': dict(self.pr(8), invalid=True), '9': dict(self.pr(9), fail=True)}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [7])
        self.assertTrue(any('not valid JSON' in w for w in data['repos'][0]['warnings']))
        self.assertTrue(any('gh pr view failed' in w for w in data['repos'][0]['warnings']))

    def test_exact_session_lookup_is_bounded_and_reports_coverage(self):
        self.fixture['commits'] = []
        self.fixture['rows'][0]['title'] = ', '.join(f'PR #{n}' for n in range(1, 106))
        self.fixture['exact'] = {str(n): self.pr(n) for n in range(1, 106)}
        data = self.collect()
        self.assertEqual([p['number'] for p in data['repos'][0]['prs']], list(range(1, 101)))
        self.assertEqual(len([c for c in self.calls() if c[:2] == ['pr', 'view']]), 100)
        self.assertFalse(any('--paginate' in c for c in self.calls()))
        self.assertTrue(any('100-PR limit' in w for w in data['repos'][0]['warnings']))

    def test_exact_hash_lookup_is_bounded_and_reports_coverage(self):
        self.fixture['commits'] = [self.commit(hash=f'{n:040x}') for n in range(1, 106)]
        data = self.collect()
        exact = [c for c in self.calls() if c[0] == 'api' and '/commits/' in c[1]]
        self.assertEqual(len(exact), 100)
        self.assertTrue(all('per_page=100' in c and '--paginate' not in c for c in exact))
        self.assertTrue(any('100-commit limit' in w for w in data['repos'][0]['warnings']))
        self.assertEqual(data['repos'][0]['prs'], [])

    def test_probe_unavailable_and_top_level_error_diagnostics(self):
        (self.root / 'bin/opencode.ps1').unlink()
        data = self.collect('-ProbeOnly')
        self.assertTrue(data['meta']['probeOnly'])
        self.assertIsNone(data['meta']['diagnostics']['stages']['json']['calls'])
        data = self.collect()
        self.assertEqual(data['meta']['collectionStatus'], 'no-sources')
        self.assertIsNone(data['meta']['diagnostics']['stages']['git']['calls'])
        self.codex_root = 'SyntheticMissingDrive:\\records'
        data = self.collect(expect_error=True)
        self.assertEqual(data['meta']['collectionStatus'], 'error')
        self.assertEqual(data['meta']['diagnostics']['stages']['sourceAdapter']['calls'], 1)
        self.assertGreaterEqual(data['meta']['diagnostics']['stages']['sourceAdapter']['durationMs'], 0)
        self.assertIsNone(data['meta']['diagnostics']['stages']['json']['calls'])
        self.assertEqual(data['meta']['diagnostics']['stages']['output']['calls'], 1)

    def test_diagnostics_early_and_failure_are_known_not_fabricated(self):
        self.fixture['rows'] = []
        data = self.collect()
        diag = data['meta']['diagnostics']
        self.assertEqual(diag['schemaVersion'], 1)
        self.assertEqual(set(diag['stages']), {'sourceAdapter', 'json', 'repoDiscovery', 'git', 'github', 'output'})
        for stage in ('git', 'github', 'repoDiscovery'):
            self.assertIsNone(diag['stages'][stage]['durationMs'])
            self.assertIsNone(diag['stages'][stage]['calls'])
        for stage in ('sourceAdapter', 'json', 'output'):
            self.assertGreaterEqual(diag['stages'][stage]['durationMs'], 0)
            self.assertGreater(diag['stages'][stage]['calls'], 0)
        self.assertGreaterEqual(diag['totalDurationMs'], 0)
        self.assertNotIn(str(self.root), json.dumps(diag))
        self.fixture['dbFail'] = True
        failure = self.collect()
        self.assertEqual(failure['meta']['collectionStatus'], 'read-failed')
        self.assertGreater(failure['meta']['diagnostics']['stages']['sourceAdapter']['calls'], 0)
        self.assertIsNone(failure['meta']['diagnostics']['stages']['github']['calls'])

    def test_native_dual_stream_preserves_json_and_nonzero_error(self):
        self.fixture['flood'] = True
        data = self.collect()
        self.assertEqual(data['repos'][0]['commits'][0]['hash'], 'a' * 40)
        self.fixture['dbFail'] = True
        failure = self.collect()
        self.assertEqual(failure['meta']['collectionStatus'], 'read-failed')
        self.assertTrue(any('DB session discovery failed' in w for w in failure['warnings']))


if __name__ == '__main__':
    unittest.main()
