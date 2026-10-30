param([ValidateSet('none','renumber')][string]$Mutation = 'none')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$formatter = Join-Path $PSScriptRoot '../scripts/format-daily-work-log-evidence.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$parent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Temporary parent unavailable.' }
$root = Join-Path $parent ('selection-cli-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Format([string[]]$Options) {
  $text = (& $pwsh -NoProfile -File $formatter -InputPath "$root/raw.json" @Options) -join "`n"
  Assert ($LASTEXITCODE -eq 0) 'Formatter CLI failed.'
  $text | ConvertFrom-Json -Depth 100
}
function Raw([string]$Pointer) { Format @('-View','raw','-JsonPointer',$Pointer) }
try {
  if ($Mutation -eq 'renumber') {
    $text = [IO.File]::ReadAllText($formatter).Replace('/repos/$repoIndex/sessionEvidence/$i','/repos/0/sessionEvidence/0')
    $formatter = "$root/mutated-formatter.ps1"
    [IO.File]::WriteAllText($formatter, $text, [Text.UTF8Encoding]::new($false))
  }
  # Observer: readers navigate one captured raw document. Break: filtered offsets are renumbered,
  # another source/resume disappears, or summary truncation replaces complete ERP evidence.
  $routine = @{source='codex';agent='codex';role='tool';sessionId='parent';sessionIds=@('parent','child');sourceId='item';turnId='turn';detail='routine synthetic payload';tool=@{name='read';status='completed';exitCode=0}}
  $fixture = @{
    meta=@{canGenerateLog=$true;collectionStatus='partial';diagnostics=@{schemaVersion=1;totalDurationMs=10;stages=@{sourceAdapter=@{durationMs=8;calls=2;cacheHits=0};git=@{durationMs=6;calls=3;cacheHits=1};github=@{durationMs=$null;calls=$null;cacheHits=$null}};future=@{calls=3;unexecuted=$null;payload='UNKNOWN-PRIVATE-DIAGNOSTIC'}};sources=@{opencode=@{readStatus='success'};codex=@{readStatus='partial';coverage=@{complete=$false}}}}
    warnings=@('coverage gap');errors=@();repos=@(
      @{name='other';githubRepo='fixture/other';commits=@();prs=@();warnings=@();sessionEvidence=@(@{sessionId='child';title='not this repo'})},
      @{name='a';githubRepo='fixture/shared';source=@('session','codex');isGitRepo=$true;warnings=@('repo gap');commits=@(1..10 | ForEach-Object { @{hash="hash$_";subject="change $_";refs='origin/feature/a'} });prs=@(@{number=7;state='MERGED';closingIssuesReferences=@(@{number=57})});sessionEvidence=@(@{sessionId='unrelated';title='not this session'},$routine)},
      @{name='b';githubRepo='fixture/shared';source=@('session');commits=@();prs=@();warnings=@();sessionEvidence=@(@{agent='opencode';source='session';sessionId='child';title="中文 'quote'`ncontinued"})},
      @{name='c';githubRepo=$null;commits=@();prs=@();warnings=@();sessionEvidence=@()}
    )
    'escaped/~key'=@{'01'='object key';'empty'=@();'null'=$null;'nested'=@(@{value='first'},@{value='second'})}
  }
  $deep = @{value='deep exact'}
  for ($depth = 0; $depth -lt 70; $depth++) { $deep = @{child=$deep} }
  $fixture.deep = $deep
  [IO.File]::WriteAllText("$root/raw.json", ($fixture | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
  $original = [IO.File]::ReadAllText("$root/raw.json")
  $index = Format @('-View','index','-GithubRepo','FIXTURE/SHARED')
  Assert (($index.repos.name -join ',') -eq 'a,b') 'Canonical selection lost a worktree or included another repo.'
  Assert (($index.repos.detailRef.jsonPointer -join ',') -eq '/repos/1,/repos/2') 'Filtered index renumbered raw repo positions.'
  Assert ($index.meta.detailRef.jsonPointer -eq '/meta' -and $index.meta.detailRef.inputPath -eq "$root/raw.json") 'Unknown diagnostics have no exact raw entry point.'
  Assert ($index.meta.diagnostics.detailRef.jsonPointer -eq '/meta/diagnostics' -and $index.meta.diagnostics.schemaVersion -eq 1) 'Diagnostics navigation/version missing.'
  Assert ($index.meta.diagnostics.totalDurationMs -eq 10 -and $index.meta.diagnostics.stages.sourceAdapter.durationMs -eq 8 -and $index.meta.diagnostics.stages.git.durationMs -eq 6) 'Overlapping stages were summed as total or changed.'
  Assert ($index.meta.diagnostics.stages.git.calls -eq 3 -and $index.meta.diagnostics.stages.git.cacheHits -eq 1 -and $null -eq $index.meta.diagnostics.stages.github.calls) 'Diagnostic call/reuse counts or unexecuted null changed.'
  Assert (($index | ConvertTo-Json -Depth 100) -notmatch 'UNKNOWN-PRIVATE-DIAGNOSTIC') 'Index expanded unknown diagnostics.'
  Assert ((Raw '/meta/diagnostics').value.future.calls -eq 3) 'Unknown diagnostics cannot be selected.'
  $sessions = Format @('-View','sessions','-GithubRepo','fixture/shared')
  Assert ($sessions.repos[0].sessionEvidence.Count -eq 2 -and $sessions.repos[1].sessionEvidence.Count -eq 1) 'Session navigation truncated sources or unrelated sessions.'
  Assert ($sessions.repos[0].sessionEvidence[1].sessionIds[1] -ceq 'child') 'Session navigation dropped continuation identities.'
  $selected = Format @('-View','sessions','-GithubRepo','fixture/shared','-SessionId','child')
  Assert (($selected.repos.name -join ',') -eq 'a,b') 'Session selection lost matching continuation worktree.'
  Assert ($selected.repos[0].sessionEvidence.Count -eq 1 -and $selected.repos[1].sessionEvidence.Count -eq 1) 'Session selection included unrelated rows.'
  $refs = @($selected.repos | ForEach-Object { $_.sessionEvidence.detailRef })
  Assert (($refs.jsonPointer -join ',') -eq '/repos/1/sessionEvidence/1,/repos/2/sessionEvidence/0') 'Filtered sessions renumbered raw positions.'
  foreach ($ref in $refs) {
    $raw = Raw $ref.jsonPointer
    Assert ($raw.detailRef.inputPath -ceq "$root/raw.json" -and $raw.detailRef.jsonPointer -ceq $ref.jsonPointer) 'Raw read changed capture provenance.'
    Assert ($raw.value.sessionId -cin @('parent','child')) 'Navigation reference does not resolve to the matching raw session.'
  }
  $summary = Format @('-View','summary','-GithubRepo','fixture/shared','-SessionId','child')
  Assert ($summary.repos[0].sessionEvidence[0].detailRef.jsonPointer -eq '/repos/1/sessionEvidence/1') 'Summary compact detailRef was renumbered after filtering.'
  Assert ((Raw $summary.repos[0].sessionEvidence[0].detailRef.jsonPointer).value.detail -ceq 'routine synthetic payload') 'Compact reference lost complete raw evidence.'
  $erp = Format @('-View','erp','-GithubRepo','fixture/shared','-SessionId','child')
  Assert ($erp.repos[0].commits.Count -eq 10 -and $erp.repos[0].commits[9].refs -eq 'origin/feature/a') 'Selected ERP used summary commit truncation.'
  Assert ($erp.repos[0].prs[0].closingIssuesReferences[0].number -eq 57 -and $erp.repos[0].sessionEvidence[0].detail -ceq 'routine synthetic payload') 'Selected ERP compacted complete PR/session evidence.'
  Assert ($erp.meta.sources.codex.readStatus -eq 'partial' -and -not $erp.meta.sources.codex.coverage.complete -and $erp.meta.sources.opencode.readStatus -eq 'success') 'Selection lost global source coverage.'
  Assert ($erp.warnings[0] -eq 'coverage gap' -and $erp.repos[0].warnings[0] -eq 'repo gap') 'Selection lost warnings.'
  Assert ((Format @('-View','sessions','-SessionId','CHILD')).repos.Count -eq 0) 'Session IDs became case-insensitive.'
  Assert ((Format @('-View','erp','-GithubRepo','fixture/missing')).repos.Count -eq 0) 'Empty selection expanded scope.'
  Assert ((Raw '/escaped~1~0key/01').value -ceq 'object key') 'Escaped object pointer treated numeric key as array offset.'
  Assert ((Raw '/escaped~1~0key/nested/1/value').value -ceq 'second') 'Exact nested pointer selected wrong array offset.'
  Assert ((Raw ('/deep' + ('/child' * 70) + '/value')).value -ceq 'deep exact') 'Raw selection rejected evidence deeper than the JSON DOM default.'
  Assert ((Raw '/escaped~1~0key/empty').value.Count -eq 0) 'Empty raw array changed shape.'
  Assert ($null -eq (Raw '/escaped~1~0key/null').value) 'Raw JSON null changed shape.'
  Assert ((Raw '').value.repos.Count -eq 4) 'Empty JSON pointer did not select the full document.'
  foreach ($pointer in @('/missing','/repos/01','/repos/-','/repos/99','/repos/-1','/bad~2escape','repos/0','/repos/0/name/0')) {
    $bad = Raw $pointer
    Assert ($bad.errors.Count -gt 0 -and $null -eq $bad.PSObject.Properties['value']) "Invalid pointer silently returned data: $pointer"
  }
  $bad = Format @('-View','raw','-JsonPointer','/repos/0','-GithubRepo','fixture/shared')
  Assert ($bad.errors.Count -gt 0) 'Ambiguous raw pointer plus repo selection was accepted.'
  Assert ([IO.File]::ReadAllText("$root/raw.json") -ceq $original) 'Selection modified the captured evidence.'
  $fixture.meta.diagnostics.schemaVersion = 2
  [IO.File]::WriteAllText("$root/raw.json", ($fixture | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
  $unknown = Format @('-View','index')
  Assert ($unknown.meta.diagnostics.schemaVersion -eq 2 -and $unknown.meta.diagnostics.detailRef.jsonPointer -eq '/meta/diagnostics' -and $null -eq $unknown.meta.diagnostics.PSObject.Properties['stages']) 'Unknown diagnostics schema interpreted as version 1.'
  'PASS selection CLI: canonical repos, all sessions/continuations, original offsets, full ERP, exact RFC6901 reads/errors, unknown diagnostics.'
} finally { [IO.Directory]::Delete($root, $true) }
