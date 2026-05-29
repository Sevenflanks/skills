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

function Get-OpenCodeLogRoot {
  $homePath = [Environment]::GetFolderPath('UserProfile')
  $candidate = Join-Path $homePath '.local\share\opencode\log'
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
      $content = Read-SharedTextFile -Path $file.FullName
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
      if (Test-GitRepo -RepositoryPath $root) {
        $repos.Add((Get-Item -LiteralPath $root).FullName)
      }

      $gitMarkers = Get-ChildItem -LiteralPath $root -Force -Filter '.git' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Parent }

      foreach ($gitMarker in $gitMarkers) {
        if ($gitMarker.Parent) {
          $repos.Add($gitMarker.Parent.FullName)
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
      branchHints = (Get-BranchHintsFromRefs -Refs $refs)
      issuesMentioned = $issuesMentioned
    })
  }

  return $records
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
    [object]$PrDetails
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

  return $false
}

function Get-GhContext {
  param(
    [string]$RepositoryPath,
    [string]$GithubRepo,
    [datetimeoffset]$FromRange,
    [datetimeoffset]$ToRange,
    [object[]]$Commits,
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

    if (-not (Test-PrMatchesCommits -Commits $Commits -Pr $pr -PrDetails $prDetails)) {
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
  $range = Resolve-DateRange -FromInput $From -ToInput $To -TimezoneId $Timezone
  $resolvedFrom = $range.From
  $resolvedTo = $range.To

  if ($SourceMode -in @('session', 'mixed')) {
    foreach ($path in Get-SessionDirectoriesFromLogs -FromRange $resolvedFrom -ToRange $resolvedTo -Warnings $warnings) {
      Add-PathItem -Map $repoMap -Path $path -Source 'session'
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

    if (@($commits).Count -eq 0) {
      Add-WarningMessage -List $repoWarnings -Message 'No commits found in the selected range.'

      $repos.Add([ordered]@{
        name = $repoName
        path = $repoPath
        source = $sources
        isGitRepo = $true
        githubRepo = $null
        commits = $commits
        prs = $prs
        warnings = $repoWarnings
      })
      continue
    }

    $remoteResult = Invoke-Native -FilePath 'git' -Arguments @('remote', 'get-url', 'origin') -WorkingDirectory $repoPath
    if ($remoteResult.ExitCode -eq 0) {
      $githubRepo = Parse-GithubRepo -RemoteUrl $remoteResult.StdOut
    }

    if ($ghAvailable) {
      $prs = Get-GhContext -RepositoryPath $repoPath -GithubRepo $githubRepo -FromRange $resolvedFrom -ToRange $resolvedTo -Commits $commits -Warnings $repoWarnings
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
