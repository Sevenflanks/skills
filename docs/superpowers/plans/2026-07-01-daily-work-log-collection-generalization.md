# Daily Work Log Collection Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize `daily-work-log` collection so personal work logs recall user/project collection preferences, expand safe aggregate session directories, and default to current-user work evidence.

**Architecture:** Keep `collect-daily-work-log.ps1` as the deterministic JSON source of truth. Add focused PowerShell functions for identity resolution, current-author filtering, fast nested `.git` marker discovery, and session evidence preservation; keep natural-language summaries in the agent/skill layer. Update formatter, docs, and evals after collector behavior is test-covered.

**Tech Stack:** PowerShell 7+, Pester-style PowerShell tests, Git CLI, GitHub CLI, `rg` for fast `.git` marker discovery, OpenCode CLI (`opencode db --format json`), JSON via `ConvertFrom-Json` / `ConvertTo-Json`.

## Global Constraints

- Do not hard-code `jasmine-scins-ah-2026` or any user/project-specific rule into `SKILL.md` or collector logic.
- Do not commit unless the user explicitly asks for a git commit.
- Preserve collector stdout as pure JSON.
- Preserve existing `session`, `scan`, and `mixed` modes; new defaults must still degrade with warnings instead of aborting.
- Use `rg` as the primary nested `.git` marker discovery path; PowerShell recursion is only a bounded fallback.
- Personal daily logs default to current-user evidence; team/all-author behavior is only an extension point.
- If current identity cannot be resolved, keep old all-author behavior and emit a warning.
- If a repo has session evidence but no current-user commit, keep it in evidence so the agent can write one short session-summary bullet.

---

## File Structure

- Modify: `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`
  - Extend fake CLI helpers for `git config`, `gh api user`, and `rg` call logging.
  - Add RED tests for session aggregate expansion, unsafe root refusal, fast `rg` marker discovery, author filtering, identity fallback, PR filtering, and no-commit session evidence.
- Modify: `skills/daily-work-log/scripts/collect-daily-work-log.ps1`
  - Add identity resolution and author filtering functions.
  - Add fast nested repo discovery functions for safe aggregate session paths.
  - Preserve session evidence for repos that have no current-user commits.
  - Add metadata fields for `authorScope`, `currentIdentity`, and session expansion sources.
- Modify: `skills/daily-work-log/scripts/format-daily-work-log-evidence.ps1`
  - Preserve `authorEmail`, author filtering metadata, `sessionEvidence`, and no-commit repo evidence in compact JSON.
- Modify: `skills/daily-work-log/SKILL.md`
  - Add pre-collection recall workflow.
  - Document current-user default, aggregate session expansion, and no-commit session summary behavior.
- Modify: `skills/daily-work-log/README.md`
  - Mirror helper behavior and JSON metadata changes.
- Modify: `skills/daily-work-log/evals/evals.json`
  - Add evals for recall, aggregate session directories, current-user filtering, and no-commit session summary.

---

### Task 1: Add RED Tests for Identity and Author Filtering

**Files:**
- Modify: `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`

**Interfaces:**
- Consumes: existing `New-TestRoot`, `New-GitRepo`, `Invoke-CollectorJson`, fake `git.ps1`, fake `gh.ps1` helpers.
- Produces: failing tests that later tasks satisfy with `Resolve-CurrentIdentity`, filtered commit collection, and metadata output.

- [ ] **Step 1: Extend `New-TestRoot` fake git to support `git config user.name/user.email`**

In `New-TestRoot`, update the fake `git.ps1` content before the final real-git passthrough so it handles config reads deterministically:

```powershell
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
```

- [ ] **Step 2: Extend `Invoke-CollectorJson` to set and restore fake identity env vars**

Add parameters:

```powershell
[string]$GitName = 'test-user',
[string]$GitEmail = 'test@example.invalid',
[switch]$FailIdentity
```

Save old env vars near the existing `$oldGhPrMatchHash` block:

```powershell
$oldGitName = $env:DAILY_WORK_LOG_FAKE_GIT_NAME
$oldGitEmail = $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL
$oldGitNameMode = $env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE
$oldGitEmailMode = $env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE
$oldGhUserMode = $env:DAILY_WORK_LOG_FAKE_GH_USER_MODE
```

