"""#67: public capture/collector/formatter, synthetic external GitHub responses only."""
import json
import os
from pathlib import Path
import shutil
import subprocess
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
        # A malformed session is readable. Default GitHub must never probe or parse it.
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

    def test_midnight_author_and_current_state_do_not_backdate_work(self):
        self.search('pr', [self.candidate(n) for n in (7, 8, 9, 10)])
        self.search('issue', [self.candidate(4, 'issues')])
        self.response('repos/acme/app/pulls/7', self.pr(merged='2026-11-15T16:00:00Z'))
        self.response('repos/acme/app/pulls/8', self.pr(8, merged='2026-11-16T16:00:00Z'))
        self.response('repos/acme/app/pulls/9', self.pr(9, user='other', body='Unrelated work'))
        self.response('repos/acme/app/pulls/10', self.pr(10, merged=None))
        self.response('repos/acme/app/issues/3', self.issue())
        self.response('repos/acme/app/issues/4', self.issue(4, created='2026-11-16T03:00:00Z'))
        data, erp = self.run_cli(view='erp')
        self.assertEqual([p['number'] for p in erp['repos'][0]['prs']], [7])
        issues = {i['number']: i for i in erp['repos'][0]['issues']}
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
        helper.write('fixture.json', json.dumps(helper.fixture))
        # Only external git/gh/OpenCode processes are substituted, as in the established suite.
        script = helper.root / 'bin/git.ps1'
        script.write_text(script.read_text(encoding='utf-8').replace('synthetic/project', 'acme/app'), encoding='utf-8')
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
        self.assertEqual(len(combined['repos']), 1)
        self.assertEqual(combined['repos'][0]['prs'][0]['number'], 7)
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
        data = self.run_cli(config=dict(From='2026-11-16T00:00:00-05:00', To='2026-11-17T00:00:00-05:00',
                                       Timezone='America/New_York', ManualInputPath=str(manual)))
        self.assertTrue(data['meta']['canGenerateLog'])
        self.assertEqual(data['repos'][0]['manualEvidence'][0]['date'], '2026-11-16')


if __name__ == '__main__':
    unittest.main()
