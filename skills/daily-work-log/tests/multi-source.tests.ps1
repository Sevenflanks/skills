[CmdletBinding()]
param([string]$Case = 'probe', [string]$EvidenceRoot)

# 僅合成資料；PATH 與全部紀錄入口隔離，絕不讀取使用者的 transcripts。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Case -eq 'all') {
  foreach ($name in @('probe', 'guard', 'empty-failed', 'codex', 'partial', 'opencode', 'merge', 'formatter', 'read-failures', 'archive-only', 'db-fallback', 'source-isolation', 'timestamp-failure', 'valid-empty-events', 'timestamp-partial', 'empty-sibling-failures', 'all-empty-entries', 'opencode-empty-sibling-failures', 'opencode-empty-authority')) {
    & $PSCommandPath -Case $name -EvidenceRoot $EvidenceRoot
  }
  return
}
$collector = Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'
$formatter = Join-Path $PSScriptRoot '..\scripts\format-daily-work-log-evidence.ps1'
$pwsh = (Get-Command pwsh).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-synthetic-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH

function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Write-Fixture([string]$Path, [string]$Content) {
  $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
  [IO.File]::WriteAllText($Path, $Content)
}
function Invoke-Json([switch]$Probe, [string]$Mode = 'session') {
  $args = @('-NoProfile', '-File', $collector, '-From', '2026-05-29T00:00:00+08:00', '-To', '2026-05-29T23:59:59+08:00',
    '-OpenCodeLogRoot', "$root\logs", '-OpenCodeStorageRoot', "$root\storage", '-CodexRoot', "$root\codex", '-SourceMode', $Mode,
    '-ScanRoots', "$root\repo")
  if ($Probe) { $args += '-ProbeOnly' }
  $raw = & $pwsh @args
  Assert ($LASTEXITCODE -eq 0) 'collector process failed'
  $data = ($raw -join "`n") | ConvertFrom-Json
  if ($EvidenceRoot) { Write-Fixture "$EvidenceRoot\$Case-$(if ($Probe) {'probe'} else {'collection'}).json" ($raw -join "`n") }
  Assert (@($data.errors).Count -eq 0) ('collector errors: ' + ($data.errors -join '; '))
  return $data
}
function Add-Codex([string]$File = 'sessions\2020\old.jsonl', [string]$Id = 'parent', [string]$Parent = '', [string]$Time = '2026-05-29T02:00:00Z', [string]$Text = '修正合成登入流程') {
  $lines = @(
    @{timestamp='2020-01-01T00:00:00Z'; type='session_meta'; payload=@{id=$Id; cwd="$root\repo"; forked_from_id=$Parent}},
    @{timestamp=$Time; type='event_msg'; payload=@{type='user_message'; message=$Text}},
    @{timestamp=$Time; type='response_item'; payload=@{type='message'; role='user'; content=@(@{type='input_text'; text=$Text})}}
  ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
  $path = "$root\codex\$File"
  Write-Fixture $path ($lines -join "`n")
  [IO.File]::SetLastWriteTime($path, [datetime]'2026-05-28T00:00:00')
}
function Add-OpenCode([string]$Result = '[]', [switch]$Fail) {
  $body = if ($Fail) { 'exit 1' } else { "'$($Result.Replace("'", "''"))'; exit 0" }
  Write-Fixture "$root\bin\opencode.ps1" ("param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Arguments)`n" + $body)
}

try {
  $null = [IO.Directory]::CreateDirectory("$root\bin")
  $null = [IO.Directory]::CreateDirectory("$root\repo")
  $env:PATH = "$root\bin;$(Split-Path -Parent $pwsh)"
  # git/gh 公開邊界 stub 記錄所有呼叫，讓 no-source guard 可觀察。
  $stub = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::AppendAllText('__CALLS__', ($Arguments -join ' ') + "`n")
if ($Arguments[0] -eq 'rev-parse') {
  if ($Arguments[1] -eq '--is-inside-work-tree') { 'true' } else { '__REPO__' }
  exit 0
}
if ($Arguments[0] -eq 'log') { exit 0 }
exit 1
'@
  $stub = $stub.Replace('__CALLS__', "$root\calls.txt").Replace('__REPO__', "$root\repo")
  Write-Fixture "$root\bin\git.ps1" $stub
  Write-Fixture "$root\bin\gh.ps1" $stub

  switch ($Case) {
    'probe' {
      foreach ($combination in @('none', 'opencode', 'codex', 'both')) {
        if ($combination -in @('opencode', 'both')) { $null = [IO.Directory]::CreateDirectory("$root\logs") }
        if ($combination -in @('codex', 'both')) { $null = [IO.Directory]::CreateDirectory("$root\codex\sessions") }
        $data = Invoke-Json -Probe
        Assert ($data.meta.probeOnly) 'probeOnly missing'
        Assert ($data.meta.sources.opencode.available -eq ($combination -in @('opencode', 'both'))) 'OpenCode availability mismatch'
        Assert ($data.meta.sources.codex.available -eq ($combination -in @('codex', 'both'))) 'Codex availability mismatch'
        Assert (-not $data.meta.sources.opencode.cliAvailable) 'unexpected OpenCode CLI'
        Assert (-not $data.meta.sources.codex.cliAvailable) 'unexpected Codex CLI'
        Assert (@($data.repos).Count -eq 0) 'probe collected repos'
        Assert (-not (Test-Path "$root\calls.txt")) 'probe invoked git/gh'
        if (Test-Path "$root\logs") { [IO.Directory]::Delete("$root\logs", $true) }
        if (Test-Path "$root\codex") { [IO.Directory]::Delete("$root\codex", $true) }
      }
      $cliStub = "param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Arguments)`n[IO.File]::WriteAllText('$root\calls.txt', 'CLI invoked'); exit 1"
      Write-Fixture "$root\bin\opencode.ps1" $cliStub
      Write-Fixture "$root\bin\codex.ps1" $cliStub
      $data = Invoke-Json -Probe
      Assert ($data.meta.sources.opencode.available -and $data.meta.sources.opencode.cliAvailable) 'OpenCode DB CLI entry unavailable'
      Assert ($data.meta.sources.codex.cliAvailable -and -not $data.meta.sources.codex.available) 'Codex CLI alone was treated as readable history'
      Assert (-not (Test-Path "$root\calls.txt")) 'probe invoked CLI'
    }
    'guard' {
      foreach ($mode in @('session', 'mixed', 'scan')) {
        $data = Invoke-Json -Mode $mode
        Assert ($data.meta.collectionStatus -eq 'no-sources') 'no source must stop'
        Assert (-not $data.meta.canGenerateLog) 'no sources allowed log'
        Assert (-not (Test-Path "$root\calls.txt")) 'no sources invoked git/gh'
      }
    }
    'empty-failed' {
      $null = [IO.Directory]::CreateDirectory("$root\codex\sessions")
      $data = Invoke-Json
      Assert ($data.meta.sources.codex.readStatus -eq 'empty') 'empty source classified as failure'
      Assert ($data.meta.collectionStatus -eq 'no-activity') 'empty activity status missing'
      Write-Fixture "$root\codex\sessions\bad.jsonl" '{broken'
      $data = Invoke-Json -Mode mixed
      Assert ($data.meta.sources.codex.readStatus -eq 'failed') 'malformed source classified as empty'
      Assert ($data.meta.collectionStatus -eq 'read-failed') 'all read failures must stop'
      Assert (-not $data.meta.canGenerateLog) 'failed collection allowed log'
      Assert (-not (Test-Path "$root\calls.txt")) 'failed/empty collection invoked git/gh'
    }
    'codex' {
      Add-Codex
      Add-Codex -File 'archived_sessions\child.jsonl' -Id child -Parent parent
      Add-Codex -File 'sessions\resume.jsonl'
      Add-Codex -File 'sessions\outside.jsonl' -Id outside -Time '2026-05-28T15:59:59Z'
      Add-Codex -File 'sessions\tomorrow.jsonl' -Id tomorrow -Time '2026-05-29T16:00:00Z'
      $data = Invoke-Json
      Assert ($data.meta.sources.codex.readStatus -eq 'success') 'Codex not collected'
      Assert (@($data.repos).Count -eq 1) 'repo not deduplicated'
      $evidence = @($data.repos[0].sessionEvidence)
      Assert ($evidence.Count -eq 1) 'parent/continuation duplicate topic'
      Assert (@($evidence[0].sessionIds).Count -eq 2) 'parent/child evidence lost'
      Assert (@($evidence[0].files).Count -eq 3) 'archive/resume evidence lost'
      Assert ($evidence[0].title -eq '修正合成登入流程') 'topic evidence missing'
      $compact = (($data | ConvertTo-Json -Depth 12) | & $pwsh -NoProfile -File $formatter) | ConvertFrom-Json
      Assert (@($compact.errors).Count -eq 0) 'formatter incompatible'
      Assert (@($compact.repos[0].sessionEvidence[0].files).Count -eq 3) 'formatter lost Codex evidence'
    }
    'partial' {
      Add-Codex
      Write-Fixture "$root\codex\archived_sessions\bad.jsonl" '{broken'
      Add-OpenCode -Fail
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'failed') 'OpenCode failure missing'
      Assert ($data.meta.sources.codex.readStatus -eq 'partial') 'Codex partial failure missing'
      Assert ($data.meta.collectionStatus -eq 'partial') 'global partial status missing'
      Assert ($data.meta.canGenerateLog) 'partial successful evidence blocked'
      Assert (@($data.warnings).Count -gt 0) 'partial gap not disclosed'
    }
    'opencode' {
      Write-Fixture "$root\logs\fallback.log" "INFO  2026-05-29T10:00:00 +1ms service=default directory=$root\repo creating instance"
      Add-OpenCode
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'empty') 'successful DB [] not authoritative'
      Assert (@($data.repos).Count -eq 0) 'DB [] fell back'
      Add-OpenCode -Fail
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'success') 'DB failure did not fall back to readable logs'
      Assert (@($data.repos).Count -eq 1) 'fallback evidence missing'
      [IO.File]::Delete("$root\bin\opencode.ps1")
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'success') 'no CLI readable OpenCode logs unavailable'
    }
    'merge' {
      Add-Codex
      $rows = @(@{id='one'; directory="$root\repo"; title='修正合成登入流程'}, @{id='two'; directory="$root\repo"; title='補上合成測試'}) | ConvertTo-Json -Compress
      Add-OpenCode $rows
      $data = Invoke-Json
      Assert (@($data.repos).Count -eq 1) 'cross-source repo duplicated'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 3) 'same repo session/source evidence lost'
      Assert (@($data.repos[0].sessionEvidence | Where-Object agent -eq codex).Count -eq 1) 'Codex evidence missing'
      Assert (@($data.repos[0].sessionEvidence | Where-Object agent -eq opencode).Count -eq 2) 'OpenCode evidence missing'
    }
    'formatter' {
      Add-Codex
      $rows = @(1..6 | ForEach-Object { @{id="session-$_"; directory="$root\repo"; title="合成工作 $_"} }) | ConvertTo-Json -Compress
      Add-OpenCode $rows
      $data = Invoke-Json
      $compact = (($data | ConvertTo-Json -Depth 12) | & $pwsh -NoProfile -File $formatter) | ConvertFrom-Json
      Assert (@($compact.repos[0].sessionEvidence).Count -eq 7) 'formatter truncated session/source evidence'
      Assert (@($compact.repos[0].sessionEvidence | Where-Object agent -eq codex).Count -eq 1) 'formatter dropped second agent'
    }
    'read-failures' {
      Add-Codex
      $locked = [IO.File]::Open("$root\codex\sessions\2020\old.jsonl", 'Open', 'ReadWrite', 'None')
      try {
        $probe = Invoke-Json -Probe
        Assert ($probe.meta.sources.codex.available) 'probe attempted to read locked transcripts'
        $data = Invoke-Json -Mode scan
        Assert ($data.meta.collectionStatus -eq 'read-failed') 'locked source treated as empty'
        Assert (-not (Test-Path "$root\calls.txt")) 'all read failures scanned git/gh'
      } finally { $locked.Dispose() }
      Write-Fixture "$root\logs\locked.log" 'synthetic inaccessible log'
      Add-OpenCode -Fail
      [IO.Directory]::Delete("$root\codex", $true)
      $locked = [IO.File]::Open("$root\logs\locked.log", 'Open', 'ReadWrite', 'None')
      try {
        $data = Invoke-Json
        Assert ($data.meta.sources.opencode.readStatus -eq 'failed') 'failed OpenCode logs treated as no activity'
        Assert ($data.meta.collectionStatus -eq 'read-failed') 'OpenCode failed source allowed log'
        Assert (-not (Test-Path "$root\calls.txt")) 'OpenCode read failures scanned git/gh'
      } finally { $locked.Dispose() }
    }
    'archive-only' {
      Add-Codex -File 'archived_sessions\only.jsonl' -Id child -Parent parent -Time '2026-05-28T16:00:00Z'
      Add-Codex -File 'archived_sessions\native-child.jsonl' -Id native -Time '2026-05-29T15:59:59Z'
      $nativeFile = "$root\codex\archived_sessions\native-child.jsonl"
      $lines = [IO.File]::ReadAllLines($nativeFile)
      $meta = $lines[0] | ConvertFrom-Json
      $meta.payload | Add-Member -NotePropertyName source -NotePropertyValue @{subagent=@{thread_spawn=@{parent_thread_id='parent'}}}
      $lines[0] = $meta | ConvertTo-Json -Depth 8 -Compress
      Write-Fixture $nativeFile ($lines -join "`n")
      $data = Invoke-Json
      Assert ($data.meta.sources.codex.available) 'archive-only unavailable'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 1) 'native parent metadata not deduplicated'
      Assert (@($data.repos[0].sessionEvidence[0].timestamps).Count -eq 2) 'inclusive timezone boundaries lost'
      Assert (@($data.repos[0].sessionEvidence[0].sessionIds).Count -eq 2) 'archive parent evidence lost'
    }
    'db-fallback' {
      Write-Fixture "$root\logs\fallback.log" "INFO  2026-05-29T10:00:00 +1ms service=default directory=$root\repo creating instance"
      Add-OpenCode '{invalid'
      $data = Invoke-Json
      Assert (@($data.repos).Count -eq 1) 'invalid DB JSON did not fall back'
      $record = @{updatedAt=1780010000000; injectedPaths=@("$root\repo")} | ConvertTo-Json -Compress
      Write-Fixture "$root\storage\directory-readme\record.json" $record
      Add-OpenCode -Fail
      $data = Invoke-Json
      Assert (@($data.repos).Count -eq 1) 'directory-readme fallback lost'
      Assert ($data.repos[0].sessionEvidence[0].updatedAt -eq 1780010000000) 'directory-readme evidence lost'
      [IO.File]::Delete("$root\bin\opencode.ps1")
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.available) 'CLI-less directory-readme source unavailable'
    }
    'source-isolation' {
      Add-Codex
      Add-OpenCode '[null]'
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'failed') 'unexpected OpenCode reader failure not isolated'
      Assert ($data.meta.sources.codex.readStatus -eq 'success') 'OpenCode reader exception blocked Codex'
      Assert ($data.meta.collectionStatus -eq 'partial') 'unexpected source failure gap missing'
      Assert (@($data.repos).Count -eq 1) 'remaining successful source not collected'
    }
    'timestamp-failure' {
      $badEvent = @{timestamp='broken'; type='event_msg'; payload=@{type='user_message'; message='合成活動'}} | ConvertTo-Json -Depth 5 -Compress
      foreach ($withMetadata in @($false, $true)) {
        $lines = @()
        if ($withMetadata) {
          $lines += (@{timestamp='2026-05-29T02:00:00Z'; type='session_meta'; payload=@{id='synthetic'; cwd="$root\repo"}} | ConvertTo-Json -Depth 5 -Compress)
        }
        $lines += $badEvent
        Write-Fixture "$root\codex\sessions\bad-time.jsonl" ($lines -join "`n")
        foreach ($mode in @('scan', 'mixed', 'session')) {
          $data = Invoke-Json -Mode $mode
          Assert ($data.meta.sources.codex.readStatus -eq 'failed') "bad activity timestamp escaped failure (metadata=$withMetadata, mode=$mode)"
          Assert ($data.meta.collectionStatus -eq 'read-failed') 'all timestamp failures did not stop collection'
          Assert (-not $data.meta.canGenerateLog) 'invalid timestamp allowed work log'
          Assert (@($data.repos).Count -eq 0) 'invalid timestamp collected repositories'
          Assert (-not (Test-Path "$root\calls.txt")) 'invalid timestamp invoked git/gh'
        }
      }
    }
    'valid-empty-events' {
      $meta = @{timestamp='2026-05-29T02:00:00Z'; type='session_meta'; payload=@{id='synthetic'; cwd="$root\repo"}} | ConvertTo-Json -Depth 5 -Compress
      $context = @{timestamp='2026-05-29T02:00:00Z'; type='turn_context'; payload=@{cwd="$root\repo"}} | ConvertTo-Json -Depth 5 -Compress
      $telemetry = @{timestamp='2026-05-29T02:00:00Z'; type='event_msg'; payload=@{type='token_count'; info=@{total_token_usage=@{input_tokens=10}}}} | ConvertTo-Json -Depth 6 -Compress
      foreach ($content in @('', $meta, ($meta + "`n" + $context), ($meta + "`n" + $telemetry))) {
        Write-Fixture "$root\codex\sessions\empty-session.jsonl" $content
        $data = Invoke-Json
        Assert ($data.meta.sources.codex.readStatus -eq 'empty') 'valid empty/metadata/non-activity session treated as failure'
        Assert ($data.meta.collectionStatus -eq 'no-activity') 'valid empty session lost no-activity status'
        Assert (-not $data.meta.canGenerateLog) 'empty session invented work log'
        Assert (-not (Test-Path "$root\calls.txt")) 'empty session invoked git/gh'
      }
    }
    'timestamp-partial' {
      Add-Codex -Time broken
      $validEvent = @{timestamp='2026-05-29T02:00:00Z'; type='event_msg'; payload=@{type='agent_message'; message='已完成合成修正'}} | ConvertTo-Json -Depth 5 -Compress
      [IO.File]::AppendAllText("$root\codex\sessions\2020\old.jsonl", "`n" + $validEvent)
      $data = Invoke-Json
      Assert ($data.meta.sources.codex.readStatus -eq 'partial') 'valid different event could not preserve partial result'
      Assert ($data.meta.canGenerateLog) 'valid activity blocked by bad sibling timestamp'
      Assert (@($data.repos[0].sessionEvidence).Count -eq 1) 'bad timestamp activity entered evidence'
      Assert ($data.repos[0].sessionEvidence[0].title -eq '已完成合成修正') 'valid different activity evidence missing'
      Add-Codex -Time '2026-05-28T15:59:59Z'
      $data = Invoke-Json
      Assert ($data.meta.sources.codex.readStatus -eq 'empty') 'valid out-of-range timestamp treated as failure'
      Assert (-not $data.meta.canGenerateLog) 'out-of-range activity entered work log'
    }
    'empty-sibling-failures' {
      $meta = @{timestamp='2026-05-29T02:00:00Z'; type='session_meta'; payload=@{id='empty'; cwd="$root\repo"}} | ConvertTo-Json -Depth 5 -Compress
      foreach ($failedEntry in @('sessions', 'archived_sessions')) {
        $emptyEntry = if ($failedEntry -eq 'sessions') { 'archived_sessions' } else { 'sessions' }
        foreach ($failure in @('bad', 'locked')) {
          foreach ($sibling in @('directory', 'file', 'metadata')) {
            if (Test-Path "$root\codex") { [IO.Directory]::Delete("$root\codex", $true) }
            $null = [IO.Directory]::CreateDirectory("$root\codex\$emptyEntry")
            if ($sibling -ne 'directory') { Write-Fixture "$root\codex\$emptyEntry\empty.jsonl" $(if ($sibling -eq 'metadata') { $meta } else { '' }) }
            $failedPath = "$root\codex\$failedEntry\failed.jsonl"
            Write-Fixture $failedPath $(if ($failure -eq 'locked') { $meta } else { '{broken' })
            $locked = $null
            try {
              if ($failure -eq 'locked') { $locked = [IO.File]::Open($failedPath, 'Open', 'ReadWrite', 'None') }
              foreach ($mode in @('scan', 'mixed', 'session')) {
                $data = Invoke-Json -Mode $mode
                $scenario = "$failedEntry-$failure-$sibling-$mode"
                if ($EvidenceRoot) { Write-Fixture "$EvidenceRoot\empty-sibling-$scenario.json" ($data | ConvertTo-Json -Depth 12) }
                Assert ($data.meta.sources.codex.readStatus -eq 'failed') "empty sibling masked all file failures: $scenario"
                Assert ($data.meta.collectionStatus -eq 'read-failed') "file failures escaped guard: $scenario"
                Assert (-not $data.meta.canGenerateLog) "file failures allowed log: $scenario"
                Assert (@($data.repos).Count -eq 0) "file failures collected repos: $scenario"
                Assert (-not (Test-Path "$root\calls.txt")) "file failures invoked git/gh: $scenario"
              }
            } finally { if ($null -ne $locked) { $locked.Dispose() } }
          }
        }
      }
    }
    'all-empty-entries' {
      $meta = @{timestamp='2026-05-29T02:00:00Z'; type='session_meta'; payload=@{id='empty'; cwd="$root\repo"}} | ConvertTo-Json -Depth 5 -Compress
      foreach ($content in @('directory', 'file', 'metadata')) {
        $null = [IO.Directory]::CreateDirectory("$root\codex\sessions")
        $null = [IO.Directory]::CreateDirectory("$root\codex\archived_sessions")
        if ($content -ne 'directory') {
          Write-Fixture "$root\codex\sessions\empty.jsonl" $(if ($content -eq 'metadata') { $meta } else { '' })
          Write-Fixture "$root\codex\archived_sessions\empty.jsonl" ''
        }
        $data = Invoke-Json
        Assert ($data.meta.sources.codex.readStatus -eq 'empty') "truly empty entries treated as failure: $content"
        Assert ($data.meta.collectionStatus -eq 'no-activity') "truly empty entries lost no-activity: $content"
        Assert (-not $data.meta.canGenerateLog) "truly empty entries allowed log: $content"
        Assert (-not (Test-Path "$root\calls.txt")) "truly empty entries invoked git/gh: $content"
      }
    }
    'opencode-empty-sibling-failures' {
      $emptyCache = @{updatedAt=1780010000000; injectedPaths=@()} | ConvertTo-Json -Compress
      $validCache = @{updatedAt=1780010000000; injectedPaths=@("$root\repo")} | ConvertTo-Json -Compress
      foreach ($failure in @('locked-log', 'bad-time-log', 'locked-cache', 'malformed-cache', 'missing-time-cache', 'bad-time-cache')) {
        foreach ($sibling in @('directory', 'empty-log', 'empty-cache')) {
          foreach ($path in @("$root\logs", "$root\storage")) { if (Test-Path $path) { [IO.Directory]::Delete($path, $true) } }
          $null = [IO.Directory]::CreateDirectory("$root\logs")
          $null = [IO.Directory]::CreateDirectory("$root\storage\directory-readme")
          if ($sibling -eq 'empty-log') { Write-Fixture "$root\logs\empty.log" '' }
          if ($sibling -eq 'empty-cache') { Write-Fixture "$root\storage\directory-readme\empty.json" $emptyCache }
          $failedPath = if ($failure -like '*-log') { "$root\logs\failed.log" } else { "$root\storage\directory-readme\failed.json" }
          $content = switch ($failure) {
            'locked-log' { "INFO  2026-05-29T10:00:00 +1ms service=default directory=$root\repo creating instance" }
            'bad-time-log' { "INFO  broken +1ms service=default directory=$root\repo creating instance" }
            'locked-cache' { $validCache }
            'malformed-cache' { '{broken' }
            'missing-time-cache' { @{injectedPaths=@("$root\repo")} | ConvertTo-Json -Compress }
            'bad-time-cache' { @{updatedAt='broken'; injectedPaths=@("$root\repo")} | ConvertTo-Json -Compress }
          }
          Write-Fixture $failedPath $content
          $locked = $null
          try {
            if ($failure -like 'locked-*') { $locked = [IO.File]::Open($failedPath, 'Open', 'ReadWrite', 'None') }
            foreach ($mode in @('scan', 'mixed', 'session')) {
              $data = Invoke-Json -Mode $mode
              $scenario = "$failure-$sibling-$mode"
              if ($EvidenceRoot) { Write-Fixture "$EvidenceRoot\opencode-empty-sibling-$scenario.json" ($data | ConvertTo-Json -Depth 12) }
              Assert ($data.meta.sources.opencode.readStatus -eq 'failed') "empty OpenCode sibling masked failures: $scenario"
              Assert ($data.meta.collectionStatus -eq 'read-failed') "OpenCode failure escaped guard: $scenario"
              Assert (-not $data.meta.canGenerateLog) "OpenCode failure allowed log: $scenario"
              Assert (@($data.repos).Count -eq 0) "OpenCode failure collected repos: $scenario"
              Assert (-not (Test-Path "$root\calls.txt")) "OpenCode failure invoked git/gh: $scenario"
            }
          } finally { if ($null -ne $locked) { $locked.Dispose() } }
        }
      }
    }
    'opencode-empty-authority' {
      $null = [IO.Directory]::CreateDirectory("$root\logs")
      $null = [IO.Directory]::CreateDirectory("$root\storage\directory-readme")
      foreach ($empty in @('directory', 'log', 'cache', 'noise')) {
        if ($empty -eq 'log') { Write-Fixture "$root\logs\empty.log" '' }
        if ($empty -eq 'cache') { Write-Fixture "$root\storage\directory-readme\empty.json" (@{updatedAt=1780010000000; injectedPaths=@()} | ConvertTo-Json -Compress) }
        if ($empty -eq 'noise') { Write-Fixture "$root\logs\noise.log" "permission=read path=$root\repo" }
        $data = Invoke-Json
        Assert ($data.meta.sources.opencode.readStatus -eq 'empty') "genuinely empty OpenCode treated as failed: $empty"
        Assert ($data.meta.collectionStatus -eq 'no-activity') 'empty OpenCode lost no-activity status'
        Assert (-not (Test-Path "$root\calls.txt")) 'empty OpenCode scanned git/gh'
      }
      Write-Fixture "$root\storage\directory-readme\bad.json" '{broken'
      Write-Fixture "$root\logs\locked.log" 'synthetic inaccessible log'
      $locked = [IO.File]::Open("$root\logs\locked.log", 'Open', 'ReadWrite', 'None')
      try {
        Add-OpenCode '[]'
        foreach ($mode in @('session', 'scan', 'mixed')) {
          $data = Invoke-Json -Mode $mode
          Assert ($data.meta.sources.opencode.readStatus -eq 'empty') 'DB [] not authoritative over failed files'
          Assert (@($data.warnings | Where-Object { $_ -match 'falling back|could not be parsed|Failed to read OpenCode log' }).Count -eq 0) 'DB [] read failed fallback sources'
        }
      } finally { $locked.Dispose() }
      [IO.File]::Delete("$root\logs\locked.log")
      Write-Fixture "$root\logs\valid.log" "INFO  2026-05-29T10:00:00 +1ms service=default directory=$root\repo creating instance"
      Add-OpenCode -Fail
      $data = Invoke-Json
      Assert ($data.meta.sources.opencode.readStatus -eq 'partial') 'genuine log record could not rescue partial cache failure'
      Assert ($data.meta.canGenerateLog) 'valid fallback activity was blocked'
      Assert (@($data.repos[0].sessionEvidence | Where-Object discoverySource -eq log).Count -eq 1) 'log fallback evidence missing'
    }
    default { throw "Unknown case: $Case" }
  }
  "PASS $Case"
}
finally {
  $env:PATH = $oldPath
  if (Test-Path $root) { [IO.Directory]::Delete($root, $true) }
}
