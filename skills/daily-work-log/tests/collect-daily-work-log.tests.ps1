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
    RgLogFile = Join-Path $root 'rg-calls.log'
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

if ($Arguments.Count -ge 4 -and $Arguments[0] -eq 'api' -and $Arguments[1] -eq 'user' -and $Arguments[2] -eq '--jq') {
  if ($env:DAILY_WORK_LOG_FAKE_GH_USER_MODE -eq 'fail') {
    [Console]::Error.WriteLine('fake gh user unavailable')
    exit 1
  }
  if ($Arguments[3] -eq '.login') {
    if ($env:DAILY_WORK_LOG_FAKE_GH_LOGIN) { $env:DAILY_WORK_LOG_FAKE_GH_LOGIN } else { 'test-user' }
    exit 0
  }
  if ($Arguments[3] -eq '.name') {
    if ($env:DAILY_WORK_LOG_FAKE_GH_NAME) { $env:DAILY_WORK_LOG_FAKE_GH_NAME } else { 'Test User' }
    exit 0
  }
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
    },
    [ordered]@{
      number = 3
      title = 'Current user authored PR'
      url = 'https://github.com/sevenflanks/fixture-repo/pull/3'
      updatedAt = '2026-05-29T06:00:00Z'
      mergedAt = '2026-05-29T06:30:00Z'
      closedAt = $null
      state = 'MERGED'
      isDraft = $false
      headRefName = 'feature/current-user-pr'
      baseRefName = 'main'
      closingIssuesReferences = @()
      author = [ordered]@{ login = 'test-user' }
    }
  ) | ConvertTo-Json -Compress -Depth 8
  exit 0
}

