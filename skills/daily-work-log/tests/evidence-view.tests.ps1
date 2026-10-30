[CmdletBinding()]
param([ValidateSet('canonical', 'reuse', 'formatter', 'failures', 'all')][string]$Case = 'all', [string]$EvidenceRoot,
  [string]$CollectorPath = (Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'), [switch]$MeasureOnly,
  [ValidatePattern('^[0-9a-fA-F]{7,40}$')][string]$BaselineRevision)

# 只在本次 TEMP 中建立來源；git/gh/OpenCode 邊界替身不連網，也不讀個人歷史。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$formatter = Join-Path $PSScriptRoot '..\scripts\format-daily-work-log-evidence.ps1'
$pwsh = (Get-Command pwsh).Source
$realGit = (Get-Command git).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-evidence-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Fixture([string]$Path, [string]$Text) {
  $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
  [IO.File]::WriteAllText($Path, $Text)
}
function Collect {
  $raw = & $pwsh -NoProfile -File $CollectorPath -From '2026-05-29T00:00:00+08:00' -To '2026-05-29T23:59:59+08:00' -OpenCodeLogRoot "$root\logs" -OpenCodeStorageRoot "$root\storage" -CodexRoot "$root\codex"
  Assert ($LASTEXITCODE -eq 0) 'collector process failed'
  $data = ($raw -join "`n") | ConvertFrom-Json
  Assert (@($data.errors).Count -eq 0) ('collector errors: ' + ($data.errors -join ';'))
  return $data
}
try {
  foreach ($name in @('bin', 'repo-a', 'repo-b', 'logs')) { $null = [IO.Directory]::CreateDirectory("$root\$name") }
  if ($BaselineRevision) {
    $baseline = & $realGit show "${BaselineRevision}:skills/daily-work-log/scripts/collect-daily-work-log.ps1"
    Assert ($LASTEXITCODE -eq 0) 'baseline collector could not be read'
    $CollectorPath = "$root\baseline-collector.ps1"
    Write-Fixture $CollectorPath ($baseline -join "`n")
  }
  $env:PATH = "$root\bin;$(Split-Path -Parent $pwsh)"
  $git = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$repo = (Get-Location).Path
[IO.File]::AppendAllText('__ROOT__\git-calls.txt', ($Arguments -join ' ') + "`n")
switch ($Arguments[0]) {
  'rev-parse' { if ($Arguments[1] -eq '--is-inside-work-tree') { 'true' } else { $repo }; exit 0 }
  'config' { if ($Arguments[-1] -eq 'user.name') { 'fixture-user' } else { 'fixture@example.invalid' }; exit 0 }
  'remote' { $value = [IO.File]::ReadAllText('__ROOT__\remote.txt'); if ($value -eq 'missing') { exit 1 }; $value; exit 0 }
  'log' {
    if ([IO.File]::Exists('__ROOT__\with-commits')) {
      $suffix = if ($repo.EndsWith('repo-a')) { 'a' } else { 'b' }
      $fields = @(($suffix * 40), ($suffix * 7), '2026-05-29T10:00:00+08:00', 'fixture-user', 'fixture@example.invalid', "修正 $suffix", "origin/feature/$suffix", '__DWL_END__')
      ($fields -join [char]0x1f) + [char]0x1e
    }; exit 0
  }
}
exit 2
'@
  Write-Fixture "$root\bin\git.ps1" ($git.Replace('__ROOT__', $root))
  $gh = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::AppendAllText('__ROOT__\gh-calls.txt', ($Arguments -join ' ') + "`n")
if ($Arguments[0] -eq 'api' -and $Arguments[1] -eq 'user') {
  if ([IO.File]::Exists('__ROOT__\viewer-invalid')) { '{broken'; exit 0 }
  if ($Arguments.Count -eq 2) { '{"login":"fixture-user","name":"Fixture User"}' }
  elseif ($Arguments[-1] -eq '.login') { 'fixture-user' } else { 'Fixture User' }; exit 0
}
if ($Arguments[0] -eq 'pr') {
  $repoIndex = [Array]::IndexOf($Arguments, '--repo')
  if ($repoIndex -lt 0 -or $Arguments[$repoIndex+1] -ne 'fixture/shared') { [Console]::Error.WriteLine('wrong canonical repo argument'); exit 2 }
}
if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'list') {
  if ([IO.File]::Exists('__ROOT__\list-failed')) { [Console]::Error.WriteLine('synthetic list failure'); exit 1 }
  @(1..3 | ForEach-Object {
    $head = @('a','hash-only','unrelated')[$_ - 1]
    @{number=$_;title="合成 PR $_";url="https://github.com/fixture/shared/pull/$_";updatedAt='2026-05-29T04:00:00Z';mergedAt=$null;closedAt=$null;state='OPEN';isDraft=($_ -eq 2);headRefName="feature/$head";baseRefName='main';closingIssuesReferences=@(@{number=(100+$_);title='合成 issue';url="https://github.com/fixture/shared/issues/$(100+$_)"});author=@{login='fixture-user'}}
  }) | ConvertTo-Json -Depth 8 -Compress; exit 0
}
if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'view') {
  if ([IO.File]::Exists('__ROOT__\detail-invalid')) { '{broken'; exit 0 }
  $hash = @('d','b','c')[[int]$Arguments[2] - 1] * 40
  @{number=[int]$Arguments[2];commits=@(@{oid=$hash;authoredDate='2026-05-29T02:00:00Z';committedDate='2026-05-29T02:00:00Z'})} | ConvertTo-Json -Depth 5 -Compress; exit 0
}
exit 2
'@
  Write-Fixture "$root\bin\gh.ps1" ($gh.Replace('__ROOT__', $root))
  $rows = @('a','b') | ForEach-Object { @{id="session-$_";directory="$root\repo-$_";title="合成工作 $_";time_created=1780012800000;time_updated=1780016400000} }
  $rowsJson = ConvertTo-Json -InputObject @($rows) -Compress
  Write-Fixture "$root\bin\opencode.ps1" ("param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Arguments)`nif (`$Arguments[-1] -match 'join session') { '[]' } else { '$rowsJson' }; exit 0")
  Write-Fixture "$root\remote.txt" 'https://github.com/fixture/shared.git'

  if ($Case -in @('canonical','all')) {
    foreach ($remote in @('https://github.com/fixture/shared.git', 'git@github.com:fixture/shared.git', 'ssh://git@github.com/fixture/shared.git', 'missing', 'https://notgithub.com/fixture/shared.git', 'https://github.com/fixture/shared/extra', 'broken')) {
      Write-Fixture "$root\remote.txt" $remote
      $data = Collect
      foreach ($repo in $data.repos) {
        $valid = $remote -in @('https://github.com/fixture/shared.git', 'git@github.com:fixture/shared.git', 'ssh://git@github.com/fixture/shared.git')
        Assert ($repo.githubRepo -eq $(if ($valid) { 'fixture/shared' } else { $null })) "canonical repo wrong for $remote"
        Assert (@($repo.commits).Count -eq 0 -and @($repo.prs).Count -eq 0 -and @($repo.sessionEvidence).Count -eq 1) 'session-only evidence invented or dropped'
        if (-not $valid) { Assert (($repo.warnings -join '|') -match 'remote') 'remote gap missing' }
      }
    }
    $calls = [IO.File]::ReadAllText("$root\git-calls.txt")
    Assert ($calls -notmatch 'symbolic-ref|branch --show-current') 'used current checkout as historical branch'
    Assert ([IO.File]::ReadAllText("$root\gh-calls.txt") -notmatch 'pr list|pr view') 'session-only without reliable PR evidence queried unrelated PRs'
    'PASS canonical'
  }
  if ($Case -in @('reuse','all')) {
    Write-Fixture "$root\remote.txt" 'https://github.com/fixture/shared.git'
    Write-Fixture "$root\with-commits" ''
    Write-Fixture "$root\gh-calls.txt" ''
    foreach ($part in @(1,2)) {
      $lines = @(
        @{timestamp='2026-05-29T01:00:00Z';type='session_meta';payload=@{id='codex-resume';cwd="$root\repo-a"}},
        @{timestamp="2026-05-29T0${part}:00:00Z";type='event_msg';payload=@{type='user_message';message="合成續行 $part"}}
      ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
      Write-Fixture "$root\codex\sessions\2026\05\29\part-$part.jsonl" ($lines -join "`n")
    }
    $data = Collect
    Assert ($data.meta.sources.opencode.readStatus -eq 'success' -and $data.meta.sources.codex.readStatus -eq 'success') 'multi-source fixture was not collected'
    Assert (@($data.repos[0].sessionEvidence | Where-Object agent -eq codex).Count -eq 2) 'Codex continuation missing'
    $calls = [IO.File]::ReadAllLines("$root\gh-calls.txt")
    $counts = [ordered]@{viewer=@($calls | Where-Object { $_ -like 'api user*' }).Count;prList=@($calls | Where-Object { $_ -like 'pr list*' }).Count;prView=@($calls | Where-Object { $_ -like 'pr view*' }).Count}
    if ($EvidenceRoot) {
      Write-Fixture "$EvidenceRoot\query-counts.json" ($counts | ConvertTo-Json)
      Write-Fixture "$EvidenceRoot\collection.json" (($data | ConvertTo-Json -Depth 30).Replace($root.Replace('\','\\'), '<synthetic-task>'))
    }
    $counts | ConvertTo-Json -Compress
    if (-not $MeasureOnly) {
      Assert ($counts.viewer -eq 1 -and $counts.prList -eq 1 -and $counts.prView -eq 3) 'same collection repeated viewer or canonical PR query'
      Assert (($data.repos[0].prs.number -join ',') -eq '1') 'worktree A received another worktree or author-only PR'
      Assert (($data.repos[1].prs.number -join ',') -eq '2' -and $data.repos[1].prs[0].isDraft) 'worktree B lost Draft or relation isolation'
      # 新 collection 仍須重新讀取，不能跨任務沿用 cache。
      $null = Collect
      Assert (@([IO.File]::ReadAllLines("$root\gh-calls.txt") | Where-Object { $_ -like 'pr list*' }).Count -eq 2) 'cache escaped collection lifetime'
    }
    'PASS reuse'
  }
  if ($Case -in @('failures','all')) {
    Write-Fixture "$root\remote.txt" 'https://github.com/fixture/shared.git'
    Write-Fixture "$root\with-commits" ''
    foreach ($fault in @('list-failed','detail-invalid','viewer-invalid')) {
      Write-Fixture "$root\$fault" ''
      Write-Fixture "$root\gh-calls.txt" ''
      $data = Collect
      $calls = [IO.File]::ReadAllLines("$root\gh-calls.txt")
      Assert (@($data.repos[0].prs).Count -eq 0 -and @($data.repos[1].prs).Count -eq 0) "$fault fabricated PRs"
      if ($fault -eq 'viewer-invalid') {
        Assert (-not $data.meta.ghAvailable -and @($data.warnings).Count -gt 0 -and @($calls).Count -eq 1) 'bad viewer retried or treated as authenticated'
      } else {
        foreach ($repo in $data.repos) { Assert (($repo.warnings -join '|') -match $(if ($fault -eq 'list-failed') { 'list failed' } else { 'not valid JSON' })) 'shared failure gap lost for a worktree' }
        Assert (@($calls | Where-Object { $_ -like 'pr list*' }).Count -eq 1) 'failed list query retried'
        Assert (@($calls | Where-Object { $_ -like 'pr view*' }).Count -eq $(if ($fault -eq 'list-failed') { 0 } else { 3 })) 'failed detail query retried'
      }
      [IO.File]::Delete("$root\$fault")
    }
    'PASS failures'
  }
  if ($Case -in @('formatter','all')) {
    # 直接提供既有 schema；此案例獨立於 #43 的 identity 修正。
    $sessions = @(1..6 | ForEach-Object { @{agent='opencode';source='session';sessionId="s$_";title="合成工作 $_";timeCreated=1780012800000;timeUpdated=1780016400000} })
    $sessions += @{agent='codex';source='codex';title='合成續行';sessionId='parent';sessionIds=@('parent','child');files=@('synthetic-parent.jsonl','synthetic-resume.jsonl');timestamps=@('2026-05-29T02:00:00Z','2026-05-29T03:00:00Z');role='user'}
    $fixture = [ordered]@{
      meta=@{sources=@{opencode=@{readStatus='success'};codex=@{readStatus='partial';coverage=@{complete=$false;limitHits=@('fileBytes');unvisitedDays=@('2026/05/28');stopReason='totalBytes'}}};canGenerateLog=$true;collectionStatus='partial'}
      warnings=@('合成 coverage 缺口');errors=@('合成可保留錯誤');repos=@(@{
        name='synthetic-a';path='C:\synthetic\repo-a';githubRepo='fixture/shared';source=@('session','codex');isGitRepo=$true
        commits=@(1..10 | ForEach-Object { @{hash=('a'*39+($_%10));short="hash$_";date='2026-05-29T02:00:00Z';author='fixture-user';authorEmail='fixture@example.invalid';subject="合成提交 $_";refs='origin/feature/a';branchHints=@('feature/a');issuesMentioned=@('#101')} })
        prs=@(@{number=1;title='合成修正';headRefName='feature/a';isDraft=$false;state='MERGED';mergedAt='2026-05-29T04:00:00Z';closingIssuesReferences=@(@{number=101})},@{number=2;title='合成續作';headRefName='feature/b';isDraft=$true;state='OPEN';mergedAt=$null;closingIssuesReferences=@()},@{number=3;title='合成取消';headRefName=$null;isDraft=$null;state='CLOSED';mergedAt=$null;closingIssuesReferences=@()})
        sessionEvidence=$sessions;warnings=@('合成 repo 缺口')
      },@{name='synthetic-b';githubRepo='fixture/shared';source=@('session');isGitRepo=$true;commits=@();prs=@();sessionEvidence=@($sessions[0]);warnings=@('session-only')})
    }
    $raw = $fixture | ConvertTo-Json -Depth 30
    Write-Fixture "$root\raw.json" $raw
    $compactRaw = (& $pwsh -NoProfile -File $formatter -InputPath "$root\raw.json" -View erp) -join "`n"
    Assert ($LASTEXITCODE -eq 0) 'formatter process failed'
    $compact = $compactRaw | ConvertFrom-Json
    Assert (@($compact.repos).Count -eq 2 -and @($compact.repos[0].commits).Count -eq 10) 'ERP view truncated commits or worktrees'
    Assert ($compact.repos[0].commits[9].refs -eq 'origin/feature/a' -and $compact.repos[0].commits[9].branchHints[0] -eq 'feature/a') 'branch evidence lost'
    Assert ($compact.repos[0].prs[0].closingIssuesReferences[0].number -eq 101 -and $compact.repos[0].prs[0].state -eq 'MERGED') 'merged/issue evidence lost'
    Assert ($compact.repos[0].prs[1].headRefName -eq 'feature/b' -and $compact.repos[0].prs[1].isDraft) 'Draft/head lost'
    Assert ($compact.repos[0].prs[2].state -eq 'CLOSED' -and $null -eq $compact.repos[0].prs[2].isDraft -and $null -eq $compact.repos[0].prs[2].headRefName) 'unknown or unmerged status guessed'
    Assert (@($compact.repos[0].sessionEvidence).Count -eq 7 -and $compact.repos[0].sessionEvidence[6].sessionIds[1] -eq 'child' -and $compact.repos[0].sessionEvidence[6].files[1] -eq 'synthetic-resume.jsonl') 'second source/continuation truncated'
    Assert (($compact.meta | ConvertTo-Json -Depth 30 -Compress) -eq ($fixture.meta | ConvertTo-Json -Depth 30 -Compress)) 'meta/source coverage changed'
    Assert ($compact.errors[0] -eq '合成可保留錯誤' -and $compact.warnings[0] -eq '合成 coverage 缺口' -and $compact.repos[0].warnings[0] -eq '合成 repo 缺口' -and $compact.repos[0].source[1] -eq 'codex') 'gaps/source lost'
    Assert ($null -eq $compact.repos[0].PSObject.Properties['path']) 'unneeded repo path in ERP view'
    $default = ($raw | & $pwsh -NoProfile -File $formatter) | ConvertFrom-Json
    Assert (@($default.repos[0].shownCommits).Count -eq 8 -and $default.repos[0].prs[0] -is [string]) 'default formatter contract changed'
    Assert (($default.meta | ConvertTo-Json -Depth 30 -Compress) -eq ($fixture.meta | ConvertTo-Json -Depth 30 -Compress)) 'default summary meta/source coverage changed'
    $bytes = [ordered]@{rawUtf8=[Text.Encoding]::UTF8.GetByteCount($raw);erpUtf8=[Text.Encoding]::UTF8.GetByteCount($compactRaw)}
    Assert ($bytes.erpUtf8 -lt $bytes.rawUtf8) 'ERP view did not reduce serialized bytes'
    if ($EvidenceRoot) {
      Write-Fixture "$EvidenceRoot\formatter-input.json" $raw
      Write-Fixture "$EvidenceRoot\erp-view.json" $compactRaw
      Write-Fixture "$EvidenceRoot\output-bytes.json" ($bytes | ConvertTo-Json)
    }
    $bytes | ConvertTo-Json -Compress
    'PASS formatter'
  }
} finally {
  $env:PATH = $oldPath
  if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
