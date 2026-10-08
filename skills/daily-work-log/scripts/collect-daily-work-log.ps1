[CmdletBinding()]
param(
  [datetimeoffset]$From,
  [datetimeoffset]$To,
  [ValidateSet('session', 'scan', 'mixed')]
  [string]$SourceMode = 'session',
  [string[]]$ScanRoots = @(),
  [string]$Timezone = 'Asia/Taipei',
  [string]$OpenCodeLogRoot,
  [string]$OpenCodeStorageRoot,
  [string]$CodexRoot,
  [switch]$ProbeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GitRepoRootCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:NoisyDirectoryNames = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@('node_modules', '.output', 'dist', 'build', 'target', '.gradle', '.mvn', '.nuxt', '.next'),
  [System.StringComparer]::OrdinalIgnoreCase
)
$script:MaxGitMarkerDepth = 6
$script:MaxGitMarkers = 5000

function Add-WarningMessage {
  param(
    [System.Collections.Generic.List[string]]$List,
    [string]$Message
  )

  if (-not [string]::IsNullOrWhiteSpace($Message) -and -not $List.Contains($Message)) {
    $List.Add($Message)
  }
}

function Add-PathItem {
  param(
    [System.Collections.Generic.Dictionary[string, object]]$Map,
    [string]$Path,
    [string]$Source,
    [object]$SessionEvidence = $null
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $normalized = [System.IO.Path]::GetFullPath($Path)
  if (-not $Map.ContainsKey($normalized)) {
    $Map[$normalized] = [ordered]@{
      path = $normalized
      source = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      sessionEvidence = [System.Collections.Generic.List[object]]::new()
    }
  }

  $null = $Map[$normalized].source.Add($Source)
  if ($null -ne $SessionEvidence) {
    $Map[$normalized].sessionEvidence.Add($SessionEvidence)
  }
}

function Get-ObjectPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if (-not $property) {
    return $null
  }

  return $property.Value
}

function Test-RecordDirectory {
  param([string]$Path, [object]$Work = $null)

  # Probe 僅開啟已知入口的第一個 directory entry，不遞迴、不讀紀錄內容。
  $entry = [ordered]@{ path = $Path; available = $false; reason = 'not-found' }
  $enumerator = $null
  if ($null -ne $Work) { $Work.checkedPaths++ }
  try {
    if ([System.IO.Directory]::Exists($Path)) {
      $enumerator = [System.IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
      $hasEntry = $enumerator.MoveNext()
      if ($hasEntry -and $null -ne $Work) { $Work.visitedEntries++ }
      $entry.available = $true
      $entry.reason = 'readable-directory'
    }
  }
  catch { $entry.reason = 'unreadable-directory' }
  finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
  return [pscustomobject]$entry
}

function Get-SourceProbe {
  $homePath = [Environment]::GetFolderPath('UserProfile')
  $logPath = if ($OpenCodeLogRoot) { $OpenCodeLogRoot } else { Join-Path $homePath '.local\share\opencode\log' }
  $storagePath = if ($OpenCodeStorageRoot) { $OpenCodeStorageRoot } else { Join-Path $homePath '.local\share\opencode\storage' }
  $codexPath = if ($CodexRoot) { $CodexRoot } elseif ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homePath '.codex' }
  $sources = [ordered]@{}
  foreach ($name in @('opencode', 'codex')) {
    $probeWork = [ordered]@{ checkedPaths = 0; visitedEntries = 0; openedFiles = 0; readBytes = 0 }
    $entries = if ($name -eq 'opencode') {
      @((Test-RecordDirectory $logPath), (Test-RecordDirectory (Join-Path $storagePath 'directory-readme')))
    } else {
      @((Test-RecordDirectory (Join-Path $codexPath 'sessions') -Work $probeWork), (Test-RecordDirectory (Join-Path $codexPath 'archived_sessions') -Work $probeWork))
    }
    $cliAvailable = $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
    # Codex CLI 不提供本 collector 所需的非互動式歷史介面；僅紀錄入口能供 collection。
    $available = (@($entries | Where-Object available).Count -gt 0) -or ($name -eq 'opencode' -and $cliAvailable)
    $sources[$name] = [pscustomobject][ordered]@{
      available = $available
      cliAvailable = $cliAvailable
      reason = if (@($entries | Where-Object available).Count -gt 0) { 'local-records-readable' } elseif ($available) { 'db-cli-available' } else { 'no-readable-records' }
      entries = $entries
      readStatus = if ($available) { 'not-read' } else { 'unavailable' }
    }
    if ($name -eq 'codex') { $sources[$name] | Add-Member -NotePropertyName probeWork -NotePropertyValue $probeWork }
  }
  return $sources
}

function Write-CollectionState {
  param([string]$Status, [object]$Sources)
  [ordered]@{
    meta = [ordered]@{
      generatedAt = [datetimeoffset]::Now.ToString('o'); timezone = $Timezone
      from = $resolvedFrom.ToString('o'); to = $resolvedTo.ToString('o')
      sourceMode = $SourceMode; scanRoots = $ScanRoots; probeOnly = $false
      sources = $Sources; collectionStatus = $Status; canGenerateLog = $false
      ghAvailable = $false; ghViewer = $null
    }
    repos = @(); warnings = @($warnings); errors = @($errors)
  } | ConvertTo-Json -Depth 10
}

function Get-CodexFilesBounded {
  param([object]$Source, [datetimeoffset]$FromRange, [datetimeoffset]$ToRange)

  # Issue #28：可漏收，不能先掃全歷史再過濾。日期僅定位候選；已讀事件仍以 timestamp 為準。
  $coverage = [pscustomobject][ordered]@{
    complete = $false; strategy = 'date-partitions-no-cache'; archive = 'skipped'
    limits = [ordered]@{ days = 32; entries = 2048; files = 128; totalBytes = 16777216; fileBytes = 2097152; lineBytes = 65536; pathComponents = 64 }
    daysConsidered = 0; visitedEntries = 0; candidateFiles = 0; openedFiles = 0; readBytes = [long]0
    enumerationFailures = 0; selectedDays = [System.Collections.Generic.List[string]]::new()
    limitHits = [System.Collections.Generic.HashSet[string]]::new()
    skipped = [System.Collections.Generic.HashSet[string]]::new([string[]]@('archive', 'outside-date-partitions'))
  }
  $Source | Add-Member -NotePropertyName coverage -NotePropertyValue $coverage -Force
  $zone = Resolve-TimeZoneInfo -TimezoneId $Timezone
  $dates = @($FromRange.UtcDateTime.Date, $ToRange.UtcDateTime.Date,
    ([TimeZoneInfo]::ConvertTime($FromRange, $zone)).Date, ([TimeZoneInfo]::ConvertTime($ToRange, $zone)).Date)
  $first = ($dates | Measure-Object -Minimum).Minimum
  $last = ($dates | Measure-Object -Maximum).Maximum
  $dayCount = [int]($last - $first).TotalDays + 1
  if ($dayCount -gt $coverage.limits.days) { $null = $coverage.limitHits.Add('days') }
  $sessionRoot = @($Source.entries)[0].path
  for ($i = 0; $i -lt [Math]::Min($dayCount, $coverage.limits.days); $i++) {
    if ($coverage.visitedEntries -ge $coverage.limits.entries -or $coverage.candidateFiles -ge $coverage.limits.files -or $coverage.readBytes -ge $coverage.limits.totalBytes) { break }
    $day = $first.AddDays($i).ToString('yyyy/MM/dd', [Globalization.CultureInfo]::InvariantCulture)
    $coverage.daysConsidered++
    $coverage.selectedDays.Add($day)
    $path = Join-Path $sessionRoot $day
    if (-not (Test-CodexPartitionPath -Path $path -Coverage $coverage)) { continue }
    $enumerator = $null
    try {
      # 列舉全部 entry（連非 JSONL 也計數），達限即 Dispose；不排序、不遞迴、不 materialize。
      $enumerator = [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
      while ($coverage.visitedEntries -lt $coverage.limits.entries -and $coverage.candidateFiles -lt $coverage.limits.files -and $coverage.readBytes -lt $coverage.limits.totalBytes -and $enumerator.MoveNext()) {
        $coverage.visitedEntries++
        $attributes = [IO.File]::GetAttributes($enumerator.Current)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $null = $coverage.skipped.Add('reparse-points'); continue }
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $null = $coverage.skipped.Add('nested-directories'); continue }
        if ([IO.Path]::GetExtension($enumerator.Current) -ine '.jsonl') { continue }
        $coverage.candidateFiles++
        [IO.FileInfo]::new($enumerator.Current)
      }
    }
    catch { $coverage.enumerationFailures++ }
    finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
  }
  if ($coverage.visitedEntries -ge $coverage.limits.entries) { $null = $coverage.limitHits.Add('entries') }
  if ($coverage.candidateFiles -ge $coverage.limits.files) { $null = $coverage.limitHits.Add('files') }
  if ($coverage.readBytes -ge $coverage.limits.totalBytes) { $null = $coverage.limitHits.Add('totalBytes') }
}

