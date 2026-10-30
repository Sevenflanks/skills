[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('probe','collect','format')][string]$Mode,
  [Parameter(Mandatory = $true)][string]$ParametersPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [string]$ProbePath,
  [string]$ScriptPath,
  [switch]$InternalChild
)

# Keep this caller ASCII/PS5.1 compatible. JSON parsing and capture run only in pwsh 7+.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
  if (-not $ScriptPath) {
    $name = if ($Mode -eq 'format') { 'format-daily-work-log-evidence.ps1' } else { 'collect-daily-work-log.ps1' }
    $ScriptPath = Join-Path $PSScriptRoot $name
  }
  foreach ($name in @('ParametersPath','OutputPath','ScriptPath','ProbePath')) {
    $value = Get-Variable -Name $name -ValueOnly
    if ($value) { Set-Variable -Name $name -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value) }
  }
  if (-not $InternalChild) {
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $childArguments = @('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-InternalChild','-Mode',$Mode,'-ParametersPath',$ParametersPath,'-OutputPath',$OutputPath,'-ScriptPath',$ScriptPath)
    if ($ProbePath) { $childArguments += @('-ProbePath',$ProbePath) }
    & $pwsh @childArguments
    exit $LASTEXITCODE
  }
  if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Capture child requires pwsh 7+.' }
  if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputPath) -PathType Container)) { throw 'Output parent directory must already exist.' }
  $jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
  $jsonOptions.MaxDepth = 100
  $parameterJson = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($ParametersPath), $jsonOptions)
  try {
    if ($parameterJson.RootElement.ValueKind.ToString() -ne 'Object') { throw 'ParametersPath must contain a JSON object.' }
    $arguments = @{}
    foreach ($property in $parameterJson.RootElement.EnumerateObject()) {
      if ($arguments.ContainsKey($property.Name)) { throw 'Parameter names must be unique (case-insensitive).' }
      # Top-level strings remain strings (not inferred DateTime), including From/To and quoted JSON text.
      $arguments[$property.Name] = if ($property.Value.ValueKind.ToString() -eq 'String') { $property.Value.GetString() } else { ,($property.Value.GetRawText() | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate) }
    }
  }
  finally { $parameterJson.Dispose() }
  foreach ($inputFile in @($ParametersPath,$ScriptPath,$ProbePath,$PSCommandPath,$arguments['InputPath'])) {
    if ($inputFile -and $OutputPath -ieq $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$inputFile)) { throw 'OutputPath must not overwrite an input file.' }
  }
  if ($Mode -ne 'collect' -and $ProbePath) { throw 'ProbePath is only used by explicit collect mode.' }
  if ($Mode -in @('probe','collect')) {
    if ($arguments.Contains('ProbeOnly')) { throw 'Use Mode probe/collect instead of a ProbeOnly JSON parameter.' }
    if ($Mode -eq 'probe') { $arguments.ProbeOnly = $true }
    else {
      if (-not $ProbePath) { throw 'Collect requires an existing ProbePath; run probe and announce sources first.' }
      $probeText = [IO.File]::ReadAllText($ProbePath)
      $probe = $probeText | ConvertFrom-Json -AsHashtable -Depth 100
      if ($probe.meta.probeOnly -ne $true -or @($probe.errors).Count -gt 0) { throw 'ProbePath must contain a successful probe result.' }
      $available = @($probe.meta.sources.Values | Where-Object { $_.available -eq $true })
      if ($available.Count -eq 0) { throw 'No probe sources are available; stop without collection.' }
      # Freeze the probe range, even across midnight; never infer a new reporting day in collect.
      $probeJson = [System.Text.Json.JsonDocument]::Parse($probeText, $jsonOptions)
      try {
        foreach ($key in @('from','to','timezone')) {
          $value = $probeJson.RootElement.GetProperty('meta').GetProperty($key).GetString()
          if ([string]::IsNullOrWhiteSpace($value)) { throw "Probe is missing $key." }
          if ($arguments.ContainsKey($key)) {
            $matches = if ($key -eq 'timezone') { [string]$arguments[$key] -ceq $value } else { [datetimeoffset]::Parse([string]$arguments[$key]) -eq [datetimeoffset]::Parse($value) }
            if (-not $matches) { throw "Collect $key differs from the probe; stop without collection." }
          }
          $arguments[$key] = $value
        }
      }
      finally { $probeJson.Dispose() }
    }
  }
  # Each invocation runs exactly one script. No automatic collect, retry, redirect or global encoding changes.
  $LASTEXITCODE = 0
  $lines = & $ScriptPath @arguments
  if (-not $?) {
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    throw 'Script invocation failed; stop without retry.'
  }
  $content = $lines -join [Environment]::NewLine
  [IO.File]::WriteAllText($OutputPath, $content, [Text.UTF8Encoding]::new($false))
  if ([string]::IsNullOrWhiteSpace($content)) { throw 'Script produced no JSON; stop without retry.' }
  $null = $content | ConvertFrom-Json -Depth 100
  exit 0
}
catch {
  Write-Error -Message $_.Exception.Message -ErrorAction Continue
  exit 1
}
