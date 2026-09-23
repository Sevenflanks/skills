[CmdletBinding()]
param(
    [ValidateSet('All', 'HostDiagnostic', 'CleanupDiagnostic')][string]$Scenario = 'All',
    [ValidateRange(1000, 10000)][int]$FixtureLifetimeMilliseconds = 8000,
    [string]$DiagnosticRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$node = (Get-Command node -CommandType Application).Source
$fixture = Join-Path $PSScriptRoot 'fixtures\short-cli-descendant.cjs'
$root = Join-Path $PSScriptRoot ".runtime-descendant-$([guid]::NewGuid().ToString('N'))"
$cases = [Collections.Generic.List[object]]::new()

if ($Scenario -eq 'CleanupDiagnostic') {
    $expectedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if (-not $DiagnosticRoot -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DiagnosticRoot)) -cne $expectedParent -or
        [IO.Path]::GetFileName($DiagnosticRoot) -notmatch '^\.runtime-descendant-[a-f0-9]{32}$' -or
        -not [IO.File]::Exists((Join-Path $DiagnosticRoot 'host-diagnostic\shell-end.json')) -or
        -not [IO.File]::Exists((Join-Path $DiagnosticRoot 'host-diagnostic\child-exit-intent.json')) -or
        -not [IO.File]::Exists((Join-Path $DiagnosticRoot 'host-diagnostic\process-identity.json'))) {
        throw 'Exact host diagnostic root/identity/intent evidence missing; retain evidence, do not remove.'
    }
    $dir = Join-Path $DiagnosticRoot 'host-diagnostic'
    $intent = [IO.File]::ReadAllText((Join-Path $dir 'child-exit-intent.json')) | ConvertFrom-Json
    $identity = [IO.File]::ReadAllText((Join-Path $dir 'process-identity.json')) | ConvertFrom-Json
    if ($intent.reason -notin @('fixture-deadline', 'owner-stop') -or $intent.pid -ne $identity.pid -or
        -not $identity.startTimeUtcTicks) {
        throw 'Diagnostic process identity/intent mismatch; retain evidence.'
    }
    try {
        $observed = [Diagnostics.Process]::GetProcessById([int]$identity.pid)
    }
    catch [ArgumentException] { $observed = $null }
    if ($null -ne $observed) {
        try {
            if ($observed.StartTime.ToUniversalTime().Ticks -ne [long]$identity.startTimeUtcTicks) {
                throw 'Diagnostic PID was reused; OS exit is unresolved; retain evidence.'
            }
            if (-not $observed.HasExited) { throw 'Diagnostic child is still running; retain evidence.' }
        }
        finally { $observed.Dispose() }
    }
    Remove-Item -LiteralPath $DiagnosticRoot -Recurse -Force
    Write-Host "Diagnostic OS exit and fixture cleanup verified: $DiagnosticRoot removed."
    return
}

function Invoke-Cli([string]$Mode, [string]$Directory, [string]$Token) {
    & $node $fixture $Mode $Directory $Token $FixtureLifetimeMilliseconds
    if ($LASTEXITCODE -ne 0) { throw "Fixture CLI $Mode failed with exit code $LASTEXITCODE" }
}

function Wait-File([string]$Path, [int]$Milliseconds) {
    $limit = [DateTimeOffset]::UtcNow.AddMilliseconds($Milliseconds)
    while (-not [IO.File]::Exists($Path) -and [DateTimeOffset]::UtcNow -lt $limit) {
        Start-Sleep -Milliseconds 25
    }
    return [IO.File]::Exists($Path)
}

