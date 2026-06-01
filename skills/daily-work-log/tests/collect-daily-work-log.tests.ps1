[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $skillRoot 'scripts\collect-daily-work-log.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('daily-work-log-test-' + [System.Guid]::NewGuid().ToString('N'))
$logRoot = Join-Path $tempRoot 'opencode-log'
$repoA = Join-Path $tempRoot 'repo-a'
$repoB = Join-Path $tempRoot 'repo-b'
$todayRepo = Join-Path $tempRoot 'repo-today'
$yesterdayRepo = Join-Path $tempRoot 'repo-yesterday'
$tomorrowRepo = Join-Path $tempRoot 'repo-tomorrow'
$externalRepo = Join-Path $tempRoot 'external-git'
$deletedReadRepo = Join-Path $tempRoot 'external-deleted-read-git'
$readOnlyRepo = Join-Path $tempRoot 'external-read-only-git'
$nonGitExternal = Join-Path $tempRoot 'external-plain'

function Write-Utf8NoBomFile {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Format-LogTimestamp {
  param([datetime]$Value)

  return $Value.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Assert-ContainsName {
  param(
    [object[]]$Names,
    [string]$Expected,
    [string]$Message
  )

  if (-not ($Names -contains $Expected)) {
    throw $Message
  }
}

function Assert-NotContainsName {
  param(
    [object[]]$Names,
    [string]$Unexpected,
    [string]$Message
  )

  if ($Names -contains $Unexpected) {
    throw $Message
  }
}

function Get-TaipeiNow {
  param([System.TimeZoneInfo]$TimeZone)

  return [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $TimeZone)
}

function Get-LocalDateTime {
  param(
    [datetimeoffset]$Value,
    [int]$Hour
  )

  return [datetime]::new($Value.Year, $Value.Month, $Value.Day, $Hour, 0, 0, [System.DateTimeKind]::Unspecified)
}

function Assert-DefaultTodaySemantics {
  param(
    [string]$HelperPath,
    [string]$OpenCodeLogRoot,
    [System.TimeZoneInfo]$TimeZone
  )

  $stableDate = $null
  $defaultData = $null
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $beforeTaipei = Get-TaipeiNow -TimeZone $TimeZone
    $defaultRaw = & pwsh -NoProfile -File $HelperPath `
      -SourceMode session `
      -OpenCodeLogRoot $OpenCodeLogRoot
    $afterTaipei = Get-TaipeiNow -TimeZone $TimeZone

    if ($beforeTaipei.Date -eq $afterTaipei.Date) {
      $stableDate = $beforeTaipei.Date
      $defaultData = $defaultRaw | ConvertFrom-Json
      break
    }

    Start-Sleep -Milliseconds 1100
  }

  if ($null -eq $stableDate -or $null -eq $defaultData) {
    throw 'Could not obtain a stable Asia/Taipei local date around omitted From/To helper invocation.'
  }

  return [ordered]@{
    StableDate = $stableDate
    Data = $defaultData
  }
}

try {
  New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $repoA -Force | Out-Null
  New-Item -ItemType Directory -Path $repoB -Force | Out-Null
  New-Item -ItemType Directory -Path $todayRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $yesterdayRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $tomorrowRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $externalRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $deletedReadRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $readOnlyRepo -Force | Out-Null
  New-Item -ItemType Directory -Path $nonGitExternal -Force | Out-Null

  git -C $repoA init | Out-Null
  git -C $repoB init | Out-Null
  git -C $todayRepo init | Out-Null
  git -C $yesterdayRepo init | Out-Null
  git -C $tomorrowRepo init | Out-Null
  git -C $externalRepo init | Out-Null
  git -C $deletedReadRepo init | Out-Null
  git -C $readOnlyRepo init | Out-Null

  $externalRepoReadme = Join-Path $externalRepo 'README.md'
  $deletedReadRepoFile = Join-Path $deletedReadRepo 'deleted.md'
  $readOnlyRepoReadme = Join-Path $readOnlyRepo 'README.md'
  $nonGitTouchedFile = Join-Path $nonGitExternal 'notes.txt'
  Write-Utf8NoBomFile -Path $externalRepoReadme -Content "# touched external repo`n"
  Write-Utf8NoBomFile -Path $deletedReadRepoFile -Content "# deleted file in git repo`n"
  Write-Utf8NoBomFile -Path $readOnlyRepoReadme -Content "# read-only touched repo`n"
  Write-Utf8NoBomFile -Path $nonGitTouchedFile -Content "plain folder`n"
  Remove-Item -LiteralPath $deletedReadRepoFile -Force

  $logFile = Join-Path $logRoot '2026-05-29T235959.log'
  $content = @(
    "INFO  2026-05-29T10:15:00 +10ms service=default directory=$repoA creating instance",
    "INFO  2026-05-30T09:00:00 +10ms service=default directory=$repoB creating instance"
  ) -join [Environment]::NewLine
  Write-Utf8NoBomFile -Path $logFile -Content $content
  (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-30T09:00:00'

  $taipeiTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
  $nowTaipei = Get-TaipeiNow -TimeZone $taipeiTimeZone
  $todayEvent = Get-LocalDateTime -Value $nowTaipei -Hour 10
  $yesterdayEvent = $todayEvent.AddDays(-1)
  $tomorrowEvent = $todayEvent.AddDays(1)

  $todayLogFile = Join-Path $logRoot 'today.log'
  $todayContent = @(
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms service=default directory=$todayRepo creating instance",
    "INFO  $(Format-LogTimestamp -Value $yesterdayEvent) +10ms service=default directory=$yesterdayRepo creating instance",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms service=default directory=$tomorrowRepo creating instance",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=external_directory path=$externalRepo",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=read path=$externalRepoReadme",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=read path=$deletedReadRepoFile",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=read-only path=$readOnlyRepoReadme",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=external_directory path=$nonGitExternal",
    "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms permission=read path=$nonGitTouchedFile",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=external_directory path=$externalRepo",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=read path=$externalRepoReadme",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=read path=$deletedReadRepoFile",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=read-only path=$readOnlyRepoReadme",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=external_directory path=$nonGitExternal",
    "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms permission=read path=$nonGitTouchedFile"
  ) -join [Environment]::NewLine
  Write-Utf8NoBomFile -Path $todayLogFile -Content $todayContent
  (Get-Item -LiteralPath $todayLogFile).LastWriteTime = $todayEvent

  $todayRangeDate = $todayEvent.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
  $permissionRaw = & pwsh -NoProfile -File $helperPath `
    -From ($todayRangeDate + 'T00:00:00+08:00') `
    -To ($todayRangeDate + 'T23:59:59+08:00') `
    -SourceMode session `
    -OpenCodeLogRoot $logRoot

  $permissionData = $permissionRaw | ConvertFrom-Json
  $permissionNames = @($permissionData.repos | ForEach-Object { $_.name })

  $raw = & pwsh -NoProfile -File $helperPath `
    -From '2026-05-29T00:00:00+08:00' `
    -To '2026-05-29T23:59:59+08:00' `
    -SourceMode session `
    -OpenCodeLogRoot $logRoot

  $data = $raw | ConvertFrom-Json
  $names = @($data.repos | ForEach-Object { $_.name })

  Assert-NotContainsName -Names $names -Unexpected 'repo-b' -Message 'Expected range filter to exclude repo-b event from next day, but repo-b was included.'

  Assert-ContainsName -Names $names -Expected 'repo-a' -Message 'Expected range filter to include repo-a event from target day, but repo-a was missing.'

  $defaultResult = Assert-DefaultTodaySemantics -HelperPath $helperPath -OpenCodeLogRoot $logRoot -TimeZone $taipeiTimeZone
  $defaultData = $defaultResult.Data
  $defaultNames = @($defaultData.repos | ForEach-Object { $_.name })
  $stableDate = [datetime]$defaultResult.StableDate

  Assert-NotContainsName -Names $defaultNames -Unexpected 'repo-yesterday' -Message 'Expected omitted From/To to default to today and exclude repo-yesterday, but repo-yesterday was included.'

  if ($stableDate -eq $todayEvent.Date) {
    Assert-ContainsName -Names $defaultNames -Expected 'repo-today' -Message 'Expected omitted From/To to default to today and include repo-today, but repo-today was missing.'
    Assert-NotContainsName -Names $defaultNames -Unexpected 'repo-tomorrow' -Message 'Expected omitted From/To to default to today and exclude repo-tomorrow, but repo-tomorrow was included.'
  }
  elseif ($stableDate -eq $tomorrowEvent.Date) {
    Assert-ContainsName -Names $defaultNames -Expected 'repo-tomorrow' -Message 'Expected omitted From/To to default to Asia/Taipei current day and include repo-tomorrow after local midnight rollover, but repo-tomorrow was missing.'
    Assert-NotContainsName -Names $defaultNames -Unexpected 'repo-today' -Message 'Expected omitted From/To to move to next Asia/Taipei day after local midnight rollover and exclude repo-today, but repo-today was included.'
  }
  else {
    throw "Expected omitted From/To helper invocation to resolve to either fixture day $($todayEvent.Date.ToString('yyyy-MM-dd')) or $($tomorrowEvent.Date.ToString('yyyy-MM-dd')), but got $($stableDate.ToString('yyyy-MM-dd'))."
  }

  Assert-ContainsName -Names $defaultNames -Expected 'external-git' -Message 'Expected touched external git repo to be included from permission log lines, but external-git was missing.'

  Assert-ContainsName -Names $permissionNames -Expected 'external-deleted-read-git' -Message 'Expected permission=read path inside git repo to resolve repo root even when referenced file no longer exists, but external-deleted-read-git was missing.'

  Assert-ContainsName -Names $permissionNames -Expected 'external-read-only-git' -Message 'Expected permission=read-only evidence to discover git repo without matching permission=external_directory line, but external-read-only-git was missing.'

  Assert-NotContainsName -Names $defaultNames -Unexpected 'external-plain' -Message 'Expected non-git external path to stay excluded, but external-plain was included.'

  'PASS collect-daily-work-log regression tests'
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