function Test-CodexPartitionPath {
  param([string]$Path, [object]$Coverage)
  $current = [IO.Path]::GetFullPath($Path)
  # 檢查固定路徑的 ancestors 而非展開 junction；過深的入口也只做有限次 metadata 檢查。
  for ($depth = 0; $depth -lt $Coverage.limits.pathComponents; $depth++) {
    if (-not [IO.Directory]::Exists($current)) { return $false }
    if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      $null = $Coverage.skipped.Add('reparse-points'); return $false
    }
    $parent = [IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent -eq $current) { return $true }
    $current = $parent
  }
  $null = $Coverage.limitHits.Add('pathComponents')
  return $false
}

function Read-CodexLinesBounded {
  param([string]$Path, [object]$Coverage)
  $budget = [int][Math]::Min($Coverage.limits.fileBytes, $Coverage.limits.totalBytes - $Coverage.readBytes)
  if ($budget -le 0) { return }
  $stream = $null
  try {
    # 直接限制 FileStream.Read 的實際 bytes；不用可能先吞掉巨大單行的 StreamReader.ReadLine。
    $stream = [IO.FileStream]::new($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 1)
    $Coverage.openedFiles++
    $buffer = [byte[]]::new($budget)
    $count = 0
    while ($count -lt $budget) {
      $read = $stream.Read($buffer, $count, [Math]::Min(4096, $budget - $count))
      if ($read -eq 0) { break }
      $count += $read; $Coverage.readBytes += $read
    }
    $truncated = $stream.Position -lt $stream.Length
    if ($truncated) {
      $null = $Coverage.limitHits.Add($(if ($Coverage.readBytes -ge $Coverage.limits.totalBytes) { 'totalBytes' } else { 'fileBytes' }))
    }
    $start = 0
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    while ($start -lt $count) {
      $end = [Array]::IndexOf($buffer, [byte]10, $start, $count - $start)
      if ($end -lt 0) {
        if ($count - $start -gt $Coverage.limits.lineBytes) { $null = $Coverage.limitHits.Add('lineBytes'); break }
        if ($truncated) { break } # 未讀完的尾行不解析，避免 partial JSON／UTF-8 偽失敗。
        $end = $count
      }
      if ($end - $start -gt $Coverage.limits.lineBytes) { $null = $Coverage.limitHits.Add('lineBytes'); break }
      $line = $utf8.GetString($buffer, $start, $end - $start).TrimEnd([char]13)
      if ($start -eq 0) { $line = $line.TrimStart([char]0xfeff) }
      $line
      $start = $end + 1
    }
  }
  finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-CodexSessionDirectories {
  param([object]$Source, [datetimeoffset]$FromRange, [datetimeoffset]$ToRange,
    [System.Collections.Generic.List[string]]$Warnings)

  $events = [System.Collections.Generic.List[object]]::new()
  $parents = @{}
  $readCount = 0
  $failedCount = 0
  # Pipeline 逐一處理候選，讓全域 byte 預算在下一次 MoveNext 前生效。
  Get-CodexFilesBounded -Source $Source -FromRange $FromRange -ToRange $ToRange | ForEach-Object {
      $file = $_
      $sessionId = $file.FullName
      $cwd = $null
      $validTimedEvents = 0
      $fileFailed = $false
      try {
        foreach ($line in (Read-CodexLinesBounded -Path $file.FullName -Coverage $Source.coverage)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          try {
            $event = $line | ConvertFrom-Json
            if ($null -eq $event -or -not (Get-ObjectPropertyValue $event 'type')) { throw 'Invalid event' }
          }
          catch { $fileFailed = $true; continue }
          $type = [string](Get-ObjectPropertyValue $event 'type')
          $payload = Get-ObjectPropertyValue $event 'payload'
          if ($type -eq 'session_meta') {
            $id = [string](Get-ObjectPropertyValue $payload 'id')
            if ($id) { $sessionId = $id }
            foreach ($name in @('forked_from_id', 'parent_session_id', 'previous_session_id')) {
              $parent = [string](Get-ObjectPropertyValue $payload $name)
              if ($parent) { $parents[$sessionId] = $parent; break }
            }
            $sourceMetadata = Get-ObjectPropertyValue $payload 'source'
            $subagent = Get-ObjectPropertyValue $sourceMetadata 'subagent'
            $spawn = Get-ObjectPropertyValue $subagent 'thread_spawn'
            $spawnParent = [string](Get-ObjectPropertyValue $spawn 'parent_thread_id')
            if ($spawnParent) { $parents[$sessionId] = $spawnParent }
          }
          if ($type -in @('session_meta', 'turn_context')) {
            $path = [string](Get-ObjectPropertyValue $payload 'cwd')
            if ($path) { $cwd = $path }
            continue
          }
          $rawTime = Get-ObjectPropertyValue $event 'timestamp'
          try {
            $time = if ($rawTime -is [datetime]) { [datetimeoffset]$rawTime } else { [datetimeoffset]::Parse([string]$rawTime, [System.Globalization.CultureInfo]::InvariantCulture) }
          }
          catch { $fileFailed = $true; continue }
          $validTimedEvents++
          if ($time -lt $FromRange -or $time -gt $ToRange) { continue }
          $payloadType = [string](Get-ObjectPropertyValue $payload 'type')
          $text = $null
          $role = $null
          if ($type -eq 'event_msg' -and $payloadType -in @('user_message', 'agent_message')) {
            $text = [string](Get-ObjectPropertyValue $payload 'message')
            $role = if ($payloadType -eq 'user_message') { 'user' } else { 'assistant' }
          }
          elseif ($type -eq 'response_item' -and $payloadType -eq 'message') {
            $role = [string](Get-ObjectPropertyValue $payload 'role')
            if ($role -notin @('user', 'assistant')) { continue }
            $text = (@(Get-ObjectPropertyValue $payload 'content') | ForEach-Object {
              [string](Get-ObjectPropertyValue $_ 'text')
            }) -join "`n"
          }
          elseif ($type -eq 'response_item' -and $payloadType -in @('function_call', 'custom_tool_call')) {
            $text = 'tool: ' + [string](Get-ObjectPropertyValue $payload 'name')
            $role = 'tool'
          }
          if (-not $cwd -or [string]::IsNullOrWhiteSpace($text)) { continue }
          try { $path = [System.IO.Path]::GetFullPath($cwd) } catch { $fileFailed = $true; continue }
          $events.Add([pscustomobject]@{
            path = $path; sessionId = $sessionId; text = $text.Trim(); role = $role
            time = $time.ToString('o'); file = $file.FullName
          })
        }
        # 空入口／空檔／metadata-only 不算事件讀取成功，避免掩蓋另一入口的全部檔案失敗。
        if ($validTimedEvents -gt 0) { $readCount++ }
      }
      catch { $fileFailed = $true }
      if ($fileFailed) {
        $failedCount++
        Add-WarningMessage -List $Warnings -Message ('Some Codex events could not be read or parsed: {0}' -f $file.FullName)
      }
  }

  $failedCount += $Source.coverage.enumerationFailures
  if (@($Source.entries | Where-Object reason -eq 'unreadable-directory').Count -gt 0) { $failedCount++ }
  Add-WarningMessage -List $Warnings -Message ('Codex bounded coverage: archive and outside-date partitions skipped; limits={0}; skipped={1}; enumerationFailures={2}; completeness is not guaranteed.' -f ($Source.coverage.limitHits -join ','), ($Source.coverage.skipped -join ','), $Source.coverage.enumerationFailures)

  $groups = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
  foreach ($event in $events) {
    $family = $event.sessionId
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($parents.ContainsKey($family) -and $visited.Add($family)) { $family = $parents[$family] }
    # 精確文字去重涵蓋 event/response 鏡像、父子重播及同 ID 續行；語意主題由 skill 合併。
    $key = (@($event.path.ToUpperInvariant(), $family, $event.role, $event.text) | ConvertTo-Json -Compress)
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = [ordered]@{
        source = 'codex'; agent = 'codex'; path = $event.path; sessionId = $family
        title = $event.text.Substring(0, [Math]::Min(240, $event.text.Length)); role = $event.role
        sessionIds = [System.Collections.Generic.HashSet[string]]::new()
        files = [System.Collections.Generic.HashSet[string]]::new()
        timestamps = [System.Collections.Generic.HashSet[string]]::new()
      }
    }
    $group = $groups[$key]
    $null = $group.sessionIds.Add($event.sessionId)
    $null = $group.files.Add($event.file)
    $null = $group.timestamps.Add($event.time)
  }
  $Source.readStatus = if ($readCount -eq 0 -and $failedCount -gt 0) { 'failed' } elseif ($failedCount -gt 0 -or ($events.Count -gt 0 -and $Source.coverage.limitHits.Count -gt 0)) { 'partial' } elseif ($events.Count -gt 0) { 'success' } else { 'empty' }
  foreach ($group in $groups.Values) {
    $group.sessionIds = @($group.sessionIds | Sort-Object)
    $group.files = @($group.files | Sort-Object)
    $group.timestamps = @($group.timestamps | Sort-Object)
    New-SessionCandidate -Path $group.path -Evidence ([pscustomobject]$group)
  }
}

