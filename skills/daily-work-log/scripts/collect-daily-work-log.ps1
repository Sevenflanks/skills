[CmdletBinding()]
param(
  [datetimeoffset]$From,
  [datetimeoffset]$To,
  [ValidateSet('session', 'scan', 'mixed')]
  [string]$SourceMode = 'session',
  [string[]]$ScanRoots = @(),
  [string]$Timezone = 'Asia/Taipei',
  [string]$OpenCodeLogRoot,
  [string]$OpenCodeStorageRoot
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
    $rows = $result.StdOut | ConvertFrom-Json
    $Succeeded.Value = $true
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
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $seenCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $unresolvedCount = 0

  if (@($rows).Count -eq 0) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode DB returned no sessions for the requested range; fallback discovery was not used.'
  }

  foreach ($row in @($rows)) {
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
      if ($repoRoot -and $seen.Add($repoRoot)) {
        $paths.Add((New-SessionCandidate -Path $repoRoot -Evidence (New-SessionEvidence -Source 'session' -Path $candidatePath -Session $row)))
      }
      elseif (-not $repoRoot) {
        if ((Test-Path -LiteralPath $candidatePath -PathType Container) -and $seen.Add($candidatePath)) {
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
    $files = Get-ChildItem -LiteralPath $directoryReadmeRoot -File -Filter '*.json' | Sort-Object Name
  }
  catch {
    Add-WarningMessage -List $Warnings -Message 'OpenCode directory-readme discovery unavailable; falling back to log session discovery.'
    return @()
  }

  foreach ($file in $files) {
    try {
      $session = (Read-SharedTextFile -Path $file.FullName) | ConvertFrom-Json
    }
    catch {
      $hadParseFailure = $true
      continue
    }

    if ($null -eq $session) {
      $hadParseFailure = $true
      continue
    }

    $updatedAtProperty = $session.PSObject.Properties['updatedAt']
    if (-not $updatedAtProperty) {
      continue
    }

    try {
      $updatedAtMilliseconds = [int64]$updatedAtProperty.Value
    }
    catch {
      continue
    }

    if ($updatedAtMilliseconds -lt $fromMilliseconds -or $updatedAtMilliseconds -gt $toMilliseconds) {
      continue
    }

    $injectedPathsProperty = $session.PSObject.Properties['injectedPaths']
    if (-not $injectedPathsProperty) {
      continue
    }

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
  $logFiles = Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log' | Sort-Object Name
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

        $candidate = Get-PathCandidateFromLogLine -Line $line
        if ([string]::IsNullOrWhiteSpace($candidate)) {
          continue
        }

        $eventTime = TryParse-LogLineTimestamp -Line $line
        if (-not (Test-LogEventInRange -EventTime $eventTime -FromRange $FromRange -ToRange $ToRange -TimezoneId $TimezoneId)) {
          continue
        }

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
    }
    catch {
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

try {
  $range = Resolve-DateRange -FromInput $From -ToInput $To -TimezoneId $Timezone
  $resolvedFrom = $range.From
  $resolvedTo = $range.To

  if ($SourceMode -in @('session', 'mixed')) {
    $unresolvedSessionPathCount = 0
    foreach ($sessionCandidate in Get-SessionDirectories -FromRange $resolvedFrom -ToRange $resolvedTo -TimezoneId $Timezone -OverrideLogRoot $OpenCodeLogRoot -OverrideStorageRoot $OpenCodeStorageRoot -Warnings $warnings) {
      $path = [string]$sessionCandidate.path
      $resolvedItems = @(Resolve-SessionCandidatePaths -Path $path -Warnings $warnings)
      if (@($resolvedItems).Count -eq 0) {
        $unresolvedSessionPathCount++
        continue
      }

      foreach ($item in $resolvedItems) {
        Add-PathItem -Map $repoMap -Path $item.path -Source $item.source -SessionEvidence (Copy-SessionEvidenceForSource -Evidence $sessionCandidate.evidence -Source $item.source)
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
    $sources = @($item.source | Sort-Object)
    $repoWarnings = [System.Collections.Generic.List[string]]::new()
    $repoName = Split-Path -Path $repoPath -Leaf
    $isGitRepo = Test-GitRepo -RepositoryPath $repoPath
    if (-not $isGitRepo) {
      $repos.Add([ordered]@{
        name = $repoName
        path = $repoPath
        source = $sources
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
        source = $sources
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
      source = $sources
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
