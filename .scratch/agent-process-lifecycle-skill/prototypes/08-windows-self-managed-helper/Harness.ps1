# THROWAWAY PROTOTYPE. One-command harness:
# pwsh -NoLogo -NoProfile -File .\Harness.ps1

[CmdletBinding()]
param(
    [switch]$InternalFixture,
    [switch]$InternalSentinel,

    [ValidateSet('Graceful', 'IgnoreGraceful', 'NeverReady', 'ForcedChild')]
    [string]$FixtureBehavior = 'Graceful',

    [string]$RunId,
    [string]$ShutdownEventName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Native.ps1')

$nativeType = [ThrowawayAgentProcessLifecycle.Native]
$pwshPath = [Environment]::ProcessPath

function Invoke-InternalFixture {
    $eventHandle = $nativeType::CreateManualResetEvent($ShutdownEventName)
    try {
        [Console]::Out.WriteLine("fixture-start:${RunId}:$FixtureBehavior")
        [Console]::Out.Flush()
        [Console]::Error.WriteLine("fixture-stderr:${RunId}:$FixtureBehavior")
        [Console]::Error.Flush()

        if ($FixtureBehavior -eq 'IgnoreGraceful') {
            $childStart = [Diagnostics.ProcessStartInfo]::new($pwshPath)
            $childStart.UseShellExecute = $false
            $childStart.CreateNoWindow = $true
            foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
                '-InternalFixture', '-FixtureBehavior', 'ForcedChild',
                '-RunId', $RunId, '-ShutdownEventName', $ShutdownEventName
            )) {
                $childStart.ArgumentList.Add($argument)
            }
            $child = [Diagnostics.Process]::Start($childStart)
            [Console]::Out.WriteLine("fixture-child-pid:$($child.Id)")
            [Console]::Out.Flush()
            $child.Dispose()
        }

        if ($FixtureBehavior -ne 'NeverReady' -and $FixtureBehavior -ne 'ForcedChild') {
            [Console]::Out.WriteLine("READY:$RunId")
            [Console]::Out.Flush()
        }
        elseif ($FixtureBehavior -eq 'ForcedChild') {
            [Console]::Out.WriteLine("fixture-child-start:$RunId")
            [Console]::Out.Flush()
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        if ($FixtureBehavior -eq 'Graceful') {
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($nativeType::Wait($eventHandle, 250) -eq $nativeType::WaitObject0) {
                    [Console]::Out.WriteLine("fixture-graceful-stop:$RunId")
                    [Console]::Out.Flush()
                    return
                }
            }
            throw 'fixture safety deadline expired before graceful shutdown'
        }

        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        throw 'fixture safety deadline expired'
    }
    finally {
        $nativeType::Close($eventHandle)
    }
}

function Invoke-InternalSentinel {
    $eventHandle = $nativeType::CreateManualResetEvent($ShutdownEventName)
    try {
        [Console]::Out.WriteLine("SENTINEL-READY:$RunId")
        [Console]::Out.Flush()
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($nativeType::Wait($eventHandle, 250) -eq $nativeType::WaitObject0) {
                return
            }
        }
        throw 'sentinel safety deadline expired'
    }
    finally {
        $nativeType::Close($eventHandle)
    }
}

if ($InternalFixture) {
    Invoke-InternalFixture
    exit 0
}

if ($InternalSentinel) {
    Invoke-InternalSentinel
    exit 0
}

$lifecycleScript = Join-Path $PSScriptRoot 'Lifecycle.ps1'