function New-SessionCandidate {
  param(
    [string]$Path,
    [object]$Evidence
  )

  return [ordered]@{
    path = $Path
    evidence = $Evidence
  }
}

function New-SessionEvidence {
  param(
    [string]$Source,
    [string]$Path,
    [object]$Session = $null
  )

  $evidence = [ordered]@{
    source = $Source
    agent = 'opencode'
    discoverySource = $Source
    path = $Path
  }

  foreach ($mapping in @(
    @{ Input = 'id'; Output = 'sessionId' },
    @{ Input = 'title'; Output = 'title' },
    @{ Input = 'time_created'; Output = 'timeCreated' },
    @{ Input = 'time_updated'; Output = 'timeUpdated' },
    @{ Input = 'updatedAt'; Output = 'updatedAt' }
  )) {
    $value = Get-ObjectPropertyValue -Object $Session -Name $mapping.Input
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
      $evidence[$mapping.Output] = $value
    }
  }

  return [pscustomobject]$evidence
}

function Copy-SessionEvidenceForSource {
  param(
    [object]$Evidence,
    [string]$Source
  )

  $copy = [ordered]@{ source = $Source }
  if ($Evidence -is [System.Collections.IDictionary]) {
    foreach ($key in @($Evidence.Keys)) {
      if ([string]$key -eq 'source') {
        continue
      }
      $copy[[string]$key] = $Evidence[$key]
    }
  }
  else {
    foreach ($property in @($Evidence.PSObject.Properties)) {
      if ($property.Name -eq 'source') {
        continue
      }
      $copy[$property.Name] = $property.Value
    }
  }

  return [pscustomobject]$copy
}

function Resolve-TimeZoneInfo {
  param([string]$TimezoneId)

  $ianaToWindows = @{
    'Asia/Taipei' = 'Taipei Standard Time'
  }

  foreach ($candidate in @($TimezoneId, $ianaToWindows[$TimezoneId])) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    try {
      return [System.TimeZoneInfo]::FindSystemTimeZoneById($candidate)
    }
    catch {
      continue
    }
  }

  throw ("Unsupported timezone: {0}" -f $TimezoneId)
}

function Resolve-DateRange {
  param(
    [AllowNull()]
    [Nullable[datetimeoffset]]$FromInput,
    [AllowNull()]
    [Nullable[datetimeoffset]]$ToInput,
    [string]$TimezoneId
  )

  if ($null -ne $FromInput -and $null -ne $ToInput) {
    return [ordered]@{ From = $FromInput; To = $ToInput }
  }

  $timeZoneInfo = Resolve-TimeZoneInfo -TimezoneId $TimezoneId
  $now = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $timeZoneInfo)
  $startLocal = [datetime]::new($now.Year, $now.Month, $now.Day, 0, 0, 0, [System.DateTimeKind]::Unspecified)
  $startOffset = $timeZoneInfo.GetUtcOffset($startLocal)
  $start = [datetimeoffset]::new($startLocal, $startOffset)
  $end = $start.AddDays(1).AddTicks(-1)

  if ($FromInput) { $start = $FromInput }
  if ($ToInput) { $end = $ToInput }

  return [ordered]@{ From = $start; To = $end }
}

function ConvertTo-EpochMilliseconds {
  param([datetimeoffset]$Value)

  return $Value.ToUniversalTime().ToUnixTimeMilliseconds()
}

function New-OpenCodeSessionSql {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange
  )

  $fromMilliseconds = ConvertTo-EpochMilliseconds -Value $FromRange
  $toMilliseconds = ConvertTo-EpochMilliseconds -Value $ToRange

  return ('select id, directory, path, title, time_created, time_updated from session where time_created <= {1} and time_updated >= {0} order by time_updated' -f $fromMilliseconds, $toMilliseconds)
}

function Get-OpenCodeLogRoot {
  param([string]$OverrideLogRoot)

  if (-not [string]::IsNullOrWhiteSpace($OverrideLogRoot)) {
    if (Test-Path -LiteralPath $OverrideLogRoot) {
      return (Get-Item -LiteralPath $OverrideLogRoot).FullName
    }

    return $null
  }

  $homePath = [Environment]::GetFolderPath('UserProfile')
  $candidate = Join-Path $homePath '.local\share\opencode\log'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Get-OpenCodeStorageRoot {
  param([string]$OverrideStorageRoot)

  if (-not [string]::IsNullOrWhiteSpace($OverrideStorageRoot)) {
    if (Test-Path -LiteralPath $OverrideStorageRoot) {
      return (Get-Item -LiteralPath $OverrideStorageRoot).FullName
    }

    return $null
  }

  $homePath = [Environment]::GetFolderPath('UserProfile')
  $candidate = Join-Path $homePath '.local\share\opencode\storage'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Read-SharedTextFile {
  param([string]$Path)

  $fileStream = [System.IO.FileStream]::new(
    $Path,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
  )

  try {
    $reader = [System.IO.StreamReader]::new($fileStream)
    try {
      return $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $fileStream.Dispose()
  }
}

function Resolve-GitRepoRootFromPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  try {
    $cacheKey = [System.IO.Path]::GetFullPath($Path)
  }
  catch {
    return $null
  }

  if ($script:GitRepoRootCache.ContainsKey($cacheKey)) {
    return $script:GitRepoRootCache[$cacheKey]
  }

  $repoRoot = Resolve-GitRepoRoot -Path $cacheKey
  $script:GitRepoRootCache[$cacheKey] = $repoRoot
  return $repoRoot
}

function TryParse-LogLineTimestamp {
  param([string]$Line)

  $match = [regex]::Match($Line, '^INFO\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})')
  if (-not $match.Success) {
    return $null
  }

  try {
    return [datetime]::ParseExact(
      $match.Groups[1].Value,
      'yyyy-MM-ddTHH:mm:ss',
      [System.Globalization.CultureInfo]::InvariantCulture
    )
  }
  catch {
    return $null
  }
}

function Get-PathCandidateFromLogLine {
  param([string]$Line)

  $directoryMatch = [regex]::Match($Line, 'service=default directory=(.+?) creating instance')
  if ($directoryMatch.Success) {
    return $directoryMatch.Groups[1].Value.Trim()
  }

  $permissionMatch = [regex]::Match($Line, 'permission=(external_directory|read|read-only) path=(.+)')
  if ($permissionMatch.Success) {
    return $permissionMatch.Groups[2].Value.Trim()
  }

  return $null
}

function Test-LogEventInRange {
  param(
    [AllowNull()]
    $EventTime,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [string]$TimezoneId
  )

  if ($null -eq $EventTime) {
    return $false
  }

  $timeZoneInfo = Resolve-TimeZoneInfo -TimezoneId $TimezoneId
  $eventDateTime = [datetime]$EventTime
  $offset = $timeZoneInfo.GetUtcOffset($eventDateTime)
  $eventOffset = [datetimeoffset]::new($eventDateTime, $offset)
  return $eventOffset -ge $FromRange -and $eventOffset -le $ToRange
}

function Get-OpenCodeSessionRowsFromDb {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [System.Collections.Generic.List[string]]$Warnings,
    [ref]$Succeeded
  )

  $Succeeded.Value = $false

  if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode CLI not found; DB session discovery unavailable.'
    return @()
  }

  $sql = New-OpenCodeSessionSql -FromRange $FromRange -ToRange $ToRange
  try {
    $result = Invoke-Native -FilePath 'opencode' -Arguments @('db', '--format', 'json', $sql)
  }
  catch {
    Add-WarningMessage -List $Warnings -Message ("OpenCode DB session discovery failed: {0}" -f $_.Exception.Message)
    return @()
  }

  if ($result.ExitCode -ne 0) {
    Add-WarningMessage -List $Warnings -Message ("OpenCode DB session discovery failed: {0}" -f $result.StdErr)
    return @()
  }

  try {
    $rows = $result.StdOut | ConvertFrom-Json -NoEnumerate
    # 保留既有 single-row JSON 相容性；成功 [] 仍是權威空結果。
    if ($rows -isnot [array] -and $rows -isnot [pscustomobject]) { throw 'Expected session rows' }
    $rows = @($rows)
    $Succeeded.Value = $true
    $script:OpenCodeReadSucceeded = $true
    $script:OpenCodeActivityCount += $rows.Count
    return @($rows)
  }
  catch {
    Add-WarningMessage -List $Warnings -Message 'OpenCode DB session discovery returned invalid JSON.'
    return @()
  }
}