Set them inside `try`:

```powershell
$env:DAILY_WORK_LOG_FAKE_GIT_NAME = $GitName
$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL = $GitEmail
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
```

Restore them in `finally`:

```powershell
$env:DAILY_WORK_LOG_FAKE_GIT_NAME = $oldGitName
$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL = $oldGitEmail
$env:DAILY_WORK_LOG_FAKE_GIT_NAME_MODE = $oldGitNameMode
$env:DAILY_WORK_LOG_FAKE_GIT_EMAIL_MODE = $oldGitEmailMode
$env:DAILY_WORK_LOG_FAKE_GH_USER_MODE = $oldGhUserMode
```

- [ ] **Step 3: Extend fake `gh.ps1` user lookup**

In the fake `gh-impl.ps1`, update the `gh api user --jq .login` block:

```powershell
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
```

- [ ] **Step 4: Add helper for author-specific commits**

Add after `New-GitRepo`:

```powershell
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
    $env:GIT_AUTHOR_NAME = $null
    $env:GIT_AUTHOR_EMAIL = $null
    $env:GIT_AUTHOR_DATE = $null
    $env:GIT_COMMITTER_NAME = $null
    $env:GIT_COMMITTER_EMAIL = $null
    $env:GIT_COMMITTER_DATE = $null
  }

  return (git -C $RepositoryPath rev-parse HEAD).Trim()
}
```

- [ ] **Step 5: Add RED test for current-user author filtering**

Append in `Describe 'collect-daily-work-log session discovery'`:

```powershell
It 'filters commits to current identity by email login or name' {
  $testRoot = New-TestRoot
  try {
    $repo = New-GitRepo -TestRoot $testRoot -Name 'author-filter-repo'
    Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: my work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
    Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

    $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GitName 'test-user' -GitEmail 'test@example.invalid'
    $repoResult = @($data.repos | Where-Object { $_.name -eq 'author-filter-repo' })[0]
    $subjects = @($repoResult.commits | ForEach-Object { $_.subject })

    $data.meta.authorScope | Should Be 'current'
    $data.meta.currentIdentity.gitName | Should Be 'test-user'
    $data.meta.currentIdentity.gitEmail | Should Be 'test@example.invalid'
    ($subjects -contains 'feat: my work') | Should Be $true
    ($subjects -contains 'feat: other work') | Should Be $false
    $repoResult.commits[0].authorEmail | Should Be 'test@example.invalid'
  }
  finally {
    if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
```

- [ ] **Step 6: Add RED test for identity fallback**

Append:

```powershell
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
```

- [ ] **Step 7: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected before implementation: failures mention missing `meta.authorScope`, missing `authorEmail`, or unfiltered `feat: other work`.

---

### Task 2: Implement Identity Resolution and Commit Filtering

**Files:**
- Modify: `skills/daily-work-log/scripts/collect-daily-work-log.ps1`

**Interfaces:**
- Consumes: tests from Task 1.
- Produces:
  - `Resolve-CurrentIdentity -WorkingDirectory <path>` returns ordered object with `CanFilter`, `GhLogin`, `GhName`, `GitName`, `GitEmail`, `Warnings`.
  - `Get-CommitData -CurrentIdentity <object>` returns filtered commits with `authorEmail`.
  - payload `meta.authorScope` and `meta.currentIdentity`.

- [ ] **Step 1: Add identity resolver after `Parse-GithubRepo`**

Add:

```powershell
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
    if (-not [string]::IsNullOrWhiteSpace($token)) { $null = $tokens.Add($token.Trim()) }
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

  if (-not $CurrentIdentity -or -not $CurrentIdentity.canFilter) { return $true }

  foreach ($candidate in @($Commit.author, $Commit.authorEmail)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    foreach ($token in @($CurrentIdentity.tokens)) {
      if (-not [string]::IsNullOrWhiteSpace($token) -and $candidate.Trim() -ieq ([string]$token).Trim()) {
        return $true
      }
    }
  }

  return $false
}
```