function New-TempScenarioDirectory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)

    $path = Join-Path $Root $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Invoke-FreshLifecycle {
    param(
        [Parameter(Mandatory)][ValidateSet('Launch', 'Finalize')][string]$Action,
        [Parameter(Mandatory)][string]$ScenarioDirectory,
        [string]$Behavior = 'Graceful',
        [int]$ReadinessTimeoutMilliseconds = 3000,
        [int]$GraceTimeoutMilliseconds = 1000
    )

    $start = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $lifecycleScript,
        '-Action', $Action,
        '-RunDirectory', $ScenarioDirectory,
        '-FixtureBehavior', $Behavior,
        '-ReadinessTimeoutMilliseconds', [string]$ReadinessTimeoutMilliseconds,
        '-GraceTimeoutMilliseconds', [string]$GraceTimeoutMilliseconds,
        '-ForceTimeoutMilliseconds', '3000'
    )) {
        $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) {
        $process.Kill($true)
        $process.WaitForExit(3000) | Out-Null
        throw "$Action lifecycle invocation exceeded the 15 second harness bound"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    $exitCode = $process.ExitCode
    $process.Dispose()

    $evidence = $null
    if ($stdout) {
        try {
            $evidence = $stdout | ConvertFrom-Json
        }
        catch {
            throw "$Action did not emit one JSON result. stdout=$stdout stderr=$stderr"
        }
    }

    return [pscustomobject]@{
        action = $Action
        exitCode = $exitCode
        stderr = $stderr
        evidence = $evidence
    }
}

function Read-RunRecord {
    param([Parameter(Mandatory)][string]$ScenarioDirectory)

    return [IO.File]::ReadAllText((Join-Path $ScenarioDirectory 'run-record.json')) | ConvertFrom-Json -DateKind String
}

