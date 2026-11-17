"""GitHub activity provider and source composition behind the public PowerShell CLI.

CLI and connector captures share all date/identity/coverage rules here. Captures
contain external responses, never preclassified work or an alternative policy.
"""
import json
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


class SourceError(Exception):
    pass


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise SourceError('duplicate-json-key')
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding='utf-8-sig'), object_pairs_hook=unique)


def now():
    return datetime.now(timezone.utc).isoformat()


def tz_for(name, system=None):
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        if name == 'Asia/Taipei':
            return timezone(timedelta(hours=8))
        if name in ('UTC', 'Etc/UTC'):
            return timezone.utc
        if system and isinstance(system.get('offsetMinutes'), (int, float)):
            return timezone(timedelta(minutes=system['offsetMinutes']))
        raise SourceError('timezone-unavailable') from None


def date_value(value, tz):
    if not isinstance(value, str):
        raise SourceError('invalid-event-time')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return result.replace(tzinfo=tz) if result.tzinfo is None else result


def canonical(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r'(?:https://github.com/|git@github.com:)?([\w.-]+/[\w.-]+?)(?:\.git)?/?', value.strip())
    return match.group(1).lower() if match else None


class Provider:
    def __init__(self, path=None):
        self.responses = read_json(path).get('responses') if path else None
        if path and not isinstance(self.responses, list):
            raise SourceError('invalid-provider-capture')
        self.cache = {}
        self.requests = []
        self.hits = 0
        self.duration_ms = 0

    def get(self, path, **parameters):
        started = time.perf_counter()
        try:
            return self._get(path, **parameters)
        finally:
            self.duration_ms += (time.perf_counter() - started) * 1000

    def _get(self, path, **parameters):
        key = json.dumps([path, parameters], sort_keys=True)
        if key in self.cache:
            self.hits += 1
            return self.cache[key]
        self.requests.append(dict(path=path, parameters=parameters))
        if self.responses is not None:
            rows = [r for r in self.responses if r.get('path') == path and r.get('parameters', {}) == parameters]
            if len(rows) != 1:
                raise SourceError('provider-response-missing-or-ambiguous')
            row = rows[0]
            if row.get('status', 200) != 200:
                raise SourceError('provider-request-failed')
            data = row.get('response')
        else:
            endpoint = path + ('?' + urlencode(parameters) if parameters else '')
            try:
                result = subprocess.run(['gh', 'api', endpoint], capture_output=True, encoding='utf-8')
            except OSError:
                raise SourceError('github-cli-unavailable') from None
            if result.returncode:
                # 外部錯誤可能反射私有內容；raw 與 aggregate 都只保留安全錯誤碼。
                raise SourceError('provider-request-failed')
            try:
                data = json.loads(result.stdout)
            except ValueError:
                raise SourceError('provider-invalid-json') from None
        if not isinstance(data, (dict, list)):
            raise SourceError('provider-invalid-response')
        self.cache[key] = data
        return data


def local_repos(config, warnings):
    roots = list(config.get('ScanRoots') or [])
    if not roots and config.get('Repositories'):
        return {}
    if not roots:
        roots = [str(Path.cwd())]
    found = {}
    visited = 0
    def inspect(path):
        nonlocal visited
        visited += 1
        if visited > 5000:
            warnings.append('repo-discovery-limit')
            return
        marker = path / '.git'
        if marker.exists():
            try:
                result = subprocess.run(['git', '-C', str(path), 'remote', 'get-url', 'origin'],
                                        capture_output=True, encoding='utf-8')
                repo = canonical(result.stdout.strip()) if result.returncode == 0 else None
                if repo:
                    found.setdefault(repo, []).append(str(path))
                else:
                    warnings.append('canonical-repo-unresolved')
            except OSError:
                warnings.append('git-unavailable-for-repo-discovery')
            return
        if config.get('SourceMode', 'session') in ('scan', 'mixed'):
            try:
                if len(path.parts) - len(base.parts) >= 6:
                    return
                for child in path.iterdir():
                    if visited >= 5000:
                        warnings.append('repo-discovery-limit')
                        break
                    if child.is_dir() and not child.is_symlink() and child.name not in (
                            'node_modules', '.git', '.scratch', '.benchmark-artifacts', 'dist', 'build', 'target'):
                        inspect(child)
            except OSError:
                warnings.append('repo-discovery-unreadable')
    for root in roots:
        base = Path(root).resolve()
        inspect(base)
    return found


