[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$TempRoot = $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() })
)

$ErrorActionPreference = 'Stop'
$env:GIT_MASTER = '1'

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArguments
    )

    $output = & git @GitArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($GitArguments -join ' ')"
    }

    return $output
}

function New-OwnedCloneDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempRoot,

        [int]$MaximumAttempts = 32,

        [scriptblock]$NameFactory = { "wg-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }
    )

    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        $clonePath = Join-Path $TempRoot (& $NameFactory)
        if (Test-Path -LiteralPath $clonePath) {
            continue
        }

        try {
            New-Item -ItemType Directory -Path $clonePath -ErrorAction Stop | Out-Null
            return $clonePath
        } catch {
            if (Test-Path -LiteralPath $clonePath) {
                continue
            }
            throw
        }
    }

    throw "Unable to reserve a unique temporary clone directory under $TempRoot"
}

function Invoke-WindowsGitCheckoutSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TempRoot
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Source checkout does not exist: $SourcePath"
    }

    if (-not (Test-Path -LiteralPath $TempRoot -PathType Container)) {
        throw "Temporary clone parent does not exist: $TempRoot"
    }

    $resolvedSourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
    $resolvedTempRoot = (Resolve-Path -LiteralPath $TempRoot).Path
    $clonePath = $null

    try {
        $clonePath = New-OwnedCloneDirectory -TempRoot $resolvedTempRoot
        $sourceHead = (Invoke-GitCommand -GitArguments @('-c', 'core.longpaths=true', '-C', $resolvedSourcePath, 'rev-parse', 'HEAD')).Trim()
        Invoke-GitCommand -GitArguments @('-c', 'core.longpaths=false', 'clone', '--no-local', $resolvedSourcePath, $clonePath) | Out-Null

        $cloneStatus = Invoke-GitCommand -GitArguments @('-c', 'core.longpaths=true', '-C', $clonePath, 'status', '--short')
        if ($cloneStatus) {
            throw "Cloned checkout is not clean: $($cloneStatus -join [Environment]::NewLine)"
        }

        $cloneHead = (Invoke-GitCommand -GitArguments @('-c', 'core.longpaths=true', '-C', $clonePath, 'rev-parse', 'HEAD')).Trim()
        if ($cloneHead -ne $sourceHead) {
            throw "Cloned HEAD $cloneHead does not match source HEAD $sourceHead"
        }

        Write-Host "Windows checkout smoke test passed: $cloneHead"
    } finally {
        if ($null -ne $clonePath -and (Test-Path -LiteralPath $clonePath)) {
            Remove-Item -LiteralPath $clonePath -Recurse -Force
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WindowsGitCheckoutSmoke -SourcePath $SourcePath -TempRoot $TempRoot
}