- [ ] **Step 2: Change `Get-CommitData` signature and git format**

Change function signature:

```powershell
function Get-CommitData {
  param(
    [string]$RepositoryPath,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [object]$CurrentIdentity
  )
```

Change format:

```powershell
$format = '%H%x1f%h%x1f%aI%x1f%an%x1f%ae%x1f%s%x1f%D%x1e'
```

Change parse indexes:

```powershell
if ($parts.Count -lt 7) { continue }
$refs = $parts[6]
$subject = $parts[5]
```

Create the commit object with `authorEmail`:

```powershell
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
if (Test-CommitMatchesIdentity -Commit $commitRecord -CurrentIdentity $CurrentIdentity) {
  $records.Add($commitRecord)
}
```

- [ ] **Step 3: Resolve identity once after GitHub CLI availability check**

After the `$ghAvailable` block, add:

```powershell
$currentIdentity = Resolve-CurrentIdentity -WorkingDirectory $PWD.Path
$authorScope = if ($currentIdentity.canFilter) { 'current' } else { 'all' }
if (-not $currentIdentity.canFilter) {
  Add-WarningMessage -List $warnings -Message 'Current author identity could not be resolved; author filtering was not applied.'
}
```

- [ ] **Step 4: Pass identity into `Get-CommitData`**

Replace:

```powershell
$commits = Get-CommitData -RepositoryPath $repoPath -FromRange $resolvedFrom -ToRange $resolvedTo
```

with:

```powershell
$commits = Get-CommitData -RepositoryPath $repoPath -FromRange $resolvedFrom -ToRange $resolvedTo -CurrentIdentity $currentIdentity
```

- [ ] **Step 5: Add identity metadata to success payload**

In `$payload.meta`, add:

```powershell
authorScope = $authorScope
currentIdentity = [ordered]@{
  ghLogin = $currentIdentity.ghLogin
  ghName = $currentIdentity.ghName
  gitName = $currentIdentity.gitName
  gitEmail = $currentIdentity.gitEmail
}
```

Also add the same keys in the catch/error payload meta, with `authorScope = 'all'` and null identity fields.

- [ ] **Step 6: Run tests and verify GREEN for Task 1 tests**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected: Task 1 tests pass or only later unimplemented aggregate/PR/session-evidence tests fail after they are added.

---

### Task 3: Add RED Tests for Safe Aggregate Session Expansion and Fast `rg` Discovery

**Files:**
- Modify: `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`

**Interfaces:**
- Consumes: existing DB fake returning one `directory` path.
- Produces: failing tests for `session-expanded` nested repo discovery and safe-root refusal.

- [ ] **Step 1: Add fake `rg` command in `New-TestRoot`**

After fake `git.ps1` creation, add:

```powershell
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
  ForEach-Object { $_.FullName }
exit 0
'@
```

Add `RgLogFile` to the `$paths` object:

```powershell
RgLogFile = Join-Path $root 'rg-calls.log'
```

- [ ] **Step 2: Extend `Invoke-CollectorJson` to preserve fake rg env**

Save old values:

```powershell
$oldRgLogFile = $env:DAILY_WORK_LOG_RG_LOG_FILE
$oldRgMode = $env:DAILY_WORK_LOG_FAKE_RG_MODE
```

Set inside `try`:

```powershell
$env:DAILY_WORK_LOG_RG_LOG_FILE = $TestRoot.RgLogFile
$env:DAILY_WORK_LOG_FAKE_RG_MODE = $null
```

Restore in `finally`:

```powershell
$env:DAILY_WORK_LOG_RG_LOG_FILE = $oldRgLogFile
$env:DAILY_WORK_LOG_FAKE_RG_MODE = $oldRgMode
```

- [ ] **Step 3: Add RED test for aggregate directory expansion**

Append:

