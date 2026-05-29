[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $skillRoot 'scripts\collect-daily-work-log.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('daily-work-log-test-' + [System.Guid]::NewGuid().ToString('N'))
$logRoot = Join-Path $tempRoot 'opencode-log'
$repoA = Join-Path $tempRoot 'repo-a'
$repoB = Join-Path $tempRoot 'repo-b'

try {
  New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $repoA -Force | Out-Null
  New-Item -ItemType Directory -Path $repoB -Force | Out-Null

  git -C $repoA init | Out-Null
  git -C $repoB init | Out-Null

  $logFile = Join-Path $logRoot '2026-05-29T235959.log'
  $content = @(
    "INFO  2026-05-29T10:15:00 +10ms service=default directory=$repoA creating instance",
    "INFO  2026-05-30T09:00:00 +10ms service=default directory=$repoB creating instance"
  ) -join [Environment]::NewLine
  [System.IO.File]::WriteAllText($logFile, $content, [System.Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $logFile).LastWriteTime = [datetime]'2026-05-30T09:00:00'

  $raw = & pwsh -NoProfile -File $helperPath `
    -From '2026-05-29T00:00:00+08:00' `
    -To '2026-05-29T23:59:59+08:00' `
    -SourceMode session `
    -OpenCodeLogRoot $logRoot

  $data = $raw | ConvertFrom-Json
  $names = @($data.repos | ForEach-Object { $_.name })

  if ($names -contains 'repo-b') {
    throw 'Expected range filter to exclude repo-b event from next day, but repo-b was included.'
  }

  if (-not ($names -contains 'repo-a')) {
    throw 'Expected range filter to include repo-a event from target day, but repo-a was missing.'
  }

  'PASS collect-daily-work-log timestamp filtering regression test'
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
