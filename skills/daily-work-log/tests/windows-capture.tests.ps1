[CmdletBinding()]
param(
  [string]$EvidenceRoot,
  [ValidateSet('none', 'utf16')][string]$Mutation = 'none'
)

# Seam: execute the documented capture/selection recipes and real formatter CLI.
# Observer: a consumer reading UTF-8 JSON and selected sessions, never raw stdout.
# Breaks: PS5 UTF-16 redirect, damaged JSON/quotes/newlines, wrong worktree/session selection.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this test driver with pwsh 7+.' }
$skillRoot = Split-Path -Parent $PSScriptRoot
$recipePath = Join-Path $skillRoot 'references/evidence-views.md'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$ps5 = (Get-Command powershell.exe -ErrorAction Stop).Source
$null = Get-Command python -ErrorAction Stop
$parent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Missing temporary parent.' }
if ($EvidenceRoot -and -not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'EvidenceRoot must already exist.' }
$root = Join-Path $parent ("capture 中文 'quoted' spaces-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Utf8($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
try {
  $note = "中文第一行`n第二行含 `"double quotes`"、'single quotes'、反斜線 C:\synthetic\尾端\"
  $session = "session `"中文`"`n'continued'"
  $large = ("LARGE-PRIVATE-SYNTHETIC 中文 `"quoted`" 'single' \`n" * 24000)
  $fixture = [ordered]@{
    meta = @{from='2026-05-29T00:00:00+08:00';to='2026-05-29T23:59:59+08:00';note=$note;canGenerateLog=$true;collectionStatus='partial';sources=@{opencode=@{available=$true;readStatus='success'};codex=@{available=$true;readStatus='partial';coverage=@{complete=$false;limitHits=@('fileBytes')}}}}
    warnings=@('合成缺口');errors=@();repos=@(
      @{name='worktree-a';path='C:\synthetic\a';githubRepo='fixture/shared';source=@('session');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='opencode';source='session';sessionId=$session;title=$note},
        @{agent='opencode';source='session';sessionId='not-selected';title=$large})},
      @{name='worktree-b';path='C:\synthetic\b';githubRepo='fixture/shared';source=@('codex');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='codex';source='codex';sessionId='parent';sessionIds=@('parent',$session);title=$note;role='user'})},
      @{name='other-repo';githubRepo='fixture/other';source=@('session');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='opencode';sessionId=$session;title=$large})}
    )
  }
  Write-Utf8 "$root\fixture.json" ($fixture | ConvertTo-Json -Depth 100)
  # The only replacement is the external collector boundary; no source entry is probed.
  Write-Utf8 "$root\synthetic-collector.ps1" @'
param([string]$From, [string]$To, [string]$Timezone, [string]$Note, [switch]$ProbeOnly)
$ErrorActionPreference = 'Stop'
$data = Get-Content -LiteralPath "$PSScriptRoot/fixture.json" -Raw -Encoding utf8 | ConvertFrom-Json
if ($Note -cne $data.meta.note -or $From -ne $data.meta.from -or $To -ne $data.meta.to -or $Timezone -ne 'Asia/Taipei') { throw 'Parameter round-trip damaged.' }
[IO.File]::AppendAllText("$PSScriptRoot/calls.txt", $(if ($ProbeOnly) { "probe`n" } else { "collect`n" }))
if ($ProbeOnly) { @{meta=$data.meta} | ConvertTo-Json -Depth 100 } else { Get-Content -LiteralPath "$PSScriptRoot/fixture.json" -Raw -Encoding utf8 }
'@
  Write-Utf8 "$root\scenario.ps1" @'
param([string]$Root, [string]$RecipePath, [string]$SkillRoot, [string]$Mutation)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$recipes = @{}
$markdown = [IO.File]::ReadAllText($RecipePath, [Text.Encoding]::UTF8)
foreach ($match in [regex]::Matches($markdown, '(?ms)^```powershell\r?\n# recipe: ([\w-]+)\r?\n(.*?)^```')) {
  $recipes[$match.Groups[1].Value] = [scriptblock]::Create($match.Groups[2].Value)
}
$taskRoot = $null
try {
  . $recipes.setup
  $fixture = Get-Content -LiteralPath "$Root/fixture.json" -Raw -Encoding utf8 | ConvertFrom-Json
  $collectorPath = Join-Path $Root 'synthetic-collector.ps1'
  $parameters = @{From=$fixture.meta.from;To=$fixture.meta.to;Timezone='Asia/Taipei';Note=$fixture.meta.note}
  [IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 100), $utf8)
  if ($Mutation -eq 'utf16') {
    $capture = $capture.Replace('Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM', 'Out-File -LiteralPath $OutputPath -Encoding unicode')
    [IO.File]::WriteAllText($capturePath, $capture, $utf8)
  }
  $probeOutput = @(. $recipes.probe)
  Assert ($probe.meta.sources.opencode.available -and $probe.meta.sources.codex.available) 'Synthetic probe unavailable.'
  # This orchestration models the announcement boundary; no actual collection precedes it.
  Assert ([IO.File]::ReadAllText("$Root/calls.txt") -eq "probe`n") 'Collection occurred before announcement boundary.'
  Assert (@(. $recipes.collect).Count -eq 0) 'Capture leaked raw JSON into tool stdout.'
  Assert (@(. $recipes.format).Count -eq 0) 'Formatter leaked ERP JSON into tool stdout.'
  foreach ($path in @($probePath,$rawPath,$erpPath)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert ($bytes.Length -gt 0 -and [Array]::IndexOf($bytes, [byte]0) -eq -1 -and $bytes[0] -ne 255 -and $bytes[0] -ne 239) 'Capture is not BOM-less UTF-8 (UTF-16/default redirect regression).'
    $null = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes)
  }
  $original = [IO.File]::ReadAllText("$Root/fixture.json", [Text.Encoding]::UTF8)
  $captured = [IO.File]::ReadAllText($rawPath, [Text.Encoding]::UTF8)
  Assert ($original.TrimEnd("`r","`n") -ceq $captured.TrimEnd("`r","`n")) 'Raw Chinese/quotes/newlines/large output changed in transit.'
  $index = (. $recipes.index) -join "`n"
  Assert ($index.Length -lt 16000 -and $index -notmatch 'LARGE-PRIVATE-SYNTHETIC') 'Index leaked large session content.'
  $indexData = $index | ConvertFrom-Json
  Assert (@($indexData.repos).Count -eq 3 -and $indexData.repos[0].sessions -eq 2) 'Index omitted repo/session counts.'
  Assert ($evidence.repos[0].sessionEvidence[1].title -ceq $fixture.repos[0].sessionEvidence[1].title) 'ERP formatter damaged large payload.'
  Assert ($evidence.repos[0].sessionEvidence[0].title -ceq $fixture.meta.note -and -not $evidence.meta.sources.codex.coverage.complete) 'ERP lost multilingual evidence or coverage gap.'
  $selection = @{githubRepo='fixture/shared';sessionId=$fixture.repos[0].sessionEvidence[0].sessionId}
  Assert (@(. $recipes.select).Count -eq 0) 'Selection leaked raw payload into tool stdout.'
  $selectedText = Get-Content -LiteralPath $selectedPath -Raw -Encoding utf8
  $selected = $selectedText | ConvertFrom-Json
  Assert (@($selected).Count -eq 2 -and $selected[0].name -eq 'worktree-a' -and $selected[1].name -eq 'worktree-b') 'Selection lost worktree or included another canonical repo.'
  Assert (@($selected[0].sessionEvidence).Count -eq 1 -and @($selected[1].sessionEvidence).Count -eq 1) 'Selection retained unrelated sessions or lost continuation.'
  Assert ($selected[0].sessionEvidence[0].sessionId -ceq $selection.sessionId -and $selected[1].sessionEvidence[0].sessionIds[1] -ceq $selection.sessionId) 'Quoted/multiline selector or continuation changed.'
  Assert ($selected[0].sessionEvidence[0].title -ceq $fixture.meta.note -and $selectedText.Length -lt 16000 -and $selectedText -notmatch 'LARGE-PRIVATE-SYNTHETIC') 'Selected read damaged text or included large unselected content.'
  Assert ([IO.File]::ReadAllText("$Root/calls.txt") -eq "probe`ncollect`n") 'Formatter/selection recollected evidence.'
  $run = Join-Path $Root ('result-' + $PSVersionTable.PSVersion.Major)
  $null = New-Item -ItemType Directory -Path $run
  foreach ($path in @($probePath,$rawPath,$erpPath,$selectedPath)) { Copy-Item -LiteralPath $path -Destination $run }
  [IO.File]::WriteAllText((Join-Path $run 'index.json'), $index, $utf8)
  [IO.File]::WriteAllText((Join-Path $run 'runtime.json'), (@{caller=$PSVersionTable.PSVersion.ToString();rawBytes=(Get-Item -LiteralPath $rawPath).Length;selectedBytes=(Get-Item -LiteralPath $selectedPath).Length;processId=$PID} | ConvertTo-Json), $utf8)
} finally {
  if ($taskRoot -and (Test-Path -LiteralPath $taskRoot)) { . $recipes.cleanup }
}
'@
  foreach ($shell in @($ps5, $pwsh)) {
    if (Test-Path -LiteralPath "$root\calls.txt") { Remove-Item -LiteralPath "$root\calls.txt" }
    # Process-only policy for synthetic scripts; no registry/profile/global change.
    & $shell -NoProfile -ExecutionPolicy Bypass -File "$root\scenario.ps1" -Root $root -RecipePath $recipePath -SkillRoot $skillRoot -Mutation $Mutation
    if ($LASTEXITCODE -ne 0) { throw "Windows capture failed with $shell (mutation=$Mutation)." }
  }
  if ($EvidenceRoot) {
    $destination = Join-Path $EvidenceRoot ('windows-capture-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $destination
    Copy-Item -Path "$root\result-*" -Destination $destination -Recurse
    "Synthetic evidence: $destination"
  }
  'PASS Windows PowerShell 5.1 -> pwsh 7 and pwsh 7 -> pwsh 7; UTF-8 capture, JSON arguments, real formatter, selected Python file reads.'
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