```powershell
It 'expands a safe non-git session directory into nested git repos using rg markers' {
  $testRoot = New-TestRoot
  try {
    $aggregate = Join-Path $testRoot.Root 'aggregate-project'
    New-Item -ItemType Directory -Path $aggregate -Force | Out-Null
    $repoA = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'repo-a'
    $repoB = New-GitRepo -TestRoot ([pscustomobject]@{ Root = $aggregate }) -Name 'repo-b'
    Add-TestCommit -RepositoryPath $repoA -FileName 'a.txt' -Subject 'feat: repo a work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
    Add-TestCommit -RepositoryPath $repoB -FileName 'b.txt' -Subject 'feat: repo b work' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'

    $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $aggregate
    $names = @($data.repos | ForEach-Object { $_.name })
    $sources = @($data.repos | ForEach-Object { $_.source })
    $rgCalls = Get-Content -LiteralPath $testRoot.RgLogFile -Raw

    ($names -contains 'repo-a') | Should Be $true
    ($names -contains 'repo-b') | Should Be $true
    ($sources -contains 'session-expanded') | Should Be $true
    $rgCalls | Should Match 'aggregate-project'
  }
  finally {
    if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
```

- [ ] **Step 4: Add RED test for unsafe root refusal**

Append:

```powershell
It 'does not expand an unsafe broad session root' {
  $testRoot = New-TestRoot
  try {
    $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo ([System.IO.Path]::GetPathRoot($testRoot.Root))

    @($data.repos).Count | Should Be 0
    (@($data.warnings) -contains 'Some OpenCode DB session paths could not be resolved to git repositories.') | Should Be $true
  }
  finally {
    if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
```

- [ ] **Step 5: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected before implementation: aggregate repo names are missing or source lacks `session-expanded`.

---

### Task 4: Implement Safe Aggregate Session Expansion

**Files:**
- Modify: `skills/daily-work-log/scripts/collect-daily-work-log.ps1`

**Interfaces:**
- Consumes: RED tests from Task 3.
- Produces:
  - `Get-NestedGitRepositories -Root <path> -Warnings <list>`.
  - `Resolve-SessionCandidatePaths -Path <path> -Warnings <list>` returns objects `{ path, source }`.
  - session-expanded source reaches `repos[].source`.

- [ ] **Step 1: Add safe-root and marker discovery helpers after `Resolve-GitRepoRoot`**

Add:

```powershell
function Test-SafeExpansionRoot {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  $rootPath = ([System.IO.Path]::GetPathRoot($fullPath)).TrimEnd('\')
  if ($fullPath -ieq $rootPath) { return $false }

  $homePath = [Environment]::GetFolderPath('UserProfile')
  if (-not [string]::IsNullOrWhiteSpace($homePath) -and $fullPath -ieq ([System.IO.Path]::GetFullPath($homePath).TrimEnd('\'))) { return $false }

  return $true
}

function Find-GitMarkersFast {
  param(
    [string]$Root,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $rgCommand = Get-Command rg -ErrorAction SilentlyContinue
  if ($rgCommand) {
    $result = Invoke-Native -FilePath 'rg' -Arguments @('--files', '-uu', '-g', '.git', $Root) -WorkingDirectory $Root
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
      return @($result.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($result.ExitCode -gt 1) {
      Add-WarningMessage -List $Warnings -Message ("rg git marker discovery failed under: {0}" -f $Root)
    }
  }

  return @(Get-ChildItem -LiteralPath $Root -Force -Filter '.git' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Get-NestedGitRepositories {
  param(
    [string]$Root,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $repos = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  if (-not (Test-SafeExpansionRoot -Path $Root)) { return $repos }

  $markers = Find-GitMarkersFast -Root $Root -Warnings $Warnings
  foreach ($marker in @($markers)) {
    $markerPath = if ([System.IO.Path]::IsPathRooted([string]$marker)) { [string]$marker } else { Join-Path $Root ([string]$marker) }
    $repoCandidate = Split-Path -Path $markerPath -Parent
    if ([string]::IsNullOrWhiteSpace($repoCandidate)) { continue }
    $resolved = Resolve-GitRepoRoot -Path $repoCandidate
    if (-not [string]::IsNullOrWhiteSpace($resolved) -and $seen.Add($resolved)) {
      $repos.Add($resolved)
    }
  }

  return $repos
}
```

- [ ] **Step 2: Add session candidate resolver**