function Test-Ready([string]$Directory, [string]$Token) {
    $ready = [IO.File]::ReadAllText((Join-Path $Directory 'ready.json')) | ConvertFrom-Json
    $binding = [IO.File]::ReadAllText((Join-Path $Directory 'launcher.json')) | ConvertFrom-Json
    if ($ready.token -cne $Token -or $binding.token -cne $Token -or $binding.childPid -ne $ready.pid) {
        throw 'CLI exit did not yield a matching descendant binding.'
    }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync([Net.IPAddress]::Loopback, [int]$ready.port)
        if (-not $connect.Wait(1000)) { return $false }
        $reader = [IO.StreamReader]::new($client.GetStream())
        try { return [bool]($reader.ReadLine() -ceq $Token) }
        finally { $reader.Dispose() }
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Open-OwnedProcess([string]$Directory, [string]$Token) {
    $ready = [IO.File]::ReadAllText((Join-Path $Directory 'ready.json')) | ConvertFrom-Json
    $binding = [IO.File]::ReadAllText((Join-Path $Directory 'launcher.json')) | ConvertFrom-Json
    if ($ready.token -cne $Token -or $binding.token -cne $Token -or $binding.childPid -ne $ready.pid) {
        throw 'No matching fixture descendant identity.'
    }
    $process = [Diagnostics.Process]::GetProcessById([int]$ready.pid)
    try {
        if ($process.StartTime.ToUniversalTime() -lt [datetime]::Parse($binding.launchStartedUtc).ToUniversalTime()) {
            throw 'Process start predates fixture launch; retain evidence.'
        }
        [IO.File]::WriteAllText((Join-Path $Directory 'process-identity.json'),
            (@{ pid = $process.Id; startTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json -Compress))
        return $process
    }
    catch { $process.Dispose(); throw }
}

function Confirm-OsExit([hashtable]$Case) {
    if ($null -eq $Case.processHandle -or -not $Case.processHandle.WaitForExit($FixtureLifetimeMilliseconds + 1500)) {
        throw 'No bounded OS-exit observation for the bound descendant; retain evidence.'
    }
    $intentPath = Join-Path $Case.dir 'child-exit-intent.json'
    if (-not [IO.File]::Exists($intentPath)) { throw 'OS exit without fixture intent; retain evidence.' }
    $intent = [IO.File]::ReadAllText($intentPath) | ConvertFrom-Json
    if ($intent.pid -ne $Case.processHandle.Id) { throw 'Exit intent does not match the observed process.' }
    return $intent.reason
}

function Run-OwnedCase([string]$Name, [string]$Failure) {
    $dir = Join-Path $root $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $case = @{ dir = $dir; token = $token; launched = $false; stopped = $false; processHandle = $null }
    $cases.Add($case)
    try {
        Invoke-Cli 'launch' $dir $token
        $case.launched = $true
        if (-not (Wait-File (Join-Path $dir 'ready.json') 2500)) { throw 'Readiness deadline exceeded.' }
        $case.processHandle = Open-OwnedProcess $dir $token
        if ($Failure -eq 'readiness') { throw 'Simulated readiness failure after launch.' }
        if (-not (Test-Ready $dir $token)) { throw 'Readiness probe failed.' }
        if ($case.processHandle.HasExited) { throw 'Child exited before CLI return was checked.' }
        if ($Failure -eq 'none') {
            & $node $fixture stop $dir ([guid]::NewGuid().ToString('N')) $FixtureLifetimeMilliseconds 2>$null
            if ($LASTEXITCODE -eq 0 -or $case.processHandle.HasExited -or
                -not (Test-Ready $dir $token)) { throw 'Unknown binding stopped or disrupted the owned child.' }
        }
        # A one-off failed probe/HTTP 202 does not establish process exit.
        $downstream = @{ status = 'accepted'; httpStatus = 202; singleProbeFailed = $true }
        if ($Failure -eq 'cancel') { throw 'Simulated cancellation after readiness.' }
    }
    catch {
        if ($Failure -eq 'none' -or $_.Exception.Message -notmatch 'Simulated (cancellation|readiness failure)') { throw }
    }
    finally {
        # This Stop is in the same tool as Launch, regardless of downstream outcome.
        if ($case.launched -and $null -ne $case.processHandle) {
            Invoke-Cli 'stop' $dir $token
            if (-not (Wait-File (Join-Path $dir 'child-exit-intent.json') 2500)) {
                throw 'Owner Stop did not produce exit intent.'
            }
            if ($case.processHandle.WaitForExit(0)) { throw 'Fixture did not expose intent before OS exit.' }
            Invoke-Cli 'release' $dir $token
            $reason = Confirm-OsExit $case
            if ($reason -ne 'owner-stop') { throw "Stop was not owner-finalized: $reason" }
            $case.stopped = $true
        }
    }
    if ($Failure -eq 'none' -and ($downstream.httpStatus -ne 202 -or -not $downstream.singleProbeFailed)) {
        throw 'Downstream state was conflated with lifecycle exit.'
    }
}

try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    if ($Scenario -eq 'All') {
        $baseline = Join-Path $root 'baseline'
        [IO.Directory]::CreateDirectory($baseline) | Out-Null
        Invoke-Cli 'baseline' $baseline 'unused'
        if (-not [IO.File]::Exists((Join-Path $baseline 'baseline.json')) -or
            [IO.File]::Exists((Join-Path $baseline 'ready.json'))) { throw 'Synchronous baseline left a managed child.' }
        Run-OwnedCase 'stop' 'none'
        Run-OwnedCase 'cancel' 'cancel'
        Run-OwnedCase 'readiness-failure' 'readiness'
        $deadlineDir = Join-Path $root 'open-socket-deadline'
        [IO.Directory]::CreateDirectory($deadlineDir) | Out-Null
        $deadlineToken = [guid]::NewGuid().ToString('N')
        $deadlineCase = @{ dir = $deadlineDir; token = $deadlineToken; launched = $false; stopped = $false; processHandle = $null }
        $cases.Add($deadlineCase)
        Invoke-Cli 'launch' $deadlineDir $deadlineToken
        $deadlineCase.launched = $true
        if (-not (Wait-File (Join-Path $deadlineDir 'ready.json') 2500)) { throw 'Open-socket child did not become ready.' }
        $deadlineCase.processHandle = Open-OwnedProcess $deadlineDir $deadlineToken
        $ready = [IO.File]::ReadAllText((Join-Path $deadlineDir 'ready.json')) | ConvertFrom-Json
        $heldSocket = [Net.Sockets.TcpClient]::new()
        try {
            $heldSocket.Connect('127.0.0.1', [int]$ready.port)
            if (-not (Wait-File (Join-Path $deadlineDir 'child-exit-intent.json') ($FixtureLifetimeMilliseconds + 1500))) {
                throw 'Hard deadline failed with an open socket.'
            }
            if ((Confirm-OsExit $deadlineCase) -ne 'fixture-deadline') { throw 'Open socket did not expire at fixture deadline.' }
            $deadlineCase.stopped = $true
        }
        finally { $heldSocket.Dispose() }
        Write-Host 'Short CLI/descendant Stop, failure reconciliation and synchronous baseline passed.'
    }
    else {
        $dir = Join-Path $root 'host-diagnostic'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $token = [guid]::NewGuid().ToString('N')
        $cases.Add(@{ dir = $dir; token = $token; launched = $false; stopped = $false; processHandle = $null })
        Invoke-Cli 'launch' $dir $token
        $cases[0].launched = $true
        if (-not (Wait-File (Join-Path $dir 'ready.json') 2500)) {
            throw 'Host diagnostic child did not become ready.'
        }
        $cases[0].processHandle = Open-OwnedProcess $dir $token
        if (-not (Test-Ready $dir $token)) { throw 'Host diagnostic readiness probe failed.' }
        [IO.File]::WriteAllText((Join-Path $dir 'shell-end.json'), ([DateTimeOffset]::UtcNow.ToString('O')))
        Write-Host "shell-end=$dir; caller must measure actual tool return and check process identity/liveness; exit-intent alone does not prove OS exit."
        Write-Host "After independent fixture exit: pwsh -NoProfile -File skills/agent-process-lifecycle/tests/short-cli-descendant.regression.test.ps1 -Scenario CleanupDiagnostic -DiagnosticRoot '$root'"
    }
}
finally {
    foreach ($case in $cases) {
        if ($Scenario -ne 'HostDiagnostic' -and $case.launched -and -not $case.stopped -and $null -ne $case.processHandle) {
            if (-not $case.processHandle.HasExited) {
                try {
                    Invoke-Cli 'stop' $case.dir $case.token
                    if ((Wait-File (Join-Path $case.dir 'child-exit-intent.json') 2500) -and
                        -not $case.processHandle.HasExited) {
                        Invoke-Cli 'release' $case.dir $case.token
                    }
                }
                catch { Write-Warning "Owner recovery failed; fixture has independent deadline: $($_.Exception.Message)" }
            }
            try { $null = Confirm-OsExit $case; $case.stopped = $true }
            catch { Write-Warning "OS exit unresolved; fixture evidence retained: $($_.Exception.Message)" }
        }
    }
    $unresolved = @($cases | Where-Object { $_.launched -and -not $_.stopped })
    foreach ($case in $cases) { if ($null -ne $case.processHandle) { $case.processHandle.Dispose() } }
    if ($Scenario -eq 'HostDiagnostic') {
        Write-Host "Host diagnostic evidence retained for caller-side completion check: $root (child independently expires within $FixtureLifetimeMilliseconds ms)."
    }
    elseif ($unresolved.Count -eq 0) {
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host "Fixture cleanup verified: $root removed."
    }
    else { Write-Warning "Unresolved fixture evidence retained: $root" }
}
