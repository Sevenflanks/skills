[CmdletBinding()]
param([ValidateSet('empty', 'metadata', 'workdir', 'envelope', 'cap', 'failure', 'expansion', 'attribution', 'all')][string]$Case = 'all', [string]$EvidenceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$python = (Get-Command python -ErrorAction Stop).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-diag-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$envNames = @('DWL_DIAG_ROOT','DWL_DIAG_MODE','DWL_DIAG_PYTHON','DWL_DIAG_FIXTURE')
$oldEnv = @{}; foreach ($name in $envNames) { $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Collect([string]$Mode, [switch]$Probe) {
  $env:DWL_DIAG_MODE = $Mode
  [IO.File]::WriteAllText("$root\queries.txt", '')
  $arguments = @('-NoProfile','-File',$collector,'-From','2026-10-08T00:00:00+08:00','-To','2026-10-08T23:59:59.999+08:00',
    '-OpenCodeLogRoot',"$root\missing-log",'-OpenCodeStorageRoot',"$root\missing-storage",'-CodexRoot',"$root\missing-codex")
  if ($Probe) { $arguments += '-ProbeOnly' }
  $raw = & $pwsh @arguments
  Assert ($LASTEXITCODE -eq 0) 'Collector CLI failed'
  $script:Result = ($raw -join "`n") | ConvertFrom-Json
  Assert ($script:Result.errors.Count -eq 0) ('Collector error: ' + ($script:Result.errors -join '|'))
  if ($EvidenceRoot) {
    $null = [IO.Directory]::CreateDirectory($EvidenceRoot)
    # 僅合成資料，仍將暫存路徑換成固定名稱供 PR 比較。
    $safe = ($raw -join "`n").Replace($root.Replace('\','\\'), 'C:\\synthetic')
    $safe = $safe.Replace(([Environment]::GetFolderPath('UserProfile')).Replace('\','\\'), 'C:\\synthetic-home')
    $name = if ($Probe) { "$Mode-probe" } else { $Mode }
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot "$name.json"), $safe)
  }
  return $script:Result
}
try {
  foreach ($dir in @('bin','home','repo','other-repo')) { $null = [IO.Directory]::CreateDirectory("$root\$dir") }
  $env:DWL_DIAG_ROOT = $root; $env:DWL_DIAG_PYTHON = $python
  $env:DWL_DIAG_FIXTURE = Join-Path $PSScriptRoot 'discovery-db-fixture.py'
  # 真正執行 public collector CLI；只以獨立 process 替換外部 CLI，不載入私有 functions。
  [IO.File]::WriteAllText("$root\bin\opencode.ps1", @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$sql = $Arguments[-1]
[IO.File]::AppendAllText("$env:DWL_DIAG_ROOT\queries.txt", $sql + "`n--end--`n")
if ($env:DWL_DIAG_MODE -eq 'metadata-failed' -or ($sql -match 'join session' -and $env:DWL_DIAG_MODE -eq 'supplement-failed')) {
  [Console]::Error.WriteLine('private-exception C:\private\sensitive-history.db'); exit 1
}
if ($sql -match 'join session') {
  switch ($env:DWL_DIAG_MODE) {
    'supplement-invalid' { '{invalid'; exit 0 }
    'supplement-scalar' { '42'; exit 0 }
    'supplement-true' { 'true'; exit 0 }
    'supplement-false' { 'false'; exit 0 }
    'supplement-null' { 'null'; exit 0 }
    'supplement-shape' { '[{"tool":"bash"}]'; exit 0 }
  }
}
@{root=$env:DWL_DIAG_ROOT.Replace('\','/');home=[Environment]::GetFolderPath('UserProfile');mode=$env:DWL_DIAG_MODE;sql=$sql} | ConvertTo-Json -Compress |
  & $env:DWL_DIAG_PYTHON -B $env:DWL_DIAG_FIXTURE
exit $LASTEXITCODE
'@)
  [IO.File]::WriteAllText("$root\bin\git.ps1", @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if ($Arguments[0] -eq 'rev-parse' -and $PWD.Path -in @("$env:DWL_DIAG_ROOT\repo", "$env:DWL_DIAG_ROOT\other-repo")) {
  if ($Arguments[-1] -eq '--show-toplevel') { $PWD.Path } else { 'true' }; exit 0
}
exit 1
'@)
  [IO.File]::WriteAllText("$root\bin\gh.ps1", 'exit 1')
  $env:PATH = "$root\bin;$(Split-Path $pwsh);$(Split-Path $python)"
  if ($Case -in @('empty','all')) {
    $result = Collect 'empty'
    Assert ($null -ne $result.meta.sources.opencode.PSObject.Properties['discovery']) 'Successful empty DB must expose discovery, not hide the read population'
    $d = $result.meta.sources.opencode.discovery
    Assert ($d.metadata.status -eq 'success' -and $d.metadata.rows -eq 0 -and $d.metadata.nonemptyInputs -eq 0) 'Empty DB must report known zero metadata counts'
    Assert ($d.workdir.status -eq 'not-read' -and $null -eq $d.workdir.returnedRows -and $null -eq $d.workdir.processedRows) 'Authoritative empty DB must not invent workdir reads'
    Assert ($result.meta.sources.opencode.readStatus -eq 'empty' -and $result.meta.collectionStatus -eq 'no-activity') 'Empty source guard changed'
    Assert (([IO.File]::ReadAllText("$root\queries.txt") -split '--end--').Count -eq 2) 'Empty DB queried supplement/fallback'
    $probe = Collect 'empty' -Probe
    Assert ($null -eq $probe.meta.sources.opencode.PSObject.Properties['discovery'] -and [IO.File]::ReadAllText("$root\queries.txt") -eq '') 'Probe performed collection diagnostics/query'
    [IO.File]::Move("$root\bin\opencode.ps1", "$root\bin\opencode.off")
    try {
      $unavailable = Collect 'unavailable'
      Assert ($unavailable.meta.collectionStatus -eq 'no-sources') 'Unavailable source guard changed'
      Assert ($unavailable.meta.sources.opencode.discovery.metadata.status -eq 'not-read' -and $null -eq $unavailable.meta.sources.opencode.discovery.metadata.rows) 'Unavailable source fabricated read results'
    } finally { [IO.File]::Move("$root\bin\opencode.off", "$root\bin\opencode.ps1") }
  }
  if ($Case -in @('metadata','all')) {
    $result = Collect 'diagnostics-metadata'
    $m = $result.meta.sources.opencode.discovery.metadata
    Assert ($m.status -eq 'success' -and $m.rows -eq 6 -and $m.nonemptyInputs -eq 9) 'Metadata must count rows and nonempty directory/path inputs separately'
    Assert ($m.normalizedUniqueCandidates -eq 3 -and $m.duplicateInputs -eq 3) 'Metadata must dedup normalized (session,path) before resolution, including failed candidates'
    Assert ($m.skippedInputs.notFullyQualified -eq 2 -and $m.skippedInputs.normalizationError -eq 1) 'Relative inputs and normalization failures must remain distinct'
    Assert ($m.results.repo -eq 1 -and $m.results.aggregateDirectory -eq 1 -and $m.results.notResolved -eq 1) 'Metadata unique candidates must partition into repo/aggregate/not-resolved results'
    Assert ($result.meta.sources.opencode.readStatus -eq 'success') 'Metadata unresolved counters must not redefine readStatus as partial'
    Assert ($result.repos.Count -eq 1 -and $result.repos[0].sessionEvidence.Count -eq 1) 'Metadata diagnostics changed attribution/dedup'
    Assert (($result.meta.sources.opencode.discovery | ConvertTo-Json -Depth 10 -Compress) -notmatch 'dwl-diag|\\u0000|synthetic') 'Discovery leaks private input/exception text'
  }
  if ($Case -in @('workdir','all')) {
    $result = Collect 'diagnostics-workdir'
    $w = $result.meta.sources.opencode.discovery.workdir
    Assert ($w.status -eq 'success' -and $w.returnedRows -eq 10 -and $w.processedRows -eq 10 -and $w.invalidRows -eq 0 -and -not $w.truncated) 'Workdir must expose its actual returned/processed row population'
    Assert ($w.emptyInputs -eq 1 -and $w.nonemptyInputs -eq 9 -and $w.skippedInputs.notFullyQualified -eq 2 -and $w.skippedInputs.normalizationError -eq 0) 'Workdir relative/normalization skips were conflated with unresolved resolver outcomes'
    Assert ($w.normalizedUniqueCandidates -eq 5 -and $w.repeatedCandidateRows -eq 2) 'Workdir must separately count normalized unique candidates and repeated rows, including repeated failures'
    Assert ($w.results.repoRows -eq 1 -and $w.results.alreadyAttributedRows -eq 2 -and $w.results.notResolvedRows -eq 4) 'Workdir results must partition normalized rows, retaining failed-row repeats and shared metadata dedup'
    Assert ($result.meta.sources.opencode.readStatus -eq 'partial' -and $result.meta.collectionStatus -eq 'partial') 'Existing unresolved workdir partial semantics changed'
    Assert ($result.repos.Count -eq 1 -and $result.repos[0].sessionEvidence.Count -eq 2) 'Workdir diagnostics changed retained evidence/dedup'
    Assert (([IO.File]::ReadAllText("$root\queries.txt") -split '--end--').Count -eq 3) 'Workdir diagnostics added a query/retry'
  }
  if ($Case -in @('envelope','all')) {
    # CLI 的 singleton 與 array 均是既有合法格式；應保留相同歸屬，而非把成功查詢說成 partial。
    foreach ($example in @(
      @{mode='supplement-singleton';rows=1;evidence=2},
      @{mode='supplement-array';rows=1;evidence=2},
      @{mode='supplement-empty';rows=0;evidence=1}
    )) {
      $result = Collect $example.mode
      $w = $result.meta.sources.opencode.discovery.workdir
      Assert ($w.status -eq 'success' -and $null -eq $w.reason -and $w.returnedRows -eq $example.rows -and $w.processedRows -eq $example.rows -and $w.invalidRows -eq 0 -and -not $w.truncated) "$($example.mode): legal query envelope rejected or miscounted"
      Assert ($w.normalizedUniqueCandidates -eq $example.rows -and $w.results.repoRows -eq $example.rows -and $w.results.alreadyAttributedRows -eq 0 -and $w.results.notResolvedRows -eq 0) "$($example.mode): legal envelope lost workdir attribution"
      Assert ($result.meta.sources.opencode.readStatus -eq 'success' -and $result.meta.collectionStatus -eq 'success' -and $result.repos.Count -eq 1 -and $result.repos[0].sessionEvidence.Count -eq $example.evidence) "$($example.mode): legal envelope changed retained evidence/source status"
      Assert (([IO.File]::ReadAllText("$root\queries.txt") -split '--end--').Count -eq 3) "$($example.mode): envelope handling added a query/fallback"
    }
  }
  if ($Case -in @('cap','all')) {
    $result = Collect 'cap'
    $w = $result.meta.sources.opencode.discovery.workdir
    Assert ($w.returnedRows -eq 2049 -and $w.processedRows -eq 2048 -and $w.truncated -and $w.limit -eq 2048) '2049 sentinel must be returned but not processed'
    Assert ($w.normalizedUniqueCandidates -eq 1 -and $w.repeatedCandidateRows -eq 2047 -and $w.results.repoRows -eq 1 -and $w.results.alreadyAttributedRows -eq 2047 -and $w.results.notResolvedRows -eq 0) 'Capped workdir row/unique/duplicate populations mixed or sentinel processed'
    Assert ($result.meta.sources.opencode.readStatus -eq 'partial' -and $result.repos.Count -eq 1 -and $result.repos[0].sessionEvidence.Count -eq 2) 'Sentinel changed retained evidence/partial guard'
    Assert (([IO.File]::ReadAllText("$root\queries.txt") -split '--end--').Count -eq 3) 'Cap triggered a retry/additional query'
  }
  if ($Case -in @('failure','all')) {
    foreach ($mode in @('supplement-failed','supplement-invalid','supplement-scalar','supplement-true','supplement-false','supplement-null','supplement-shape')) {
      $result = Collect $mode
      $w = $result.meta.sources.opencode.discovery.workdir
      if ($mode -eq 'supplement-shape') {
        Assert ($w.status -eq 'success' -and $w.returnedRows -eq 1 -and $w.processedRows -eq 1 -and $w.invalidRows -eq 1 -and $w.nonemptyInputs -eq 0) 'Invalid row must count only in the processed-row population'
      } else {
        Assert ($w.status -eq 'failed' -and $w.reason -eq 'supplement-failed' -and $null -eq $w.returnedRows -and $null -eq $w.processedRows -and $null -eq $w.results.repoRows) 'Failed supplement fabricated known zero rows/results'
      }
      Assert ($result.meta.sources.opencode.discovery.metadata.rows -eq 2 -and $result.meta.sources.opencode.readStatus -eq 'partial' -and $result.repos.Count -eq 1 -and $result.repos[0].sessionEvidence.Count -eq 1) 'Supplement failure destroyed retained metadata/partial semantics'
      Assert ((($result.warnings + $result.errors) -join '|') -notmatch 'private-exception|sensitive-history') 'Supplement failure leaked raw exception/path'
      Assert (([IO.File]::ReadAllText("$root\queries.txt") -split '--end--').Count -eq 3) 'Failure triggered supplement retry/fallback'
    }
    $result = Collect 'metadata-failed'
    Assert ($result.meta.sources.opencode.discovery.metadata.status -eq 'failed' -and $null -eq $result.meta.sources.opencode.discovery.metadata.rows -and $result.meta.sources.opencode.discovery.workdir.status -eq 'not-read') 'Failed metadata fabricated reads or queried supplement'
    Assert ((($result.warnings + $result.errors) -join '|') -notmatch 'private-exception|sensitive-history') 'Metadata failure leaked raw exception/path'
  }
  if ($Case -in @('expansion','all')) {
    # 只以 OS home 本身作合成候選：guard 應在任何 nested scan 前拒絕，不讀 home 內容。
    $result = Collect 'unsafe-home-expansion'
    $e = $result.meta.sources.opencode.discovery.expansion
    Assert ($e.status -eq 'success' -and $e.candidates -eq 2 -and $e.resolvedCandidates -eq 1 -and $e.notResolvedCandidates -eq 1) 'Expansion must account for candidate outcomes separately from metadata/workdir rows'
    Assert (($result.warnings -join '|') -match 'unsafe session expansion' -and ($result.warnings -join '|') -match 'OpenCode session paths') 'Unsafe expansion result disappeared'
    Assert (-not (($result.warnings -join '|').Contains([Environment]::GetFolderPath('UserProfile')))) 'Unsafe home expansion leaked a private path'
    Assert ($result.meta.sources.opencode.readStatus -eq 'success' -and $result.meta.collectionStatus -eq 'success' -and $result.repos.Count -eq 1) 'Expansion diagnostics redefined source readStatus or lost retained repo'
  }
  if ($Case -in @('attribution','all')) {
    $dir = "$root\missing-codex\sessions\2026\10\08"
    $null = [IO.Directory]::CreateDirectory($dir)
    $lines = @(
      @{type='session_meta';payload=@{id='synthetic-codex';cwd="$root\home"}},
      @{type='event_msg';timestamp='2026-10-08T02:00:00Z';payload=@{type='user_message';message='synthetic'}}
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    [IO.File]::WriteAllText("$dir\synthetic.jsonl", $lines -join "`n")
    [IO.File]::Move("$root\bin\opencode.ps1", "$root\bin\opencode.off")
    try {
      $result = Collect 'codex-expansion'
      Assert (($result.warnings -join '|') -match 'Some Codex session paths' -and ($result.warnings -join '|') -notmatch 'Some OpenCode session paths') 'Codex-only expansion failures were mislabeled as OpenCode'
      $e = $result.meta.sources.opencode.discovery.expansion
      Assert ($e.status -eq 'not-read' -and $null -eq $e.candidates -and $result.meta.sources.opencode.discovery.metadata.status -eq 'not-read') 'Codex-only candidates polluted unavailable OpenCode counters'
      Assert ($result.meta.sources.codex.readStatus -eq 'success' -and [IO.File]::ReadAllText("$root\queries.txt") -eq '') 'Attribution changed source reads or queried unavailable OpenCode'
    } finally { [IO.File]::Move("$root\bin\opencode.off", "$root\bin\opencode.ps1") }
  }
  @{case=$Case;passed=$true;privateDataRead=$false} | ConvertTo-Json
} finally {
  $env:PATH = $oldPath
  foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $oldEnv[$name]) }
  if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
