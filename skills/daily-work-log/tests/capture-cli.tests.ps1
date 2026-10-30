param([ValidateSet('none','utf16')][string]$Mutation = 'none')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../scripts/capture-daily-work-log.ps1'
$formatter = Join-Path $PSScriptRoot '../scripts/format-daily-work-log-evidence.ps1'
$parent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Temporary parent unavailable.' }
$root = Join-Path $parent ("capture-cli 中文 'quoted' spaces-" + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), $utf8) }
try {
  if ($Mutation -eq 'utf16') {
    $text = [IO.File]::ReadAllText($helper).Replace('[Text.UTF8Encoding]::new($false)','[Text.Encoding]::Unicode')
    $helper = "$root/mutated-capture.ps1"
    [IO.File]::WriteAllText($helper, $text, $utf8)
  }
  # Only the external collector is replaced. The caller/helper/formatter use their real public CLIs.
  [IO.File]::WriteAllText("$root/collector.ps1", @'
param([string]$From,[string]$To,[string]$Timezone,[string]$Note,[string[]]$ScanRoots,[switch]$ProbeOnly,[switch]$Invalid,[switch]$Fail)
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText("$PSScriptRoot/calls.txt", $(if ($ProbeOnly) { "probe`n" } else { "collect`n" }))
if ($Fail) { exit 9 }
if ($Invalid) { 'invalid JSON'; return }
if ($ScanRoots.Count -ne 2 -or $ScanRoots[1] -cne "C:\synthetic\quoted 'two'") { throw 'Array parameter damaged.' }
if (-not $ProbeOnly -and ($From -ne '2026-10-29T00:00:00+08:00' -or $To -ne '2026-10-30T00:00:00+08:00' -or $Timezone -ne 'Asia/Taipei')) { throw 'Probe boundaries were not frozen.' }
@{meta=@{probeOnly=[bool]$ProbeOnly;from='2026-10-29T00:00:00+08:00';to='2026-10-30T00:00:00+08:00';timezone='Asia/Taipei';sources=@{opencode=@{available=$true;readStatus='success'}}};repos=@(@{name='fixture';githubRepo='fixture/shared';commits=@();prs=@();sessionEvidence=@(@{sessionId='child';title=$Note});warnings=@()});warnings=@();errors=@()} | ConvertTo-Json -Depth 100
'@, $utf8)
  # ASCII caller is parseable in PS5.1 under any local ANSI codepage.
  [IO.File]::WriteAllText("$root/caller.ps1", @'
param([string]$Helper,[string]$Collector,[string]$Parameters,[string]$Output,[string]$Mode,[string]$Probe)
$ErrorActionPreference = 'Stop'
$arguments = @{Mode=$Mode;ScriptPath=$Collector;ParametersPath=$Parameters;OutputPath=$Output}
if ($Probe) { $arguments.ProbePath = $Probe }
& $Helper @arguments
exit $LASTEXITCODE
'@, $utf8)
  $note = ("中文`n'quoted' double: `"text`" C:\synthetic\" * 18000)
  $params = @{Note=$note;From='2026-10-29T00:00:00.0000000+08:00';To='2026-10-29T16:00:00Z';Timezone='Asia/Taipei';ScanRoots=@('C:\synthetic\one',"C:\synthetic\quoted 'two'")}
  foreach ($shell in @((Get-Command powershell.exe).Source,(Get-Command pwsh).Source)) {
    $label = [IO.Path]::GetFileNameWithoutExtension($shell)
    $probe = "$root/$label-probe.json"
    $raw = "$root/$label-raw.json"
    Write-Json "$root/params.json" $params
    $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File "$root/caller.ps1" -Helper $helper -Collector "$root/collector.ps1" -Mode probe -Parameters "$root/params.json" -Output $probe)
    Assert ($LASTEXITCODE -eq 0 -and $out.Count -eq 0) "$label probe must succeed without raw stdout."
    $calls = [IO.File]::ReadAllLines("$root/calls.txt")
    Assert ($calls[-1] -eq 'probe' -and @($calls | Where-Object { $_ -eq 'collect' }).Count -eq $(if ($label -eq 'powershell') {0} else {1})) 'Probe collected automatically.'
    $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File "$root/caller.ps1" -Helper $helper -Collector "$root/collector.ps1" -Mode collect -Parameters "$root/params.json" -Output $raw -Probe $probe)
    Assert ($LASTEXITCODE -eq 0 -and $out.Count -eq 0) "$label collect must use fixed probe boundaries without raw stdout."
    foreach ($file in @($probe,$raw)) {
      $bytes = [IO.File]::ReadAllBytes($file)
      Assert ($bytes[0] -ne 239 -and $bytes[0] -ne 255 -and [Array]::IndexOf($bytes,[byte]0) -eq -1) "$label capture is not BOM-less UTF8."
      $null = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    }
    $data = [IO.File]::ReadAllText($raw) | ConvertFrom-Json -Depth 100
    Assert ($data.repos[0].sessionEvidence[0].title -ceq $note) "$label capture damaged large Unicode/quotes/newlines parameter."
    Write-Json "$root/view.json" @{InputPath=$raw;View='raw';JsonPointer='/repos/0/sessionEvidence/0/title'}
    $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File "$root/caller.ps1" -Helper $helper -Collector $formatter -Mode format -Parameters "$root/view.json" -Output "$root/$label-selected.json")
    Assert ($LASTEXITCODE -eq 0 -and $out.Count -eq 0) "$label formatter capture failed."
    $selected = [IO.File]::ReadAllText("$root/$label-selected.json") | ConvertFrom-Json -Depth 100
    Assert ($selected.value -ceq $note -and $selected.detailRef.inputPath -ceq $raw) "$label raw selection changed capture provenance or text."
  }
  $pwsh = (Get-Command pwsh).Source
  $before = [IO.File]::ReadAllText("$root/calls.txt")
  foreach ($fault in @('missing-probe','different-day','unavailable','not-probe','overwrite-input')) {
    $args = @('-NoProfile','-File',$helper,'-Mode','collect','-ScriptPath',"$root/collector.ps1",'-ParametersPath',"$root/params.json",'-OutputPath',"$root/$fault.json")
    Write-Json "$root/params.json" $(if ($fault -eq 'different-day') { @{From='2026-10-28T00:00:00+08:00'} } else { @{Note='safe'} })
    $probeData = @{meta=@{probeOnly=($fault -ne 'not-probe');from='2026-10-29T00:00:00+08:00';to='2026-10-30T00:00:00+08:00';timezone='Asia/Taipei';sources=@{opencode=@{available=($fault -ne 'unavailable')}}};errors=@()}
    Write-Json "$root/guard-probe.json" $probeData
    if ($fault -ne 'missing-probe') { $args += @('-ProbePath',"$root/guard-probe.json") }
    if ($fault -eq 'overwrite-input') { $args[-3] = "$root/params.json" }
    $null = & $pwsh @args 2>&1
    Assert ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText("$root/calls.txt") -ceq $before) "$fault should stop before collection."
  }
  foreach ($fault in @('invalid','fail')) {
    Write-Json "$root/params.json" $(if ($fault -eq 'invalid') { @{Invalid=$true} } else { @{Fail=$true} })
    $null = & $pwsh -NoProfile -File $helper -Mode probe -ScriptPath "$root/collector.ps1" -ParametersPath "$root/params.json" -OutputPath "$root/$fault.json" 2>&1
    Assert ($LASTEXITCODE -eq $(if ($fault -eq 'fail') {9} else {1})) "$fault did not retain failure exit status."
  }
  $calls = [IO.File]::ReadAllLines("$root/calls.txt")
  Assert ($calls.Count -eq 6 -and ($calls -join ',') -eq 'probe,collect,probe,collect,probe,probe') 'Capture retried, probed/collected implicitly or skipped an explicit request.'
  'PASS capture CLI: PS5.1/7 callers, UTF8 file params, large Unicode, fixed probe range, explicit modes, failure/no-retry guards.'
} finally { [IO.Directory]::Delete($root, $true) }
