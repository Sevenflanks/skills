[CmdletBinding()]
param(
    [string]$HelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Test-WindowsGitCheckout.ps1')
)

$ErrorActionPreference = 'Stop'

$helperContent = Get-Content -LiteralPath $HelperPath -Raw
if ($helperContent -notmatch '(?m)^function New-OwnedCloneDirectory') {
    throw 'Test-WindowsGitCheckout.ps1 must expose New-OwnedCloneDirectory for ownership testing.'
}

$tempParent = [System.IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $tempParent -PathType Container)) {
    throw "Temporary test parent does not exist: $tempParent"
}

$testRoot = Join-Path $tempParent "windows-git-checkout-test-$([guid]::NewGuid().ToString('N'))"
$preexistingPath = $null
$ownedPath = $null

try {
    New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null
    $preexistingPath = Join-Path $testRoot 'wg-deadbeef'
    New-Item -ItemType Directory -Path $preexistingPath -ErrorAction Stop | Out-Null

    . $HelperPath -SourcePath $testRoot -TempRoot $testRoot

    $names = [System.Collections.Generic.Queue[string]]::new()
    $names.Enqueue('wg-deadbeef')
    $names.Enqueue('wg-cafebabe')
    $nameFactory = { $names.Dequeue() }.GetNewClosure()
    $ownedPath = New-OwnedCloneDirectory -TempRoot $testRoot -NameFactory $nameFactory

    if ($ownedPath -ne (Join-Path $testRoot 'wg-cafebabe')) {
        throw "Expected retry destination wg-cafebabe, received $ownedPath"
    }
    if (-not (Test-Path -LiteralPath $ownedPath -PathType Container)) {
        throw "Owned clone destination was not created: $ownedPath"
    }
    if (-not (Test-Path -LiteralPath $preexistingPath -PathType Container)) {
        throw "Pre-existing destination was removed or reused: $preexistingPath"
    }

    Remove-Item -LiteralPath $ownedPath -Recurse -Force
    $ownedPath = $null

    if (-not (Test-Path -LiteralPath $preexistingPath -PathType Container)) {
        throw "Removing the owned destination removed the pre-existing directory: $preexistingPath"
    }

    Write-Host 'Windows checkout temporary destination ownership test passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
