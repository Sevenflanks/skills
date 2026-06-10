[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SkillRoot = Split-Path -Parent $PSScriptRoot
$script:HelperPath = Join-Path $script:SkillRoot 'scripts\collect-daily-work-log.ps1'
$script:FormatterPath = Join-Path $script:SkillRoot 'scripts\format-daily-work-log-evidence.ps1'
$script:RealGitPath = (Get-Command git -ErrorAction Stop).Source

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

function New-TestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('daily-work-log-test-' + [System.Guid]::NewGuid().ToString('N'))
  $paths = [ordered]@{
    Root = $root
    BinRoot = Join-Path $root 'bin'
    LogRoot = Join-Path $root 'opencode-log'
    StorageRoot = Join-Path $root 'opencode-storage'
    GitCountFile = Join-Path $root 'git-rev-parse-count.txt'
    GhLogFile = Join-Path $root 'gh-calls.log'
  }

  foreach ($path in @($paths.Root, $paths.BinRoot, $paths.LogRoot, $paths.StorageRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  $opencodeCmd = Join-Path $paths.BinRoot 'opencode.cmd'
  $opencodePs1 = Join-Path $paths.BinRoot 'opencode.ps1'
  $opencodeImpl = Join-Path $paths.BinRoot 'opencode-impl.ps1'
  Write-Utf8NoBom -Path $opencodeCmd -Content ('@echo off' + [Environment]::NewLine + 'pwsh -NoProfile -File "%~dp0opencode-impl.ps1" %*' + [Environment]::NewLine + 'exit /b %ERRORLEVEL%')
  Write-Utf8NoBom -Path $opencodePs1 -Content ('param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)' + [Environment]::NewLine + '& $PSScriptRoot\opencode-impl.ps1 @Arguments' + [Environment]::NewLine + 'exit $LASTEXITCODE')
  Write-Utf8NoBom -Path $opencodeImpl -Content @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:DAILY_WORK_LOG_FAKE_DB_MODE -ne 'fail') {
  $sql = [string]$Arguments[-1]
  $expectedFrom = [regex]::Escape($env:DAILY_WORK_LOG_EXPECTED_FROM_MS)
  $expectedTo = [regex]::Escape($env:DAILY_WORK_LOG_EXPECTED_TO_MS)
  $hasCreatedBeforeEnd = [regex]::IsMatch($sql, ("time_created\s*<=\s*{0}" -f $expectedTo), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  $hasUpdatedAfterStart = [regex]::IsMatch($sql, ("time_updated\s*>=\s*{0}" -f $expectedFrom), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not ($hasCreatedBeforeEnd -and $hasUpdatedAfterStart)) {
    [Console]::Error.WriteLine("expected overlap SQL with time_created <= $($env:DAILY_WORK_LOG_EXPECTED_TO_MS) and time_updated >= $($env:DAILY_WORK_LOG_EXPECTED_FROM_MS), got: $sql")
    exit 42
  }
}

switch ($env:DAILY_WORK_LOG_FAKE_DB_MODE) {
  'fail' {
    [Console]::Error.WriteLine('fake db unavailable')
    exit 1
  }
  'empty' {
    '[]'
    exit 0
  }
  'duplicate' {
    $repo = $env:DAILY_WORK_LOG_FAKE_DB_REPO
    @(
      [ordered]@{ id = '1'; directory = $repo; path = $repo; title = 'one'; time_created = 1780000000000; time_updated = 1780000000000 },
      [ordered]@{ id = '2'; directory = $repo; path = $repo; title = 'two'; time_created = 1780000000001; time_updated = 1780000000001 },
      [ordered]@{ id = '3'; directory = $repo; path = $repo; title = 'three'; time_created = 1780000000002; time_updated = 1780000000002 },
      [ordered]@{ id = '4'; directory = $repo; path = $repo; title = 'four'; time_created = 1780000000003; time_updated = 1780000000003 }
    ) | ConvertTo-Json -Compress
    exit 0
  }
  default {
    $repo = $env:DAILY_WORK_LOG_FAKE_DB_REPO
    @([ordered]@{ id = '1'; directory = $repo; path = $null; title = 'session'; time_created = 1780000000000; time_updated = 1780000000000 }) | ConvertTo-Json -Compress
    exit 0
  }
}
'@

  $ghPs1 = Join-Path $paths.BinRoot 'gh.ps1'
  $ghImpl = Join-Path $paths.BinRoot 'gh-impl.ps1'
  Write-Utf8NoBom -Path $ghPs1 -Content ('param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)' + [Environment]::NewLine + '& $PSScriptRoot\gh-impl.ps1 @Arguments' + [Environment]::NewLine + 'exit $LASTEXITCODE')
  Write-Utf8NoBom -Path $ghImpl -Content @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:DAILY_WORK_LOG_GH_LOG_FILE) {
  Add-Content -LiteralPath $env:DAILY_WORK_LOG_GH_LOG_FILE -Value ($Arguments -join ' ') -Encoding utf8
}

if ($Arguments.Count -ge 4 -and $Arguments[0] -eq 'api' -and $Arguments[1] -eq 'user' -and $Arguments[2] -eq '--jq' -and $Arguments[3] -eq '.login') {
  'test-user'
  exit 0
}

if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'api' -and $Arguments[1] -eq 'graphql') {
  [ordered]@{ data = [ordered]@{ viewer = [ordered]@{ login = 'graphql-user' } } } | ConvertTo-Json -Compress -Depth 5
  exit 0
}

if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'list') {
  @(
    [ordered]@{
      number = 1
      title = 'Related PR'
      url = 'https://github.com/sevenflanks/fixture-repo/pull/1'
      updatedAt = '2026-05-29T04:00:00Z'
      mergedAt = '2026-05-29T04:30:00Z'
      closedAt = $null
      state = 'MERGED'
      isDraft = $false
      headRefName = 'feature/related'
      baseRefName = 'main'
      closingIssuesReferences = @([ordered]@{ number = 99; title = 'Issue 99'; url = 'https://github.com/sevenflanks/fixture-repo/issues/99' })
      author = [ordered]@{ login = 'test-user' }
    },
    [ordered]@{
      number = 2
      title = 'Unrelated PR'
      url = 'https://github.com/sevenflanks/fixture-repo/pull/2'
      updatedAt = '2026-05-29T05:00:00Z'
      mergedAt = '2026-05-29T05:30:00Z'
      closedAt = $null
      state = 'MERGED'
      isDraft = $false
      headRefName = 'feature/unrelated'
      baseRefName = 'main'
      closingIssuesReferences = @([ordered]@{ number = 100; title = 'Issue 100'; url = 'https://github.com/sevenflanks/fixture-repo/issues/100' })
      author = [ordered]@{ login = 'other-user' }
    }
  ) | ConvertTo-Json -Compress -Depth 8
  exit 0
}

