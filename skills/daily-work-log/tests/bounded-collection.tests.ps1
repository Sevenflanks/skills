[CmdletBinding()]
param([string]$Case = 'scope', [string]$EvidenceRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-bounds-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$pwshDirectory = Split-Path (Get-Command pwsh).Source -Parent
$measurements = [Collections.Generic.List[object]]::new()
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Write-Fixture([string]$Relative, [string]$Content) {
  $path = Join-Path $root $Relative
  $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
  return $path
}
function Session([string]$Id = 'parent', [string]$Parent = '', [string]$Time = '2026-05-29T02:00:00Z', [string]$Text = '合成工作') {
  @(
    @{type='session_meta'; timestamp='2020-01-01T00:00:00Z'; payload=@{id=$Id; cwd="$root\repo"; previous_session_id=$Parent}},
    @{type='event_msg'; timestamp=$Time; payload=@{type='user_message'; message=$Text}}
  ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
}
function Collect([switch]$Probe, [string]$From = '2026-05-29T00:00:00+08:00', [string]$To = '2026-05-29T23:59:59+08:00', [string]$Label = '') {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $parameters = @{From=$From;To=$To;CodexRoot="$root\codex";OpenCodeLogRoot="$root\absent-log";OpenCodeStorageRoot="$root\absent-storage"}
  if ($Probe) { $parameters.ProbeOnly = $true }
  $raw = & $collector @parameters
  $watch.Stop()
  $data = $raw | ConvertFrom-Json
  Assert (@($data.errors).Count -eq 0) ('collector errors: ' + ($data.errors -join '; '))
  $coverage = $data.meta.sources.codex.PSObject.Properties['coverage']
  $process = [Diagnostics.Process]::GetCurrentProcess()
  $measurements.Add([pscustomobject]@{
    label=$Label; probe=[bool]$Probe; milliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,2)
    visitedEntries=if ($coverage) { $coverage.Value.visitedEntries } else { $data.meta.sources.codex.probeWork.visitedEntries }
    openedFiles=if ($coverage) { $coverage.Value.openedFiles } else { $data.meta.sources.codex.probeWork.openedFiles }
    readBytes=if ($coverage) { $coverage.Value.readBytes } else { 0 }
    peakWorkingSetBytes=$process.PeakWorkingSet64; outputBytes=[Text.Encoding]::UTF8.GetByteCount($raw)
  })
  if ($EvidenceRoot -and $Label) {
    # 僅 synthetic；公開範例仍替換 fixture 絕對路徑，避免 PR 貼上本機資訊。
    [IO.File]::WriteAllText("$EvidenceRoot\$Label.json", $raw.Replace($root.Replace('\','\\'), '<synthetic-root>'))
  }
  return $data
}
function Bounds($Data) {
  $c = $Data.meta.sources.codex.coverage
  Assert (-not $c.complete) 'bounded coverage claimed complete'
  Assert ($c.daysConsidered -le $c.limits.days) 'day budget exceeded'
  Assert ($c.visitedEntries -le $c.limits.entries) 'entry budget exceeded'
  Assert ($c.candidateFiles -le $c.limits.files -and $c.openedFiles -le $c.candidateFiles) 'file budget exceeded'
  Assert ($c.readBytes -le $c.limits.totalBytes) 'actual byte budget exceeded'
  return $c
}

try {
  $null = [IO.Directory]::CreateDirectory($root)
  $null = [IO.Directory]::CreateDirectory("$root\repo")
  # Git 公開邊界 stub 讓 selected session cwd 能解析為 repo；不用真正的 Git 或私人來源。
  $stub = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if ($Arguments[0] -eq 'rev-parse') {
  if ($Arguments[1] -eq '--is-inside-work-tree') { 'true' } else { '__REPO__' }
  exit 0
}
exit 1
'@
  $null = Write-Fixture 'bin\git.ps1' ($stub.Replace('__REPO__', "$root\repo"))
  $env:PATH = "$root\bin;$pwshDirectory"
  if ($Case -eq 'all') {
    foreach ($name in @('scope','days','max-date','probe-work','entries','files','bytes','line','partial-line','junction','statuses','benchmark')) {
      & $PSCommandPath -Case $name -EvidenceRoot $EvidenceRoot
    }
    return
  }
  switch ($Case) {
    'scope' {
      $path = Write-Fixture 'codex\sessions\2026\05\28\rollout-2020-old.jsonl' ((Session -Time '2026-05-28T16:00:00Z') -join "`n")
      [IO.File]::SetLastWriteTime($path, [datetime]'2020-01-01')
      $null = Write-Fixture 'codex\sessions\2026\05\29\child.jsonl' ((Session -Id child -Parent parent -Time '2026-05-29T15:59:59Z') -join "`n")
      $null = Write-Fixture 'codex\sessions\2026\05\29\resume.jsonl' ((Session) -join "`n")
      $null = Write-Fixture 'codex\sessions\2026\05\29\outside.jsonl' ((Session -Id outside -Time '2026-05-29T16:00:00Z' -Text '範圍外') -join "`n")
      $null = Write-Fixture 'codex\archived_sessions\old.jsonl' ((Session -Text 'archive 不選') -join "`n")
      $data = Collect -Label selected
      $c = Bounds $data
      Assert ($c.openedFiles -eq 4 -and $c.visitedEntries -eq 4) 'outside partition or archive visited'
      Assert ($c.archive -eq 'skipped') 'archive gap missing'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 1) 'selected parent/continuation not deduplicated'
      Assert (@($data.repos[0].sessionEvidence[0].sessionIds).Count -eq 2) 'selected child evidence lost'
      Assert (@($data.repos[0].sessionEvidence[0].files).Count -eq 3) 'old filename/mtime or inclusive UTC boundary lost'
      $before = $c
      for ($i=0; $i -lt 2000; $i++) { $null = Write-Fixture "codex\sessions\2000\01\01\old-$i.jsonl" '{broken' }
      $c = Bounds (Collect -Label history-growth)
      Assert ($c.visitedEntries -eq $before.visitedEntries -and $c.readBytes -eq $before.readBytes -and $c.openedFiles -eq $before.openedFiles) 'old history expanded collection work'
    }
    'days' {
      $null = Write-Fixture 'codex\sessions\0001\01\01\first.jsonl' ''
      $c = Bounds (Collect -From '0001-01-01T00:00:00Z' -To '9999-12-30T00:00:00Z' -Label extreme-days)
      Assert ($c.daysConsidered -eq 32 -and 'days' -in $c.limitHits) 'huge date range not stopped at fixed day cap'
      Assert ($c.selectedDays[-1] -eq '0001/02/01') 'day truncation direction changed'
    }
    'entries' {
      for ($i=0; $i -lt 2300; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\noise-$i.txt" '' }
      $null = Write-Fixture 'codex\sessions\2026\05\29\deep\a\b\c\secret.jsonl' ((Session) -join "`n")
      $c = Bounds (Collect -Label entry-cap)
      Assert ($c.visitedEntries -eq 2048 -and 'entries' -in $c.limitHits) 'non-json entries escaped budget'
      Assert ($c.openedFiles -eq 0) 'deep directory escaped nonrecursive boundary'
    }
    'max-date' {
      $null = Write-Fixture 'codex\sessions\9999\12\31\empty.jsonl' ''
      $data = Collect -From '9999-12-31T00:00:00Z' -To '9999-12-31T23:59:59Z' -Label max-date
      $c = Bounds $data
      Assert ($data.meta.sources.codex.readStatus -eq 'empty' -and $c.daysConsidered -eq 1) 'last representable day overflowed discovery'
    }
    'probe-work' {
      $null = Write-Fixture 'codex\sessions\2000\01\01\old.jsonl' '{broken'
      $null = Write-Fixture 'codex\archived_sessions\old.jsonl' '{broken'
      $data = Collect -Probe -Label probe-work
      $p = $data.meta.sources.codex.probeWork
      Assert ($p.checkedPaths -eq 2 -and $p.visitedEntries -eq 2 -and $p.openedFiles -eq 0 -and $p.readBytes -eq 0) 'probe work is not measurable or bounded'
    }
    'files' {
      for ($i=0; $i -lt 150; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\empty-$i.jsonl" '' }
      $c = Bounds (Collect -Label file-cap)
      Assert ($c.openedFiles -eq 128 -and $c.visitedEntries -eq 128 -and 'files' -in $c.limitHits) 'candidate cap exceeded or eagerly enumerated'
    }
    'bytes' {
      $padding = (' ' * 1023) + "`n"
      for ($i=0; $i -lt 12; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\large-$i.jsonl" ($padding * 2300) }
      $c = Bounds (Collect -Label byte-cap)
      Assert ($c.readBytes -eq 16777216 -and $c.openedFiles -eq 8 -and $c.visitedEntries -eq 8) 'actual byte read or lazy byte stop wrong'
      Assert ('fileBytes' -in $c.limitHits -and 'totalBytes' -in $c.limitHits) 'byte gaps undisclosed'
    }
    'line' {
      $null = Write-Fixture 'codex\sessions\2026\05\29\giant.jsonl' (((Session) -join "`n") + "`n" + ('x' * 3000000) + "`n" + ((Session -Text '巨行後不得解析') -join "`n"))
      $data = Collect -Label giant-line
      $c = Bounds $data
      Assert ($c.readBytes -eq 2097152) 'giant line read beyond actual file budget'
      Assert ('lineBytes' -in $c.limitHits) 'giant line limit not disclosed'
      Assert ($data.meta.sources.codex.readStatus -eq 'partial') 'preceding activity lost partial status'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 1) 'oversize/truncated line parsed'
    }
    'partial-line' {
      $line = '{"type":"event_msg","timestamp":"2026-05-29T02:00:00Z","payload":{"type":"token_count"}}' + "`n"
      $null = Write-Fixture 'codex\sessions\2026\05\29\tail.jsonl' ($line * 24000)
      $data = Collect -Label truncated-tail
      $c = Bounds $data
      Assert ('fileBytes' -in $c.limitHits) 'partial line did not expose byte limit'
      Assert ($data.meta.sources.codex.readStatus -eq 'empty') 'partial JSON tail incorrectly classified as parse failure'
    }
    'junction' {
      $null = Write-Fixture 'outside\secret.jsonl' ((Session) -join "`n")
      $null = [IO.Directory]::CreateDirectory("$root\codex\sessions\2026\05")
      $null = New-Item -ItemType Junction -Path "$root\codex\sessions\2026\05\29" -Target "$root\outside"
      $c = Bounds (Collect -Label junction-skipped)
      Assert ($c.visitedEntries -eq 0 -and $c.readBytes -eq 0 -and 'reparse-points' -in $c.skipped) 'junction escaped bounded partition'
      [IO.Directory]::Delete("$root\codex\sessions\2026\05\29")
    }
    'statuses' {
      $null = Write-Fixture 'codex\archived_sessions\only.jsonl' '{broken'
      $data = Collect -Label archive-only
      Assert ($data.meta.sources.codex.readStatus -eq 'empty' -and $data.meta.collectionStatus -eq 'no-activity' -and -not $data.meta.canGenerateLog) 'skipped archive incorrectly declared failed/activity'
      $path = Write-Fixture 'codex\sessions\2026\05\29\broken.jsonl' '{broken'
      $data = Collect -Label all-failed
      Assert ($data.meta.collectionStatus -eq 'read-failed' -and -not $data.meta.canGenerateLog -and -not $data.meta.ghAvailable) 'all failed source escaped stop guard'
      [IO.File]::WriteAllText($path, '')
      $data = Collect -Label empty
      Assert ($data.meta.collectionStatus -eq 'no-activity') 'empty bounded source lost stop state'
    }
    'benchmark' {
      # Reference 只掃本次建立的 synthetic root，永不提供 production fallback。
      $record = ((Session -Text '合成量測') -join "`n")
      for ($i=0; $i -lt 64; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\selected-$i.jsonl" $record }
      foreach ($oldCount in @(100,10000)) {
        for ($i=0; $i -lt $oldCount; $i++) { $null = Write-Fixture "codex\sessions\2000\01\01\old-$i.jsonl" $record }
        foreach ($temperature in @('cold','warm')) {
          $probe = Collect -Probe -Label "$oldCount-probe-$temperature"
          Assert ($probe.meta.probeOnly -and @($probe.repos).Count -eq 0 -and -not $probe.meta.sources.codex.PSObject.Properties['coverage']) 'probe read transcripts'
          $c = Bounds (Collect -Label "$oldCount-collection-$temperature")
          Assert ($c.visitedEntries -eq 64 -and $c.openedFiles -eq 64) 'old history increased bounded work'
          $watch = [Diagnostics.Stopwatch]::StartNew(); $entries=0; $bytes=[long]0
          foreach ($file in [IO.Directory]::EnumerateFiles("$root\codex", '*.jsonl', [IO.SearchOption]::AllDirectories)) {
            $entries++; $raw = [IO.File]::ReadAllText($file); $bytes += [Text.Encoding]::UTF8.GetByteCount($raw)
            foreach ($line in ($raw -split "`n")) { $null = $line | ConvertFrom-Json }
          }
          $watch.Stop()
          $measurements.Add([pscustomobject]@{label="$oldCount-synthetic-reference-$temperature";probe=$false;milliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,2);visitedEntries=$entries;openedFiles=$entries;readBytes=$bytes;peakWorkingSetBytes=[Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64;outputBytes=$null})
        }
      }
      if ($EvidenceRoot) {
        [IO.File]::WriteAllText("$EvidenceRoot\benchmark-scope.json", (@{
          fixture='64 selected files; 100 then 10000 outside-date files; synthetic only'
          cold='first call after fixture growth; same test process; OS filesystem cache uncontrolled'
          warm='repeat in same process; not a latency SLA'
          memory='PeakWorkingSet64 of test process, cumulative high-water including fixture construction and reference; not collector-only or per-run allocation'
          bytes='actual FileStream.Read return counts; excludes OS/directory metadata buffers'
          entries='successful application-level directory MoveNext visits; excludes OS enumeration prefetch and ancestor metadata checks'
          reference='isolated all-history enumerate/read/parse comparator only, not full collector/Git/gh; latency is not like-for-like'
          output='UTF-8 bytes of raw JSON before path sanitization; reference emits no collection JSON'
        } | ConvertTo-Json))
      }
    }
    default { throw "Unknown case: $Case" }
  }
  "PASS $Case"
  if ($EvidenceRoot) {
    [IO.File]::WriteAllText("$EvidenceRoot\$Case-measurements.json", ($measurements | ConvertTo-Json -Depth 10))
  }
}
finally {
  $env:PATH = $oldPath
  if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