Add:

```powershell
function Resolve-SessionCandidatePaths {
  param(
    [string]$Path,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $items = [System.Collections.Generic.List[object]]::new()
  $repoRoot = Resolve-GitRepoRoot -Path $Path
  if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
    $items.Add([ordered]@{ path = $repoRoot; source = 'session' })
    return $items
  }

  if (Test-Path -LiteralPath $Path -PathType Container -and (Test-SafeExpansionRoot -Path $Path)) {
    foreach ($nestedRepo in Get-NestedGitRepositories -Root $Path -Warnings $Warnings) {
      $items.Add([ordered]@{ path = $nestedRepo; source = 'session-expanded' })
    }
  }

  return $items
}
```

- [ ] **Step 3: Use resolver in session orchestration**

Replace:

```powershell
foreach ($path in Get-SessionDirectories -FromRange $resolvedFrom -ToRange $resolvedTo -TimezoneId $Timezone -OverrideLogRoot $OpenCodeLogRoot -OverrideStorageRoot $OpenCodeStorageRoot -Warnings $warnings) {
  Add-PathItem -Map $repoMap -Path $path -Source 'session'
}
```

with:

```powershell
$unresolvedSessionPathCount = 0
foreach ($path in Get-SessionDirectories -FromRange $resolvedFrom -ToRange $resolvedTo -TimezoneId $Timezone -OverrideLogRoot $OpenCodeLogRoot -OverrideStorageRoot $OpenCodeStorageRoot -Warnings $warnings) {
  $resolvedItems = @(Resolve-SessionCandidatePaths -Path $path -Warnings $warnings)
  if (@($resolvedItems).Count -eq 0) {
    $unresolvedSessionPathCount++
    continue
  }
  foreach ($item in $resolvedItems) {
    Add-PathItem -Map $repoMap -Path $item.path -Source $item.source
  }
}
if ($unresolvedSessionPathCount -gt 0) {
  Add-WarningMessage -List $warnings -Message 'Some OpenCode DB session paths could not be resolved to git repositories.'
}
```

- [ ] **Step 4: Run tests and verify GREEN for aggregate expansion**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected: aggregate expansion tests pass; no existing session discovery tests regress.

---

### Task 5: Add RED Tests for PR Filtering and Bot PR-Chain Rules

**Files:**
- Modify: `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`

**Interfaces:**
- Consumes: author-filtered commits from Task 2.
- Produces: failing tests that require PRs to match filtered commits, and release/deploy bot commits to require PR-chain evidence.

- [ ] **Step 1: Add test for unrelated PR exclusion after author filtering**

Append:

```powershell
It 'keeps only PRs tied to filtered current-user commits' {
  $testRoot = New-TestRoot
  try {
    $repo = New-GitRepo -TestRoot $testRoot -Name 'pr-filter-repo'
    $matchingHash = Add-TestCommit -RepositoryPath $repo -FileName 'mine.txt' -Subject 'feat: related work (#1)' -AuthorName 'test-user' -AuthorEmail 'test@example.invalid'
    Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: unrelated other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

    $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo -GhPrMatchHash $matchingHash
    $repoResult = @($data.repos | Where-Object { $_.name -eq 'pr-filter-repo' })[0]
    $prNumbers = @($repoResult.prs | ForEach-Object { $_.number })

    ($prNumbers -contains 1) | Should Be $true
    ($prNumbers -contains 2) | Should Be $false
  }
  finally {
    if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
```

- [ ] **Step 2: Add test for bot release/deploy requiring PR-chain evidence**

Append:

```powershell
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
```

- [ ] **Step 3: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected before implementation: bot related release commit is missing or unrelated bot release is included.

---

### Task 6: Implement PR-Chain Bot Commit Handling

**Files:**
- Modify: `skills/daily-work-log/scripts/collect-daily-work-log.ps1`

**Interfaces:**
- Consumes: RED tests from Task 5.
- Produces: commit filtering that keeps current-user commits plus release/deploy bot commits with PR-chain evidence.

- [ ] **Step 1: Add helper functions near commit filtering helpers**

Add:

```powershell
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
```

- [ ] **Step 2: Refactor `Get-CommitData` to collect first, then filter**

Inside `Get-CommitData`, replace direct `$records.Add(...)` filtering with two lists:

```powershell
$allRecords = [System.Collections.Generic.List[object]]::new()
```

Add every parsed non-stash commit to `$allRecords`.

After parsing all entries, build current-user issue tokens:

```powershell
$currentRecords = [System.Collections.Generic.List[object]]::new()
$currentIssueTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($record in $allRecords) {
  if (Test-CommitMatchesIdentity -Commit $record -CurrentIdentity $CurrentIdentity) {
    $currentRecords.Add($record)
    foreach ($issueToken in Get-IssueTokensFromCommit -Commit $record) { $null = $currentIssueTokens.Add($issueToken) }
  }
}

if (-not $CurrentIdentity -or -not $CurrentIdentity.canFilter) { return $allRecords }
```

Then append bot PR-chain release/deploy commits:

```powershell
foreach ($record in $allRecords) {
  if (-not (Test-BotAuthor -Commit $record)) { continue }
  if (-not (Test-ReleaseOrDeploySubject -Subject $record.subject)) { continue }
  foreach ($issueToken in Get-IssueTokensFromCommit -Commit $record) {
    if ($currentIssueTokens.Contains($issueToken) -and -not ($currentRecords | Where-Object { $_.hash -eq $record.hash })) {
      $currentRecords.Add($record)
      break
    }
  }
}

return $currentRecords
```

- [ ] **Step 3: Run tests and verify GREEN for PR/bot behavior**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected: Task 5 tests pass and existing PR relevance tests still pass.

---

### Task 7: Preserve No-Commit Session Evidence for Agent Summaries

**Files:**
- Modify: `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`
- Modify: `skills/daily-work-log/scripts/collect-daily-work-log.ps1`
- Modify: `skills/daily-work-log/scripts/format-daily-work-log-evidence.ps1`

**Interfaces:**
- Consumes: author filtering from Task 2.
- Produces: `repos[].sessionEvidence` for repos that have session evidence but zero current-user commits; formatter preserves it.

- [ ] **Step 1: Add RED collector test for no-commit session evidence**

Append:

```powershell
It 'keeps session evidence for repos with no current-user commits after author filtering' {
  $testRoot = New-TestRoot
  try {
    $repo = New-GitRepo -TestRoot $testRoot -Name 'no-commit-session-repo'
    Add-TestCommit -RepositoryPath $repo -FileName 'other.txt' -Subject 'feat: other work' -AuthorName 'other-user' -AuthorEmail 'other@example.invalid'

    $data = Invoke-CollectorJson -TestRoot $testRoot -DbMode 'success' -DbRepo $repo
    $repoResult = @($data.repos | Where-Object { $_.name -eq 'no-commit-session-repo' })[0]

    @($repoResult.commits).Count | Should Be 0
    @($repoResult.sessionEvidence).Count | Should BeGreaterThan 0
    $repoResult.sessionEvidence[0].source | Should Be 'session'
  }
  finally {
    if (Test-Path -LiteralPath $testRoot.Root) { Remove-Item -LiteralPath $testRoot.Root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
```

- [ ] **Step 2: Add RED formatter test for session evidence preservation**

In the formatter `Describe`, add a fixture repo with empty commits and `sessionEvidence`:

```powershell
[ordered]@{
  name = 'no-commit-session-repo'
  githubRepo = 'sevenflanks/no-commit-session-repo'
  commits = @()
  prs = @()
  warnings = @('No current-user commits found in the selected range.')
  sessionEvidence = @([ordered]@{ source = 'session'; title = 'Investigate no commit repo'; path = 'C:\work\no-commit-session-repo' })
}
```

Assert compact output keeps it:

```powershell
$repo = @($data.repos | Where-Object { $_.name -eq 'no-commit-session-repo' })[0]
@($repo.sessionEvidence).Count | Should Be 1
$repo.sessionEvidence[0].title | Should Be 'Investigate no commit repo'
```

- [ ] **Step 3: Add `sessionEvidence` to path map entries**