function Get-SessionDirectoriesFromDb {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [System.Collections.Generic.List[string]]$Warnings,
    [ref]$Succeeded
  )

  $dbSucceeded = $false
  $rows = Get-OpenCodeSessionRowsFromDb -FromRange $FromRange -ToRange $ToRange -Warnings $Warnings -Succeeded ([ref]$dbSucceeded)
  $Succeeded.Value = $dbSucceeded

  if (-not $dbSucceeded) {
    return @()
  }

  $paths = [System.Collections.Generic.List[object]]::new()
  $seenCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $unresolvedCount = 0

  if (@($rows).Count -eq 0) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode DB returned no sessions for the requested range; fallback discovery was not used.'
  }

  foreach ($row in @($rows)) {
    $seenCandidates.Clear()
    foreach ($propertyName in @('directory', 'path')) {
      $property = $row.PSObject.Properties[$propertyName]
      if (-not $property) {
        continue
      }

      $candidatePath = [string]$property.Value
      if ([string]::IsNullOrWhiteSpace($candidatePath)) {
        continue
      }

      try {
        $candidatePath = [System.IO.Path]::GetFullPath($candidatePath)
      }
      catch {
        $unresolvedCount += 1
        continue
      }

      if (-not $seenCandidates.Add($candidatePath)) {
        continue
      }

      $repoRoot = Resolve-GitRepoRootFromPath -Path $candidatePath
      if ($repoRoot) {
        $paths.Add((New-SessionCandidate -Path $repoRoot -Evidence (New-SessionEvidence -Source 'session' -Path $candidatePath -Session $row)))
      }
      elseif (-not $repoRoot) {
        if (Test-Path -LiteralPath $candidatePath -PathType Container) {
          $paths.Add((New-SessionCandidate -Path $candidatePath -Evidence (New-SessionEvidence -Source 'session' -Path $candidatePath -Session $row)))
        }
        else {
          $unresolvedCount += 1
        }
      }
    }
  }

  if ($unresolvedCount -gt 0) {
    Add-WarningMessage -List $Warnings -Message 'Some OpenCode DB session paths could not be resolved to git repositories.'
  }

  return $paths
}

function Get-SessionDirectories {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [string]$TimezoneId,
    [string]$OverrideLogRoot,
    [string]$OverrideStorageRoot,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $dbSucceeded = $false
  $dbPaths = Get-SessionDirectoriesFromDb -FromRange $FromRange -ToRange $ToRange -Warnings $Warnings -Succeeded ([ref]$dbSucceeded)
  if ($dbSucceeded) {
    return $dbPaths
  }

  Add-WarningMessage -List $Warnings -Message 'OpenCode db query failed; falling back to directory-readme session discovery.'
  $directoryReadmeSucceeded = $false
  $directoryReadmePaths = Get-SessionDirectoriesFromDirectoryReadme -FromRange $FromRange -ToRange $ToRange -OverrideStorageRoot $OverrideStorageRoot -Warnings $Warnings -Succeeded ([ref]$directoryReadmeSucceeded)
  if ($directoryReadmeSucceeded -and @($directoryReadmePaths).Count -gt 0) {
    return $directoryReadmePaths
  }

  return Get-SessionDirectoriesFromLogs -FromRange $FromRange -ToRange $ToRange -TimezoneId $TimezoneId -OverrideLogRoot $OverrideLogRoot -Warnings $Warnings
}

function Get-SessionDirectoriesFromDirectoryReadme {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [string]$OverrideStorageRoot,
    [System.Collections.Generic.List[string]]$Warnings,
    [ref]$Succeeded
  )

  $Succeeded.Value = $false
  $storageRoot = Get-OpenCodeStorageRoot -OverrideStorageRoot $OverrideStorageRoot
  if (-not $storageRoot) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode directory-readme discovery unavailable; falling back to log session discovery.'
    return @()
  }

  $directoryReadmeRoot = Join-Path $storageRoot 'directory-readme'
  if (-not (Test-Path -LiteralPath $directoryReadmeRoot)) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode directory-readme discovery unavailable; falling back to log session discovery.'
    return @()
  }

  $fromMilliseconds = ConvertTo-EpochMilliseconds -Value $FromRange
  $toMilliseconds = ConvertTo-EpochMilliseconds -Value $ToRange
  $paths = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $hadParseFailure = $false
  $unresolvedCount = 0

  try {
    $files = @(Get-ChildItem -LiteralPath $directoryReadmeRoot -File -Filter '*.json' -ErrorAction Stop | Sort-Object Name)
    if ($files.Count -eq 0) { $script:OpenCodeEmptyReadSucceeded = $true }
  }
  catch {
    $script:OpenCodeReadFailures++
    Add-WarningMessage -List $Warnings -Message 'OpenCode directory-readme discovery unavailable; falling back to log session discovery.'
    return @()
  }

  foreach ($file in $files) {
    try {
      $session = (Read-SharedTextFile -Path $file.FullName) | ConvertFrom-Json
    }
    catch {
      $hadParseFailure = $true
      $script:OpenCodeReadFailures++
      continue
    }

    if ($null -eq $session) {
      $hadParseFailure = $true
      $script:OpenCodeReadFailures++
      continue
    }

    $seen.Clear()

    $updatedAtProperty = $session.PSObject.Properties['updatedAt']
    $injectedPathsProperty = $session.PSObject.Properties['injectedPaths']
    if (-not $updatedAtProperty -or -not $injectedPathsProperty -or $null -eq $updatedAtProperty.Value) {
      $hadParseFailure = $true
      $script:OpenCodeReadFailures++
      continue
    }

    try {
      $updatedAtMilliseconds = [int64]$updatedAtProperty.Value
    }
    catch {
      $hadParseFailure = $true
      $script:OpenCodeReadFailures++
      continue
    }

    if (@($injectedPathsProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
      $script:OpenCodeEmptyReadSucceeded = $true
      continue
    }
    $script:OpenCodeReadSucceeded = $true
    if ($updatedAtMilliseconds -lt $fromMilliseconds -or $updatedAtMilliseconds -gt $toMilliseconds) {
      continue
    }

    $script:OpenCodeActivityCount++

    foreach ($candidatePath in @($injectedPathsProperty.Value)) {
      $candidate = [string]$candidatePath
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }

      $repoRoot = Resolve-GitRepoRootFromPath -Path $candidate
      if ($repoRoot -and $seen.Add($repoRoot)) {
        $paths.Add((New-SessionCandidate -Path $repoRoot -Evidence (New-SessionEvidence -Source 'directory-readme' -Path $candidate -Session $session)))
      }
      elseif (-not $repoRoot) {
        try {
          $candidate = [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
          $unresolvedCount += 1
          continue
        }

        if ((Test-Path -LiteralPath $candidate -PathType Container) -and $seen.Add($candidate)) {
          $paths.Add((New-SessionCandidate -Path $candidate -Evidence (New-SessionEvidence -Source 'directory-readme' -Path $candidate -Session $session)))
        }
        else {
          $unresolvedCount += 1
        }
      }
    }
  }

  if ($hadParseFailure) {
    Add-WarningMessage -List $Warnings -Message 'Some directory-readme files could not be parsed.'
  }

  if ($unresolvedCount -gt 0) {
    Add-WarningMessage -List $Warnings -Message 'Some OpenCode directory-readme paths could not be resolved to git repositories.'
  }

  if ($paths.Count -eq 0) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode directory-readme discovery found no resolvable git repositories; falling back to log session discovery.'
    return $paths
  }

  $Succeeded.Value = $true
  return $paths
}