if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'view') {
  $oid = if ($Arguments[2] -eq '1') { $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH } else { '0000000000000000000000000000000000000000' }
  [ordered]@{ number = [int]$Arguments[2]; commits = @([ordered]@{ oid = $oid }) } | ConvertTo-Json -Compress -Depth 5
  exit 0
}

[Console]::Error.WriteLine('unexpected gh call: ' + ($Arguments -join ' '))
exit 2
'@

  $gitPs1 = Join-Path $paths.BinRoot 'git.ps1'
  $realGit = $script:RealGitPath.Replace("'", "''")
  Write-Utf8NoBom -Path $gitPs1 -Content @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Arguments)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
if (`$Arguments.Count -gt 0 -and `$Arguments[0] -eq 'rev-parse') {
  `$countPath = `$env:DAILY_WORK_LOG_GIT_COUNT_FILE
  if (`$countPath) {
    `$count = 0
    if (Test-Path -LiteralPath `$countPath) {
      `$rawCount = (Get-Content -LiteralPath `$countPath -Raw).Trim()
      if (-not [string]::IsNullOrWhiteSpace(`$rawCount)) { `$count = [int]`$rawCount }
    }
    [System.IO.File]::WriteAllText(`$countPath, [string](`$count + 1), [System.Text.UTF8Encoding]::new(`$false))
  }
}
& '$realGit' @Arguments
exit `$LASTEXITCODE
"@

  return [pscustomobject]$paths
}

function New-GitRepo {
  param(
    [pscustomobject]$TestRoot,
    [string]$Name
  )

  $repo = Join-Path $TestRoot.Root $Name
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  git -C $repo init | Out-Null
  git -C $repo config user.email 'test@example.invalid' | Out-Null
  git -C $repo config user.name 'Daily Work Log Test' | Out-Null

  return (Get-Item -LiteralPath $repo).FullName
}

function Add-OpenCodeLogEvent {
  param(
    [pscustomobject]$TestRoot,
    [string]$RepositoryPath,
    [string]$Timestamp = '2026-05-29T10:15:00'
  )

  $logFile = Join-Path $TestRoot.LogRoot '2026-05-29T235959.log'
  $line = "INFO  $Timestamp +10ms service=default directory=$RepositoryPath creating instance"
  Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
  (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-30T09:00:00'
}

function Add-DirectoryReadmeSession {
  param(
    [pscustomobject]$TestRoot,
    [string]$RepositoryPath
  )

  $directoryReadmeRoot = Join-Path $TestRoot.StorageRoot 'directory-readme'
  New-Item -ItemType Directory -Path $directoryReadmeRoot -Force | Out-Null
  $sessionPath = Join-Path $directoryReadmeRoot ([System.Guid]::NewGuid().ToString('N') + '.json')
  [ordered]@{
    updatedAt = 1780000000000
    injectedPaths = @($RepositoryPath)
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath $sessionPath -Encoding utf8
}

function Get-FunctionBody {
  param(
    [string]$Path,
    [string]$FunctionName
  )

  $content = Get-Content -LiteralPath $Path -Raw
  $pattern = '(?s)function\s+' + [regex]::Escape($FunctionName) + '\s*\{(?<body>.*?)(?=\r?\nfunction\s+|\r?\n\$warnings\s*=)'
  $match = [regex]::Match($content, $pattern)
  if (-not $match.Success) {
    throw "Function not found: $FunctionName"
  }

  return $match.Groups['body'].Value
}

function Format-LogTimestamp {
  param([datetime]$Value)

  return $Value.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TaipeiNow {
  $timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
  [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $timeZone)
}

function Invoke-CollectorJson {
  param(
    [pscustomobject]$TestRoot,
    [string]$DbMode,
    [string]$DbRepo,
    [string]$GhPrMatchHash = $null,
    [ValidateSet('session', 'scan', 'mixed')]
    [string]$SourceMode = 'session',
    [string[]]$ScanRoots = @(),
    [switch]$UseDefaultRange
  )

  $oldPath = $env:PATH
  $oldDbMode = $env:DAILY_WORK_LOG_FAKE_DB_MODE
  $oldDbRepo = $env:DAILY_WORK_LOG_FAKE_DB_REPO
  $oldGitCountFile = $env:DAILY_WORK_LOG_GIT_COUNT_FILE
  $oldExpectedFrom = $env:DAILY_WORK_LOG_EXPECTED_FROM_MS
  $oldExpectedTo = $env:DAILY_WORK_LOG_EXPECTED_TO_MS
  $oldGhLogFile = $env:DAILY_WORK_LOG_GH_LOG_FILE
  $oldGhPrMatchHash = $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH

  try {
    $env:PATH = $TestRoot.BinRoot + [System.IO.Path]::PathSeparator + $oldPath
    $env:DAILY_WORK_LOG_FAKE_DB_MODE = $DbMode
    $env:DAILY_WORK_LOG_FAKE_DB_REPO = $DbRepo
    $env:DAILY_WORK_LOG_GIT_COUNT_FILE = $TestRoot.GitCountFile
    $env:DAILY_WORK_LOG_GH_LOG_FILE = $TestRoot.GhLogFile
    $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH = $GhPrMatchHash
    $env:DAILY_WORK_LOG_EXPECTED_FROM_MS = ([datetimeoffset]'2026-05-29T00:00:00+08:00').ToUniversalTime().ToUnixTimeMilliseconds().ToString()
    $env:DAILY_WORK_LOG_EXPECTED_TO_MS = ([datetimeoffset]'2026-05-29T23:59:59+08:00').ToUniversalTime().ToUnixTimeMilliseconds().ToString()

    $collectorArgs = @(
      '-NoProfile',
      '-File', $script:HelperPath,
      '-SourceMode', $SourceMode,
      '-OpenCodeLogRoot', $TestRoot.LogRoot,
      '-OpenCodeStorageRoot', $TestRoot.StorageRoot
    )
    if (-not $UseDefaultRange) {
      $collectorArgs += @('-From', '2026-05-29T00:00:00+08:00', '-To', '2026-05-29T23:59:59+08:00')
    }
    if (@($ScanRoots).Count -gt 0) {
      $collectorArgs += '-ScanRoots'
      $collectorArgs += $ScanRoots
    }

    $raw = & pwsh @collectorArgs
    return ($raw | ConvertFrom-Json)
  }
  finally {
    $env:PATH = $oldPath
    $env:DAILY_WORK_LOG_FAKE_DB_MODE = $oldDbMode
    $env:DAILY_WORK_LOG_FAKE_DB_REPO = $oldDbRepo
    $env:DAILY_WORK_LOG_GIT_COUNT_FILE = $oldGitCountFile
    $env:DAILY_WORK_LOG_GH_LOG_FILE = $oldGhLogFile
    $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH = $oldGhPrMatchHash
    $env:DAILY_WORK_LOG_EXPECTED_FROM_MS = $oldExpectedFrom
    $env:DAILY_WORK_LOG_EXPECTED_TO_MS = $oldExpectedTo
  }
}

Describe 'collect-daily-work-log session discovery' {
  It 'falls back to timestamp-filtered logs when OpenCode DB fails' {
    $testRoot = New-TestRoot
    try {
      $repoA = New-GitRepo -TestRoot $testRoot -Name 'repo-a'
      $repoB = New-GitRepo -TestRoot $testRoot -Name 'repo-b'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $repoA -Timestamp '2026-05-29T10:15:00'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $repoB -Timestamp '2026-05-30T09:00:00'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'fail' -DbRepo $repoA
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'repo-a') | Should Be $true
      ($names -contains 'repo-b') | Should Be $false
      (@($data.warnings) -contains 'OpenCode db query failed; falling back to directory-readme session discovery.') | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'streams OpenCode log files line by line for fallback discovery' {
    $body = Get-FunctionBody -Path $script:HelperPath -FunctionName 'Get-SessionDirectoriesFromLogs'

    $body | Should Match 'StreamReader'
    $body | Should Match 'ReadLine\(\)'
    $body | Should Not Match 'Read-SharedTextFile'
    $body | Should Not Match '-split\s+"`r\?`n"'
  }

  It 'ignores large next-day log noise while preserving timestamp-filtered fallback results' {
    $testRoot = New-TestRoot
    try {
      $repoA = New-GitRepo -TestRoot $testRoot -Name 'large-log-repo-a'
      $repoB = New-GitRepo -TestRoot $testRoot -Name 'large-log-repo-b'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $repoA -Timestamp '2026-05-29T10:15:00'

      $logFile = Join-Path $testRoot.LogRoot '2026-05-29T235959.log'
      $nextDayNoise = 1..2000 | ForEach-Object { "INFO  2026-05-30T09:00:00 +$($_)ms service=default directory=$repoB creating instance" }
      Add-Content -LiteralPath $logFile -Value $nextDayNoise -Encoding utf8

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'fail' -DbRepo $repoA
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'large-log-repo-a') | Should Be $true
      ($names -contains 'large-log-repo-b') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'deduplicates duplicate scan roots before resolving repositories' {
    $testRoot = New-TestRoot
    try {
      $body = Get-FunctionBody -Path $script:HelperPath -FunctionName 'Get-ScanRepositories'
      $repo = New-GitRepo -TestRoot $testRoot -Name 'scan-duplicate-repo'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'empty' -DbRepo $repo -SourceMode 'scan' -ScanRoots @($repo, $repo)
      $names = @($data.repos | ForEach-Object { $_.name })
      $gitResolveCount = [int]((Get-Content -LiteralPath $testRoot.GitCountFile -Raw).Trim())

      $body | Should Match 'HashSet\[string\]'
      $body | Should Match 'OrdinalIgnoreCase'
      @($data.repos).Count | Should Be 1
      ($names -contains 'scan-duplicate-repo') | Should Be $true
      $gitResolveCount | Should Be 2
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'uses successful OpenCode DB rows without falling back to logs or directory-readme storage' {
    $testRoot = New-TestRoot
    try {
      $dbRepo = New-GitRepo -TestRoot $testRoot -Name 'db-repo'
      $fallbackRepo = New-GitRepo -TestRoot $testRoot -Name 'fallback-repo'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $fallbackRepo
      Add-DirectoryReadmeSession -TestRoot $testRoot -RepositoryPath $fallbackRepo

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $dbRepo
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'db-repo') | Should Be $true
      ($names -contains 'fallback-repo') | Should Be $false
      (@($data.warnings) -contains 'OpenCode directory-readme discovery found no resolvable git repositories; falling back to log session discovery.') | Should Be $false
      (@($data.warnings) -contains 'OpenCode db query failed; falling back to directory-readme session discovery.') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'treats empty OpenCode DB result as authoritative and warns without fallback' {
    $testRoot = New-TestRoot
    try {
      $fallbackRepo = New-GitRepo -TestRoot $testRoot -Name 'fallback-repo'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $fallbackRepo
      Add-DirectoryReadmeSession -TestRoot $testRoot -RepositoryPath $fallbackRepo

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'empty' -DbRepo $fallbackRepo

      @($data.repos).Count | Should Be 0
      (@($data.warnings) -contains 'OpenCode DB returned no sessions for the requested range; fallback discovery was not used.') | Should Be $true
      (@($data.warnings) -contains 'OpenCode db query failed; falling back to directory-readme session discovery.') | Should Be $false
      (@($data.warnings) -contains 'OpenCode directory-readme discovery found no resolvable git repositories; falling back to log session discovery.') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'deduplicates duplicate OpenCode DB paths before resolving repo roots' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'duplicate-repo'
      New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $repo 'src\file.txt') -Value 'content' -Encoding utf8

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'duplicate' -DbRepo $repo
      $names = @($data.repos | ForEach-Object { $_.name })
      $gitResolveCount = [int]((Get-Content -LiteralPath $testRoot.GitCountFile -Raw).Trim())

      @($data.repos).Count | Should Be 1
      ($names -contains 'duplicate-repo') | Should Be $true
      ($gitResolveCount -le 4) | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'discovers touched external repos from permission log evidence when DB fallback reaches logs' {
    $testRoot = New-TestRoot
    try {
      $repoA = New-GitRepo -TestRoot $testRoot -Name 'repo-a'
      $repoB = New-GitRepo -TestRoot $testRoot -Name 'repo-b'
      $externalRepo = New-GitRepo -TestRoot $testRoot -Name 'external-git'
      $deletedReadRepo = New-GitRepo -TestRoot $testRoot -Name 'external-deleted-read-git'
      $readOnlyRepo = New-GitRepo -TestRoot $testRoot -Name 'external-read-only-git'
      $nonGitPath = Join-Path $testRoot.Root 'log-not-a-repo'
      New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
      $externalRepoReadme = Join-Path $externalRepo 'README.md'
      $deletedReadRepoFile = Join-Path $deletedReadRepo 'deleted.md'
      $readOnlyRepoReadme = Join-Path $readOnlyRepo 'README.md'
      Write-Utf8NoBom -Path $externalRepoReadme -Content 'touched'
      Write-Utf8NoBom -Path $deletedReadRepoFile -Content 'deleted'
      Write-Utf8NoBom -Path $readOnlyRepoReadme -Content 'read-only'
      Remove-Item -LiteralPath $deletedReadRepoFile -Force

      $logFile = Join-Path $testRoot.LogRoot '2026-05-29T235959.log'
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

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'fail' -DbRepo $repoA
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'repo-a') | Should Be $true
      ($names -contains 'repo-b') | Should Be $false
      ($names -contains 'external-git') | Should Be $true
      ($names -contains 'external-deleted-read-git') | Should Be $true
      ($names -contains 'external-read-only-git') | Should Be $true
      ($names -contains 'log-not-a-repo') | Should Be $false
      (@($data.warnings) -contains 'Some OpenCode log session paths could not be resolved to git repositories.') | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'defaults omitted From and To to today in the configured timezone' {
    $testRoot = New-TestRoot
    try {
      $todayRepo = New-GitRepo -TestRoot $testRoot -Name 'repo-today'
      $yesterdayRepo = New-GitRepo -TestRoot $testRoot -Name 'repo-yesterday'
      $tomorrowRepo = New-GitRepo -TestRoot $testRoot -Name 'repo-tomorrow'
      $nowTaipei = Get-TaipeiNow
      $todayEvent = [datetime]::new($nowTaipei.Year, $nowTaipei.Month, $nowTaipei.Day, 10, 0, 0, [System.DateTimeKind]::Unspecified)
      $yesterdayEvent = $todayEvent.AddDays(-1)
      $tomorrowEvent = $todayEvent.AddDays(1)
      $logFile = Join-Path $testRoot.LogRoot 'today.log'
      $content = @(
        "INFO  $(Format-LogTimestamp -Value $todayEvent) +10ms service=default directory=$todayRepo creating instance",
        "INFO  $(Format-LogTimestamp -Value $yesterdayEvent) +10ms service=default directory=$yesterdayRepo creating instance",
        "INFO  $(Format-LogTimestamp -Value $tomorrowEvent) +10ms service=default directory=$tomorrowRepo creating instance"
      ) -join [Environment]::NewLine
      Write-Utf8NoBom -Path $logFile -Content $content

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'fail' -DbRepo $todayRepo -UseDefaultRange
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'repo-today') | Should Be $true
      ($names -contains 'repo-yesterday') | Should Be $false
      ($names -contains 'repo-tomorrow') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'uses legacy gh PR list and view enrichment without GraphQL and preserves closing issue references' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'github-repo'
      Set-Content -LiteralPath (Join-Path $repo 'work.txt') -Value 'daily work' -Encoding utf8
      git -C $repo add work.txt | Out-Null
      $oldAuthorDate = $env:GIT_AUTHOR_DATE
      $oldCommitterDate = $env:GIT_COMMITTER_DATE
      try {
        $env:GIT_AUTHOR_DATE = '2026-05-29T10:00:00+08:00'
        $env:GIT_COMMITTER_DATE = '2026-05-29T10:00:00+08:00'
        git -C $repo commit -m 'Add daily work fixture' | Out-Null
      }
      finally {
        $env:GIT_AUTHOR_DATE = $oldAuthorDate
        $env:GIT_COMMITTER_DATE = $oldCommitterDate
      }
      git -C $repo remote add origin 'https://github.com/sevenflanks/fixture-repo.git' | Out-Null
      git -C $repo tag daily-work-fixture | Out-Null
      $commitHash = (git -C $repo rev-parse HEAD).Trim()
      $fixtureLog = git -C $repo log --all --since='2026-05-29T00:00:00+08:00' --until='2026-05-29T23:59:59+08:00' --pretty=format:'%H'
      @($fixtureLog).Count | Should Be 1
      Remove-Item -LiteralPath (Join-Path $testRoot.BinRoot 'git.ps1') -Force

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GhPrMatchHash $commitHash
      $calls = if (Test-Path -LiteralPath $testRoot.GhLogFile) { @(Get-Content -LiteralPath $testRoot.GhLogFile) } else { @() }
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'github-repo' })[0]
      $prNumbers = @($repoResult.prs | ForEach-Object { $_.number })

      @($repoResult.commits).Count | Should Be 1
      $repoResult.githubRepo | Should Be 'sevenflanks/fixture-repo'
      (@($calls | Where-Object { $_ -like 'pr list*' }).Count -ge 1) | Should Be $true
      (@($calls | Where-Object { $_ -like 'pr view 1*' }).Count -ge 1) | Should Be $true
      (@($calls | Where-Object { $_ -like 'pr view 2*' }).Count -ge 1) | Should Be $true
      (@($calls | Where-Object { $_ -like 'api graphql*' }).Count) | Should Be 0
      ($prNumbers -contains 1) | Should Be $true
      ($prNumbers -contains 2) | Should Be $false
      $relatedPr = @($repoResult.prs | Where-Object { $_.number -eq 1 })[0]
      (@($relatedPr.issuesClosed) -contains 99) | Should Be $true
      (@($relatedPr.closingIssuesReferences | ForEach-Object { $_.number }) -contains 99) | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
}

Describe 'format-daily-work-log-evidence compaction' {
  It 'caps shown commits, removes stash noise, and separates noop PR references' {
    $input = [ordered]@{
      meta = [ordered]@{
        generatedAt = '2026-05-29T18:00:00+08:00'
        timezone = 'Asia/Taipei'
        from = '2026-05-29T00:00:00+08:00'
        to = '2026-05-29T23:59:59+08:00'
        sourceMode = 'session'
        ghAvailable = $true
      }
      warnings = @('collector warning')
      errors = @()
      repos = @(
        [ordered]@{
          name = 'busy-repo'
          path = 'C:\fixture\busy-repo'
          source = @('session')
          isGitRepo = $true
          githubRepo = 'sevenflanks/busy-repo'
          commits = @(
            [ordered]@{ hash = '0000000000000000000000000000000000000001'; subject = 'Commit 1'; authorDate = '2026-05-29T01:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000002'; subject = 'Commit 2'; authorDate = '2026-05-29T02:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000003'; subject = 'refs/stash'; authorDate = '2026-05-29T03:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000004'; subject = 'Commit 4'; authorDate = '2026-05-29T04:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000005'; subject = 'index on feature: abc1234 work'; authorDate = '2026-05-29T05:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000006'; subject = 'Commit 6'; authorDate = '2026-05-29T06:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000007'; subject = 'untracked files on feature: abc1234 work'; authorDate = '2026-05-29T07:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000008'; subject = 'Commit 8'; authorDate = '2026-05-29T08:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000009'; subject = 'Commit 9'; authorDate = '2026-05-29T09:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000010'; subject = 'Commit 10'; authorDate = '2026-05-29T10:00:00+08:00' },
            [ordered]@{ hash = '0000000000000000000000000000000000000011'; subject = 'Commit 11'; authorDate = '2026-05-29T11:00:00+08:00' }
          )
          prs = @(
            [ordered]@{ number = 237; title = 'Improve collection'; state = 'MERGED' },
            [ordered]@{ number = 238; title = 'noop'; state = 'MERGED' }
          )
          warnings = @('repo warning')
        }
      )
    }

    $raw = $input | ConvertTo-Json -Depth 8 | & pwsh -NoProfile -File $script:FormatterPath -MaxCommitsPerRepo 8
    $output = $raw | ConvertFrom-Json
    $repo = @($output.repos | Where-Object { $_.name -eq 'busy-repo' })[0]

    $output.meta.timezone | Should Be 'Asia/Taipei'
    $repo.githubRepo | Should Be 'sevenflanks/busy-repo'
    (@($repo.shownCommits).Count -le 8) | Should Be $true
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'refs/stash') | Should Be $false
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'index on feature: abc1234 work') | Should Be $false
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'untracked files on feature: abc1234 work') | Should Be $false
    $repo.commitCount | Should Be 8
    (@($repo.prs) -contains 'PR #237: Improve collection [MERGED]') | Should Be $true
    (@($repo.prs) -contains 'PR #238: noop [MERGED]') | Should Be $false
    (@($repo.lowSignalPrRefs) -contains 'PR #238 [MERGED]') | Should Be $true
    (@($repo.warnings) -contains 'repo warning') | Should Be $true
    (@($output.warnings) -contains 'collector warning') | Should Be $true
  }
}
