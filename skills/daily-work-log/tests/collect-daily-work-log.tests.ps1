[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $skillRoot 'scripts\collect-daily-work-log.ps1'

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-WarningPresent {
  param(
    $Data,
    [string]$ExpectedWarning
  )

  Assert-True -Condition (@($Data.warnings) -contains $ExpectedWarning) -Message ("Expected top-level warning: {0}" -f $ExpectedWarning)
}

function Assert-ContainsName {
  param(
    [object[]]$Names,
    [string]$Expected,
    [string]$Message
  )

  Assert-True -Condition ($Names -contains $Expected) -Message $Message
}

function Assert-NotContainsName {
  param(
    [object[]]$Names,
    [string]$Unexpected,
    [string]$Message
  )

  Assert-True -Condition (-not ($Names -contains $Unexpected)) -Message $Message
}

function New-TestRoot {
  Join-Path ([System.IO.Path]::GetTempPath()) ('daily-work-log-test-' + [System.Guid]::NewGuid().ToString('N'))
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Format-LogTimestamp {
  param([datetime]$Value)

  return $Value.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-GitRepo {
  param(
    [string]$Root,
    [string]$Name
  )

  $repoPath = Join-Path $Root $Name
  New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
  git -C $repoPath init | Out-Null
  $repoPath
}

function New-FakeOpenCode {
  param(
    [string]$BinRoot,
    [string]$JsonOutput,
    [int]$ExitCode
  )

  New-Item -ItemType Directory -Path $BinRoot -Force | Out-Null
  $scriptPath = Join-Path $BinRoot 'opencode.ps1'
  $encodedJson = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($JsonOutput))
  $outputLine = if ($ExitCode -ne 0) {
    '[Console]::Error.WriteLine($decoded)'
  }
  else {
    'Write-Output $decoded'
  }
  $content = @(
    "`$bytes = [System.Convert]::FromBase64String('$encodedJson')",
    '$decoded = [System.Text.Encoding]::UTF8.GetString($bytes)',
    $outputLine,
    "exit $ExitCode"
  ) -join [Environment]::NewLine
  Write-Utf8NoBom -Path $scriptPath -Content $content
  $BinRoot
}

function Invoke-Collector {
  param(
    [string]$From,
    [string]$To,
    [string]$SourceMode,
    [string]$OpenCodeLogRoot,
    [string]$OpenCodeStorageRoot,
    [string]$ExtraPath
  )

  $collectorArgs = @(
    '-NoProfile',
    '-File', $helperPath,
    '-SourceMode', $SourceMode
  )

  if (-not [string]::IsNullOrWhiteSpace($From)) {
    $collectorArgs += @('-From', $From)
  }

  if (-not [string]::IsNullOrWhiteSpace($To)) {
    $collectorArgs += @('-To', $To)
  }

  if (-not [string]::IsNullOrWhiteSpace($OpenCodeLogRoot)) {
    $collectorArgs += @('-OpenCodeLogRoot', $OpenCodeLogRoot)
  }

  if (-not [string]::IsNullOrWhiteSpace($OpenCodeStorageRoot)) {
    $collectorArgs += @('-OpenCodeStorageRoot', $OpenCodeStorageRoot)
  }

  $originalPath = $env:PATH
  try {
    if (-not [string]::IsNullOrWhiteSpace($ExtraPath)) {
      $env:PATH = $ExtraPath + [System.IO.Path]::PathSeparator + $env:PATH
    }

    & pwsh @collectorArgs
  }
  finally {
    $env:PATH = $originalPath
  }
}

function Get-RepoNames {
  param($Data)

  @($Data.repos | ForEach-Object { $_.name })
}

function Get-TaipeiNow {
  $timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
  [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $timeZone)
}

$tests = [System.Collections.Generic.List[scriptblock]]::new()

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $json = @(
    '{"repo":"repo-a"}',
    '{"repo":"repo-b"}'
  ) -join [Environment]::NewLine

  $originalPath = $env:PATH
  try {
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput $json -ExitCode 0
    Assert-True -Condition ($pathRoot -eq $binRoot) -Message 'Expected New-FakeOpenCode to return BinRoot.'

    $env:PATH = $pathRoot + [System.IO.Path]::PathSeparator + $env:PATH
    $captured = & opencode db --format json 'select 1'

    Assert-True -Condition (($captured -join [Environment]::NewLine) -eq $json) -Message 'Expected fake opencode stdout to be pipeline-capturable.'
  }
  finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'

  try {
    $nonGitPath = Join-Path $tempRoot 'not-a-repo'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    $directoryJson = $nonGitPath | ConvertTo-Json -Compress
    $json = "[{`"directory`":$directoryJson}]"
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput $json -ExitCode 0

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-NotContainsName -Names $names -Unexpected 'not-a-repo' -Message 'Expected DB session discovery to exclude non-git not-a-repo directory, but it was included.'
    Assert-True -Condition (@($data.errors).Count -eq 0) -Message 'Expected non-git DB session directory to be ignored without fatal errors.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'Some OpenCode DB session paths could not be resolved to git repositories.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'

  try {
    $repo = New-GitRepo -Root $tempRoot -Name 'db-git-file-repo'
    $externalGitRoot = Join-Path $tempRoot 'gitdirs'
    New-Item -ItemType Directory -Path $externalGitRoot -Force | Out-Null
    $externalGitDir = Join-Path $externalGitRoot 'db-git-file-repo.git'
    Move-Item -LiteralPath (Join-Path $repo '.git') -Destination $externalGitDir
    Write-Utf8NoBom -Path (Join-Path $repo '.git') -Content ("gitdir: {0}" -f $externalGitDir)
    $child = Join-Path $repo 'child'
    New-Item -ItemType Directory -Path $child -Force | Out-Null
    $directoryJson = $child | ConvertTo-Json -Compress
    $json = "[{`"directory`":$directoryJson}]"
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput $json -ExitCode 0

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-ContainsName -Names $names -Expected 'db-git-file-repo' -Message 'Expected DB path inside .git-file worktree to resolve to db-git-file-repo root.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'

  try {
    $repo = New-GitRepo -Root $tempRoot -Name 'db-repo'
    $directoryJson = $repo | ConvertTo-Json -Compress
    $json = "[{`"directory`":$directoryJson}]"
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput $json -ExitCode 0

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data
    $fallbackWarnings = @($data.warnings | Where-Object { $_ -like '*fallback*' -or $_ -like '*log*' })

    Assert-ContainsName -Names $names -Expected 'db-repo' -Message 'Expected DB session discovery to include db-repo, but it was missing.'
    Assert-True -Condition (@($fallbackWarnings).Count -eq 0) -Message 'Expected DB session discovery to avoid fallback warnings.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $logRoot = Join-Path $tempRoot 'opencode-log'

  try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $fallbackRepo = New-GitRepo -Root $tempRoot -Name 'fallback-should-not-run'
    $logFile = Join-Path $logRoot '2026-05-29T120000.log'
    $content = "INFO  2026-05-29T12:00:00 +10ms service=default directory=$fallbackRepo creating instance"
    Write-Utf8NoBom -Path $logFile -Content $content
    (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-29T12:00:00'
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput '[]' -ExitCode 0

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeLogRoot $logRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-NotContainsName -Names $names -Unexpected 'fallback-should-not-run' -Message 'Expected empty DB session discovery to skip file fallback, but fallback-should-not-run was included.'
    Assert-True -Condition (@($data.errors).Count -eq 0) -Message 'Expected empty DB session discovery to finish without fatal errors.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'OpenCode db query returned no session rows; lower-level session discovery was not used.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $storageRoot = Join-Path $tempRoot 'storage'
  $directoryReadmeRoot = Join-Path $storageRoot 'directory-readme'
  $logRoot = Join-Path $tempRoot 'opencode-log'

  try {
    New-Item -ItemType Directory -Path $directoryReadmeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $nonGitPath = Join-Path $tempRoot 'directory-readme-unresolved'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    $repo = New-GitRepo -Root $tempRoot -Name 'log-after-empty-directory-readme'
    $updatedAt = [datetimeoffset]'2026-05-29T12:00:00+08:00'
    $session = [ordered]@{
      sessionID = 'ses_empty_directory_readme'
      injectedPaths = @($nonGitPath)
      updatedAt = $updatedAt.ToUnixTimeMilliseconds()
    }
    $sessionJson = $session | ConvertTo-Json -Depth 5
    Write-Utf8NoBom -Path (Join-Path $directoryReadmeRoot 'ses_empty_directory_readme.json') -Content $sessionJson
    $logFile = Join-Path $logRoot '2026-05-29T120000.log'
    $content = "INFO  2026-05-29T12:00:00 +10ms service=default directory=$repo creating instance"
    Write-Utf8NoBom -Path $logFile -Content $content
    (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-29T12:00:00'
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for empty directory-readme fallback test' -ExitCode 1

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeStorageRoot $storageRoot `
      -OpenCodeLogRoot $logRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-True -Condition ($names -contains 'log-after-empty-directory-readme') -Message 'Expected empty directory-readme result to fall through to logs and include log-after-empty-directory-readme, but it was missing.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'Some OpenCode directory-readme paths could not be resolved to git repositories.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $storageRoot = Join-Path $tempRoot 'storage'
  $directoryReadmeRoot = Join-Path $storageRoot 'directory-readme'

  try {
    New-Item -ItemType Directory -Path $directoryReadmeRoot -Force | Out-Null
    $repo = New-GitRepo -Root $tempRoot -Name 'directory-readme-repo'
    $nonGitPath = Join-Path $tempRoot 'directory-readme-not-a-repo'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    $updatedAt = [datetimeoffset]'2026-05-29T12:00:00+08:00'
    $session = [ordered]@{
      sessionID = 'ses_directory_readme'
      injectedPaths = @($repo, $nonGitPath)
      updatedAt = $updatedAt.ToUnixTimeMilliseconds()
    }
    $sessionJson = $session | ConvertTo-Json -Depth 5
    Write-Utf8NoBom -Path (Join-Path $directoryReadmeRoot 'ses_directory_readme.json') -Content $sessionJson
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for directory-readme fallback test' -ExitCode 1

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeStorageRoot $storageRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data
    $fallbackWarnings = @($data.warnings | Where-Object { $_ -like '*DB*' -and $_ -like '*directory-readme*' })

    Assert-ContainsName -Names $names -Expected 'directory-readme-repo' -Message 'Expected DB failure to fall back to directory-readme and include directory-readme-repo, but it was missing.'
    Assert-True -Condition ($fallbackWarnings.Count -gt 0) -Message 'Expected warning to indicate DB failure and directory-readme fallback.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'Some OpenCode directory-readme paths could not be resolved to git repositories.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $storageRoot = Join-Path $tempRoot 'storage'
  $directoryReadmeRoot = Join-Path $storageRoot 'directory-readme'
  $logRoot = Join-Path $tempRoot 'opencode-log'

  try {
    New-Item -ItemType Directory -Path $directoryReadmeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $nonGitPath = Join-Path $tempRoot 'directory-readme-not-a-repo'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    $logRepo = New-GitRepo -Root $tempRoot -Name 'log-after-empty-directory-readme'
    $updatedAt = [datetimeoffset]'2026-05-29T12:00:00+08:00'
    $session = [ordered]@{
      sessionID = 'ses_no_repo'
      injectedPaths = @($nonGitPath)
      updatedAt = $updatedAt.ToUnixTimeMilliseconds()
    }
    Write-Utf8NoBom -Path (Join-Path $directoryReadmeRoot 'ses_no_repo.json') -Content ($session | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom -Path (Join-Path $logRoot '2026-05-29T121500.log') -Content "INFO  2026-05-29T12:15:00 +10ms service=default directory=$logRepo creating instance"
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for directory-readme empty fallback test' -ExitCode 1

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeStorageRoot $storageRoot `
      -OpenCodeLogRoot $logRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-ContainsName -Names $names -Expected 'log-after-empty-directory-readme' -Message 'Expected empty directory-readme discovery to fall through to logs.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'OpenCode directory-readme discovery found no resolvable git repositories; falling back to log session discovery.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $storageRoot = Join-Path $tempRoot 'storage'
  $directoryReadmeRoot = Join-Path $storageRoot 'directory-readme'

  try {
    New-Item -ItemType Directory -Path $directoryReadmeRoot -Force | Out-Null
    $repo = New-GitRepo -Root $tempRoot -Name 'directory-readme-valid-repo'
    $updatedAt = [datetimeoffset]'2026-05-29T12:00:00+08:00'
    $session = [ordered]@{
      sessionID = 'ses_valid'
      injectedPaths = @($repo)
      updatedAt = $updatedAt.ToUnixTimeMilliseconds()
    }
    Write-Utf8NoBom -Path (Join-Path $directoryReadmeRoot 'ses_valid.json') -Content ($session | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom -Path (Join-Path $directoryReadmeRoot 'ses_null.json') -Content 'null'
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for null directory-readme fallback test' -ExitCode 1

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeStorageRoot $storageRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-ContainsName -Names $names -Expected 'directory-readme-valid-repo' -Message 'Expected null directory-readme file to be skipped while valid repo is discovered, but valid repo was missing.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'Some directory-readme files could not be parsed.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $logRoot = Join-Path $tempRoot 'opencode-log'
  $missingStorageRoot = Join-Path $tempRoot 'missing-storage'

  try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $repoA = New-GitRepo -Root $tempRoot -Name 'repo-a'
    $repoB = New-GitRepo -Root $tempRoot -Name 'repo-b'
    $externalRepo = New-GitRepo -Root $tempRoot -Name 'external-git'
    $deletedReadRepo = New-GitRepo -Root $tempRoot -Name 'external-deleted-read-git'
    $readOnlyRepo = New-GitRepo -Root $tempRoot -Name 'external-read-only-git'
    $nonGitPath = Join-Path $tempRoot 'log-not-a-repo'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    $externalRepoReadme = Join-Path $externalRepo 'README.md'
    $deletedReadRepoFile = Join-Path $deletedReadRepo 'deleted.md'
    $readOnlyRepoReadme = Join-Path $readOnlyRepo 'README.md'
    Write-Utf8NoBom -Path $externalRepoReadme -Content 'touched'
    Write-Utf8NoBom -Path $deletedReadRepoFile -Content 'deleted'
    Write-Utf8NoBom -Path $readOnlyRepoReadme -Content 'read-only'
    Remove-Item -LiteralPath $deletedReadRepoFile -Force

    $logFile = Join-Path $logRoot '2026-05-29T235959.log'
    $content = @(
      "INFO  2026-05-29T10:15:00 +10ms service=default directory=$repoA creating instance",
      "INFO  2026-05-29T11:30:00 +10ms permission=external_directory path=$nonGitPath",
      "INFO  2026-05-29T12:00:00 +10ms permission=external_directory path=$externalRepo",
      "INFO  2026-05-29T12:01:00 +10ms permission=read path=$externalRepoReadme",
      "INFO  2026-05-29T12:02:00 +10ms permission=read path=$deletedReadRepoFile",
      "INFO  2026-05-29T12:03:00 +10ms permission=read-only path=$readOnlyRepoReadme",
      "permission=read path=$repoA",
      "INFO  2026-05-30T09:00:00 +10ms service=default directory=$repoB creating instance"
    ) -join [Environment]::NewLine
    Write-Utf8NoBom -Path $logFile -Content $content
    (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-30T09:00:00'
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for log fallback test' -ExitCode 1

    $raw = Invoke-Collector `
      -From '2026-05-29T00:00:00+08:00' `
      -To '2026-05-29T23:59:59+08:00' `
      -SourceMode session `
      -OpenCodeLogRoot $logRoot `
      -OpenCodeStorageRoot $missingStorageRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-NotContainsName -Names $names -Unexpected 'repo-b' -Message 'Expected range filter to exclude repo-b event from next day, but repo-b was included.'
    Assert-ContainsName -Names $names -Expected 'repo-a' -Message 'Expected range filter to include repo-a event from target day, but repo-a was missing.'
    Assert-ContainsName -Names $names -Expected 'external-git' -Message 'Expected permission=external_directory/read path evidence to include external-git.'
    Assert-ContainsName -Names $names -Expected 'external-deleted-read-git' -Message 'Expected permission=read path inside git repo to resolve repo root even when referenced file no longer exists.'
    Assert-ContainsName -Names $names -Expected 'external-read-only-git' -Message 'Expected permission=read-only evidence to discover git repo.'
    Assert-NotContainsName -Names $names -Unexpected 'log-not-a-repo' -Message 'Expected non-git external path to stay excluded.'
    Assert-WarningPresent -Data $data -ExpectedWarning 'Some OpenCode log session paths could not be resolved to git repositories.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

$tests.Add({
  $tempRoot = New-TestRoot
  $binRoot = Join-Path $tempRoot 'bin'
  $logRoot = Join-Path $tempRoot 'opencode-log'
  $missingStorageRoot = Join-Path $tempRoot 'missing-storage'

  try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $todayRepo = New-GitRepo -Root $tempRoot -Name 'repo-today'
    $yesterdayRepo = New-GitRepo -Root $tempRoot -Name 'repo-yesterday'
    $tomorrowRepo = New-GitRepo -Root $tempRoot -Name 'repo-tomorrow'
    $nowTaipei = Get-TaipeiNow
    $todayEvent = [datetime]::new($nowTaipei.Year, $nowTaipei.Month, $nowTaipei.Day, 10, 0, 0, [System.DateTimeKind]::Unspecified)
    $yesterdayEvent = $todayEvent.AddDays(-1)
    $tomorrowEvent = $todayEvent.AddDays(1)
    $logFile = Join-Path $logRoot 'today.log'
    $content = @(
      "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms service=default directory=$todayRepo creating instance",
      "INFO  $(Format-LogTimestamp -Value $yesterdayEvent) +10ms service=default directory=$yesterdayRepo creating instance",
      "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms service=default directory=$tomorrowRepo creating instance"
    ) -join [Environment]::NewLine
    Write-Utf8NoBom -Path $logFile -Content $content
    (Get-Item -LiteralPath $logFile).LastWriteTime = $todayEvent
    $pathRoot = New-FakeOpenCode -BinRoot $binRoot -JsonOutput 'forced DB failure for default today test' -ExitCode 1

    $raw = Invoke-Collector `
      -SourceMode session `
      -OpenCodeLogRoot $logRoot `
      -OpenCodeStorageRoot $missingStorageRoot `
      -ExtraPath $pathRoot

    $data = $raw | ConvertFrom-Json
    $names = Get-RepoNames -Data $data

    Assert-ContainsName -Names $names -Expected 'repo-today' -Message 'Expected omitted From/To to default to today in configured timezone and include repo-today.'
    Assert-NotContainsName -Names $names -Unexpected 'repo-yesterday' -Message 'Expected omitted From/To to exclude repo-yesterday.'
    Assert-NotContainsName -Names $names -Unexpected 'repo-tomorrow' -Message 'Expected omitted From/To to exclude repo-tomorrow.'
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
})

foreach ($test in $tests) {
  & $test
}

'PASS collect-daily-work-log tests'