function Get-SessionDirectoriesFromLogs {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [string]$TimezoneId,
    [string]$OverrideLogRoot,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $logRoot = Get-OpenCodeLogRoot -OverrideLogRoot $OverrideLogRoot
  if (-not $logRoot) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode log directory not found; session-derived repo discovery unavailable.'
    return @()
  }

  $paths = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $unresolvedCount = 0
  try {
    $logFiles = @(Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log' -ErrorAction Stop | Sort-Object Name)
    if ($logFiles.Count -eq 0) { $script:OpenCodeEmptyReadSucceeded = $true }
  }
  catch {
    $script:OpenCodeReadFailures++
    Add-WarningMessage -List $Warnings -Message ('Failed to enumerate OpenCode logs: {0}' -f $logRoot)
    return @()
  }
  foreach ($file in $logFiles) {
    $reader = $null
    try {
      $fileStream = [System.IO.FileStream]::new(
        $file.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      )
      $reader = [System.IO.StreamReader]::new($fileStream)

      while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) {
          continue
        }

        $eventTime = TryParse-LogLineTimestamp -Line $line
        if ($null -ne $eventTime) { $script:OpenCodeReadSucceeded = $true }
        $candidate = Get-PathCandidateFromLogLine -Line $line
        if ([string]::IsNullOrWhiteSpace($candidate)) {
          continue
        }

        if ($null -eq $eventTime) {
          if ($line -match '^INFO\s') {
            $script:OpenCodeReadFailures++
            Add-WarningMessage -List $Warnings -Message ("Invalid OpenCode path-event timestamp: {0}" -f $file.FullName)
          }
          continue
        }
        if (-not (Test-LogEventInRange -EventTime $eventTime -FromRange $FromRange -ToRange $ToRange -TimezoneId $TimezoneId)) {
          continue
        }

        $script:OpenCodeActivityCount++
        $repoRoot = Resolve-GitRepoRootFromPath -Path $candidate
        if ($repoRoot -and $seen.Add($repoRoot)) {
          $paths.Add((New-SessionCandidate -Path $repoRoot -Evidence (New-SessionEvidence -Source 'log' -Path $candidate)))
        }
        elseif (-not $repoRoot) {
          try {
            $candidate = [System.IO.Path]::GetFullPath($candidate)
          }
          catch {
            $unresolvedCount += 1
            continue
          }

          if (Test-Path -LiteralPath $candidate -PathType Container) {
            $nestedRepos = @(Get-NestedGitRepositories -Root $candidate -Warnings $Warnings)
            if (@($nestedRepos).Count -gt 0 -and $seen.Add($candidate)) {
              $paths.Add((New-SessionCandidate -Path $candidate -Evidence (New-SessionEvidence -Source 'log' -Path $candidate)))
              continue
            }
          }

          $unresolvedCount += 1
        }
      }
      $script:OpenCodeEmptyReadSucceeded = $true
    }
    catch {
      $script:OpenCodeReadFailures++
      Add-WarningMessage -List $Warnings -Message ("Failed to read OpenCode log: {0}" -f $file.FullName)
      continue
    }
    finally {
      if ($null -ne $reader) {
        $reader.Dispose()
      }
    }
  }

  if ($unresolvedCount -gt 0) {
    Add-WarningMessage -List $Warnings -Message 'Some OpenCode log session paths could not be resolved to git repositories.'
  }

  return $paths
}

function Get-ScanRepositories {
  param(
    [string[]]$Roots,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $repos = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) {
      Add-WarningMessage -List $Warnings -Message ("Scan root not found: {0}" -f $root)
      continue
    }

    try {
      if (Test-GitRepo -RepositoryPath $root) {
        $repoPath = (Get-Item -LiteralPath $root).FullName
        if ($seen.Add($repoPath)) {
          $repos.Add($repoPath)
        }
      }

      if (-not (Test-SafeExpansionRoot -Path $root)) {
        Add-WarningMessage -List $Warnings -Message ("Skipped unsafe scan root: {0}" -f $root)
        continue
      }

      foreach ($repoPath in @(Get-NestedGitRepositories -Root $root -Warnings $Warnings)) {
        if (-not [string]::IsNullOrWhiteSpace($repoPath) -and $seen.Add($repoPath)) {
          $repos.Add($repoPath)
        }
      }
    }
    catch {
      Add-WarningMessage -List $Warnings -Message ("Failed to scan git repos under: {0}" -f $root)
    }
  }

  return $repos
}

function Invoke-Native {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )

  $resolvedFilePath = $FilePath
  $resolvedArguments = [System.Collections.Generic.List[string]]::new()
  $appendOriginalArguments = $true
  $command = Get-Command $FilePath -ErrorAction SilentlyContinue
  if ($command -and $command.Source -and [System.IO.Path]::GetExtension($command.Source) -ieq '.ps1') {
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCommand -and $pwshCommand.Source) {
      $resolvedFilePath = $pwshCommand.Source
      $scriptPathBytes = [System.Text.Encoding]::UTF8.GetBytes($command.Source)
      $scriptPathBase64 = [Convert]::ToBase64String($scriptPathBytes)
      $argumentJson = @($Arguments) | ConvertTo-Json -Compress
      $argumentBytes = [System.Text.Encoding]::UTF8.GetBytes($argumentJson)
      $argumentBase64 = [Convert]::ToBase64String($argumentBytes)
      $encodedCommandText = @"
`$scriptPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPathBase64'))
`$argumentJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$argumentBase64'))
`$scriptArguments = @(`$argumentJson | ConvertFrom-Json)
& `$scriptPath @scriptArguments
exit `$LASTEXITCODE
"@
      $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($encodedCommandText))
      $null = $resolvedArguments.Add('-NoProfile')
      $null = $resolvedArguments.Add('-EncodedCommand')
      $null = $resolvedArguments.Add($encodedCommand)
      $appendOriginalArguments = $false
    }
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $resolvedFilePath
  foreach ($arg in $resolvedArguments) {
    $null = $psi.ArgumentList.Add($arg)
  }
  if ($appendOriginalArguments) {
    foreach ($arg in $Arguments) {
      $null = $psi.ArgumentList.Add($arg)
    }
  }
  if ($WorkingDirectory) {
    $psi.WorkingDirectory = $WorkingDirectory
  }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  $null = $process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  return [ordered]@{
    ExitCode = $process.ExitCode
    StdOut = $stdout.Trim()
    StdErr = $stderr.Trim()
  }
}

function Test-GitRepo {
  param([string]$RepositoryPath)
  try {
    $result = Invoke-Native -FilePath 'git' -Arguments @('rev-parse', '--is-inside-work-tree') -WorkingDirectory $RepositoryPath
    return $result.ExitCode -eq 0 -and $result.StdOut -eq 'true'
  }
  catch {
    return $false
  }
}

function Resolve-GitRepoRoot {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  try {
    $candidatePath = [System.IO.Path]::GetFullPath($Path)
  }
  catch {
    return $null
  }

  $current = $null
  if (Test-Path -LiteralPath $candidatePath -PathType Container) {
    $current = $candidatePath
  }
  elseif (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
    $current = Split-Path -Path $candidatePath -Parent
  }
  else {
    $current = Split-Path -Path $candidatePath -Parent
    while (-not [string]::IsNullOrWhiteSpace($current) -and -not (Test-Path -LiteralPath $current -PathType Container)) {
      $parent = Split-Path -Path $current -Parent
      if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
        $current = $null
        break
      }

      $current = $parent
    }

    if ([string]::IsNullOrWhiteSpace($current)) {
      return $null
    }
  }

  while (-not [string]::IsNullOrWhiteSpace($current)) {
    if (Test-GitRepo -RepositoryPath $current) {
      $result = Invoke-Native -FilePath 'git' -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $current
      if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
        return [System.IO.Path]::GetFullPath($result.StdOut)
      }

      return [System.IO.Path]::GetFullPath($current)
    }

    $parent = Split-Path -Path $current -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
      break
    }

    $current = $parent
  }

  return $null
}

function Test-SafeExpansionRoot {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
    return $false
  }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPath = ([System.IO.Path]::GetPathRoot($fullPath)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  }
  catch {
    return $false
  }

  if ($fullPath -ieq $rootPath) {
    return $false
  }

  $homePath = [Environment]::GetFolderPath('UserProfile')
  if (-not [string]::IsNullOrWhiteSpace($homePath)) {
    $normalizedHome = [System.IO.Path]::GetFullPath($homePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($fullPath -ieq $normalizedHome) {
      return $false
    }
  }

  return $true
}

function Test-NoisyGitMarkerPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  foreach ($segment in ([string]$Path -split '[\\/]')) {
    if ($script:NoisyDirectoryNames.Contains($segment)) {
      return $true
    }
  }

  return $false
}

function Find-GitMarkersBounded {
  param([string]$Root)

  $markers = [System.Collections.Generic.List[string]]::new()
  $pending = [System.Collections.Generic.Queue[object]]::new()
  $pending.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })
  $visitedDirectories = 0

  while ($pending.Count -gt 0 -and $visitedDirectories -lt $script:MaxGitMarkers) {
    $current = $pending.Dequeue()
    $visitedDirectories += 1

    $markerPath = Join-Path ([string]$current.Path) '.git'
    if (Test-Path -LiteralPath $markerPath) {
      $markers.Add((Get-Item -LiteralPath $markerPath -Force).FullName)
    }

    if ([int]$current.Depth -ge $script:MaxGitMarkerDepth) {
      continue
    }

    foreach ($child in @(Get-ChildItem -LiteralPath ([string]$current.Path) -Force -Directory -ErrorAction SilentlyContinue)) {
      if ($child.Name -eq '.git' -or $script:NoisyDirectoryNames.Contains($child.Name)) {
        continue
      }

      $pending.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = ([int]$current.Depth + 1) })
    }
  }

  return $markers
}