function Assert-Observed {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Wait-JobEmptyForHarness {
    param(
        [Parameter(Mandatory)][IntPtr]$JobHandle,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $wait = [Diagnostics.Stopwatch]::StartNew()
    while ($wait.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (@($nativeType::QueryJobProcessIds($JobHandle)).Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 25
    }
    return @($nativeType::QueryJobProcessIds($JobHandle)).Count -eq 0
}

function Stop-TrustedRunForHarnessCleanup {
    param([Parameter(Mandatory)][object]$TrustedRecord)

    $jobHandle = [IntPtr]::Zero
    try {
        $jobHandle = $nativeType::OpenOwnedJob([string]$TrustedRecord.jobName)
        $members = @($nativeType::QueryJobProcessIds($jobHandle))
        $fixtureProcessId = [int]$TrustedRecord.fixturePid
        $expectedCreation = [DateTime]::ParseExact(
            [string]$TrustedRecord.fixtureCreationTimeUtc,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $actualCreation = $nativeType::TryGetProcessCreationTimeUtc($fixtureProcessId)
        if ($members -notcontains [long]$fixtureProcessId -or -not $actualCreation -or $actualCreation.Ticks -ne $expectedCreation.Ticks) {
            throw 'Harness cleanup refused an unvalidated Job owner record.'
        }

        if ($nativeType::SignalExistingEvent([string]$TrustedRecord.shutdownEventName)) {
            if (Wait-JobEmptyForHarness -JobHandle $jobHandle -TimeoutMilliseconds 1000) {
                return
            }
        }
        $nativeType::TerminateOwnedJob($jobHandle)
        if (-not (Wait-JobEmptyForHarness -JobHandle $jobHandle -TimeoutMilliseconds 3000)) {
            throw 'Harness cleanup could not empty the validated Job within 3 seconds.'
        }
    }
    finally {
        if ($jobHandle -ne [IntPtr]::Zero) {
            $nativeType::Close($jobHandle)
        }
    }
}

function Start-UnrelatedSentinel {
    $sentinelRunId = [Guid]::NewGuid().ToString('D')
    $eventName = "Local\Throwaway.AgentProcessLifecycle.Sentinel.$sentinelRunId"
    $start = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-InternalSentinel', '-RunId', $sentinelRunId, '-ShutdownEventName', $eventName
    )) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $readyTask = $process.StandardOutput.ReadLineAsync()
    if (-not $readyTask.Wait(3000)) {
        $process.Kill($true)
        $process.WaitForExit(3000) | Out-Null
        throw 'Unrelated sentinel did not become ready within 3 seconds.'
    }
    Assert-Observed -Condition ($readyTask.Result -ceq "SENTINEL-READY:$sentinelRunId") -Message 'Sentinel emitted an unexpected readiness token.'
    return [pscustomobject]@{
        process = $process
        eventName = $eventName
        runId = $sentinelRunId
    }
}

function Stop-UnrelatedSentinel {
    param([Parameter(Mandatory)][object]$Sentinel)

    if (-not $Sentinel.process.HasExited) {
        $nativeType::SignalExistingEvent([string]$Sentinel.eventName) | Out-Null
        $Sentinel.process.WaitForExit(3000) | Out-Null
    }
    if (-not $Sentinel.process.HasExited) {
        $Sentinel.process.Kill($true)
        $Sentinel.process.WaitForExit(3000) | Out-Null
    }
    $Sentinel.process.Dispose()
}

function Invoke-GracefulScenario {
    param([Parameter(Mandatory)][string]$Root)

    $directory = New-TempScenarioDirectory -Root $Root -Name 'graceful'
    $trustedRecord = $null
    try {
        $launch = Invoke-FreshLifecycle -Action Launch -ScenarioDirectory $directory -Behavior Graceful
        Assert-Observed ($launch.exitCode -eq 0 -and $launch.evidence.success) 'Graceful Launch failed.'
        $trustedRecord = Read-RunRecord $directory
        $aliveBetweenInvocations = $nativeType::IsProcessInstanceAlive(
            [int]$trustedRecord.fixturePid,
            [DateTime]::Parse([string]$trustedRecord.fixtureCreationTimeUtc)
        )
        $finalize = Invoke-FreshLifecycle -Action Finalize -ScenarioDirectory $directory -GraceTimeoutMilliseconds 1500
        Assert-Observed ($finalize.exitCode -eq 0 -and $finalize.evidence.success) 'Graceful Finalize failed.'

        $stdout = [IO.File]::ReadAllText([string]$trustedRecord.stdoutPath)
        $stderr = [IO.File]::ReadAllText([string]$trustedRecord.stderrPath)
        $facts = [ordered]@{
            lifecycleInvocations = @('Launch', 'Finalize')
            fixtureAliveBetweenInvocations = $aliveBetweenInvocations
            launchClosedItsJobHandle = $true
            finalizeReopenedNamedJob = [bool]$finalize.evidence.observedFacts.jobReopened
            terminationMode = $finalize.evidence.observedFacts.terminationMode
            stdoutContainsReadiness = $stdout.Contains("READY:$($trustedRecord.runId)")
            stdoutContainsGracefulStop = $stdout.Contains("fixture-graceful-stop:$($trustedRecord.runId)")
            stderrWasRedirected = $stderr.Contains("fixture-stderr:$($trustedRecord.runId):Graceful")
            fixtureAliveAfterFinalize = $nativeType::IsProcessInstanceAlive(
                [int]$trustedRecord.fixturePid,
                [DateTime]::Parse([string]$trustedRecord.fixtureCreationTimeUtc)
            )
            namedJobExistsAfterFinalize = $nativeType::NamedJobExists([string]$trustedRecord.jobName)
        }
        $passed = $facts.fixtureAliveBetweenInvocations -and
            $facts.finalizeReopenedNamedJob -and
            $facts.terminationMode -eq 'graceful' -and
            $facts.stdoutContainsReadiness -and
            $facts.stdoutContainsGracefulStop -and
            $facts.stderrWasRedirected -and
            -not $facts.fixtureAliveAfterFinalize -and
            -not $facts.namedJobExistsAfterFinalize
        return [pscustomobject]@{ name = 'cross-invocation-graceful-and-stdio'; passed = $passed; observedFacts = $facts }
    }
    finally {
        if ($trustedRecord -and $nativeType::NamedJobExists([string]$trustedRecord.jobName)) {
            Stop-TrustedRunForHarnessCleanup $trustedRecord
        }
    }
}

function Invoke-ForcedTreeScenario {
    param([Parameter(Mandatory)][string]$Root)

    $directory = New-TempScenarioDirectory -Root $Root -Name 'forced-tree'
    $sentinel = $null
    $trustedRecord = $null
    try {
        $sentinel = Start-UnrelatedSentinel
        $launch = Invoke-FreshLifecycle -Action Launch -ScenarioDirectory $directory -Behavior IgnoreGraceful
        Assert-Observed ($launch.exitCode -eq 0 -and $launch.evidence.success) 'Forced-tree Launch failed.'
        $trustedRecord = Read-RunRecord $directory
        $finalize = Invoke-FreshLifecycle -Action Finalize -ScenarioDirectory $directory -GraceTimeoutMilliseconds 300
        Assert-Observed ($finalize.exitCode -eq 0 -and $finalize.evidence.success) 'Forced-tree Finalize failed.'

        $memberCount = @($finalize.evidence.observedFacts.memberPidsBefore).Count
        $facts = [ordered]@{
            lifecycleInvocations = @('Launch', 'Finalize')
            finalizeReopenedNamedJob = [bool]$finalize.evidence.observedFacts.jobReopened
            membersBeforeFinalize = $memberCount
            inheritedChildObservedInJob = $memberCount -ge 2
            terminationMode = $finalize.evidence.observedFacts.terminationMode
            forcedTerminationUsedRetainedJobHandle = [bool]$finalize.evidence.observedFacts.terminationAttemptedThroughRetainedJobHandle
            unrelatedSentinelSurvivedForcedJobTermination = -not $sentinel.process.HasExited
            fixtureAliveAfterFinalize = $nativeType::IsProcessInstanceAlive(
                [int]$trustedRecord.fixturePid,
                [DateTime]::Parse([string]$trustedRecord.fixtureCreationTimeUtc)
            )
        }
        $sentinelStopSignaled = $nativeType::SignalExistingEvent([string]$sentinel.eventName)
        $sentinelStopped = $sentinel.process.WaitForExit(3000)
        $facts.unrelatedSentinelStoppedByOwnerEvent = $sentinelStopSignaled -and $sentinelStopped -and $sentinel.process.HasExited
        if ($sentinelStopped) {
            $sentinel.process.Dispose()
            $sentinel = $null
        }
        $passed = $facts.finalizeReopenedNamedJob -and
            $facts.inheritedChildObservedInJob -and
            $facts.terminationMode -eq 'forced-job' -and
            $facts.forcedTerminationUsedRetainedJobHandle -and
            $facts.unrelatedSentinelSurvivedForcedJobTermination -and
            $facts.unrelatedSentinelStoppedByOwnerEvent -and
            -not $facts.fixtureAliveAfterFinalize
        return [pscustomobject]@{ name = 'forced-job-tree-with-unrelated-sentinel'; passed = $passed; observedFacts = $facts }
    }
    finally {
        if ($trustedRecord -and $nativeType::NamedJobExists([string]$trustedRecord.jobName)) {
            Stop-TrustedRunForHarnessCleanup $trustedRecord
        }
        if ($sentinel) {
            Stop-UnrelatedSentinel $sentinel
        }
    }
}

function Invoke-ReadinessFailureScenario {
    param([Parameter(Mandatory)][string]$Root)

    $directory = New-TempScenarioDirectory -Root $Root -Name 'readiness-failure'
    $launch = Invoke-FreshLifecycle -Action Launch -ScenarioDirectory $directory -Behavior NeverReady -ReadinessTimeoutMilliseconds 300
    $creationTime = if ($launch.evidence.observedFacts.fixtureCreationTimeUtc) {
        [DateTime]::Parse([string]$launch.evidence.observedFacts.fixtureCreationTimeUtc)
    }
    else {
        [DateTime]::MinValue
    }
    $fixtureAlive = if ($launch.evidence.observedFacts.fixturePid) {
        $nativeType::IsProcessInstanceAlive([int]$launch.evidence.observedFacts.fixturePid, $creationTime)
    }
    else {
        $false
    }
    $facts = [ordered]@{
        lifecycleInvocations = @('Launch')
        launchFailed = $launch.exitCode -ne 0 -and -not $launch.evidence.success
        failureKind = $launch.evidence.failureKind
        cleanupAttemptedThroughLaunchRetainedJobHandle = [bool]$launch.evidence.observedFacts.cleanupAttemptedThroughRetainedJobHandle
        cleanupCompletedWithinBound = [bool]$launch.evidence.observedFacts.cleanupCompletedWithinBound
        fixtureAliveAfterFailedLaunch = $fixtureAlive
        namedJobExistsAfterFailedLaunch = $nativeType::NamedJobExists([string]$launch.evidence.observedFacts.jobName)
        recordWritten = Test-Path -LiteralPath (Join-Path $directory 'run-record.json')
        stdoutFileExists = Test-Path -LiteralPath ([string]$launch.evidence.observedFacts.stdoutPath)
        stderrFileExists = Test-Path -LiteralPath ([string]$launch.evidence.observedFacts.stderrPath)
    }
    $passed = $facts.launchFailed -and
        $facts.failureKind -eq 'readiness-timeout' -and
        $facts.cleanupAttemptedThroughLaunchRetainedJobHandle -and
        $facts.cleanupCompletedWithinBound -and
        -not $facts.fixtureAliveAfterFailedLaunch -and
        -not $facts.namedJobExistsAfterFailedLaunch -and
        -not $facts.recordWritten -and
        $facts.stdoutFileExists -and
        $facts.stderrFileExists
    return [pscustomobject]@{ name = 'readiness-failure-cleans-in-launch'; passed = $passed; observedFacts = $facts }
}

function Invoke-TamperedRecordScenario {
    param([Parameter(Mandatory)][string]$Root)

    $directory = New-TempScenarioDirectory -Root $Root -Name 'tampered-record'
    $trustedRecord = $null
    $cleanupCompleted = $false
    try {
        $launch = Invoke-FreshLifecycle -Action Launch -ScenarioDirectory $directory -Behavior Graceful
        Assert-Observed ($launch.exitCode -eq 0 -and $launch.evidence.success) 'Tamper scenario Launch failed.'
        $trustedRecord = Read-RunRecord $directory
        $tamperedRecord = $trustedRecord.PSObject.Copy()
        $tamperedRecord.fixtureCreationTimeUtc = [DateTime]::UnixEpoch.ToString('O')
        [IO.File]::WriteAllText(
            (Join-Path $directory 'run-record.json'),
            ($tamperedRecord | ConvertTo-Json -Depth 4 -Compress)
        )

        $finalize = Invoke-FreshLifecycle -Action Finalize -ScenarioDirectory $directory
        $fixtureStillAlive = $nativeType::IsProcessInstanceAlive(
            [int]$trustedRecord.fixturePid,
            [DateTime]::Parse([string]$trustedRecord.fixtureCreationTimeUtc)
        )
        $facts = [ordered]@{
            lifecycleInvocations = @('Launch', 'Finalize')
            finalizeFailedClosed = $finalize.exitCode -ne 0 -and -not $finalize.evidence.success
            failureKind = $finalize.evidence.failureKind
            jobWasReopenedOnce = [bool]$finalize.evidence.observedFacts.jobReopened
            ownershipValidated = [bool]$finalize.evidence.observedFacts.ownershipValidated
            terminationAttempted = [bool]$finalize.evidence.observedFacts.terminationAttemptedThroughRetainedJobHandle
            fixtureStillAliveAfterRejectedRecord = $fixtureStillAlive
        }
        Stop-TrustedRunForHarnessCleanup $trustedRecord
        $cleanupCompleted = $true
        $facts.fixtureAliveAfterHarnessCleanup = $nativeType::IsProcessInstanceAlive(
            [int]$trustedRecord.fixturePid,
            [DateTime]::Parse([string]$trustedRecord.fixtureCreationTimeUtc)
        )
        $facts.namedJobExistsAfterHarnessCleanup = $nativeType::NamedJobExists([string]$trustedRecord.jobName)
        $passed = $facts.finalizeFailedClosed -and
            $facts.failureKind -eq 'ownership-validation-failed' -and
            $facts.jobWasReopenedOnce -and
            -not $facts.ownershipValidated -and
            -not $facts.terminationAttempted -and
            $facts.fixtureStillAliveAfterRejectedRecord -and
            -not $facts.fixtureAliveAfterHarnessCleanup -and
            -not $facts.namedJobExistsAfterHarnessCleanup
        return [pscustomobject]@{ name = 'tampered-record-fails-closed'; passed = $passed; observedFacts = $facts }
    }
    finally {
        if (-not $cleanupCompleted -and $trustedRecord -and $nativeType::NamedJobExists([string]$trustedRecord.jobName)) {
            Stop-TrustedRunForHarnessCleanup $trustedRecord
        }
    }
}

$harnessRunId = [Guid]::NewGuid().ToString('D')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "throwaway-agent-process-lifecycle-$harnessRunId"
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$scenarioResults = [Collections.Generic.List[object]]::new()
$harnessErrors = [Collections.Generic.List[string]]::new()
$artifactsRemoved = $false

try {
    foreach ($scenario in @(
        ${function:Invoke-GracefulScenario},
        ${function:Invoke-ForcedTreeScenario},
        ${function:Invoke-ReadinessFailureScenario},
        ${function:Invoke-TamperedRecordScenario}
    )) {
        try {
            $scenarioResults.Add((& $scenario -Root $tempRoot))
        }
        catch {
            $scenarioResults.Add([pscustomobject]@{
                name = $scenario.Ast.Name
                passed = $false
                observedFacts = [ordered]@{ harnessError = $_.Exception.Message }
            })
            $harnessErrors.Add($_.Exception.Message)
        }
    }
}
finally {
    try {
        [IO.Directory]::Delete($tempRoot, $true)
        $artifactsRemoved = -not [IO.Directory]::Exists($tempRoot)
    }
    catch {
        $harnessErrors.Add("Temporary artifact cleanup failed: $($_.Exception.Message)")
    }
}

$allScenariosPassed = @($scenarioResults | Where-Object { -not $_.passed }).Count -eq 0
$passed = $allScenariosPassed -and $artifactsRemoved -and $harnessErrors.Count -eq 0
$evidence = [ordered]@{
    prototype = 'THROWAWAY Windows self-managed two-invocation helper'
    question = 'Can Launch return with a live named-Job fixture and can one fresh Finalize invocation safely reopen, validate, and stop only that Job tree?'
    passed = $passed
    documentedAssumptions = @(
        [ordered]@{
            id = 'A1'
            statement = 'Guid job names are produced from RandomNumberGenerator bytes with UUID v4 version and variant bits.'
        },
        [ordered]@{
            id = 'A2'
            statement = 'Windows named Job lifetime, child inheritance, OpenJobObject, and TerminateJobObject scoping follow the Microsoft documentation supplied in the ticket context.'
        },
        [ordered]@{
            id = 'A3'
            statement = 'A root Job member plus matching creation time and owner event is sufficient ownership evidence for this throwaway experiment; PIDs are never termination authority.'
        }
    )
    observedFacts = [ordered]@{
        environment = [ordered]@{
            osDescription = [Runtime.InteropServices.RuntimeInformation]::OSDescription
            pwshVersion = $PSVersionTable.PSVersion.ToString()
            harnessProcessWasAlreadyInJob = $nativeType::IsCurrentProcessInJob()
        }
        scenarios = $scenarioResults
        temporaryArtifactsRemoved = $artifactsRemoved
        harnessErrors = $harnessErrors
    }
}

[Console]::Out.WriteLine(($evidence | ConvertTo-Json -Depth 12))
if (-not $passed) {
    exit 1
}
