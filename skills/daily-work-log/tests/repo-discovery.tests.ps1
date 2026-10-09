[CmdletBinding()]
param([ValidateSet('cwd', 'all')][string]$Case = 'all', [string]$EvidenceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Collector syntax errors' }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
# 只替換 OS/CLI seams；SQL 在真正 SQLite 執行，discovery functions 保持原樣。
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-discovery-' + [guid]::NewGuid().ToString('N'))
$originalCwd = [Environment]::CurrentDirectory
$script:Mode = 'relative'; $script:Supplement = 'normal'; $script:Queries = [Collections.Generic.List[string]]::new()
$script:Python = (Get-Command python -ErrorAction Stop).Source
function opencode {}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Native {
  param([string]$FilePath, [string[]]$Arguments)
  Assert ($FilePath -eq 'opencode') 'Unexpected native call'
  $sql = $Arguments[-1]; $script:Queries.Add($sql)
  if ($script:Mode -eq 'db-fail') { return [pscustomobject]@{ExitCode=1;StdOut='';StdErr='synthetic DB failure'} }
  if ($sql -match 'join session') {
    switch ($script:Supplement) {
      'failed' { return [pscustomobject]@{ExitCode=1;StdOut='';StdErr='synthetic failure'} }
      'throw' { throw 'synthetic exception' }
      'invalid' { return [pscustomobject]@{ExitCode=0;StdOut='{invalid';StdErr=''} }
      'shape' { return [pscustomobject]@{ExitCode=0;StdOut='[{"tool":"bash"}]';StdErr=''} }
      'scalar' { return [pscustomobject]@{ExitCode=0;StdOut='42';StdErr=''} }
    }
  }
  $request = @{root=$root.Replace('\','/');mode=$script:Mode;sql=$sql} | ConvertTo-Json -Compress
  $raw = $request | & $script:Python (Join-Path $PSScriptRoot 'discovery-db-fixture.py')
  Assert ($LASTEXITCODE -eq 0) 'Synthetic SQLite query failed'
  return [pscustomobject]@{ExitCode=0;StdOut=($raw -join "`n");StdErr=''}
}
function Resolve-GitRepoRoot {
  param([string]$Path)
  foreach ($repo in @("$root\repo", "$root\other-repo")) {
    if ($Path -eq $repo -or $Path.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) { return $repo }
  }
  return $null
}
function Get-SessionDirectoriesFromDirectoryReadme { throw 'Unexpected fallback' }
function Get-SessionDirectoriesFromLogs { throw 'Unexpected fallback' }
function Discover {
  $script:GitRepoRootCache = @{}; $script:OpenCodeReadSucceeded = $false
  $script:OpenCodeReadFailures = 0; $script:OpenCodeActivityCount = 0
  $script:Warnings = [Collections.Generic.List[string]]::new(); $script:Queries.Clear()
  return @(Get-SessionDirectories -FromRange ([datetimeoffset]::FromUnixTimeMilliseconds(1791388800000)) -ToRange ([datetimeoffset]::FromUnixTimeMilliseconds(1791475199999)) -TimezoneId 'Asia/Taipei' -Warnings $script:Warnings)
}
$passes = [Collections.Generic.List[string]]::new()
try {
  foreach ($dir in @('home','repo','other-repo')) { $null = [IO.Directory]::CreateDirectory("$root\$dir") }
  $sets = @()
  foreach ($cwd in @('home','repo','other-repo')) {
    [Environment]::CurrentDirectory = "$root\$cwd"
    $paths = @(Discover)
    $sets += ,@($paths | ForEach-Object path | Sort-Object -Unique)
  }
  Assert (($sets[0] -join '|') -eq ($sets[1] -join '|') -and ($sets[1] -join '|') -eq ($sets[2] -join '|')) 'CWD invariance: same relative session fixture falsely attributes process repo'
  Assert ($sets[0].Count -eq 0) 'Relative/root-relative/drive-relative session paths accepted'
  $passes.Add('cwd-invariance-relative-root-drive')
  if ($Case -eq 'cwd') { @{passes=@($passes)} | ConvertTo-Json; return }
  $script:Mode = 'normal'
  $normalSets = @()
  foreach ($cwd in @('home','repo','other-repo')) {
    [Environment]::CurrentDirectory = "$root\$cwd"
    $normalSets += ,(@(Discover) | ConvertTo-Json -Depth 10 -Compress)
  }
  Assert ($normalSets[0] -eq $normalSets[1] -and $normalSets[1] -eq $normalSets[2]) 'Metadata plus workdir fixture depends on CWD'
  $passes.Add('cwd-invariance-metadata-plus-workdir')
  $paths = @(Discover)
  Assert (@($paths | Where-Object { $_.evidence.sessionId -eq 'parent' -and $_.path -eq "$root\repo" }).Count -eq 1) 'Home parent structured workdir did not recover repo or dedup session/path'
  Assert (@($paths | Where-Object path -eq "$root\other-repo").Count -eq 0) 'Out-of-range part/session or unknown tool leaked'
  Assert (@($paths | Where-Object { $_.evidence.sessionId -eq 'metadata' }).Count -eq 1) 'directory/path duplicate evidence'
  $evidence = @($paths | Where-Object { $_.evidence.sessionId -eq 'parent' -and $_.path -eq "$root\repo" })[0].evidence
  Assert ($evidence.pathSource -eq 'bash-workdir' -and $evidence.tool -eq 'bash' -and $evidence.timestamp -eq 1791388800000 -and $evidence.discoverySource -eq 'session') 'Structured provenance lost'
  Assert (($script:Warnings -join '|') -match 'workdir.*resolved' -and -not (($script:Warnings -join '|').Contains($root))) 'Missing/deleted worktree warning absent or leaks path'
  Assert ($script:Queries.Count -eq 2 -and $script:Queries[1] -match 'limit 2049' -and $script:Queries[1] -notmatch 'select\s+\*') 'Supplement query is not single bounded projection'
  $passes.Add('home-parent-range-shape-existence-dedup-provenance')
  $sample = @{meta=@{sources=@{opencode=@{readStatus='partial'}};collectionStatus='partial'};warnings=@($script:Warnings);errors=@();repos=@(@{name='repo';path="$root\repo";sessionEvidence=@($evidence);commits=@();prs=@();warnings=@()})}
  $json = $sample | ConvertTo-Json -Depth 10
  $compact = ($json | & (Join-Path $PSScriptRoot '..\scripts\format-daily-work-log-evidence.ps1')) | ConvertFrom-Json
  Assert ($compact.repos[0].sessionEvidence[0].pathSource -eq 'bash-workdir' -and $compact.meta.collectionStatus -eq 'partial') 'Formatter drops provenance/status'
  if ($EvidenceRoot) { [IO.File]::WriteAllText("$EvidenceRoot\representative-sanitized.json", $json.Replace($root.Replace('\','\\'), 'C:\\synthetic')) }
  $passes.Add('formatter')
  $script:Mode = 'cap'
  $paths = @(Discover)
  Assert (($script:Warnings -join '|') -match '2048' -and $script:OpenCodeReadFailures -gt 0) '2049 sentinel did not reveal partial gap'
  Assert (@($paths | Where-Object path -eq "$root\other-repo").Count -eq 0) '2049 sentinel was processed as repository evidence'
  Assert (@($paths | Where-Object { $_.evidence.sessionId -eq 'parent' -and $_.path -eq "$root\repo" }).Count -eq 1) 'Capped rows lost retained evidence or duplicate session/path'
  $passes.Add('2048-plus-sentinel')
  $script:Mode = 'empty'
  $paths = @(Discover)
  Assert ($paths.Count -eq 0 -and $script:Queries.Count -eq 1 -and $script:OpenCodeReadSucceeded) 'DB empty queried parts or used fallback'
  $passes.Add('empty-authority')
  $script:Mode = 'normal'
  foreach ($failure in @('failed','throw','invalid','shape','scalar')) {
    $script:Supplement = $failure; $paths = @(Discover)
    Assert ($script:OpenCodeReadSucceeded -and $script:OpenCodeReadFailures -gt 0 -and @($paths | Where-Object { $_.evidence.sessionId -eq 'metadata' }).Count -eq 1) "$failure supplement destroyed metadata success/partial"
    Assert ($script:Warnings.Count -gt 0 -and $script:Queries.Count -eq 2) "$failure supplement hid gap or retried"
    $passes.Add("partial-$failure")
  }
  # 同一正規化規則用於可達的 fallback；合法 absolute 與既有 fallback 順序維持。
  foreach ($name in @('Get-SessionDirectoriesFromDirectoryReadme','Get-SessionDirectoriesFromLogs')) {
    $definition = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name }
    Invoke-Expression $definition.Extent.Text
  }
  $script:Mode = 'db-fail'; $script:Supplement = 'normal'
  $null = [IO.Directory]::CreateDirectory("$root\storage\directory-readme")
  $null = [IO.Directory]::CreateDirectory("$root\logs")
  $injected = @{updatedAt=1791388800000;injectedPaths=@('Users/synthetic','C:repo','\repo','/repo',"$root\repo")} | ConvertTo-Json -Compress
  [IO.File]::WriteAllText("$root\storage\directory-readme\synthetic.json", $injected)
  $log = @('Users/synthetic','C:repo','\repo','/repo',"$root\other-repo") | ForEach-Object { "INFO  2026-10-08T10:00:00 +1ms permission=external_directory path=$_" }
  [IO.File]::WriteAllText("$root\logs\synthetic.log", ($log -join "`n"))
  foreach ($fallback in @('directory-readme','log')) {
    if ($fallback -eq 'log') { [IO.Directory]::Delete("$root\storage\directory-readme", $true) }
    foreach ($cwd in @('home','repo','other-repo')) {
      [Environment]::CurrentDirectory = "$root\$cwd"
      $script:GitRepoRootCache = @{}; $script:Warnings = [Collections.Generic.List[string]]::new()
      $found = @(Get-SessionDirectories -FromRange ([datetimeoffset]::FromUnixTimeMilliseconds(1791388800000)) -ToRange ([datetimeoffset]::FromUnixTimeMilliseconds(1791475199999)) -TimezoneId 'Asia/Taipei' -OverrideStorageRoot "$root\storage" -OverrideLogRoot "$root\logs" -Warnings $script:Warnings)
      $expected = if ($fallback -eq 'directory-readme') { "$root\repo" } else { "$root\other-repo" }
      Assert ($found.Count -eq 1 -and $found[0].path -eq $expected) "$fallback changed absolute contract or guessed CWD"
    }
    $passes.Add("fallback-$fallback-cwd")
  }
  foreach ($absolute in @('C:\synthetic\repo','C:/synthetic/repo','\\synthetic-server\share\repo')) {
    Assert ((ConvertTo-AbsoluteSessionPath $absolute) -eq [IO.Path]::GetFullPath($absolute)) 'Valid fully-qualified drive/UNC path destroyed'
  }
  $passes.Add('absolute-drive-and-unc')
  @{passes=@($passes);count=$passes.Count;privateDataRead=$false} | ConvertTo-Json -Depth 5
} finally {
  [Environment]::CurrentDirectory = $originalCwd
  if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