function Find-GitMarkersFast {
  param(
    [string]$Root,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $markers = [System.Collections.Generic.List[string]]::new()
  $seenMarkers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $rgCommand = Get-Command rg -ErrorAction SilentlyContinue
  if ($rgCommand) {
    $rgArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('--files', '-uu', '--max-depth', ([string]$script:MaxGitMarkerDepth), '-g', '.git')) {
      $rgArgs.Add($arg)
    }
    foreach ($name in $script:NoisyDirectoryNames) {
      $rgArgs.Add('-g')
      $rgArgs.Add(('!{0}/**' -f $name))
    }
    $rgArgs.Add($Root)

    $result = Invoke-Native -FilePath 'rg' -Arguments @($rgArgs) -WorkingDirectory $Root
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
      foreach ($marker in @($result.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (Test-NoisyGitMarkerPath -Path $marker) {
          continue
        }
        if ($markers.Count -ge $script:MaxGitMarkers) {
          Add-WarningMessage -List $Warnings -Message ("Git marker discovery hit result limit under: {0}" -f $Root)
          break
        }
        if ($seenMarkers.Add([string]$marker)) {
          $markers.Add([string]$marker)
        }
      }
    }
    if ($result.ExitCode -gt 1) {
      Add-WarningMessage -List $Warnings -Message ("rg git marker discovery failed under: {0}" -f $Root)
    }
  }

  foreach ($marker in @(Find-GitMarkersBounded -Root $Root)) {
    if (Test-NoisyGitMarkerPath -Path $marker) {
      continue
    }
    if ($markers.Count -ge $script:MaxGitMarkers) {
      Add-WarningMessage -List $Warnings -Message ("Git marker discovery hit result limit under: {0}" -f $Root)
      break
    }
    if ($seenMarkers.Add([string]$marker)) {
      $markers.Add([string]$marker)
    }
  }

  return @($markers)
}

function Get-NestedGitRepositories {
  param(
    [string]$Root,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $repos = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  if (-not (Test-SafeExpansionRoot -Path $Root)) {
    return $repos
  }

  foreach ($marker in @(Find-GitMarkersFast -Root $Root -Warnings $Warnings)) {
    $markerPath = if ([System.IO.Path]::IsPathRooted([string]$marker)) { [string]$marker } else { Join-Path $Root ([string]$marker) }
    if (Test-NoisyGitMarkerPath -Path $markerPath) {
      continue
    }
    $repoCandidate = Split-Path -Path $markerPath -Parent
    if ([string]::IsNullOrWhiteSpace($repoCandidate)) {
      continue
    }

    $resolved = Resolve-GitRepoRoot -Path $repoCandidate
    if (-not [string]::IsNullOrWhiteSpace($resolved) -and $seen.Add($resolved)) {
      $repos.Add($resolved)
    }
  }

  return $repos
}

function Resolve-SessionCandidatePaths {
  param(
    [string]$Path,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $items = [System.Collections.Generic.List[object]]::new()
  $repoRoot = Resolve-GitRepoRootFromPath -Path $Path
  if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
    $items.Add([ordered]@{ path = $repoRoot; source = 'session' })
    return $items
  }

  if (Test-Path -LiteralPath $Path -PathType Container) {
    if (Test-SafeExpansionRoot -Path $Path) {
      foreach ($nestedRepo in Get-NestedGitRepositories -Root $Path -Warnings $Warnings) {
        $items.Add([ordered]@{ path = $nestedRepo; source = 'session-expanded' })
      }
    }
    else {
      Add-WarningMessage -List $Warnings -Message ("Skipped unsafe session expansion root: {0}" -f $Path)
    }
  }

  return $items
}

function Parse-GithubRepo {
  param([string]$RemoteUrl)
  if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    return $null
  }

  $match = [regex]::Match($RemoteUrl, 'github\.com[:/](.+?)/(.+?)(?:\.git)?$')
  if ($match.Success) {
    return ('{0}/{1}' -f $match.Groups[1].Value, $match.Groups[2].Value)
  }

  return $null
}

function Get-NativeStdOutOrNull {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )

  try {
    $result = Invoke-Native -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
      return $result.StdOut.Trim()
    }
  }
  catch {
    return $null
  }

  return $null
}

function Resolve-CurrentIdentity {
  param([string]$WorkingDirectory)

  $ghLogin = Get-NativeStdOutOrNull -FilePath 'gh' -Arguments @('api', 'user', '--jq', '.login') -WorkingDirectory $WorkingDirectory
  $ghName = Get-NativeStdOutOrNull -FilePath 'gh' -Arguments @('api', 'user', '--jq', '.name') -WorkingDirectory $WorkingDirectory
  $gitName = Get-NativeStdOutOrNull -FilePath 'git' -Arguments @('config', '--get', 'user.name') -WorkingDirectory $WorkingDirectory
  $gitEmail = Get-NativeStdOutOrNull -FilePath 'git' -Arguments @('config', '--get', 'user.email') -WorkingDirectory $WorkingDirectory

  $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($token in @($ghLogin, $ghName, $gitName, $gitEmail)) {
    if (-not [string]::IsNullOrWhiteSpace($token)) {
      $null = $tokens.Add($token.Trim())
    }
  }

  return [ordered]@{
    ghLogin = $ghLogin
    ghName = $ghName
    gitName = $gitName
    gitEmail = $gitEmail
    tokens = @($tokens)
    canFilter = $tokens.Count -gt 0
  }
}

function Test-CommitMatchesIdentity {
  param(
    [object]$Commit,
    [object]$CurrentIdentity
  )

  if (-not $CurrentIdentity -or -not $CurrentIdentity.canFilter) {
    return $true
  }

  foreach ($candidate in @($Commit.author, $Commit.authorEmail)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    foreach ($token in @($CurrentIdentity.tokens)) {
      if (-not [string]::IsNullOrWhiteSpace($token) -and $candidate.Trim() -ieq ([string]$token).Trim()) {
        return $true
      }
    }
  }

  return $false
}

function Test-BotAuthor {
  param([object]$Commit)

  return (($Commit.author -match '\[bot\]') -or ($Commit.authorEmail -match '\[bot\]|bot@|github-actions'))
}

function Test-ReleaseOrDeploySubject {
  param([string]$Subject)

  if ([string]::IsNullOrWhiteSpace($Subject)) { return $false }
  return $Subject -match '(?i)\b(release|deploy)\b'
}

function Get-IssueTokensFromCommit {
  param([object]$Commit)

  $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($issue in @($Commit.issuesMentioned)) {
    if (-not [string]::IsNullOrWhiteSpace($issue)) { $null = $tokens.Add([string]$issue) }
  }
  return $tokens
}

function Get-BranchHintsFromRefs {
  param([string]$Refs)

  $hints = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($fragment in ($Refs -split ',')) {
    $token = $fragment.Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
      continue
    }

    if ($token -like 'HEAD -> *') {
      $token = $token.Substring(8).Trim()
    }

    if ($token -like 'origin/*') {
      $null = $hints.Add($token.Substring(7))
    }

    if ($token -notlike 'tag:*' -and $token -ne 'HEAD') {
      $null = $hints.Add($token)
    }
  }

  return @($hints | Sort-Object)
}

function Get-CommitData {
  param(
    [string]$RepositoryPath,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [object]$CurrentIdentity
  )

  $format = '%H%x1f%h%x1f%aI%x1f%an%x1f%ae%x1f%s%x1f%D%x1f__DWL_END__%x1e'
  $args = @(
    'log', '--all',
    ('--since={0}' -f $FromRange.ToString('o')),
    ('--until={0}' -f $ToRange.ToString('o')),
    ('--pretty=format:{0}' -f $format)
  )
  $result = Invoke-Native -FilePath 'git' -Arguments $args -WorkingDirectory $RepositoryPath
  if ($result.ExitCode -ne 0) {
    throw ("git log failed: {0}" -f $result.StdErr)
  }

  $allRecords = [System.Collections.Generic.List[object]]::new()
  $entries = $result.StdOut -split [char]0x1e
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $normalizedEntry = $entry.Trim("`r", "`n")
    $parts = $normalizedEntry.Split([char]0x1f)
    if ($parts.Count -lt 7) { continue }
    $refs = $parts[6]
    $subject = $parts[5]
    if ($refs -match 'refs/stash') { continue }
    if ($subject -match '^(index on|untracked files on) ') { continue }
    $issueMatches = [regex]::Matches(("{0} {1}" -f $subject, $refs), '#\d+')
    $issuesMentioned = [System.Collections.Generic.List[string]]::new()
    foreach ($issueMatch in $issueMatches) {
      if (-not $issuesMentioned.Contains($issueMatch.Value)) {
        $issuesMentioned.Add($issueMatch.Value)
      }
    }
    $commitRecord = [ordered]@{
      hash = $parts[0]
      short = $parts[1]
      date = $parts[2]
      author = $parts[3]
      authorEmail = $parts[4]
      subject = $subject
      refs = $refs
      branchHints = (Get-BranchHintsFromRefs -Refs $refs)
      issuesMentioned = $issuesMentioned
    }
    $allRecords.Add($commitRecord)
  }

  $currentRecords = [System.Collections.Generic.List[object]]::new()
  $currentRecordHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $currentIssueTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $allRecords) {
    if (Test-CommitMatchesIdentity -Commit $record -CurrentIdentity $CurrentIdentity) {
      $currentRecords.Add($record)
      $null = $currentRecordHashes.Add([string]$record.hash)
      foreach ($issueToken in Get-IssueTokensFromCommit -Commit $record) { $null = $currentIssueTokens.Add($issueToken) }
    }
  }

  if (-not $CurrentIdentity -or -not $CurrentIdentity.canFilter) { return $allRecords }

  foreach ($record in $allRecords) {
    if (-not (Test-BotAuthor -Commit $record)) { continue }
    if (-not (Test-ReleaseOrDeploySubject -Subject $record.subject)) { continue }
    foreach ($issueToken in Get-IssueTokensFromCommit -Commit $record) {
      if ($currentIssueTokens.Contains($issueToken) -and $currentRecordHashes.Add([string]$record.hash)) {
        $currentRecords.Add($record)
        break
      }
    }
  }

  return $currentRecords
}

