[CmdletBinding()]
param(
  [datetimeoffset]$From,
  [datetimeoffset]$To,
  [ValidateSet('session', 'scan', 'mixed')]
  [string]$SourceMode = 'session',
  [string[]]$ScanRoots = @(),
  [string]$Timezone = 'Asia/Taipei'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    [string]$Source
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $normalized = [System.IO.Path]::GetFullPath($Path)
  if (-not $Map.ContainsKey($normalized)) {
    $Map[$normalized] = [ordered]@{
      path = $normalized
      source = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
  }

  $null = $Map[$normalized].source.Add($Source)
}

function Resolve-DateRange {
  param(
    [AllowNull()]
    [Nullable[datetimeoffset]]$FromInput,
    [AllowNull()]
    [Nullable[datetimeoffset]]$ToInput
  )

  if ($PSBoundParameters.ContainsKey('FromInput') -and $PSBoundParameters.ContainsKey('ToInput') -and $FromInput -and $ToInput) {
    return [ordered]@{ From = $FromInput; To = $ToInput }
  }

  $now = [datetimeoffset]::Now
  $start = [datetimeoffset]::new($now.Year, $now.Month, $now.Day, 0, 0, 0, $now.Offset)
  $end = $start.AddDays(1).AddTicks(-1)

  if ($FromInput) { $start = $FromInput }
  if ($ToInput) { $end = $ToInput }

  return [ordered]@{ From = $start; To = $end }
}

function Get-OpenCodeLogRoot {
  $homePath = [Environment]::GetFolderPath('UserProfile')
  $candidate = Join-Path $homePath '.local\share\opencode\log'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Get-SessionDirectoriesFromLogs {
  param(
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $logRoot = Get-OpenCodeLogRoot
  if (-not $logRoot) {
    Add-WarningMessage -List $Warnings -Message 'OpenCode log directory not found; session-derived repo discovery unavailable.'
    return @()
  }

  $paths = [System.Collections.Generic.List[string]]::new()
  $logFiles = Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log' | Sort-Object Name
  foreach ($file in $logFiles) {
    if ($file.LastWriteTime -lt $FromRange.LocalDateTime.AddDays(-1) -or $file.LastWriteTime -gt $ToRange.LocalDateTime.AddDays(1)) {
      continue
    }

    try {
      $content = [System.IO.File]::ReadAllText($file.FullName)
    }
    catch {
      Add-WarningMessage -List $Warnings -Message ("Failed to read OpenCode log: {0}" -f $file.FullName)
      continue
    }

    $matches = [regex]::Matches($content, 'service=default directory=(.+?) creating instance')
    foreach ($match in $matches) {
      $candidate = $match.Groups[1].Value.Trim()
      if ($candidate) {
        $paths.Add($candidate)
      }
    }
  }

  return $paths
}

function Get-ScanRepositories {
  param(
    [string[]]$Roots,
    [System.Collections.Generic.List[string]]$Warnings
  )

  $repos = [System.Collections.Generic.List[string]]::new()
  foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) {
      Add-WarningMessage -List $Warnings -Message ("Scan root not found: {0}" -f $root)
      continue
    }

    try {
      $gitDirs = Get-ChildItem -LiteralPath $root -Directory -Filter '.git' -Recurse -ErrorAction Stop
      foreach ($gitDir in $gitDirs) {
        if ($gitDir.Parent) {
          $repos.Add($gitDir.Parent.FullName)
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

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  foreach ($arg in $Arguments) {
    $null = $psi.ArgumentList.Add($arg)
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

function Get-CommitData {
  param(
    [string]$RepositoryPath,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange
  )

  $format = '%H%x1f%h%x1f%aI%x1f%an%x1f%s%x1f%D%x1e'
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

  $records = [System.Collections.Generic.List[object]]::new()
  $entries = $result.StdOut -split [char]0x1e
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $parts = $entry.Trim() -split [char]0x1f
    if ($parts.Count -lt 6) { continue }
    $refs = $parts[5]
    $subject = $parts[4]
    if ($refs -match 'refs/stash') { continue }
    if ($subject -match '^(index on|untracked files on) ') { continue }
    $issueMatches = [regex]::Matches(("{0} {1}" -f $subject, $refs), '#\d+')
    $issuesMentioned = [System.Collections.Generic.List[string]]::new()
    foreach ($issueMatch in $issueMatches) {
      if (-not $issuesMentioned.Contains($issueMatch.Value)) {
        $issuesMentioned.Add($issueMatch.Value)
      }
    }
    $records.Add([ordered]@{
      hash = $parts[0]
      short = $parts[1]
      date = $parts[2]
      author = $parts[3]
      subject = $subject
      refs = $refs
      issuesMentioned = $issuesMentioned
    })
  }

  return $records
}

function Get-GhContext {
  param(
    [string]$RepositoryPath,
    [string]$GithubRepo,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
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
      issuesClosed = $issuesClosed
    })
  }

  return $prs
}

$warnings = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$repoMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

try {
  $range = Resolve-DateRange -FromInput $From -ToInput $To
  $resolvedFrom = $range.From
  $resolvedTo = $range.To

  if ($SourceMode -in @('session', 'mixed')) {
    foreach ($path in Get-SessionDirectoriesFromLogs -FromRange $resolvedFrom -ToRange $resolvedTo -Warnings $warnings) {
      Add-PathItem -Map $repoMap -Path $path -Source 'session'
    }
  }

  if ($SourceMode -in @('scan', 'mixed') -and $ScanRoots.Count -gt 0) {
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
        warnings = @('Directory is not a git repository.')
      })
      continue
    }

    $commits = [System.Collections.Generic.List[object]]::new()
    $prs = [System.Collections.Generic.List[object]]::new()
    $githubRepo = $null

    try {
      $commits = Get-CommitData -RepositoryPath $repoPath -FromRange $resolvedFrom -ToRange $resolvedTo
    }
    catch {
      Add-WarningMessage -List $repoWarnings -Message $_.Exception.Message
    }

    $remoteResult = Invoke-Native -FilePath 'git' -Arguments @('remote', 'get-url', 'origin') -WorkingDirectory $repoPath
    if ($remoteResult.ExitCode -eq 0) {
      $githubRepo = Parse-GithubRepo -RemoteUrl $remoteResult.StdOut
    }

    if ($ghAvailable) {
      $prs = Get-GhContext -RepositoryPath $repoPath -GithubRepo $githubRepo -FromRange $resolvedFrom -ToRange $resolvedTo -Warnings $repoWarnings
    }

    if ($commits.Count -eq 0) {
      Add-WarningMessage -List $repoWarnings -Message 'No commits found in the selected range.'
    }

    $repos.Add([ordered]@{
      name = $repoName
      path = $repoPath
      source = $sources
      isGitRepo = $true
      githubRepo = $githubRepo
      commits = $commits
      prs = $prs
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
    }
    repos = @()
    warnings = $warnings
    errors = $errors
  } | ConvertTo-Json -Depth 8
}
