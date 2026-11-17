"""#67: public capture/collector/formatter, synthetic external GitHub responses only."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
PWSH = shutil.which('pwsh')


@unittest.skipUnless(PWSH, 'PowerShell 7 required')
class SourceModes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sources67-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.responses = [dict(path='user', parameters={}, response={'login': 'owner'})]
        self.config = dict(From='2026-11-16T00:00:00+08:00', To='2026-11-17T00:00:00+08:00',
                           GitHubInputPath=str(self.root / 'provider.json'), Repositories=['acme/app'],
                           CodexRoot=str(self.root / 'forbidden-session'),
                           OpenCodeLogRoot=str(self.root / 'forbidden-session'),
                           OpenCodeStorageRoot=str(self.root / 'forbidden-session'))
        # Malformed-input coverage is separate from the observed access boundary below.
        (self.root / 'forbidden-session').mkdir()
        (self.root / 'forbidden-session' / 'history.jsonl').write_text('not-json', encoding='utf-8')

    def response(self, path, data, **parameters):
        self.responses.append(dict(path=path, parameters=parameters, response=data))

    def search(self, kind, items, total=None, page=1, incomplete=False):
        query = f'repo:acme/app is:{kind} ' + (
            'is:merged merged:2026-11-15..2026-11-17' if kind == 'pr' else
            'author:owner created:2026-11-15..2026-11-17')
        self.response('search/issues', dict(items=items, total_count=len(items) if total is None else total,
                                          incomplete_results=incomplete), q=query, per_page=100, page=page)

    def pr(self, n=7, user='owner', merged='2026-11-16T00:00:00Z', body='Closes #3'):
        return dict(number=n, title='完成匯入', body=body, user={'login': user},
                    html_url=f'https://github.com/acme/app/pull/{n}', state='closed', merged_at=merged,
                    created_at='2026-11-10T00:00:00Z', updated_at='2026-11-17T02:00:00Z',
                    closed_at=merged, draft=False, head={'ref': 'feature/import'}, base={'ref': 'main'})

    def issue(self, n=3, user='owner', created='2026-11-15T00:00:00Z', body='需求：匯入；驗收：完成對帳'):
        return dict(number=n, title='匯入規格', body=body, user={'login': user},
                    html_url=f'https://github.com/acme/app/issues/{n}', state='open',
                    created_at=created, updated_at='2026-11-17T00:00:00Z', closed_at=None)

    def candidate(self, n, kind='pull'):
        return dict(number=n, html_url=f'https://github.com/acme/app/{kind}/{n}')

    def run_cli(self, config=None, view=None):
        (self.root / 'provider.json').write_text(json.dumps({'responses': self.responses}), encoding='utf-8')
        settings = dict(self.config, **(config or {}))
        (self.root / 'parameters.json').write_text(json.dumps(settings), encoding='utf-8')
        probe = self.root / 'probe.json'
        raw = self.root / 'raw.json'
        env = dict(getattr(self, 'env', os.environ), PYTHONDONTWRITEBYTECODE='1')
        def run(*args):
            p = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'capture-daily-work-log.ps1'),
                                *args], capture_output=True, text=True, encoding='utf-8', env=env, timeout=90)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout, '', 'capture must keep private raw off stdout')
        run('-Mode', 'probe', '-ParametersPath', str(self.root / 'parameters.json'), '-OutputPath', str(probe))
        run('-Mode', 'collect', '-ParametersPath', str(self.root / 'parameters.json'),
            '-ProbePath', str(probe), '-OutputPath', str(raw))
        data = json.loads(raw.read_text(encoding='utf-8'))
        if view:
            parameters = dict(InputPath=str(raw), View=view, GithubRepo='acme/app')
            (self.root / 'view.json').write_text(json.dumps(parameters), encoding='utf-8')
            run('-Mode', 'format', '-ParametersPath', str(self.root / 'view.json'),
                '-OutputPath', str(self.root / 'view-output.json'))
            return data, json.loads((self.root / 'view-output.json').read_text(encoding='utf-8'))
        return data

    def test_default_github_merged_pr_reaches_full_erp_without_session(self):
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr())
        self.response('repos/acme/app/issues/3', self.issue())
        data, erp = self.run_cli(view='erp')
        self.assertEqual(data['errors'], [])
        self.assertEqual(data['meta']['evidenceSource'], 'github')
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['meta']['sources']['codex']['readStatus'], 'not-selected')
        self.assertEqual(data['meta']['sources']['opencode']['readStatus'], 'not-selected')
        self.assertEqual([p['number'] for p in erp['repos'][0]['prs']], [7])
        self.assertEqual(erp['repos'][0]['prs'][0]['body'], 'Closes #3')
        self.assertEqual(erp['repos'][0]['prs'][0]['headRefName'], 'feature/import')
        self.assertEqual(erp['repos'][0]['issues'][0]['number'], 3)
        self.assertEqual(erp['repos'][0]['sessionEvidence'], [])

    def test_default_refuses_and_records_session_access_with_same_positive_observer(self):
        import test_collector_efficiency as legacy
        helper = legacy.CollectorEfficiency()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        helper.write('fixture.json', json.dumps(helper.fixture))
        opencode = helper.root / 'bin/opencode.ps1'
        original = opencode.read_text(encoding='utf-8')
        boundary = r'''
[IO.File]::AppendAllText($env:DWL67_ACCESS_LOG, "opencode-query`n")
if ($env:DWL67_ALLOW_SESSION -ne '1') { throw 'unexpected-session-access' }
'''
        opencode.write_text(original.replace('$f = Get-Content', boundary + '\n$f = Get-Content', 1), encoding='utf-8')
        codex = helper.root / 'codex'
        rollout = codex / 'sessions/2026/10/08/one.jsonl'
        helper.write(str(rollout.relative_to(helper.root)), '\n'.join(json.dumps(e) for e in [
            dict(type='session_meta', payload=dict(id='observed-codex', cwd=str(helper.root / 'repo-a'))),
            dict(type='event_msg', timestamp='2026-10-08T03:00:00Z',
                 payload=dict(type='user_message', message='完成可觀測的 Session 工作'))]))
        with sqlite3.connect(codex / 'state_5.sqlite') as db:
            db.execute('create table threads(id text primary key, rollout_path text, cwd text, created_at integer, updated_at integer, created_at_ms integer, updated_at_ms integer, archived integer, cli_version text, source text)')
            for column in ('created_at', 'updated_at', 'created_at_ms', 'updated_at_ms'):
                db.execute(f'create index idx_threads_{column} on threads({column},id)')
            db.execute('insert into threads values(?,?,?,?,?,?,?,?,?,?)',
                       ('observed-codex', str(rollout), str(helper.root / 'repo-a'), 1791424800,
                        1791424800, None, None, 0, '0.164.0-alpha.11.1', 'cli'))
        # CPython's process-wide audit hook observes real file/SQLite reads in the
        # actual adapter process; no collector function or result is substituted.
        audit = helper.root / 'audit'
        audit.mkdir()
        (audit / 'sitecustomize.py').write_text('''import os, sys
from urllib.parse import urlsplit
from urllib.request import url2pathname
root = os.path.normcase(os.path.abspath(os.environ['DWL67_CODEX_ROOT']))
def observe(event, args):
    if event not in ('open', 'os.listdir', 'os.scandir', 'sqlite3.connect') or not args or not isinstance(args[0], (str, bytes)):
        return
    path = os.fsdecode(args[0])
    if path.startswith('file:'):
        path = url2pathname(urlsplit(path).path)
    path = os.path.normcase(os.path.abspath(path))
    if path == root or path.startswith(root + os.sep):
        with open(os.environ['DWL67_ACCESS_LOG'], 'a', encoding='utf-8') as log:
            log.write('codex-' + event + '\\n')
        if os.environ.get('DWL67_ALLOW_SESSION') != '1':
            raise PermissionError('unexpected-session-access')
sys.addaudithook(observe)
''', encoding='utf-8')
        access_log = helper.root / 'session-access.log'
        self.env = dict(helper.env, PYTHONPATH=str(audit), DWL67_ACCESS_LOG=str(access_log),
                        DWL67_CODEX_ROOT=str(codex), DWL67_ALLOW_SESSION='0')
        self.config.update(From='2026-10-08T00:00:00+08:00', To='2026-10-09T00:00:00+08:00',
                           CodexRoot=str(codex), OpenCodeLogRoot=str(helper.root / 'missing-log'),
                           OpenCodeStorageRoot=str(helper.root / 'missing-storage'), Repositories=[])
        for kind, query in [('pr', 'is:pr author:owner is:merged merged:2026-10-07..2026-10-09'),
                            ('issue', 'is:issue author:owner created:2026-10-07..2026-10-09')]:
            self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                          q=query, per_page=100, page=1)
        for fail in (False, True):
            with self.subTest(provider_failure=fail):
                if fail:
                    self.responses[0]['status'] = 401
                data = self.run_cli()
                self.assertEqual(data['meta']['evidenceSource'], 'github')
                self.assertFalse(access_log.exists(), 'default must not attempt Session access, even if errors are swallowed')
        self.env['DWL67_ALLOW_SESSION'] = '1'
        positive = self.run_cli(config={'EvidenceSource': 'session'})
        observed = access_log.read_text(encoding='utf-8').splitlines()
        self.assertIn('opencode-query', observed)
        self.assertIn('codex-sqlite3.connect', observed)
        self.assertIn('codex-open', observed)
        evidence = [e for r in positive['repos'] for e in r['sessionEvidence']]
        self.assertEqual({e['sessionId'] for e in evidence}, {'s1', 'observed-codex'})

    def test_midnight_author_and_current_state_do_not_backdate_work(self):
        self.search('pr', [self.candidate(n) for n in (7, 8, 9, 10)])
        self.search('issue', [self.candidate(3, 'issues'), self.candidate(4, 'issues')])
        self.response('repos/acme/app/pulls/7', self.pr(merged='2026-11-15T16:00:00Z'))
        self.response('repos/acme/app/pulls/8', self.pr(8, merged='2026-11-16T16:00:00Z'))
        self.response('repos/acme/app/pulls/9', self.pr(9, user='other', body='Unrelated work'))
        self.response('repos/acme/app/pulls/10', self.pr(10, merged=None))
        self.response('repos/acme/app/issues/3', self.issue())
        self.response('repos/acme/app/issues/4', self.issue(4, created='2026-11-16T03:00:00Z'))
        data, erp = self.run_cli(view='erp')
        self.assertEqual([p['number'] for p in erp['repos'][0]['prs']], [7])
        issues = {i['number']: i for i in erp['repos'][0]['issues']}
        self.assertEqual(sorted(issues), [3, 4])
        self.assertEqual(issues[4]['reportEvent'], 'specification-created')
        self.assertEqual(issues[3]['reportEvent'], 'related-context')
        self.assertEqual(issues[3]['state'], 'OPEN')
        self.assertEqual(erp['repos'][0]['prs'][0]['issuesClosed'], [])
        self.assertEqual(data['meta']['collectionStatus'], 'success')

    def test_pagination_proxy_identity_and_full_raw_pointers(self):
        self.search('pr', [self.candidate(8)], total=2)
        self.search('pr', [self.candidate(7)], total=2, page=2)
        self.search('issue', [])
        self.response('repos/acme/app/pulls/8', self.pr(8, user='other', body='Unrelated work'))
        self.response('repos/acme/app/pulls/7', self.pr(user='agent[bot]'))
        self.response('repos/acme/app/issues/3', self.issue())
        data, erp = self.run_cli(config={'ProxyLogins': ['agent[bot]']}, view='erp')
        self.assertEqual([p['number'] for p in erp['repos'][0]['prs']], [7])
        self.assertEqual(erp['repos'][0]['prs'][0]['attribution'], dict(
            kind='confirmed-agent-and-request', login='owner', agent='agent[bot]',
            evidenceUrls=['https://github.com/acme/app/issues/3']))
        self.assertEqual(data['meta']['sources']['github']['coverage']['pages'], 3)
        self.assertEqual(data['meta']['sources']['github']['requests'][2]['parameters']['page'], 2)
        raw = self.root / 'raw.json'
        p = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'format-daily-work-log-evidence.ps1'),
                            '-InputPath', str(raw), '-View', 'raw', '-JsonPointer', '/repos/0/prs/0/attribution'],
                           capture_output=True, text=True, encoding='utf-8', timeout=90)
        self.assertEqual(json.loads(p.stdout)['value'], erp['repos'][0]['prs'][0]['attribution'])

    def test_unknown_agent_does_not_gain_authorship_from_issue_link(self):
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(user='unconfirmed'))
        self.response('repos/acme/app/issues/3', self.issue())
        data = self.run_cli()
        self.assertFalse(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['prs'], [])
        self.assertEqual(data['repos'][0]['pendingAttribution'][0]['number'], 7)

    def test_issue_only_keeps_content_for_agent_without_requiring_template_words(self):
        self.search('pr', [])
        self.search('issue', [self.candidate(4, 'issues')])
        self.response('repos/acme/app/issues/4', self.issue(4, created='2026-11-16T03:00:00Z',
            body='## 行為\n上傳 CSV 後列出錯誤行，正常資料可匯入；空檔顯示原因。'))
        data, erp = self.run_cli(view='erp')
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual([i['number'] for i in erp['repos'][0]['issues']], [4])
        self.assertEqual(erp['repos'][0]['issues'][0]['reportEvent'], 'specification-created')

    def test_proxy_dispatch_comment_is_preserved_as_requester_evidence(self):
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(user='agent[bot]'))
        self.response('repos/acme/app/issues/3', dict(self.issue(user='other'), comments=1))
        self.response('repos/acme/app/issues/3/comments', [dict(user={'login': 'owner'},
                      body='/afk implement this issue', html_url='https://github.com/acme/app/issues/3#issuecomment-9')],
                      per_page=100, page=1)
        data = self.run_cli(config={'ProxyLogins': ['agent[bot]']})
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['prs'][0]['attribution']['evidenceUrls'],
                         ['https://github.com/acme/app/issues/3#issuecomment-9'])

    def test_negative_comment_does_not_become_proxy_dispatch(self):
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(user='agent[bot]'))
        self.response('repos/acme/app/issues/3', dict(self.issue(user='other'), comments=1))
        self.response('repos/acme/app/issues/3/comments', [dict(user={'login': 'owner'},
                      body='Do not implement this task.', html_url='https://github.com/acme/app/issues/3#issuecomment-9')],
                      per_page=100, page=1)
        data = self.run_cli(config={'ProxyLogins': ['agent[bot]']})
        self.assertFalse(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['prs'], [])
        self.assertEqual(data['repos'][0]['pendingAttribution'][0]['number'], 7)

    def test_same_number_in_remote_repos_stays_separate_and_scope_failure_is_partial(self):
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(body='完成匯入'))
        self.response('search/issues', dict(items=[dict(number=7, html_url='https://github.com/acme/tools/pull/7')],
                                           total_count=1, incomplete_results=False),
                      q='repo:acme/tools is:pr is:merged merged:2026-11-15..2026-11-17', per_page=100, page=1)
        self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                      q='repo:acme/tools is:issue author:owner created:2026-11-15..2026-11-17', per_page=100, page=1)
        self.response('repos/acme/tools/pulls/7', dict(self.pr(body='完成工具'),
                      html_url='https://github.com/acme/tools/pull/7'))
        data = self.run_cli(config={'Repositories': ['acme/app', 'acme/tools']})
        self.assertEqual([(r['githubRepo'], [p['number'] for p in r['prs']]) for r in data['repos']],
                         [('acme/app', [7]), ('acme/tools', [7])])
        self.assertEqual(data['repos'][1]['path'], None)
        self.responses[-1]['status'] = 403
        partial = self.run_cli(config={'Repositories': ['acme/app', 'acme/tools']})
        self.assertEqual(partial['meta']['collectionStatus'], 'partial')
        self.assertTrue(partial['meta']['canGenerateLog'])
        self.assertEqual(partial['repos'][0]['prs'][0]['number'], 7)

    def test_source_change_between_probe_and_collect_is_rejected(self):
        self.search('pr', [])
        self.search('issue', [])
        self.run_cli()
        parameters = self.root / 'parameters.json'
        parameters.write_text(json.dumps(dict(self.config, EvidenceSource='session')), encoding='utf-8')
        p = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'capture-daily-work-log.ps1'),
                            '-Mode', 'collect', '-ParametersPath', str(parameters),
                            '-ProbePath', str(self.root / 'probe.json'), '-OutputPath', str(self.root / 'switched.json')],
                           capture_output=True, text=True, encoding='utf-8', timeout=90)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('source differs from the probe', p.stderr)
        self.assertFalse((self.root / 'switched.json').exists())

    def test_capture_refuses_to_overwrite_provider_or_manual_inputs(self):
        provider = self.root / 'provider.json'
        manual = self.root / 'manual.json'
        provider.write_text(json.dumps({'responses': self.responses}), encoding='utf-8')
        manual.write_text(json.dumps([dict(date='2026-11-16', result='手動內容')]), encoding='utf-8')
        parameters = self.root / 'parameters.json'
        parameters.write_text(json.dumps(dict(self.config, ManualInputPath=str(manual))), encoding='utf-8')
        for target in (provider, manual):
            with self.subTest(target=target.name):
                before = target.read_bytes()
                p = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPTS / 'capture-daily-work-log.ps1'),
                                    '-Mode', 'probe', '-ParametersPath', str(parameters), '-OutputPath', str(target)],
                                   capture_output=True, text=True, encoding='utf-8', timeout=90)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(target.read_bytes(), before)

    def test_no_explicit_scope_discovers_viewer_activity_without_fixed_repo_list(self):
        self.response('search/issues', dict(items=[self.candidate(7)], total_count=1, incomplete_results=False),
                      q='is:pr author:owner is:merged merged:2026-11-15..2026-11-17', per_page=100, page=1)
        self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                      q='is:issue author:owner created:2026-11-15..2026-11-17', per_page=100, page=1)
        self.response('repos/acme/app/pulls/7', self.pr(body='完成工作'))
        data = self.run_cli(config={'Repositories': [], 'ScanRoots': [str(self.root)]})
        self.assertEqual(data['meta']['collectionStatus'], 'success')
        self.assertEqual(data['repos'][0]['githubRepo'], 'acme/app')
        self.assertEqual(data['meta']['repositoryScope']['requested'], [])

    def test_worktree_marker_remote_is_identified_without_git_history(self):
        git = shutil.which('git')
        if not git:
            self.skipTest('Git required for worktree marker fixture')
        repo, checkout = self.root / 'repository', self.root / 'worktree'
        repo.mkdir(); checkout.mkdir()
        subprocess.run([git, 'init', '-q', str(repo)], check=True, capture_output=True, timeout=30)
        subprocess.run([git, '-C', str(repo), 'remote', 'add', 'origin', 'https://github.com/acme/app.git'],
                       check=True, capture_output=True, timeout=30)
        # Git's public gitdir-file form: exercises real remote resolution, without needing a commit.
        (checkout / '.git').write_text('gitdir: ' + (repo / '.git').as_posix(), encoding='utf-8')
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(body='完成工作'))
        data = self.run_cli(config={'ScanRoots': [str(checkout)]})
        self.assertEqual([Path(p) for p in data['repos'][0]['localPaths']], [checkout])
        self.assertTrue(data['repos'][0]['isGitRepo'])
        self.assertEqual(data['repos'][0]['commits'], [])

    def test_manual_only_survives_empty_automatic_results_and_keeps_provenance(self):
        self.search('pr', [])
        self.search('issue', [])
        content = '原型驗證\n' + '完整工作內容' * 4000
        manual = [dict(date='2026-11-16', project='維運', result=content, todos=['取得正式環境驗收'])]
        path = self.root / 'manual.json'
        path.write_text(json.dumps(manual), encoding='utf-8')
        data = self.run_cli(config={'ManualInputPath': str(path)})
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['manualEvidence'][0]['result'], content)
        self.assertFalse(data['repos'][0]['manualEvidence'][0]['verifiedByGitHub'])
        self.assertEqual(data['repos'][0]['githubRepo'], None)

    def test_source_capture_keeps_utf8_under_non_utf8_python_io_override(self):
        self.search('pr', [])
        self.search('issue', [])
        manual = self.root / '中文🧪.json'
        manual.write_text(json.dumps([dict(date='2026-11-16', result='完整核對🧪')], ensure_ascii=False), encoding='utf-8')
        self.env = dict(os.environ, PYTHONUTF8='0', PYTHONIOENCODING='cp950:strict')
        data = self.run_cli(config={'ManualInputPath': str(manual)})
        self.assertEqual(data['errors'], [])
        self.assertEqual(data['repos'][0]['manualEvidence'][0]['result'], '完整核對🧪')

    def test_empty_and_failure_do_not_enable_sessions_or_invent_work(self):
        self.search('pr', [])
        self.search('issue', [])
        empty = self.run_cli()
        self.assertEqual(empty['meta']['collectionStatus'], 'no-activity')
        self.assertFalse(empty['meta']['canGenerateLog'])
        self.responses[1]['status'] = 403
        failed = self.run_cli()
        self.assertEqual(failed['meta']['collectionStatus'], 'read-failed')
        self.assertFalse(failed['meta']['sources']['github']['coverage']['complete'])
        self.assertEqual(failed['meta']['sources']['codex']['readStatus'], 'not-selected')

    def test_partial_search_retains_valid_work_without_claiming_complete(self):
        self.search('pr', [self.candidate(7)], total=1001, incomplete=True)
        self.search('pr', [], total=1001, page=2)
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(body='完成工作'))
        data = self.run_cli()
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['meta']['collectionStatus'], 'partial')
        self.assertEqual(data['meta']['sources']['github']['coverage']['limitHits'], ['search-result-limit'])

    def test_explicit_session_and_combined_keep_real_session_reader(self):
        import test_collector_efficiency as legacy
        helper = legacy.CollectorEfficiency()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        helper.fixture['rows'] = [helper.row('s1', 'repo-a'), helper.row('s2', 'repo-b', '另一個 worktree 工作')]
        shared_pr = helper.pr(7, branch='feature/one', oid='a' * 40)
        shared_pr.update(url='https://github.com/acme/app/pull/7', author={'login': 'owner'},
                         mergedAt='2026-10-08T03:00:00Z', closedAt='2026-10-08T03:00:00Z')
        helper.fixture['prs'] = [shared_pr]
        helper.write('fixture.json', json.dumps(helper.fixture))
        # Only external git/gh/OpenCode processes are substituted, as in the established suite.
        script = helper.root / 'bin/git.ps1'
        script.write_text(script.read_text(encoding='utf-8').replace('synthetic/project', 'acme/app'), encoding='utf-8')
        gh = helper.root / 'bin/gh.ps1'
        gh.write_text(gh.read_text(encoding='utf-8').replace('"login":"synthetic-user"', '"login":"owner"'), encoding='utf-8')
        self.env = helper.env
        self.config.update(From='2026-10-08T00:00:00+08:00', To='2026-10-09T00:00:00+08:00',
                           CodexRoot=str(helper.codex_root), OpenCodeLogRoot=str(helper.root / 'missing-log'),
                           OpenCodeStorageRoot=str(helper.root / 'missing-storage'))
        self.responses = [dict(path='user', parameters={}, response={'login': 'owner'})]
        for kind, query in [('pr', 'repo:acme/app is:pr is:merged merged:2026-10-07..2026-10-09'),
                            ('issue', 'repo:acme/app is:issue author:owner created:2026-10-07..2026-10-09')]:
            self.response('search/issues', dict(items=[self.candidate(7)] if kind == 'pr' else [],
                                                total_count=1 if kind == 'pr' else 0, incomplete_results=False),
                          q=query, per_page=100, page=1)
        self.response('repos/acme/app/pulls/7', self.pr(merged='2026-10-08T03:00:00Z', body='完成匯入'))
        combined = self.run_cli(config={'EvidenceSource': 'combined'})
        self.assertTrue(combined['meta']['canGenerateLog'])
        self.assertEqual(combined['meta']['collectionStatus'], 'success')
        self.assertEqual(len(combined['repos']), 1)
        self.assertEqual([p['number'] for p in combined['repos'][0]['prs']], [7])
        self.assertEqual(combined['repos'][0]['prs'][0]['number'], 7)
        self.assertEqual(combined['repos'][0]['prs'][0]['body'], '完成匯入')
        self.assertIn('commit-match', combined['repos'][0]['prs'][0]['reportEvidence'])
        self.assertEqual(combined['repos'][0]['sessionEvidence'][0]['sessionId'], 's1')
        self.assertEqual([e['sessionId'] for e in combined['repos'][0]['sessionEvidence']], ['s1', 's2'])
        self.assertEqual(combined['meta']['sources']['opencode']['readStatus'], 'success')
        # Presence observed through exactly the same public capture is the companion to default's absence.
        session = self.run_cli(config={'EvidenceSource': 'session'})
        self.assertEqual(session['meta']['evidenceSource'], 'session')
        self.assertEqual(session['repos'][0]['sessionEvidence'][0]['sessionId'], 's1')
        # Same public scope applies to Session, rather than only GitHub candidates.
        remote = "'remote' { 'https://github.com/acme/app.git' }"
        script.write_text(script.read_text(encoding='utf-8').replace(remote,
            "'remote' { if ($PWD.Path -eq ([IO.Path]::GetFullPath(\"$env:DWL57_ROOT/repo-b\"))) { 'https://github.com/acme/tools.git' } else { 'https://github.com/acme/app.git' } }"), encoding='utf-8')
        scoped = self.run_cli(config={'EvidenceSource': 'session'})
        self.assertEqual([r['githubRepo'] for r in scoped['repos']], ['acme/app'])
        self.assertEqual([e['sessionId'] for e in scoped['repos'][0]['sessionEvidence']], ['s1'])

    def test_manual_date_uses_negative_report_timezone(self):
        self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                      q='repo:acme/app is:pr is:merged merged:2026-11-16..2026-11-18', per_page=100, page=1)
        self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                      q='repo:acme/app is:issue author:owner created:2026-11-16..2026-11-18', per_page=100, page=1)
        manual = self.root / 'manual.json'
        manual.write_text(json.dumps([dict(date='2026-11-16', repo='acme/app', result='當日維運')]), encoding='utf-8')
        for timezone_database in (True, False):
            with self.subTest(timezone_database=timezone_database):
                if not timezone_database:
                    self.without_timezone_database()
                data = self.run_cli(config=dict(From='2026-11-16T00:00:00-05:00', To='2026-11-17T00:00:00-05:00',
                                               Timezone='America/New_York', ManualInputPath=str(manual)))
                self.assertTrue(data['meta']['canGenerateLog'])
                self.assertEqual(data['repos'][0]['manualEvidence'][0]['date'], '2026-11-16')

    def without_timezone_database(self):
        bin_path = self.root / 'bin'
        bin_path.mkdir()
        python = sys.executable.replace("'", "''")
        (bin_path / 'python.ps1').write_text(
            'param([Parameter(ValueFromPipeline=$true)][string]$InputJson, '
            '[Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)\n'
            'begin { $lines = [Collections.Generic.List[string]]::new() }\n'
            'process { $lines.Add($InputJson) }\n'
            f"end {{ ($lines -join [Environment]::NewLine) | & '{python}' -S @Arguments; exit $LASTEXITCODE }}\n", encoding='utf-8')
        self.env = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                        PYTHONTZPATH=str(self.root / 'missing-timezone-database'))

    def test_scoped_session_scan_keeps_commits_only_work_eligible(self):
        import test_collector_efficiency as legacy
        helper = legacy.CollectorEfficiency()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        helper.fixture['rows'] = []
        helper.write('fixture.json', json.dumps(helper.fixture))
        script = helper.root / 'bin/git.ps1'
        script.write_text(script.read_text(encoding='utf-8').replace('synthetic/project', 'acme/app'), encoding='utf-8')
        self.env = helper.env
        data = self.run_cli(config=dict(EvidenceSource='session', SourceMode='scan', ScanRoots=[str(helper.root / 'repo-a')],
            From='2026-10-08T00:00:00+08:00', To='2026-10-09T00:00:00+08:00',
            OpenCodeLogRoot=str(helper.root / 'missing-log'), OpenCodeStorageRoot=str(helper.root / 'missing-storage'),
            CodexRoot=str(helper.codex_root)))
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['sessionEvidence'], [])
        self.assertEqual(data['repos'][0]['prs'], [])
        self.assertEqual(data['repos'][0]['commits'][0]['hash'], 'a' * 40)

    def test_system_timezone_fallback_uses_each_manual_days_dst_offset(self):
        self.without_timezone_database()
        for kind, query in [('pr', 'repo:acme/app is:pr is:merged merged:2026-10-31..2026-11-04'),
                            ('issue', 'repo:acme/app is:issue author:owner created:2026-10-31..2026-11-04')]:
            self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                          q=query, per_page=100, page=1)
        path = self.root / 'manual.json'
        path.write_text(json.dumps([dict(date=d, repo='acme/app', result=d) for d in
                                   ('2026-11-01', '2026-11-02', '2026-11-03')]), encoding='utf-8')
        data = self.run_cli(config=dict(From='2026-10-31T00:00:00-04:00', To='2026-11-03T00:00:00-05:00',
                                       Timezone='America/New_York', ManualInputPath=str(path)))
        self.assertEqual([e['date'] for e in data['repos'][0]['manualEvidence']], ['2026-11-01', '2026-11-02'])

    def test_new_source_stages_record_execution_cache_failure_and_probe_skips(self):
        git = shutil.which('git')
        if not git:
            self.skipTest('Git required for real repo discovery boundary')
        repo = self.root / 'repository'
        subprocess.run([git, 'init', '-q', str(repo)], check=True, capture_output=True, timeout=30)
        subprocess.run([git, '-C', str(repo), 'remote', 'add', 'origin', 'https://github.com/acme/app.git'],
                       check=True, capture_output=True, timeout=30)
        self.search('pr', [self.candidate(7)])
        self.search('issue', [self.candidate(3, 'issues')])
        self.response('repos/acme/app/pulls/7', self.pr())
        self.response('repos/acme/app/issues/3', self.issue())
        data = self.run_cli(config={'ScanRoots': [str(repo)]})
        stages = data['meta']['diagnostics']['stages']
        for name, calls in [('sourceAdapter', 1), ('json', 2), ('repoDiscovery', 1), ('git', 1), ('github', 5), ('output', 1)]:
            with self.subTest(stage=name):
                self.assertEqual(stages[name]['calls'], calls)
                self.assertIsNotNone(stages[name]['durationMs'])
                self.assertGreaterEqual(stages[name]['durationMs'], 0)
        self.assertEqual(stages['github']['cacheHits'], 1)
        probe = json.loads((self.root / 'probe.json').read_text(encoding='utf-8'))
        for name in ('sourceAdapter', 'repoDiscovery', 'git', 'github'):
            self.assertEqual(probe['meta']['diagnostics']['stages'][name], dict(durationMs=None, calls=None, cacheHits=None))
        self.responses[0]['status'] = 401
        failed = self.run_cli(config={'ScanRoots': [str(repo)]})
        self.assertEqual(failed['meta']['collectionStatus'], 'read-failed')
        self.assertEqual(failed['meta']['diagnostics']['stages']['github']['calls'], 1)
        self.assertIsNotNone(failed['meta']['diagnostics']['stages']['github']['durationMs'])
        self.assertEqual(failed['meta']['diagnostics']['stages']['git']['calls'], None)

    def test_mode_case_variants_keep_selected_sources_and_recursive_discovery(self):
        git = shutil.which('git')
        if not git:
            self.skipTest('Git required for real repo discovery boundary')
        repo = self.root / 'nested' / 'repository'
        subprocess.run([git, 'init', '-q', str(repo)], check=True, capture_output=True, timeout=30)
        subprocess.run([git, '-C', str(repo), 'remote', 'add', 'origin', 'https://github.com/acme/app.git'],
                       check=True, capture_output=True, timeout=30)
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(body='匯入完成'))
        github = self.run_cli(config=dict(EvidenceSource='GitHub', SourceMode='ScAn', ScanRoots=[str(self.root)]))
        self.assertEqual(github['meta']['evidenceSource'], 'github')
        self.assertEqual(github['repos'][0]['prs'][0]['number'], 7)
        self.assertEqual([Path(p) for p in github['repos'][0]['localPaths']], [repo])
        import test_collector_efficiency as legacy
        helper = legacy.CollectorEfficiency()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        helper.write('fixture.json', json.dumps(helper.fixture))
        script = helper.root / 'bin/git.ps1'
        script.write_text(script.read_text(encoding='utf-8').replace('synthetic/project', 'acme/app'), encoding='utf-8')
        self.env = helper.env
        self.config.update(From='2026-10-08T00:00:00+08:00', To='2026-10-09T00:00:00+08:00',
                           CodexRoot=str(helper.codex_root), OpenCodeLogRoot=str(helper.root / 'missing-log'),
                           OpenCodeStorageRoot=str(helper.root / 'missing-storage'))
        self.responses = [dict(path='user', parameters={}, response={'login': 'owner'})]
        for query in ('repo:acme/app is:pr is:merged merged:2026-10-07..2026-10-09',
                      'repo:acme/app is:issue author:owner created:2026-10-07..2026-10-09'):
            self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                          q=query, per_page=100, page=1)
        for selected, expected in [('SESSION', 'session'), ('Combined', 'combined')]:
            with self.subTest(selected=selected):
                data = self.run_cli(config=dict(EvidenceSource=selected, SourceMode='MiXeD'))
                self.assertEqual(data['meta']['evidenceSource'], expected)
                self.assertEqual(data['repos'][0]['sessionEvidence'][0]['sessionId'], 's1')
                self.assertEqual(data['meta']['sources']['github']['readStatus'],
                                 'empty' if expected == 'combined' else 'not-selected')

    def test_remote_formats_preserve_proxy_discovery_and_reject_lookalike_hosts(self):
        git = shutil.which('git')
        if not git:
            self.skipTest('Git required for real origin boundary')
        repo = self.root / 'repository'
        subprocess.run([git, 'init', '-q', str(repo)], check=True, capture_output=True, timeout=30)
        subprocess.run([git, '-C', str(repo), 'remote', 'add', 'origin', 'ssh://git@github.com/acme/app.git'],
                       check=True, capture_output=True, timeout=30)
        for query in ('is:pr author:owner is:merged merged:2026-11-15..2026-11-17',
                      'is:issue author:owner created:2026-11-15..2026-11-17'):
            self.response('search/issues', dict(items=[], total_count=0, incomplete_results=False),
                          q=query, per_page=100, page=1)
        self.search('pr', [self.candidate(7)])
        self.search('issue', [])
        self.response('repos/acme/app/pulls/7', self.pr(user='agent[bot]'))
        self.response('repos/acme/app/issues/3', self.issue())
        config = dict(Repositories=[], ScanRoots=[str(repo)], ProxyLogins=['agent[bot]'])
        for remote in ('ssh://git@github.com/acme/app.git', 'git@github.com:acme/app.git',
                       'https://github.com/acme/app.git', 'SSH://git@GitHub.Com/AcMe/App.git'):
            with self.subTest(remote=remote):
                subprocess.run([git, '-C', str(repo), 'remote', 'set-url', 'origin', remote],
                               check=True, capture_output=True, timeout=30)
                data = self.run_cli(config=config)
                self.assertEqual(data['meta']['collectionStatus'], 'success')
                self.assertEqual(data['meta']['repositoryScope']['confirmed'], ['acme/app'])
                self.assertEqual([p['number'] for p in data['repos'][0]['prs']], [7])
                self.assertEqual(data['repos'][0]['prs'][0]['attribution'], dict(
                    kind='confirmed-agent-and-request', login='owner', agent='agent[bot]',
                    evidenceUrls=['https://github.com/acme/app/issues/3']))
        for remote in ('https://githubXcom/acme/app.git', 'ssh://git@github.com.example/acme/app.git'):
            with self.subTest(lookalike=remote):
                subprocess.run([git, '-C', str(repo), 'remote', 'set-url', 'origin', remote],
                               check=True, capture_output=True, timeout=30)
                data = self.run_cli(config=config)
                self.assertEqual(data['meta']['collectionStatus'], 'no-activity')
                self.assertEqual(data['meta']['repositoryScope']['confirmed'], [])
                self.assertEqual(data['repos'], [])


if __name__ == '__main__':
    unittest.main()