function Get-PrDetails {
  param(
    [string]$RepositoryPath,
    [string]$GithubRepo,
    [int]$PrNumber,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $args = @(
    'pr', 'view', $PrNumber.ToString(), '--repo', $GithubRepo,
    '--json', 'number,commits'
  )
  $result = Invoke-Native -FilePath 'gh' -Arguments $args -WorkingDirectory $RepositoryPath
  if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
    Add-WarningMessage -List $Warnings -Message ("gh pr view failed for {0}#{1}: {2}" -f $GithubRepo, $PrNumber, $result.StdErr)
    return $null
  }

  try {
    return ($result.StdOut | ConvertFrom-Json)
  }
  catch {
    Add-WarningMessage -List $Warnings -Message ("gh pr view output was not valid JSON for {0}#{1}" -f $GithubRepo, $PrNumber)
    return $null
  }
}

function Test-PrMatchesCommits {
  param(
    [object[]]$Commits,
    [object]$Pr,
    [object]$PrDetails,
    [object]$CurrentIdentity,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange
  )

  $commitHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $branchHints = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($commit in $Commits) {
    if ($commit.hash) {
      $null = $commitHashes.Add([string]$commit.hash)
    }
    foreach ($hint in @($commit.branchHints)) {
      if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $null = $branchHints.Add([string]$hint)
      }
    }
    if ($commit.subject -match ("Merge pull request #{0}\b" -f $Pr.number)) {
      return $true
    }
    if ($commit.subject -match ("\(#{0}\)" -f $Pr.number)) {
      return $true
    }
  }

  if ($Pr.headRefName -and $branchHints.Contains([string]$Pr.headRefName)) {
    return $true
  }

  foreach ($prCommit in @($PrDetails.commits)) {
    $oid = $prCommit.oid
    if ($oid -and $commitHashes.Contains([string]$oid)) {
      return $true
    }
  }

  $prAuthor = if ($Pr.author) { [string]$Pr.author.login } else { $null }
  if (-not [string]::IsNullOrWhiteSpace($prAuthor) -and
      $CurrentIdentity -and
      -not [string]::IsNullOrWhiteSpace([string]$CurrentIdentity.ghLogin) -and
      $prAuthor -ieq [string]$CurrentIdentity.ghLogin) {
    foreach ($prCommit in @($PrDetails.commits)) {
      foreach ($dateProperty in @('committedDate', 'authoredDate')) {
        $rawDate = Get-ObjectPropertyValue -Object $prCommit -Name $dateProperty
        if ($null -eq $rawDate -or [string]::IsNullOrWhiteSpace([string]$rawDate)) {
          continue
        }

        try {
          $commitDate = [datetimeoffset]::Parse([string]$rawDate)
        }
        catch {
          continue
        }

        if ($commitDate -ge $FromRange -and $commitDate -le $ToRange) {
          return $true
        }
      }
    }
  }

  return $false
}

function Get-GhContext {
  param(
    [string]$RepositoryPath,
    [string]$GithubRepo,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [object[]]$Commits,
    [object]$CurrentIdentity,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $prs = [System.Collections.Generic.List[object]]::new()
  if ([string]::IsNullOrWhiteSpace($GithubRepo)) {
    return $prs
  }

  $search = 'updated:>={0} involves:@me' -f $FromRange.ToString('yyyy-MM-dd')
  $args = @(
    'pr', 'list', '--repo', $GithubRepo,
    '--state', 'all', '--limit', '100',
    '--search', $search,
    '--json', 'number,title,url,updatedAt,mergedAt,closedAt,state,isDraft,headRefName,baseRefName,closingIssuesReferences,author'
  )
  $result = Invoke-Native -FilePath 'gh' -Arguments $args -WorkingDirectory $RepositoryPath
  if ($result.ExitCode -ne 0) {
    Add-WarningMessage -List $Warnings -Message ("gh pr list failed for {0}: {1}" -f $GithubRepo, $result.StdErr)
    return $prs
  }

  if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
    return $prs
  }

  try {
    $rawPrs = $result.StdOut | ConvertFrom-Json
  }
  catch {
    Add-WarningMessage -List $Warnings -Message ("gh output was not valid JSON for {0}" -f $GithubRepo)
    return $prs
  }

  foreach ($pr in @($rawPrs)) {
    $updatedAt = $null
    try { $updatedAt = [datetimeoffset]::Parse($pr.updatedAt) } catch {}
    if ($updatedAt -and ($updatedAt -lt $FromRange -or $updatedAt -gt $ToRange)) {
      continue
    }

    $prDetails = Get-PrDetails -RepositoryPath $RepositoryPath -GithubRepo $GithubRepo -PrNumber ([int]$pr.number) -Warnings $Warnings
    if (-not $prDetails) {
      continue
    }

    if (-not (Test-PrMatchesCommits -Commits $Commits -Pr $pr -PrDetails $prDetails -CurrentIdentity $CurrentIdentity -FromRange $FromRange -ToRange $ToRange)) {
      continue
    }

    $issuesClosed = [System.Collections.Generic.List[int]]::new()
    foreach ($issue in @($pr.closingIssuesReferences)) {
      if ($null -ne $issue.number -and -not $issuesClosed.Contains([int]$issue.number)) {
        $issuesClosed.Add([int]$issue.number)
      }
    }

    $prs.Add([ordered]@{
      number = [int]$pr.number
      title = $pr.title
      state = $pr.state
      updatedAt = $pr.updatedAt
      mergedAt = $pr.mergedAt
      closedAt = $pr.closedAt
      url = $pr.url
      headRefName = $pr.headRefName
      baseRefName = $pr.baseRefName
      isDraft = [bool]$pr.isDraft
      author = if ($pr.author) { $pr.author.login } else { $null }
      closingIssuesReferences = @($pr.closingIssuesReferences)
      issuesClosed = $issuesClosed
    })
  }

  return $prs
}

$warnings = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$repoMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$sources = $null

