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
function Collect([switch]$Probe, [string]$From = '2026-05-29T00:00:00+08:00', [string]$To = '2026-05-29T23:59:59+08:00', [string]$Label = '', [hashtable]$Limits = @{}, [string]$Zone = 'Asia/Taipei') {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $parameters = @{From=$From;To=$To;CodexRoot="$root\codex";OpenCodeLogRoot="$root\absent-log";OpenCodeStorageRoot="$root\absent-storage"}
  $parameters.Timezone = $Zone
  foreach ($key in $Limits.Keys) { $parameters[$key] = $Limits[$key] }
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
  Assert (($c.visitedDays -join ',') -eq ($c.selectedDays -join ',') -and $c.daysConsidered -eq $c.visitedDays.Count) 'visited compatibility counters disagree'
  Assert ($c.candidateDays.Count -eq $c.visitedDays.Count + $c.unvisitedDays.Count) 'candidate coverage partition incomplete'
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
    foreach ($name in @('limits','date-priority','stream-boundaries','long-session','scope','days','max-date','probe-work','entries','files','bytes','line','partial-line','utf8','junction','path-components','statuses','benchmark')) {
      & $PSCommandPath -Case $name -EvidenceRoot $EvidenceRoot
    }
    return
  }
  switch ($Case) {
    'limits' {
      $null = Write-Fixture 'codex\sessions\2026\05\29\empty.jsonl' ''
      $c = Bounds (Collect -Label default-limits)
      Assert ($c.limits.totalBytes -eq 64MB -and $c.limits.fileBytes -eq 8MB -and $c.limits.lineBytes -eq 64KB) 'default byte limits differ from issue30'
      $c = Bounds (Collect -Limits @{CodexTotalBytes=128MB;CodexFileBytes=16MB} -Label explicit-limits)
      Assert ($c.limits.totalBytes -eq 128MB -and $c.limits.fileBytes -eq 16MB -and $c.limits.lineBytes -eq 64KB) 'explicit finite byte limits unavailable'
      $null = Write-Fixture 'codex\sessions\2026\05\29\empty.jsonl' ((Session) -join "`n")
      $c = Bounds (Collect -Limits @{CodexTotalBytes=[long]::MaxValue;CodexFileBytes=[long]::MaxValue} -Label max-finite-budget)
      Assert ($c.readBytes -gt 0 -and $c.limits.totalBytes -eq [long]::MaxValue) ("large finite budget changed read or required budget-sized allocation: readBytes=$($c.readBytes); totalBytes=$($c.limits.totalBytes)")
      foreach ($name in @('CodexTotalBytes','CodexFileBytes')) {
        foreach ($value in @(0,-1,1.5,[double]::NaN,[double]::PositiveInfinity,'unlimited','9223372036854775808')) {
          $rejected = $false
          try { $null = & $collector @{$name=$value} -ProbeOnly } catch { $rejected = $true }
          Assert $rejected "invalid $name accepted: $value"
        }
      }
    }
    'date-priority' {
      $null = Write-Fixture 'codex\sessions\2026\05\28\busy.jsonl' (((' ' * 4095) + "`n") * 8)
      $records = @('今日一','今日二','今日三','今日四') | ForEach-Object { Session -Text $_ }
      $null = Write-Fixture 'codex\sessions\2026\05\29\today.jsonl' ($records -join "`n")
      $data = Collect -Limits @{CodexTotalBytes=16KB;CodexFileBytes=16KB} -Label date-starvation
      $c = Bounds $data
      Assert ($c.selectedDays[0] -eq '2026/05/29' -and @($data.repos[0].sessionEvidence).Count -eq 4) 'UTC extra day starved requested timezone date'
      Assert (($c.candidateDays -join ',') -eq '2026/05/29,2026/05/28') 'candidate union changed'
      Assert ($c.stopReason -eq 'totalBytes' -and $c.readBytes -eq 16KB) 'global byte stop missing'
      $c = Bounds (Collect -From '2026-05-29T00:00:00+08:00' -To '2026-05-30T23:59:59+08:00' -Label multi-days)
      Assert (($c.candidateDays -join ',') -eq '2026/05/29,2026/05/30,2026/05/28') 'timezone days not ascending before extras'
      Assert (($c.visitedDays -join ',') -eq ($c.selectedDays -join ',') -and $c.unvisitedDays.Count -eq 0 -and $c.stopReason -eq 'candidate-days-exhausted') 'missing paths not counted as visited or exhaustion wrong'
      $c = Bounds (Collect -From '2026-05-29T00:00:00-07:00' -To '2026-05-29T23:59:59-07:00' -Zone 'America/Los_Angeles' -Label negative-zone)
      Assert (($c.candidateDays -join ',') -eq '2026/05/29,2026/05/30') 'negative timezone UTC extra candidate wrong'
      $c = Bounds (Collect -Limits @{CodexTotalBytes=1;CodexFileBytes=1} -Label unvisited-date)
      Assert (($c.visitedDays -join ',') -eq '2026/05/29' -and ($c.unvisitedDays -join ',') -eq '2026/05/28') 'global cap hides unvisited day'
    }
    'stream-boundaries' {
      $path = Write-Fixture 'codex\sessions\2026\05\29\stream.jsonl' ''
      $prefix = [Text.Encoding]::UTF8.GetBytes(((Session -Text '前段有效事件') -join "`n") + "`n")
      $event = (Session -Text '後段有效事件')[1]
      $suffix = [Text.Encoding]::UTF8.GetBytes($event + "`n")
      $exact = [Text.Encoding]::UTF8.GetBytes($event + (' ' * (64KB - [Text.Encoding]::UTF8.GetByteCount($event))) + "`n")
      $cases = @(
        @{label='exact-line'; bytes=[byte[]]($prefix + $exact); evidence=2; oversized=0; failed=$false},
        @{label='over-line'; bytes=[byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes(('x' * (64KB + 1)) + "`n") + $suffix); evidence=2; oversized=1; failed=$false},
        @{label='two-oversized'; bytes=[byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes((('x' * (64KB + 1)) + "`n") * 2) + $suffix); evidence=2; oversized=2; failed=$false},
        @{label='oversized-eof'; bytes=[byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes('x' * (64KB + 1))); evidence=1; oversized=1; failed=$false},
        @{label='json-failure'; bytes=[byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes("{broken`n") + $suffix); evidence=2; oversized=0; failed=$true},
        @{label='true-eof'; bytes=[byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes($event)); evidence=2; oversized=0; failed=$false},
        @{label='bom-crlf'; bytes=[byte[]](@(0xef,0xbb,0xbf) + [Text.Encoding]::UTF8.GetBytes(((Session -Text 'BOM 與 CRLF') -join "`r`n") + "`r`n")); evidence=1; oversized=0; failed=$false}
      )
      foreach ($fixture in $cases) {
        [IO.File]::WriteAllBytes($path, $fixture.bytes)
        $data = Collect -Label $fixture.label
        $c = Bounds $data
        Assert ($c.readBytes -eq $fixture.bytes.Length -and $c.oversizedLines -eq $fixture.oversized) "$($fixture.label): byte accounting or oversized count wrong"
        Assert (@($data.repos[0].sessionEvidence).Count -eq $fixture.evidence) "$($fixture.label): valid evidence lost"
        Assert ((@($data.warnings | Where-Object { $_ -like 'Some Codex events could not be read or parsed:*' }).Count -gt 0) -eq $fixture.failed) "$($fixture.label): parse warning wrong"
        Assert ($c.stopReason -eq 'candidate-days-exhausted' -and $c.unvisitedDays.Count -eq 0) 'local line limit mislabeled as global stop'
      }
      # 讓「中」的第一個 byte 恰好落在第一個 4 KiB chunk 的末端；其餘 bytes 跨 chunk。
      $head = '{"type":"event_msg","timestamp":"2026-05-29T02:00:00Z","payload":{"type":"user_message","message":"'
      $padding = 4095 - $prefix.Length - [Text.Encoding]::UTF8.GetByteCount($head)
      $crossing = [byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes($head + ('a' * $padding) + '中"}}' + "`n"))
      [IO.File]::WriteAllBytes($path, $crossing)
      $data = Collect -Label utf8-cross-chunk
      Assert ((Bounds $data).readBytes -eq $crossing.Length -and @($data.repos[0].sessionEvidence).Count -eq 2 -and $data.meta.sources.codex.readStatus -eq 'success') 'UTF8 crossing chunk boundary failed'
      # 丟棄期間達 cap、cap 正在多 byte 字元中、cap 恰好到 newline／真正 EOF 分開驗證。
      foreach ($capKind in @('file','total')) {
        $bytes = [byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes(('x' * 100000) + "`n") + $suffix)
        [IO.File]::WriteAllBytes($path, $bytes)
        $limits = if ($capKind -eq 'file') { @{CodexFileBytes=70000} } else { @{CodexTotalBytes=70000} }
        $data = Collect -Limits $limits -Label "discard-$capKind-cap"
        $c = Bounds $data
        Assert ($c.readBytes -eq 70000 -and $c.oversizedLines -eq 1 -and @($data.repos[0].sessionEvidence).Count -eq 1) 'discard cap did not respect remaining bytes'
        Assert (("${capKind}Bytes" -in $c.limitHits) -and ($c.stopReason -eq $(if ($capKind -eq 'file') {'candidate-days-exhausted'} else {'totalBytes'}))) 'local/global byte stop confused'
      }
      [IO.File]::WriteAllBytes($path, $crossing)
      $data = Collect -Limits @{CodexFileBytes=4096} -Label utf8-small-cap
      Assert ((Bounds $data).readBytes -eq 4096 -and @($data.repos[0].sessionEvidence).Count -eq 1 -and @($data.warnings | Where-Object { $_ -like 'Some Codex events could not be read or parsed:*' }).Count -eq 0) 'capped incomplete UTF8 tail parsed'
      foreach ($ending in @('',"`n")) {
        $bytes = [byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes($event + $ending))
        [IO.File]::WriteAllBytes($path, $bytes)
        $data = Collect -Limits @{CodexTotalBytes=$bytes.Length;CodexFileBytes=$bytes.Length} -Label "exact-eof-$($ending.Length)"
        $c = Bounds $data
        Assert ($c.readBytes -eq $bytes.Length -and @($data.repos[0].sessionEvidence).Count -eq 2 -and 'fileBytes' -notin $c.limitHits -and $c.stopReason -eq 'totalBytes') 'true EOF exactly at cap misclassified'
      }
      $completeBytes = [byte[]]($prefix + $suffix)
      [IO.File]::WriteAllBytes($path, [byte[]]($completeBytes + [Text.Encoding]::UTF8.GetBytes('{broken')))
      $data = Collect -Limits @{CodexFileBytes=$completeBytes.Length} -Label capped-at-newline
      Assert ((Bounds $data).readBytes -eq $completeBytes.Length -and @($data.repos[0].sessionEvidence).Count -eq 2 -and @($data.warnings | Where-Object { $_ -like 'Some Codex events could not be read or parsed:*' }).Count -eq 0) 'complete newline line at cap lost or unread tail parsed'
    }
    'long-session' {
      # 三筆事件分別緊接 2／8／16 MiB；預期 16/2、64/8、128/16 profiles 收到 0／1／2。
      $bytes = [byte[]]::new(16MB + 4096)
      [Array]::Fill[byte]($bytes, 32)
      for ($i=4095; $i -lt $bytes.Length; $i+=4096) { $bytes[$i]=10 }
      $meta = [Text.Encoding]::UTF8.GetBytes((Session)[0] + "`n")
      [Array]::Copy($meta, $bytes, $meta.Length)
      foreach ($offset in @(2MB,8MB,16MB)) {
        $event = [Text.Encoding]::UTF8.GetBytes((Session -Text "邊界事件 $offset")[1] + "`n")
        [Array]::Copy($event, 0, $bytes, $offset, $event.Length)
      }
      $path = Write-Fixture 'codex\sessions\2026\05\29\long.jsonl' ''
      [IO.File]::WriteAllBytes($path, $bytes)
      $profiles = @(@{total=16MB;file=2MB;expected=0},@{total=64MB;file=8MB;expected=1},@{total=128MB;file=16MB;expected=2})
      foreach ($profile in $profiles) {
        $data = Collect -Limits @{CodexTotalBytes=$profile.total;CodexFileBytes=$profile.file} -Label "long-$($profile.file)"
        $c = Bounds $data
        $actual = @($data.repos | ForEach-Object { $_.sessionEvidence }).Count
        Assert ($actual -eq $profile.expected -and $c.readBytes -eq $profile.file) 'long session profile boundary changed'
        Assert ('fileBytes' -in $c.limitHits -and $c.stopReason -eq 'candidate-days-exhausted' -and -not $c.complete) 'local byte gap missing despite all candidate days visited'
        Assert ($data.meta.sources.codex.readStatus -eq $(if ($actual -eq 0) {'empty'} else {'partial'})) 'empty/partial contract changed at local cap'
      }
    }
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
      Assert ($c.stopReason -eq 'days' -and $c.unvisitedDays.Count -eq $c.candidateDays.Count - 32) 'day cap coverage missing'
      Assert ($c.selectedDays[-1] -eq '0001/02/01') 'day truncation direction changed'
    }
    'entries' {
      for ($i=0; $i -lt 2300; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\noise-$i.txt" '' }
      $null = Write-Fixture 'codex\sessions\2026\05\29\deep\a\b\c\secret.jsonl' ((Session) -join "`n")
      $c = Bounds (Collect -Label entry-cap)
      Assert ($c.visitedEntries -eq 2048 -and 'entries' -in $c.limitHits) 'non-json entries escaped budget'
      Assert ($c.openedFiles -eq 0) 'deep directory escaped nonrecursive boundary'
      Assert ($c.stopReason -eq 'entries') 'global entry stop missing'
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
      Assert ($c.stopReason -eq 'files') 'global file stop missing'
    }
    'bytes' {
      $padding = (' ' * 1023) + "`n"
      for ($i=0; $i -lt 12; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\large-$i.jsonl" ($padding * 2300) }
      $c = Bounds (Collect -Limits @{CodexTotalBytes=16MB;CodexFileBytes=2MB} -Label byte-cap)
      Assert ($c.readBytes -eq 16777216 -and $c.openedFiles -eq 8 -and $c.visitedEntries -eq 8) 'actual byte read or lazy byte stop wrong'
      Assert ('fileBytes' -in $c.limitHits -and 'totalBytes' -in $c.limitHits) 'byte gaps undisclosed'
      [IO.Directory]::Delete("$root\codex", $true)
      for ($i=0; $i -lt 9; $i++) { $null = Write-Fixture "codex\sessions\2026\05\29\default-$i.jsonl" ($padding * (8192 + 1)) }
      $c = Bounds (Collect -Label default-byte-cap)
      Assert ($c.readBytes -eq 64MB -and $c.openedFiles -eq 8 -and $c.visitedEntries -eq 8 -and $c.stopReason -eq 'totalBytes') 'default actual read/lazy cap changed'
    }
    'line' {
      $content = ((Session) -join "`n") + "`n" + ('x' * 3000000) + "`n" + ((Session -Text '巨行後仍有工作') -join "`n")
      $null = Write-Fixture 'codex\sessions\2026\05\29\giant.jsonl' $content
      $data = Collect -Label giant-line
      $c = Bounds $data
      Assert ($c.readBytes -eq [Text.Encoding]::UTF8.GetByteCount($content) -and $c.oversizedLines -eq 1) 'discarded bytes or oversized line count wrong'
      Assert ('lineBytes' -in $c.limitHits) 'giant line limit not disclosed'
      Assert ($data.meta.sources.codex.readStatus -eq 'partial') 'preceding activity lost partial status'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 2) 'normal event after oversized line lost'
    }
    'partial-line' {
      $line = '{"type":"event_msg","timestamp":"2026-05-29T02:00:00Z","payload":{"type":"token_count"}}' + "`n"
      $null = Write-Fixture 'codex\sessions\2026\05\29\tail.jsonl' ($line * 24000)
      $data = Collect -Limits @{CodexFileBytes=2MB} -Label truncated-tail
      $c = Bounds $data
      Assert ('fileBytes' -in $c.limitHits) 'partial line did not expose byte limit'
      Assert ($data.meta.sources.codex.readStatus -eq 'empty') 'partial JSON tail incorrectly classified as parse failure'
    }
    'utf8' {
      $prefix = [Text.Encoding]::UTF8.GetBytes(((Session -Text '壞 UTF-8 前的有效工作') -join "`n") + "`n")
      $suffix = [Text.Encoding]::UTF8.GetBytes(((Session -Text '壞 UTF-8 後的有效工作') -join "`n") + "`n")
      # JSON 結構有效，只有 message 中的 0xFF 壞掉；寬鬆 replacement 解碼會錯收第三筆工作。
      $badLine = [byte[]]([Text.Encoding]::UTF8.GetBytes('{"type":"event_msg","timestamp":"2026-05-29T02:00:00Z","payload":{"type":"user_message","message":"') + @(0xff) + [Text.Encoding]::UTF8.GetBytes('"}}' + "`n"))
      $path = Write-Fixture 'codex\sessions\2026\05\29\bytes.jsonl' ''
      [IO.File]::WriteAllBytes($path, [byte[]]($prefix + $badLine + $suffix))
      $data = Collect -Label utf8-mixed
      $c = Bounds $data
      Assert ($data.meta.sources.codex.readStatus -eq 'partial' -and $data.meta.canGenerateLog) 'invalid UTF-8 discarded valid evidence instead of partial'
      Assert (@($data.repos).Count -eq 1 -and @($data.repos[0].sessionEvidence).Count -eq 2) 'valid work before/after invalid UTF-8 lost'
      Assert (@($data.warnings | Where-Object { $_ -like 'Some Codex events could not be read or parsed:*' }).Count -eq 1) 'invalid UTF-8 gap not disclosed'
      Assert ($c.openedFiles -eq 1 -and $c.readBytes -eq $prefix.Length + $badLine.Length + $suffix.Length) 'invalid UTF-8 changed actual read accounting'

      [IO.File]::WriteAllBytes($path, [byte[]]($prefix + @(0xff)))
      $data = Collect -Label utf8-bad-eof
      $c = Bounds $data
      Assert ($data.meta.sources.codex.readStatus -eq 'partial' -and @($data.repos[0].sessionEvidence).Count -eq 1) 'invalid UTF-8 EOF discarded preceding evidence'
      Assert ($c.readBytes -eq $prefix.Length + 1 -and @($c.limitHits).Count -eq 0) 'invalid UTF-8 EOF mislabeled as byte truncation'

      [IO.File]::WriteAllBytes($path, [byte[]]@(0xff, 10, 0xfe, 10))
      $data = Collect -Label utf8-all-failed
      $c = Bounds $data
      Assert ($data.meta.sources.codex.readStatus -eq 'failed' -and $data.meta.collectionStatus -eq 'read-failed' -and -not $data.meta.canGenerateLog) 'all-invalid UTF-8 escaped failed stop state'
      Assert (@($data.repos).Count -eq 0 -and -not $data.meta.ghAvailable -and $c.readBytes -eq 4) 'all-invalid UTF-8 produced work or bypassed stop guard'

      # byte cap 剛好切在「中」的第一個 byte；未讀完尾行應略過，不冒充完整壞行。
      $cap = 2097152
      $bytes = [byte[]]::new($cap + 3)
      [Array]::Fill[byte]($bytes, 32)
      [Array]::Copy($prefix, $bytes, $prefix.Length)
      for ($i = $prefix.Length; $i -lt $cap - 2; $i += 1024) { $bytes[$i] = 10 }
      $bytes[$cap-1] = 0xe4; $bytes[$cap] = 0xb8; $bytes[$cap+1] = 0xad; $bytes[$cap+2] = 10
      [IO.File]::WriteAllBytes($path, $bytes)
      $data = Collect -Limits @{CodexFileBytes=2MB} -Label utf8-truncated-tail
      $c = Bounds $data
      Assert ($data.meta.sources.codex.readStatus -eq 'partial' -and @($data.repos[0].sessionEvidence).Count -eq 1) 'UTF-8 tail truncation lost preceding evidence'
      Assert ($c.readBytes -eq $cap -and 'fileBytes' -in $c.limitHits) 'UTF-8 tail escaped byte cap'
      Assert (@($data.warnings | Where-Object { $_ -like 'Some Codex events could not be read or parsed:*' }).Count -eq 0) 'truncated UTF-8 tail falsely classified as corrupt full line'
    }
    'junction' {
      $null = Write-Fixture 'outside\secret.jsonl' ((Session) -join "`n")
      $null = [IO.Directory]::CreateDirectory("$root\codex\sessions\2026\05")
      $null = New-Item -ItemType Junction -Path "$root\codex\sessions\2026\05\29" -Target "$root\outside"
      $c = Bounds (Collect -Label junction-skipped)
      Assert ($c.visitedEntries -eq 0 -and $c.readBytes -eq 0 -and 'reparse-points' -in $c.skipped) 'junction escaped bounded partition'
      Assert ('2026/05/29' -in $c.visitedDays -and $c.stopReason -eq 'candidate-days-exhausted' -and -not $c.complete) 'rejected path not counted as visited or mistaken for completeness'
      [IO.Directory]::Delete("$root\codex\sessions\2026\05\29")
    }
    'path-components' {
      # 入口深度來自合成目錄，確認固定 ancestor cap；不展開其內容。
      $deepRoot = Join-Path $root ((@('d') * 64) -join [IO.Path]::DirectorySeparatorChar)
      $null = [IO.Directory]::CreateDirectory("$deepRoot\sessions\2026\05\29")
      $data = Collect -Limits @{CodexRoot=$deepRoot} -Label deep-path
      $c = Bounds $data
      Assert ($c.readBytes -eq 0 -and $c.visitedEntries -eq 0 -and 'pathComponents' -in $c.limitHits -and '2026/05/29' -in $c.visitedDays) 'ancestor cap not enforced or rejected path unvisited'
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