In `Add-PathItem`, extend map entry:

```powershell
sessionEvidence = [System.Collections.Generic.List[object]]::new()
```

Add optional parameter:

```powershell
[object]$SessionEvidence = $null
```

After adding source:

```powershell
if ($null -ne $SessionEvidence) {
  $Map[$normalized].sessionEvidence.Add($SessionEvidence)
}
```

- [ ] **Step 4: Pass session evidence from session orchestration**

When adding session items, call:

```powershell
Add-PathItem -Map $repoMap -Path $item.path -Source $item.source -SessionEvidence ([ordered]@{
  source = $item.source
  path = $path
})
```

If Task 4 extends session row objects with title, include:

```powershell
title = $item.title
```

If title is not available from current function return shape, keep `path` and `source`; do not invent titles.

- [ ] **Step 5: Include `sessionEvidence` in repo output**

In both git repo output paths, add:

```powershell
sessionEvidence = @($item.sessionEvidence)
```

For zero filtered commits, warning should become:

```powershell
Add-WarningMessage -List $repoWarnings -Message 'No current-user commits found in the selected range.'
```

when `$authorScope -eq 'current'`; keep existing `No commits found in the selected range.` when author filtering is not applied.

- [ ] **Step 6: Update formatter to preserve session evidence**

In `format-daily-work-log-evidence.ps1`, add `sessionEvidence` to each compact repo object:

```powershell
sessionEvidence = @($repo.sessionEvidence | Select-Object -First 5)
```

- [ ] **Step 7: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected: no-commit repo tests pass; compact formatter includes `sessionEvidence`.

---

### Task 8: Update Skill Documentation and Evals

**Files:**
- Modify: `skills/daily-work-log/SKILL.md`
- Modify: `skills/daily-work-log/README.md`
- Modify: `skills/daily-work-log/evals/evals.json`

**Interfaces:**
- Consumes: collector/formatter behavior from Tasks 2-7.
- Produces: user-facing instructions and eval expectations aligned with the new behavior.

- [ ] **Step 1: Update `SKILL.md` workflow before current step 1**

Add a new workflow step before “Confirm scope and defaults”:

```markdown
1. **Recall collection preferences before collecting**
   - Before running the helper, try to recall user or project-specific daily-log collection preferences.
   - Search terms should include `daily-work-log`, `工作日誌`, `日誌`, the current working directory, user-mentioned repo / project names, `scan root`, and `repo discovery`.
   - If useful context is found, translate it into helper parameters or final-summary rules.
   - If recall is unavailable, fails, or returns no useful result, stay silent and continue with the default helper workflow.
   - Do not add project-specific rules to this skill; project-specific collection habits belong in memory.
```

Renumber later workflow steps.

- [ ] **Step 2: Update `SKILL.md` collector behavior bullets**

Add bullets under “Run the bundled collector”:

```markdown
   - In `session` mode, if a session path is a safe aggregate directory rather than a git repo, the collector expands nested git repos / worktrees using fast `.git` marker discovery.
   - The default author scope is the current user. Commits and PRs from other authors are excluded unless they are release / deploy bot commits with PR-chain evidence back to current-user work.
   - If a repo has session evidence but no current-user commits, keep it in the final report as one short agent-written session summary when evidence is sufficient; do not invent details.
```

- [ ] **Step 3: Update `SKILL.md` JSON shape**

Add to `meta` line:

```markdown
`authorScope`, `currentIdentity`
```

Add to `repos[]` line:

```markdown
optional `sessionEvidence`
```

Add to `commits[]` line:

```markdown
`authorEmail`
```

- [ ] **Step 4: Update `README.md` with matching behavior**

Add concise bullets mirroring `SKILL.md`:

```markdown
- `session` discovery can expand safe aggregate directories into nested git repos / worktrees.
- Default `authorScope` is `current`; if identity cannot be resolved, helper falls back to all authors with a warning.
- Repos with session evidence but no current-user commits remain in JSON through `sessionEvidence` for agent-generated one-line summaries.
```

- [ ] **Step 5: Add evals to `evals/evals.json`**