try {
  $range = Resolve-DateRange -FromInput $From -ToInput $To -TimezoneId $Timezone
  $resolvedFrom = $range.From
  $resolvedTo = $range.To

  $sources = Get-SourceProbe
  if ($ProbeOnly) {
    [ordered]@{
      meta = [ordered]@{
        generatedAt = [datetimeoffset]::Now.ToString('o'); timezone = $Timezone
        from = $resolvedFrom.ToString('o'); to = $resolvedTo.ToString('o')
        sourceMode = $SourceMode; scanRoots = $ScanRoots; probeOnly = $true
        sources = $sources; canGenerateLog = $false
      }
      repos = @(); warnings = @(); errors = @()
    } | ConvertTo-Json -Depth 10
    return
  }

  if (-not $sources.opencode.available -and -not $sources.codex.available) {
    Add-WarningMessage -List $warnings -Message 'No usable agent sources; collection stopped before Git / GitHub discovery.'
    Write-CollectionState -Status 'no-sources' -Sources $sources
    return
  }

  $sessionCandidates = [System.Collections.Generic.List[object]]::new()
  if ($sources.opencode.available) {
    $script:OpenCodeReadSucceeded = $false
    $script:OpenCodeEmptyReadSucceeded = $false
    $script:OpenCodeReadFailures = 0
    $script:OpenCodeActivityCount = 0
    try {
      foreach ($candidate in @(Get-SessionDirectories -FromRange $resolvedFrom -ToRange $resolvedTo -TimezoneId $Timezone -OverrideLogRoot $OpenCodeLogRoot -OverrideStorageRoot $OpenCodeStorageRoot -Warnings $warnings)) {
        $sessionCandidates.Add($candidate)
      }
      # 空入口／空 log 只證明讀完，不能救回其他紀錄全失敗；DB 成功 [] 仍由成功旗標保留權威。
      $sources.opencode.readStatus = if (-not $script:OpenCodeReadSucceeded) {
        if ($script:OpenCodeReadFailures -eq 0 -and $script:OpenCodeEmptyReadSucceeded) { 'empty' } else { 'failed' }
      } elseif ($script:OpenCodeReadFailures -gt 0) { 'partial' } elseif ($script:OpenCodeActivityCount -gt 0) { 'success' } else { 'empty' }
    }
    catch {
      $sources.opencode.readStatus = 'failed'
      Add-WarningMessage -List $warnings -Message ('OpenCode session reader failed: {0}' -f $_.Exception.Message)
    }
  }
  if ($sources.codex.available) {
    # 各來源自行承擔讀取失敗，避免一個 reader 的例外阻斷另一個可用來源。
    try {
      foreach ($candidate in @(Get-CodexSessionDirectories -Source $sources.codex -FromRange $resolvedFrom -ToRange $resolvedTo -Warnings $warnings)) {
        $sessionCandidates.Add($candidate)
      }
    }
    catch {
      $sources.codex.readStatus = 'failed'
      Add-WarningMessage -List $warnings -Message ('Codex session reader failed: {0}' -f $_.Exception.Message)
    }
  }
  $readableSources = @($sources.Values | Where-Object { $_.readStatus -in @('success', 'partial', 'empty') })
  if ($readableSources.Count -eq 0) {
    Add-WarningMessage -List $warnings -Message 'All available agent sources failed to read; collection stopped before Git / GitHub discovery.'
    Write-CollectionState -Status 'read-failed' -Sources $sources
    return
  }
  $hasGap = @($sources.Values | Where-Object { $_.readStatus -in @('failed', 'partial') -or @($_.entries | Where-Object reason -eq 'unreadable-directory').Count -gt 0 }).Count -gt 0
  $collectionStatus = if ($hasGap) { 'partial' } else { 'success' }
  foreach ($name in $sources.Keys) {
    if ($sources[$name].readStatus -in @('unavailable', 'failed', 'partial')) {
      Add-WarningMessage -List $warnings -Message ('{0} source: {1} ({2}); coverage is incomplete.' -f $name, $sources[$name].readStatus, $sources[$name].reason)
    }
  }
  if ($SourceMode -eq 'session' -and $sessionCandidates.Count -eq 0) {
    Write-CollectionState -Status $(if ($hasGap) { 'partial' } else { 'no-activity' }) -Sources $sources
    return
  }
  if ($SourceMode -in @('session', 'mixed')) {
    $unresolvedSessionPathCount = 0
    foreach ($sessionCandidate in $sessionCandidates) {
      $path = [string]$sessionCandidate.path
      $resolvedItems = @(Resolve-SessionCandidatePaths -Path $path -Warnings $warnings)
      if (@($resolvedItems).Count -eq 0) {
        $unresolvedSessionPathCount++
        continue
      }

      foreach ($item in $resolvedItems) {
        $repoSource = if ($sessionCandidate.evidence.agent -eq 'codex') { 'codex' } else { $item.source }
        Add-PathItem -Map $repoMap -Path $item.path -Source $repoSource -SessionEvidence (Copy-SessionEvidenceForSource -Evidence $sessionCandidate.evidence -Source $repoSource)
      }
    }
    if ($unresolvedSessionPathCount -gt 0) {
      Add-WarningMessage -List $warnings -Message 'Some OpenCode session paths could not be resolved to git repositories.'
    }
  }

  if ($SourceMode -in @('scan', 'mixed') -and @($ScanRoots).Count -gt 0) {
    foreach ($path in Get-ScanRepositories -Roots $ScanRoots -Warnings $warnings) {
      Add-PathItem -Map $repoMap -Path $path -Source 'scan'
    }
  }

  if ($repoMap.Count -eq 0) {
    Add-WarningMessage -List $warnings -Message 'No candidate directories were discovered for the requested range.'
  }

  $ghAvailable = $false
  $ghViewer = $null
  $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
  if ($ghCommand) {
    $viewerResult = Invoke-Native -FilePath 'gh' -Arguments @('api', 'user', '--jq', '.login') -WorkingDirectory $PWD.Path
    if ($viewerResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($viewerResult.StdOut)) {
      $ghAvailable = $true
      $ghViewer = $viewerResult.StdOut
    }
    else {
      Add-WarningMessage -List $warnings -Message 'GitHub CLI is installed but not authenticated; PR / issue supplement unavailable.'
    }
  }
  else {
    Add-WarningMessage -List $warnings -Message 'GitHub CLI not found; PR / issue supplement unavailable.'
  }

  $currentIdentity = Resolve-CurrentIdentity -WorkingDirectory $PWD.Path
  $authorScope = if ($currentIdentity.canFilter) { 'current' } else { 'all' }
  if (-not $currentIdentity.canFilter) {
    Add-WarningMessage -List $warnings -Message 'Current author identity could not be resolved; author filtering was not applied.'
  }

  $repos = [System.Collections.Generic.List[object]]::new()
  foreach ($item in $repoMap.Values | Sort-Object path) {
    $repoPath = $item.path
    $repoSources = @($item.source | Sort-Object)
    $repoWarnings = [System.Collections.Generic.List[string]]::new()
    $repoName = Split-Path -Path $repoPath -Leaf
    $isGitRepo = Test-GitRepo -RepositoryPath $repoPath
    if (-not $isGitRepo) {
      $repos.Add([ordered]@{
        name = $repoName
        path = $repoPath
        source = $repoSources
        isGitRepo = $false
        commits = @()
        prs = @()
        sessionEvidence = @($item.sessionEvidence)
        warnings = @('Directory is not a git repository.')
      })
      continue
    }

    $commits = [System.Collections.Generic.List[object]]::new()
    $prs = [System.Collections.Generic.List[object]]::new()
    $githubRepo = $null

    try {
      $commits = Get-CommitData -RepositoryPath $repoPath -FromRange $resolvedFrom -ToRange $resolvedTo -CurrentIdentity $currentIdentity
    }
    catch {
      Add-WarningMessage -List $repoWarnings -Message $_.Exception.Message
    }

    if (@($commits).Count -eq 0) {
      if ($authorScope -eq 'current') {
        Add-WarningMessage -List $repoWarnings -Message 'No current-user commits found in the selected range.'
      }
      else {
        Add-WarningMessage -List $repoWarnings -Message 'No commits found in the selected range.'
      }

      $repos.Add([ordered]@{
        name = $repoName
        path = $repoPath
        source = $repoSources
        isGitRepo = $true
        githubRepo = $null
        commits = @($commits)
        prs = @($prs)
        sessionEvidence = @($item.sessionEvidence)
        warnings = $repoWarnings
      })
      continue
    }

    $remoteResult = Invoke-Native -FilePath 'git' -Arguments @('remote', 'get-url', 'origin') -WorkingDirectory $repoPath
    if ($remoteResult.ExitCode -eq 0) {
      $githubRepo = Parse-GithubRepo -RemoteUrl $remoteResult.StdOut
    }

    if ($ghAvailable) {
      $prs = Get-GhContext -RepositoryPath $repoPath -GithubRepo $githubRepo -FromRange $resolvedFrom -ToRange $resolvedTo -Commits $commits -CurrentIdentity $currentIdentity -Warnings $repoWarnings
    }

    $repos.Add([ordered]@{
      name = $repoName
      path = $repoPath
      source = $repoSources
      isGitRepo = $true
      githubRepo = $githubRepo
      commits = @($commits)
      prs = @($prs)
      sessionEvidence = @($item.sessionEvidence)
      warnings = $repoWarnings
    })
  }

  $payload = [ordered]@{
    meta = [ordered]@{
      generatedAt = [datetimeoffset]::Now.ToString('o')
      timezone = $Timezone
      from = $resolvedFrom.ToString('o')
      to = $resolvedTo.ToString('o')
      sourceMode = $SourceMode
      probeOnly = $false
      sources = $sources
      collectionStatus = $collectionStatus
      canGenerateLog = $repos.Count -gt 0
      scanRoots = $ScanRoots
      ghAvailable = $ghAvailable
      ghViewer = $ghViewer
      authorScope = $authorScope
      currentIdentity = [ordered]@{
        ghLogin = $currentIdentity.ghLogin
        ghName = $currentIdentity.ghName
        gitName = $currentIdentity.gitName
        gitEmail = $currentIdentity.gitEmail
      }
    }
    repos = $repos
    warnings = $warnings
    errors = $errors
  }

  $payload | ConvertTo-Json -Depth 8
}
catch {
  $errors.Add($_.Exception.Message)
  [ordered]@{
    meta = [ordered]@{
      generatedAt = [datetimeoffset]::Now.ToString('o')
      timezone = $Timezone
      from = if ($From) { $From.ToString('o') } else { $null }
      to = if ($To) { $To.ToString('o') } else { $null }
      sourceMode = $SourceMode
      scanRoots = $ScanRoots
      probeOnly = [bool]$ProbeOnly
      sources = $sources
      collectionStatus = 'error'
      canGenerateLog = $false
      ghAvailable = $false
      ghViewer = $null
      authorScope = 'all'
      currentIdentity = [ordered]@{
        ghLogin = $null
        ghName = $null
        gitName = $null
        gitEmail = $null
      }
    }
    repos = @()
    warnings = $warnings
    errors = $errors
  } | ConvertTo-Json -Depth 8
}