def compose(config):
    wall_started = config.get('collectorStartedAtEpoch', time.time())
    mode = config.get('EvidenceSource', 'github')
    probe = bool(config.get('ProbeOnly'))
    tzname = config.get('Timezone', 'Asia/Taipei')
    tz = tz_for(tzname, config.get('systemTimezone'))
    start = date_value(config['From'], tz) if config.get('From') else datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = date_value(config['To'], tz) if config.get('To') else start + timedelta(days=1)
    if end <= start:
        raise SourceError('invalid-date-range')
    session = config.get('sessionData') or {}
    selected_github = mode in ('github', 'combined')
    available = bool(config.get('GitHubInputPath') and Path(config['GitHubInputPath']).is_file()) or bool(shutil.which('gh'))
    sources = dict(session.get('meta', {}).get('sources') or {})
    for name in ('opencode', 'codex'):
        sources.setdefault(name, dict(available=False, cliAvailable=False, readStatus='not-selected', reason='source-not-selected', entries=[]))
    sources['github'] = dict(available=available if selected_github else False,
                             cliAvailable=bool(shutil.which('gh')), readStatus='not-read' if selected_github else 'not-selected',
                             reason='provider-selected' if selected_github else 'source-not-selected',
                             provider='connector-capture' if config.get('GitHubInputPath') else 'gh',
                             coverage=dict(complete=True, pages=0, limitHits=[], failures=[]))
    sources['manual'] = dict(available=bool(config.get('ManualInputPath')), readStatus='not-read', reason='user-supplied')
    meta = dict(generatedAt=now(), from_=start.isoformat(), to=end.isoformat(), timezone=tzname,
                evidenceSource=mode, sourceMode=config.get('SourceMode', 'session'), probeOnly=probe,
                sources=sources, canGenerateLog=False, ghAvailable=session.get('meta', {}).get('ghAvailable', False),
                ghViewer=session.get('meta', {}).get('ghViewer'),
                authorScope=session.get('meta', {}).get('authorScope', 'current'))
    meta['from'] = meta.pop('from_')
    if session.get('meta'):
        meta['sessionContext'] = {key: session['meta'].get(key) for key in
            ('from', 'to', 'sourceMode', 'collectionStatus', 'ghViewer', 'authorScope', 'currentIdentity')}
    result = dict(meta=meta, repos=[], warnings=list(session.get('warnings', [])), errors=[])
    if probe:
        return result
    requested_scope = {canonical(value) for value in config.get('Repositories', [])}
    if None in requested_scope:
        raise SourceError('invalid-repository-scope')
    meta['scopeUnresolved'] = 0
    repos = {}
    def distinct(items):
        seen, kept = set(), []
        for item in items:
            signature = json.dumps(item, sort_keys=True)
            if signature not in seen:
                seen.add(signature)
                kept.append(item)
        return kept
    for index, repo in enumerate(session.get('repos', [])):
        identity = canonical(repo.get('githubRepo'))
        if requested_scope and identity not in requested_scope:
            if not identity:
                result.setdefault('unresolvedRepositories', []).append(repo)
                meta['scopeUnresolved'] += 1
                result['warnings'].append('session-repository-scope-unresolved')
            continue
        key = identity or repo.get('path') or f'unresolved-session-{index}'
        if key not in repos:
            repos[key] = dict(repo)
            repos[key]['localPaths'] = [repo['path']] if repo.get('path') else []
        else:
            # 同 canonical repo 的多個 worktree 都是有效證據，不能用最後一個覆蓋前者。
            existing = repos[key]
            for field in ('commits', 'prs', 'sessionEvidence', 'warnings', 'source'):
                existing[field] = distinct(existing.get(field, []) + repo.get(field, []))
            existing['localPaths'] = distinct(existing['localPaths'] + ([repo['path']] if repo.get('path') else []))
    def repo_for(repo, project=None):
        key = repo or 'manual:' + (project or 'unresolved')
        if key not in repos:
            repos[key] = dict(name=repo or project or '待確認專案', githubRepo=repo, path=None,
                              isGitRepo=False, source=[], commits=[], prs=[], issues=[], manualEvidence=[],
                              sessionEvidence=[], pendingAttribution=[], warnings=[])
        item = repos[key]
        for field in ('issues', 'manualEvidence', 'pendingAttribution'):
            item.setdefault(field, [])
        return item
    def add_item(repo, field, item):
        target = repo_for(repo)
        target['source'] = sorted(set(target.get('source', []) + ['github']))
        existing = next((x for x in target[field] if x.get('number') == item['number']), None)
        if existing:
            if field == 'issues' and existing.get('reportEvent') == 'specification-created':
                item['reportEvent'] = existing['reportEvent']
                item['reportEventAt'] = existing['reportEventAt']
            if field == 'prs':
                item['reportEvidence'] = distinct(existing.get('reportEvidence', []) + item.get('reportEvidence', []))
                item['evidenceSources'] = distinct(existing.get('evidenceSources', ['session']) + ['github'])
            existing.update(item)
            return existing
        else:
            target[field].append(item)
            return item
    provider = None
    coverage = sources['github']['coverage']
    def failure(code):
        coverage['complete'] = False
        coverage['failures'].append(code)
        result['warnings'].append(code)
    def within(value, default_tz=timezone.utc):
        return start <= date_value(value, default_tz) < end
    if selected_github:
        try:
            provider = Provider(config.get('GitHubInputPath'))
            viewer = provider.get('user').get('login')
            if not isinstance(viewer, str) or not re.fullmatch(r'[\w-]+', viewer):
                raise SourceError('github-identity-unresolved')
            meta.update(ghViewer=viewer, ghAvailable=True)
            repo_paths = local_repos(config, result['warnings'])
            requested = config.get('Repositories') or []
            scopes = []
            for value in requested:
                repo = canonical(value)
                if not repo:
                    raise SourceError('invalid-repository-scope')
                if repo not in scopes:
                    scopes.append(repo)
            # 未指定範圍時以本人活動找 repo，再只在確認的本機／Session 範圍補查代理成果。
            confirmed = sorted(set(repo_paths) | {r.get('githubRepo') for r in session.get('repos', []) if r.get('githubRepo')})
            scope_queries = [('repo:' + r, False) for r in scopes] if scopes else [('', True)] + [('repo:' + r, False) for r in confirmed]
            meta['repositoryScope'] = dict(requested=scopes, confirmed=confirmed, discovery='explicit' if scopes else 'viewer-activity-and-confirmed-local')
            lower = start.astimezone(timezone.utc).date().isoformat()
            upper = (end.astimezone(timezone.utc) + timedelta(days=1)).date().isoformat()
            candidates = {}
            for scope, own_only in scope_queries:
                for kind in ('pr', 'issue'):
                    query = ' '.join(x for x in (scope, 'is:' + kind,
                        ('author:' + viewer) if (own_only or kind == 'issue') else '',
                        ('is:merged merged:' if kind == 'pr' else 'created:') + lower + '..' + upper) if x)
                    seen = 0
                    for page in range(1, 11):
                        try:
                            data = provider.get('search/issues', q=query, per_page=100, page=page)
                            items, total = data['items'], data['total_count']
                            if not isinstance(items, list) or not isinstance(total, int):
                                raise SourceError('invalid-search-response')
                            coverage['pages'] += 1
                            if data.get('incomplete_results'):
                                failure('github-search-incomplete')
                            for item in items:
                                match = re.fullmatch(r'https://github.com/([\w.-]+/[\w.-]+)/(pull|issues)/(\d+)', item.get('html_url', ''))
                                if not match or match[2] != ('pull' if kind == 'pr' else 'issues'):
                                    failure('invalid-candidate-identity')
                                    continue
                                repo = canonical(match[1])
                                if scopes and repo not in scopes:
                                    failure('candidate-outside-repository-scope')
                                    continue
                                candidates[(repo, kind, int(match[3]))] = item
                            seen += len(items)
                            if seen >= total:
                                break
                            if not items or page == 10:
                                coverage['limitHits'].append('search-result-limit')
                                failure('github-search-coverage-limited')
                                break
                        except (SourceError, KeyError, TypeError, ValueError) as error:
                            failure(str(error) if isinstance(error, SourceError) else 'invalid-search-response')
                            break
            def issue_record(repo, number, related=False):
                data = provider.get(f'repos/{repo}/issues/{number}')
                if data.get('number') != number or data.get('html_url', '').lower() != f'https://github.com/{repo}/issues/{number}':
                    raise SourceError('issue-identity-mismatch')
                item = dict(number=number, type='issue', title=data.get('title'), body=data.get('body'),
                            url=data['html_url'], author=(data.get('user') or {}).get('login'), state=str(data.get('state', 'unknown')).upper(),
                            createdAt=data.get('created_at'), closedAt=data.get('closed_at'), stateObservedAt=meta['generatedAt'],
                            commentCount=data.get('comments', 0),
                            reportEvent='related-context', reportEventAt=None, source='github')
                if related:
                    item['relatedToPr'] = True
                return add_item(repo, 'issues', item)
            proxy_logins = {x.lower() for x in config.get('ProxyLogins', [])}
            for repo, kind, number in candidates:
                try:
                    if kind == 'issue':
                        item = issue_record(repo, number)
                        # 規格的語意由 consuming agent 依完整內容判斷；不可用固定字詞／label 漏掉合法規格。
                        if item['author'] and item['author'].lower() == viewer.lower() and within(item['createdAt']) and (item.get('body') or '').strip():
                            item.update(reportEvent='specification-created', reportEventAt=item['createdAt'], specificationCandidate=True)
                        elif not item.get('relatedToPr'):
                            repos[repo]['issues'].remove(item)
                        continue
                    data = provider.get(f'repos/{repo}/pulls/{number}')
                    if data.get('number') != number or data.get('html_url', '').lower() != f'https://github.com/{repo}/pull/{number}':
                        raise SourceError('pr-identity-mismatch')
                    if not data.get('merged_at') or not within(data['merged_at']):
                        continue
                    author = (data.get('user') or {}).get('login')
                    basis = dict(kind='author', login=viewer)
                    related = []
                    body = data.get('body') or ''
                    refs = {(repo, int(n)) for n in re.findall(r'(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|part of)\s+#(\d+)', body)}
                    refs.update((canonical(r), int(n)) for r, n in re.findall(r'https://github.com/([\w.-]+/[\w.-]+)/issues/(\d+)', body))
                    for issue_repo, issue_num in sorted(refs):
                        if not issue_repo:
                            continue
                        try:
                            related.append((issue_repo, issue_record(issue_repo, issue_num, related=True)))
                        except (SourceError, KeyError, TypeError, ValueError):
                            failure('related-issue-unverified')
                    if not author or author.lower() != viewer.lower():
                        owned = [(r, i) for r, i in related if (i['author'] or '').lower() == viewer.lower()]
                        evidence_urls = [i['url'] for _, i in owned]
                        if author and author.lower() in proxy_logins and not evidence_urls:
                            for issue_repo, issue in related:
                                if not issue.get('commentCount'):
                                    continue
                                comments = []
                                try:
                                    for page in range(1, 11):
                                        rows = provider.get(f"repos/{issue_repo}/issues/{issue['number']}/comments", per_page=100, page=page)
                                        if not isinstance(rows, list):
                                            raise SourceError('invalid-comments-response')
                                        comments.extend(rows)
                                        if len(rows) < 100:
                                            break
                                        if page == 10:
                                            failure('github-comments-coverage-limited')
                                    issue['commentsEvidence'] = comments
                                    for comment in comments:
                                        request_text = comment.get('body') or ''
                                        if ((comment.get('user') or {}).get('login', '').lower() == viewer.lower()
                                                and re.search(r'(?im)^\s*/afk\b|^\s*(?:請|麻煩).{0,20}(實作|處理)|^\s*(?:please\s+)?(?:implement|dispatch)\b', request_text)
                                                and not re.search(r"(?i)\b(?:do not|don't|not|stop|cancel)\b|不要|不需|取消|停止|尚未", request_text)
                                                and re.fullmatch(re.escape(issue['url']) + r'#issuecomment-\d+', comment.get('html_url', ''))):
                                            evidence_urls.append(comment['html_url'])
                                except (SourceError, KeyError, TypeError, ValueError):
                                    failure('requester-comments-unverified')
                        if author and author.lower() in proxy_logins and evidence_urls:
                            basis = dict(kind='confirmed-agent-and-request', login=viewer, agent=author,
                                         evidenceUrls=evidence_urls)
                        else:
                            if owned or (author and author.lower() in proxy_logins):
                                repo_for(repo)['pendingAttribution'].append(dict(number=number, type='pr', author=author,
                                    url=data['html_url'], reason='requester-or-agent-unconfirmed'))
                            continue
                    item = dict(number=number, type='pr', title=data.get('title'), body=body, url=data['html_url'],
                        state='MERGED', mergedAt=data['merged_at'], updatedAt=data.get('updated_at'), closedAt=data.get('closed_at'),
                        stateObservedAt=meta['generatedAt'], headRefName=(data.get('head') or {}).get('ref'),
                        baseRefName=(data.get('base') or {}).get('ref'), isDraft=bool(data.get('draft')), author=author,
                        reportEvent='merged', reportEventAt=data['merged_at'], source='github', attribution=basis,
                        closingIssuesReferences=[dict(number=i['number'], repository=r, url=i['url']) for r, i in related],
                        issuesClosed=[], reportEvidence=[dict(kind='merged-in-report-range', timestamp=data['merged_at'])])
                    add_item(repo, 'prs', item)
                except (SourceError, KeyError, TypeError, ValueError) as error:
                    failure(str(error) if isinstance(error, SourceError) else 'invalid-work-item-response')
            for repo, paths in repo_paths.items():
                if repo in repos:
                    repos[repo]['localPaths'] = distinct(repos[repo].get('localPaths', []) + paths)
                    repos[repo]['isGitRepo'] = True
            sources['github']['readStatus'] = 'partial' if not coverage['complete'] else ('success' if candidates else 'empty')
        except (SourceError, OSError, ValueError, TypeError, AttributeError) as error:
            failure(str(error) if isinstance(error, SourceError) else 'github-source-invalid')
            sources['github']['readStatus'] = 'failed'
    if config.get('ManualInputPath'):
        try:
            manual = read_json(config['ManualInputPath'])
            if not isinstance(manual, list):
                raise SourceError('invalid-manual-input')
            for index, item in enumerate(manual):
                if not isinstance(item, dict) or not isinstance(item.get('result'), str) or not item['result'].strip() or not item.get('date'):
                    raise SourceError('manual-date-and-result-required')
                manual_time = (config.get('systemTimezone') or {}).get('midnights', {}).get(item['date'], item['date'])
                if not within(manual_time, tz):
                    continue
                repo = canonical(item.get('repo'))
                if item.get('repo') and not repo:
                    raise SourceError('invalid-manual-repository')
                target = repo_for(repo, item.get('project'))
                target['source'] = sorted(set(target['source'] + ['manual']))
                target['manualEvidence'].append(dict(item, source='user-provided', verifiedByGitHub=False,
                                                     sourceIndex=index))
            sources['manual']['readStatus'] = 'success' if manual else 'empty'
        except (SourceError, OSError, ValueError, TypeError) as error:
            sources['manual']['readStatus'] = 'failed'
            result['warnings'].append(str(error) if isinstance(error, SourceError) else 'manual-input-invalid')
    for repo in repos.values():
        # 關聯 Issue 是背景，不能讓沒有本人成果的搜尋結果通過稿件 gate。
        if repo.get('prs') or repo.get('sessionEvidence') or repo.get('manualEvidence') or repo.get('commits') or any(
                i.get('reportEvent') == 'specification-created' for i in repo.get('issues', [])):
            meta['canGenerateLog'] = True
    result['repos'] = list(repos.values())
    gaps = any(s.get('readStatus') in ('failed', 'partial') for s in sources.values())
    meta['collectionStatus'] = ('partial' if gaps else 'success') if meta['canGenerateLog'] else ('read-failed' if gaps else 'no-activity')
    if meta['scopeUnresolved']:
        meta['collectionStatus'] = 'partial' if meta['canGenerateLog'] else 'scope-unresolved'
    if provider:
        sources['github']['requests'] = provider.requests
    stages = {name: dict(durationMs=None, calls=None, cacheHits=None) for name in
              ('sourceAdapter', 'json', 'repoDiscovery', 'git', 'github', 'output')}
    if provider:
        stages['github'] = dict(calls=len(provider.requests), cacheHits=provider.hits,
                                durationMs=round(provider.duration_ms, 3))
    meta['diagnostics'] = dict(schemaVersion=1, totalDurationMs=round(max(0, time.time() - wall_started) * 1000, 3),
                               stages=stages, session=session.get('meta', {}).get('diagnostics'))
    return result


if __name__ == '__main__':
    try:
        # Native pipe 的 bytes 固定 UTF-8，避免 PYTHONIOENCODING 或 Windows locale 改寫私有證據。
        config = json.loads(sys.stdin.buffer.read().decode('utf-8-sig'))
        output = compose(config)
    except Exception as error:
        output = dict(meta=dict(canGenerateLog=False, collectionStatus='error'), repos=[], warnings=[],
                      errors=[str(error) if isinstance(error, SourceError) else 'invalid-source-input'])
    sys.stdout.buffer.write((json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8'))