Add three eval objects with new unique IDs:

```json
{
  "id": 12,
  "prompt": "幫我整理今天工作日誌。這個專案之前可能有特殊蒐集習慣，但我現在沒講清楚。",
  "expected_output": "先嘗試 recall daily-work-log / 工作日誌 / 日誌 / repo discovery / scan root 等偏好；若沒有命中則安靜使用預設 collector，不報錯。",
  "assertions": [
    "Before collection, the agent attempts to recall user or project-specific daily-log collection preferences.",
    "Recall failure or no result does not block collection."
  ]
}
```

```json
{
  "id": 13,
  "prompt": "OpenCode session 目錄是某個大型工作資料夾，該資料夾本身不是 git repo，但底下有多個 repo 和 worktree。請整理今天工作日誌。",
  "expected_output": "collector 在 session mode 自動安全展開 nested git repos / worktrees，優先用快速 .git marker discovery，不要求使用者手動提供 ScanRoots。",
  "assertions": [
    "Safe aggregate session directories are expanded into nested git repositories or worktrees.",
    "The behavior is generalized and does not depend on a hard-coded project name."
  ]
}
```

```json
{
  "id": 14,
  "prompt": "同一個 repo 今天有我、其他同事、bot release commit；另有一個 repo 只有我今天的 session activity 但沒有 commit。請整理我的今日工作日誌。",
  "expected_output": "預設只列目前使用者相關 commit/PR；release/deploy bot commit 只有 PR-chain 關聯才列；無本人 commit 但有 session evidence 的 repo 由 agent 摘成一條短工作紀錄。",
  "assertions": [
    "Default output filters commits and PRs to current-user evidence.",
    "Release or deploy bot commits require PR-chain evidence to current-user work.",
    "Repos with session evidence but no current-user commits are summarized as one short work-log bullet when evidence is sufficient."
  ]
}
```

- [ ] **Step 6: Run JSON validation**

Run:

```powershell
node -e "JSON.parse(require('fs').readFileSync('C:/develop/projects/@sevenflanks-skills/skills/daily-work-log/evals/evals.json','utf8')); console.log('evals json ok')"
```

Expected: `evals json ok`.

---

### Task 9: Full Verification and Diff Review

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: validated implementation ready for review.

- [ ] **Step 1: Run focused tests**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\tests\collect-daily-work-log.tests.ps1"
```

Expected: all Pester tests pass.

- [ ] **Step 2: Run repo validation**

Run from repo root:

```powershell
npm run validate
```

Expected: command exits 0.

- [ ] **Step 3: Run a real collector smoke test with formatting**

Run:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\scripts\collect-daily-work-log.ps1" |
  pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\scripts\format-daily-work-log-evidence.ps1" -MaxCommitsPerRepo 3
```

Expected: valid compact JSON with `meta.authorScope`, `meta.currentIdentity`, and no mixed human text on stdout.

- [ ] **Step 4: Inspect diff**

Run:

```powershell
git -C "C:\develop\projects\@sevenflanks-skills" diff -- skills/daily-work-log docs/superpowers/specs/2026-07-01-daily-work-log-collection-generalization-design.md docs/superpowers/plans/2026-07-01-daily-work-log-collection-generalization.md
```

Expected: only intended daily-work-log collector, formatter, docs, evals, tests, spec, and plan changes.

- [ ] **Step 5: Report without committing**

Summarize:

- tests run and results,
- behavior changes,
- warnings or known limitations,
- whether a commit is requested.

Do not run `git commit` unless the user explicitly asks.

---

## Self-Review Notes

- Spec coverage: tasks cover recall workflow, aggregate session expansion, fast `rg` discovery, current identity author filtering, PR-chain bot release/deploy handling, no-commit session evidence, formatter preservation, docs, evals, and verification.
- Placeholder scan: this plan intentionally avoids unfinished-placeholder language; each code-changing task includes concrete snippets or replacement instructions.
- Type consistency: planned metadata names are `authorScope`, `currentIdentity`, `authorEmail`, `sessionEvidence`, and `session-expanded`; the same names are used in collector, formatter, tests, docs, and evals.