if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'view') {
  $oid = if ($Arguments[2] -eq '1') { $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH } elseif ($Arguments[2] -eq '3') { '3333333333333333333333333333333333333333' } else { '0000000000000000000000000000000000000000' }
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
if (`$Arguments.Count -ge 3 -and `$Arguments[0] -eq 'config' -and `$Arguments[1] -eq '--get') {
  if (`$Arguments[2] -eq 'user.name') {
    if (`$env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE -eq 'fail') { exit 1 }
    if (`$env:DAILY_WORK_LOG_FAKE_GIT_NAME) { `$env:DAILY_WORK_LOG_FAKE_GIT_NAME } else { 'test-user' }
    exit 0
  }
  if (`$Arguments[2] -eq 'user.email') {
    if (`$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE -eq 'fail') { exit 1 }
    if (`$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL) { `$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL } else { 'test@example.invalid' }
    exit 0
  }
}
& '$realGit' @Arguments
exit `$LASTEXITCODE
"@

  $rgPs1 = Join-Path $paths.BinRoot 'rg.ps1'
  Write-Utf8NoBom -Path $rgPs1 -Content @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:DAILY_WORK_LOG_RG_LOG_FILE) {
  Add-Content -LiteralPath $env:DAILY_WORK_LOG_RG_LOG_FILE -Value ($Arguments -join ' ') -Encoding utf8
}
if ($env:DAILY_WORK_LOG_FAKE_RG_MODE -eq 'fail') {
  [Console]::Error.WriteLine('fake rg failed')
  exit 1
}
$root = $Arguments[-1]
Get-ChildItem -LiteralPath $root -Force -Filter '.git' -Recurse -ErrorAction SilentlyContinue |
  Where-Object { -not $_.PSIsContainer } |
  ForEach-Object { $_.FullName }
exit 0
'@

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

function Add-TestCommit {
  param(
    [string]$RepositoryPath,
    [string]$FileName,
    [string]$Subject,
    [string]$AuthorName,
    [string]$AuthorEmail,
    [string]$Date = '2026-05-29T10:00:00+08:00'
  )

  $filePath = Join-Path $RepositoryPath $FileName
  Set-Content -LiteralPath $filePath -Value $Subject -Encoding utf8
  git -C $RepositoryPath add $FileName | Out-Null
  $oldAuthorName = $env:GIT_AUTHOR_NAME
  $oldAuthorEmail = $env:GIT_AUTHOR_EMAIL
  $oldAuthorDate = $env:GIT_AUTHOR_DATE
  $oldCommitterName = $env:GIT_COMMITTER_NAME
  $oldCommitterEmail = $env:GIT_COMMITTER_EMAIL
  $oldCommitterDate = $env:GIT_COMMITTER_DATE
  $env:GIT_AUTHOR_NAME = $AuthorName
  $env:GIT_AUTHOR_EMAIL = $AuthorEmail
  $env:GIT_AUTHOR_DATE = $Date
  $env:GIT_COMMITTER_NAME = $AuthorName
  $env:GIT_COMMITTER_EMAIL = $AuthorEmail
  $env:GIT_COMMITTER_DATE = $Date
  try {
    git -C $RepositoryPath commit -m $Subject | Out-Null
  }
  finally {
    $env:GIT_AUTHOR_NAME = $oldAuthorName
    $env:GIT_AUTHOR_EMAIL = $oldAuthorEmail
    $env:GIT_AUTHOR_DATE = $oldAuthorDate
    $env:GIT_COMMITTER_NAME = $oldCommitterName
    $env:GIT_COMMITTER_EMAIL = $oldCommitterEmail
    $env:GIT_COMMITTER_DATE = $oldCommitterDate
  }

  return (git -C $RepositoryPath rev-parse HEAD).Trim()
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
    [string]$GitName = 'test-user',
    [string]$GitEmail = 'test@example.invalid',
    [string]$GhLogin = 'test-user',
    [string]$GhName = 'Test User',
    [ValidateSet('session', 'scan', 'mixed')]
    [string]$SourceMode = 'session',
    [string[]]$ScanRoots = @(),
    [switch]$FailIdentity,
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
  $oldGitName = $env:DAILY_WORK_LOG_FAKE_GIT_NAME
  $oldGitEmail = $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL
  $oldGitNameMode = $env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE
  $oldGitEmailMode = $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE
  $oldGhUserMode = $env:DAILY_WORK_LOG_FAKE_GH_USER_MODE
  $oldGhLogin = $env:DAILY_WORK_LOG_FAKE_GH_LOGIN
  $oldGhName = $env:DAILY_WORK_LOG_FAKE_GH_NAME
  $oldRgLogFile = $env:DAILY_WORK_LOG_RG_LOG_FILE
  $oldRgMode = $env:DAILY_WORK_LOG_FAKE_RG_MODE

  try {
    $env:PATH = $TestRoot.BinRoot + [System.IO.Path]::PathSeparator + $oldPath
    $env:DAILY_WORK_LOG_FAKE_DB_MODE = $DbMode
    $env:DAILY_WORK_LOG_FAKE_DB_REPO = $DbRepo
    $env:DAILY_WORK_LOG_GIT_COUNT_FILE = $TestRoot.GitCountFile
    $env:DAILY_WORK_LOG_GH_LOG_FILE = $TestRoot.GhLogFile
    $env:DAILY_WORK_LOG_FAKE_PR_MATCH_HASH = $GhPrMatchHash
    $env:DAILY_WORK_LOG_FAKE_GIT_NAME = $GitName
    $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL = $GitEmail
    $env:DAILY_WORK_LOG_FAKE_GH_LOGIN = $GhLogin
    $env:DAILY_WORK_LOG_FAKE_GH_NAME = $GhName
    $env:DAILY_WORK_LOG_RG_LOG_FILE = $TestRoot.RgLogFile
    $env:DAILY_WORK_LOG_FAKE_RG_MODE = $null
    if ($FailIdentity) {
      $env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE = 'fail'
      $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE = 'fail'
      $env:DAILY_WORK_LOG_FAKE_GH_USER_MODE = 'fail'
    }
    else {
      $env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE = $null
      $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE = $null
      $env:DAILY_WORK_LOG_FAKE_GH_USER_MODE = $null
    }
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
    $env:DAILY_WORK_LOG_FAKE_GIT_NAME = $oldGitName
    $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL = $oldGitEmail
    $env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE = $oldGitNameMode
    $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE = $oldGitEmailMode
    $env:DAILY_WORK_LOG_FAKE_GH_USER_MODE = $oldGhUserMode
    $env:DAILY_WORK_LOG_FAKE_GH_LOGIN = $oldGhLogin
    $env:DAILY_WORK_LOG_FAKE_GH_NAME = $oldGhName
    $env:DAILY_WORK_LOG_RG_LOG_FILE = $oldRgLogFile
    $env:DAILY_WORK_LOG_FAKE_RG_MODE = $oldRgMode
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
      $gitResolveCount | Should Be 4
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

  It 'expands a safe non-git session directory into nested git repos using rg markers' {
    $testRoot = New-TestRoot
    try {
      $aggregate = Join-Path $testRoot.Root 'aggregate-project'
      New-Item -ItemType Directory -Path $aggregate -Force | Out-Null
      $repoA = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'repo-a'
      $repoB = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'repo-b'
      $worktreeLike = Join-Path $aggregate '.worktrees\repo-c'
      New-Item -ItemType Directory -Path $worktreeLike -Force | Out-Null
      Write-Utf8NoBom -Path (Join-Path $worktreeLike '.git') -Content 'gitdir: ../.git/worktrees/repo-c'
      Add-TestCommit -RepositoryPath $repoA -FileName 'a.txt' -Subject 'feat: repo a work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $repoB -FileName 'b.txt' -Subject 'feat: repo b work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $aggregate
      $names = @($data.repos | ForEach-Object { $_.name })
      $repoAResult = @($data.repos | Where-Object { $_.name -eq 'repo-a' })[0]
      $repoBResult = @($data.repos | Where-Object { $_.name -eq 'repo-b' })[0]
      $rgCalls = if (Test-Path -LiteralPath $testRoot.RgLogFile) { Get-Content -LiteralPath $testRoot.RgLogFile -Raw } else { '' }

      ($names -contains 'repo-a') | Should Be $true
      ($names -contains 'repo-b') | Should Be $true
      (@($repoAResult.source) -contains 'session-expanded') | Should Be $true
      (@($repoBResult.source) -contains 'session-expanded') | Should Be $true
      $rgCalls | Should Match 'aggregate-project'
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'skips noisy nested directories while expanding aggregate session directories' {
    $testRoot = New-TestRoot
    try {
      $aggregate = Join-Path $testRoot.Root 'aggregate-with-noise'
      New-Item -ItemType Directory -Path $aggregate -Force | Out-Null
      $repo = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'real-repo'
      $noiseRoot = Join-Path $aggregate 'node_modules\vendored'
      $noiseRepo = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $noiseRoot }) -Name 'noise-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'real.txt' -Subject 'feat: real work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $noiseRepo -FileName 'noise.txt' -Subject 'feat: noisy vendored work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $aggregate
      $names = @($data.repos | ForEach-Object { $_.name })

      ($names -contains 'real-repo') | Should Be $true
      ($names -contains 'noise-repo') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'does not expand an unsafe broad session root' {
    $testRoot = New-TestRoot
    try {
      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo ([System.IO.Path]::GetPathRoot($testRoot.Root))
      $rgCalls = if (Test-Path -LiteralPath $testRoot.RgLogFile) { Get-Content -LiteralPath $testRoot.RgLogFile -Raw } else { '' }

      @($data.repos).Count | Should Be 0
      $rgCalls | Should Be ''
      @(@($data.warnings) | Where-Object { $_ -like 'Skipped unsafe session expansion root:*' }).Count | Should Be 1
      (@($data.warnings) -contains 'Some OpenCode session paths could not be resolved to git repositories.') | Should Be $true
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

  It 'expands a safe non-git log session directory without unresolved log warning' {
    $testRoot = New-TestRoot
    try {
      $aggregate = Join-Path $testRoot.Root 'log-aggregate-project'
      New-Item -ItemType Directory -Path $aggregate -Force | Out-Null
      $repoA = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'log-repo-a'
      Add-TestCommit -RepositoryPath $repoA -FileName 'a.txt' -Subject 'feat: log repo a work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-OpenCodeLogEvent -TestRoot $testRoot -RepositoryPath $aggregate -Timestamp '2026-05-29T10:15:00'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'fail' -DbRepo $aggregate
      $names = @($data.repos | ForEach-Object { $_.name })
      $repoAResult = @($data.repos | Where-Object { $_.name -eq 'log-repo-a' })[0]

      ($names -contains 'log-repo-a') | Should Be $true
      (@($repoAResult.source) -contains 'session-expanded') | Should Be $true
      (@($data.warnings) -contains 'Some OpenCode log session paths could not be resolved to git repositories.') | Should Be $false
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

  It 'filters commits by current git email without matching author name or GitHub identity' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'email-author-filter-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: email matched work' -AuthorName 'email-only-author' -AuthorEmail 'current@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'current-git-name' -GitEmail 'current@example.invalid' -GhLogin 'current-gh-login' -GhName 'Current Gh Name'
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'email-author-filter-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      $data.meta.authorScope | Should Be 'current'
      $data.meta.currentIdentity.gitName | Should Be 'current-git-name'
      $data.meta.currentIdentity.gitEmail | Should Be 'current@example.invalid'
      ($subjects -contains 'feat: email matched work') | Should Be $true
      ($subjects -contains 'feat: other work') | Should Be $false
      $repoResult.commits[0].authorEmail | Should Be 'current@example.invalid'
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'filters commits by current git name when email and GitHub identity do not match' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'git-name-author-filter-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: git name matched work' -AuthorName 'current-git-name' -AuthorEmail 'name-only@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'current-git-name' -GitEmail 'current@example.invalid' -GhLogin 'current-gh-login' -GhName 'Current Gh Name'
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'git-name-author-filter-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      $data.meta.authorScope | Should Be 'current'
      $data.meta.currentIdentity.gitName | Should Be 'current-git-name'
      $data.meta.currentIdentity.gitEmail | Should Be 'current@example.invalid'
      ($subjects -contains 'feat: git name matched work') | Should Be $true
      ($subjects -contains 'feat: other work') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'filters commits by current GitHub login when git identity does not match' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'github-login-author-filter-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: gh login matched work' -AuthorName 'current-gh-login' -AuthorEmail 'github-login-only@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'current-git-name' -GitEmail 'current@example.invalid' -GhLogin 'current-gh-login' -GhName 'Current Gh Name'
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'github-login-author-filter-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      $data.meta.authorScope | Should Be 'current'
      ($subjects -contains 'feat: gh login matched work') | Should Be $true
      ($subjects -contains 'feat: other work') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'filters commits by current GitHub display name when git identity does not match' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'github-name-author-filter-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: gh name matched work' -AuthorName 'Current Gh Name' -AuthorEmail 'github-name-only@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'current-git-name' -GitEmail 'current@example.invalid' -GhLogin 'current-gh-login' -GhName 'Current Gh Name'
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'github-name-author-filter-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      $data.meta.authorScope | Should Be 'current'
      ($subjects -contains 'feat: gh name matched work') | Should Be $true
      ($subjects -contains 'feat: other work') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'keeps all commits and warns when current identity cannot be resolved' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'identity-fallback-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: my work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -FailIdentity
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'identity-fallback-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      $data.meta.authorScope | Should Be 'all'
      (@($data.warnings) -contains 'Current author identity could not be resolved; author filtering was not applied.') | Should Be $true
      ($subjects -contains 'feat: my work') | Should Be $true
      ($subjects -contains 'feat: other work') | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'keeps session evidence for repos with no current-user commits after author filtering' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'no-commit-session-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'current-user' -GitEmail 'current@example.invalid' -GhLogin 'current-gh-login' -GhName 'Current User'
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'no-commit-session-repo' })[0]

      @($repoResult.commits).Count | Should Be 0
      @($repoResult.sessionEvidence).Count | Should BeGreaterThan 0
      $repoResult.sessionEvidence[0].source | Should Be 'session'
      $repoResult.sessionEvidence[0].title | Should Be 'session'
      $repoResult.sessionEvidence[0].timeCreated | Should Be 1780000000000
      $repoResult.sessionEvidence[0].timeUpdated | Should Be 1780000000000
      (@($repoResult.warnings) -contains 'No current-user commits found in the selected range.') | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'keeps only PRs tied to filtered current-user commits' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'pr-filter-repo'
      $matchingHash = Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: related work (#1)' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: unrelated other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'
      git -C $repo remote add origin 'https://github.com/sevenflanks/fixture-repo.git' | Out-Null

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GhPrMatchHash $matchingHash
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'pr-filter-repo' })[0]
      $prNumbers = @($repoResult.prs | ForEach-Object { $_.number })

      ($prNumbers -contains 1) | Should Be $true
      ($prNumbers -contains 2) | Should Be $false
      ($prNumbers -contains 3) | Should Be $true
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'excludes bot release commits unless they have PR-chain evidence to current-user work' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'bot-chain-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: my work (#1)' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'bot-related.txt' -Subject 'chore(main): release 1.2.3 (#1)' -AuthorName 'github-actions[bot]' -AuthorEmail '41898282+github-actions[bot]@users.noreply.github.com'
      Add-TestCommit -RepositoryPath $repo -FileName 'bot-unrelated.txt' -Subject 'chore(main): release 9.9.9' -AuthorName 'github-actions[bot]' -AuthorEmail '41898282+github-actions[bot]@users.noreply.github.com'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'bot-chain-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      ($subjects -contains 'feat: my work (#1)') | Should Be $true
      ($subjects -contains 'chore(main): release 1.2.3 (#1)') | Should Be $true
      ($subjects -contains 'chore(main): release 9.9.9') | Should Be $false
    }
    finally {
      if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  It 'excludes bot deploy commits unless they have PR-chain evidence to current-user work' {
    $testRoot = New-TestRoot
    try {
      $repo = New-GitRepo -TestRoot $testRoot -Name 'deploy-bot-chain-repo'
      Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: deployable work (#1)' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
      Add-TestCommit -RepositoryPath $repo -FileName 'deploy-related.txt' -Subject 'chore(main): deploy production (#1)' -AuthorName 'github-actions[bot]' -AuthorEmail '41898282+github-actions[bot]@users.noreply.github.com'
      Add-TestCommit -RepositoryPath $repo -FileName 'deploy-unrelated.txt' -Subject 'chore(main): deploy staging' -AuthorName 'github-actions[bot]' -AuthorEmail '41898282+github-actions[bot]@users.noreply.github.com'

      $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo
      $repoResult = @($data.repos | Where-Object { $_.name -eq 'deploy-bot-chain-repo' })[0]
      $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

      ($subjects -contains 'feat: deployable work (#1)') | Should Be $true
      ($subjects -contains 'chore(main): deploy production (#1)') | Should Be $true
      ($subjects -contains 'chore(main): deploy staging') | Should Be $false
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
            [ordered]@{ hash = '0000000000000000000000000000000000000001'; subject = 'Commit 1'; author = 'test-user'; authorEmail = 'test@example.invalid'; date = '2026-05-29T01:00:00+08:00' },
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
        },
        [ordered]@{
          name = 'no-commit-session-repo'
          path = 'C:\fixture\no-commit-session-repo'
          source = @('session')
          isGitRepo = $true
          githubRepo = 'sevenflanks/no-commit-session-repo'
          commits = @()
          prs = @()
          warnings = @('No current-user commits found in the selected range.')
          sessionEvidence = @(
            [ordered]@{ source = 'session'; title = 'Investigate no commit repo'; path = 'C:\work\no-commit-session-repo' },
            [ordered]@{ source = 'session'; title = 'Second'; path = 'C:\work\no-commit-session-repo-2' },
            [ordered]@{ source = 'session'; title = 'Third'; path = 'C:\work\no-commit-session-repo-3' },
            [ordered]@{ source = 'session'; title = 'Fourth'; path = 'C:\work\no-commit-session-repo-4' },
            [ordered]@{ source = 'session'; title = 'Fifth'; path = 'C:\work\no-commit-session-repo-5' },
            [ordered]@{ source = 'session'; title = 'Sixth'; path = 'C:\work\no-commit-session-repo-6' }
          )
        }
      )
    }

    $raw = $input | ConvertTo-Json -Depth 8 | & pwsh -NoProfile -File $script:FormatterPath -MaxCommitsPerRepo 8
    $rawText = $raw -join [Environment]::NewLine
    $output = $raw | ConvertFrom-Json
    $repo = @($output.repos | Where-Object { $_.name -eq 'busy-repo' })[0]

    $output.meta.timezone | Should Be 'Asia/Taipei'
    $repo.githubRepo | Should Be 'sevenflanks/busy-repo'
    (@($repo.shownCommits).Count -le 8) | Should Be $true
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'refs/stash') | Should Be $false
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'index on feature: abc1234 work') | Should Be $false
    (@($repo.shownCommits | ForEach-Object { $_.subject }) -contains 'untracked files on feature: abc1234 work') | Should Be $false
    $repo.shownCommits[0].author | Should Be 'test-user'
    $repo.shownCommits[0].authorEmail | Should Be 'test@example.invalid'
    $rawText | Should Match '"authorDate"\s*:\s*"2026-05-29T01:00:00"'
    $repo.commitCount | Should Be 8
    (@($repo.prs) -contains 'PR #237: Improve collection [MERGED]') | Should Be $true
    (@($repo.prs) -contains 'PR #238: noop [MERGED]') | Should Be $false
    (@($repo.lowSignalPrRefs) -contains 'PR #238 [MERGED]') | Should Be $true
    (@($repo.warnings) -contains 'repo warning') | Should Be $true
    (@($output.warnings) -contains 'collector warning') | Should Be $true

    $sessionRepo = @($output.repos | Where-Object { $_.name -eq 'no-commit-session-repo' })[0]
    @($sessionRepo.sessionEvidence).Count | Should Be 5
    $sessionRepo.sessionEvidence[0].title | Should Be 'Investigate no commit repo'
  }
}
