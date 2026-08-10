# THROWAWAY PROTOTYPE: only Launch and Finalize are lifecycle actions.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Launch', 'Finalize')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$RunDirectory,

    [ValidateSet('Graceful', 'IgnoreGraceful', 'NeverReady')]
    [string]$FixtureBehavior = 'Graceful',

    [ValidateRange(100, 10000)]
    [int]$ReadinessTimeoutMilliseconds = 3000,

    [ValidateRange(100, 10000)]
    [int]$GraceTimeoutMilliseconds = 1000,

    [ValidateRange(100, 10000)]
    [int]$ForceTimeoutMilliseconds = 3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Native.ps1')

$nativeType = [ThrowawayAgentProcessLifecycle.Native]
$recordPath = Join-Path $RunDirectory 'run-record.json'

function New-CryptoUuid {
    $bytes = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $bytes[7] = [byte](($bytes[7] -band 0x0f) -bor 0x40)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)
    return ([Guid]::new($bytes)).ToString('D')
}

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Depth 8 -Compress))
    exit $ExitCode
}

function Wait-JobEmpty {
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

function Test-RecordShape {
    param([Parameter(Mandatory)][object]$Record)

    if ($Record.schemaVersion -ne 1) {
        throw 'record-invalid: schemaVersion must be 1'
    }

    $runUuid = [Guid]::Empty
    $ownerUuid = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$Record.runId, 'D', [ref]$runUuid)) {
        throw 'record-invalid: runId is not a UUID'
    }
    if (-not [Guid]::TryParseExact([string]$Record.ownerToken, 'D', [ref]$ownerUuid)) {
        throw 'record-invalid: ownerToken is not a UUID'
    }

    $expectedJobName = "Local\Throwaway.AgentProcessLifecycle.Job.$($Record.runId)"
    $expectedEventName = "Local\Throwaway.AgentProcessLifecycle.Shutdown.$($Record.runId).$($Record.ownerToken)"
    if ($Record.jobName -cne $expectedJobName) {
        throw 'record-invalid: jobName does not derive from runId'
    }
    if ($Record.shutdownEventName -cne $expectedEventName) {
        throw 'record-invalid: shutdownEventName does not derive from runId and ownerToken'
    }

    $creationTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
        [string]$Record.fixtureCreationTimeUtc,
        'O',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$creationTime
    )) {
        throw 'record-invalid: fixtureCreationTimeUtc is not round-trip UTC time'
    }
    if ($creationTime.Kind -ne [DateTimeKind]::Utc) {
        throw 'record-invalid: fixtureCreationTimeUtc is not UTC'
    }

    return $creationTime
}

function Invoke-Launch {
    [IO.Directory]::CreateDirectory($RunDirectory) | Out-Null

    $runId = New-CryptoUuid
    $ownerToken = New-CryptoUuid
    $jobName = "Local\Throwaway.AgentProcessLifecycle.Job.$runId"
    $shutdownEventName = "Local\Throwaway.AgentProcessLifecycle.Shutdown.$runId.$ownerToken"
    $stdoutPath = Join-Path $RunDirectory 'fixture.stdout.log'
    $stderrPath = Join-Path $RunDirectory 'fixture.stderr.log'
    $fixtureScript = Join-Path $PSScriptRoot 'Harness.ps1'
    $pwshPath = [Environment]::ProcessPath
    $commandLine = $nativeType::BuildCommandLine([string[]]@(
        $pwshPath,
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $fixtureScript,
        '-InternalFixture',
        '-FixtureBehavior',
        $FixtureBehavior,
        '-RunId',
        $runId,
        '-ShutdownEventName',
        $shutdownEventName
    ))

    $launch = $null
    $jobHandle = [IntPtr]::Zero
    $cleanupAttempted = $false
    $cleanupCompleted = $false
    $failureKind = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        $launch = $nativeType::StartSuspendedInNamedJob(
            $jobName,
            $pwshPath,
            $commandLine,
            $PSScriptRoot,
            $stdoutPath,
            $stderrPath
        )
        $jobHandle = $launch.JobHandle

        $readyToken = "READY:$runId"
        $ready = $false
        while ($stopwatch.ElapsedMilliseconds -lt $ReadinessTimeoutMilliseconds) {
            if (Test-Path -LiteralPath $stdoutPath) {
                $stream = [IO.FileStream]::new(
                    $stdoutPath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                )
                try {
                    $reader = [IO.StreamReader]::new($stream)
                    $stdout = $reader.ReadToEnd()
                    $reader.Dispose()
                }
                finally {
                    $stream.Dispose()
                }
                if (($stdout -split "`r?`n") -ccontains $readyToken) {
                    $ready = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 25
        }

        if (-not $ready) {
            $failureKind = 'readiness-timeout'
            $cleanupAttempted = $true
            $nativeType::TerminateOwnedJob($jobHandle)
            $cleanupCompleted = Wait-JobEmpty -JobHandle $jobHandle -TimeoutMilliseconds $ForceTimeoutMilliseconds
            throw "readiness-timeout: fixture did not emit the exact readiness token within $ReadinessTimeoutMilliseconds ms"
        }

        $record = [ordered]@{
            schemaVersion = 1
            runId = $runId
            ownerToken = $ownerToken
            jobName = $jobName
            shutdownEventName = $shutdownEventName
            fixturePid = $launch.ProcessId
            fixtureCreationTimeUtc = $launch.ProcessCreationTimeUtc.ToString('O')
            stdoutPath = $stdoutPath
            stderrPath = $stderrPath
        }
        $memberPidsBeforeReturn = @($nativeType::QueryJobProcessIds($jobHandle))
        [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 4 -Compress))

        $result = [ordered]@{
            action = 'Launch'
            success = $true
            failureKind = $null
            observedFacts = [ordered]@{
                runId = $runId
                jobName = $jobName
                fixturePid = $launch.ProcessId
                fixtureCreationTimeUtc = $launch.ProcessCreationTimeUtc.ToString('O')
                launcherWasAlreadyInJob = $launch.LauncherWasAlreadyInJob
                memberPidsBeforeReturn = $memberPidsBeforeReturn
                readinessObserved = $true
                readinessElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                stdoutPath = $stdoutPath
                stderrPath = $stderrPath
                recordPath = $recordPath
                fixtureAliveBeforeReturn = $nativeType::IsProcessInstanceAlive(
                    $launch.ProcessId,
                    $launch.ProcessCreationTimeUtc
                )
            }
        }
        Write-ResultAndExit -Result $result -ExitCode 0
    }
    catch {
        if ($jobHandle -ne [IntPtr]::Zero -and -not $cleanupAttempted) {
            $cleanupAttempted = $true
            try {
                $nativeType::TerminateOwnedJob($jobHandle)
                $cleanupCompleted = Wait-JobEmpty -JobHandle $jobHandle -TimeoutMilliseconds $ForceTimeoutMilliseconds
            }
            catch {
                $cleanupCompleted = $false
            }
        }

        if (-not $failureKind) {
            $failureKind = 'launch-failed'
        }
        $result = [ordered]@{
            action = 'Launch'
            success = $false
            failureKind = $failureKind
            error = $_.Exception.Message
            observedFacts = [ordered]@{
                runId = $runId
                jobName = $jobName
                fixturePid = if ($launch) { $launch.ProcessId } else { $null }
                fixtureCreationTimeUtc = if ($launch) { $launch.ProcessCreationTimeUtc.ToString('O') } else { $null }
                readinessObserved = $false
                readinessElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                cleanupAttemptedThroughRetainedJobHandle = $cleanupAttempted
                cleanupCompletedWithinBound = $cleanupCompleted
                recordWritten = Test-Path -LiteralPath $recordPath
                stdoutPath = $stdoutPath
                stderrPath = $stderrPath
            }
        }
        Write-ResultAndExit -Result $result -ExitCode 20
    }
    finally {
        if ($jobHandle -ne [IntPtr]::Zero) {
            $nativeType::Close($jobHandle)
        }
    }
}

function Invoke-Finalize {
    $jobHandle = [IntPtr]::Zero
    $jobReopened = $false
    $terminationAttempted = $false
    $memberPidsBefore = @()
    $failureKind = 'record-invalid'

    try {
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw 'record-invalid: run record does not exist'
        }
        $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -DateKind String
        $expectedCreationTime = Test-RecordShape -Record $record

        $jobHandle = $nativeType::OpenOwnedJob([string]$record.jobName)
        $jobReopened = $true
        $memberPidsBefore = @($nativeType::QueryJobProcessIds($jobHandle))
        $fixturePid = [int]$record.fixturePid
        $failureKind = 'ownership-validation-failed'

        if ($memberPidsBefore -notcontains [long]$fixturePid) {
            throw 'ownership-validation-failed: recorded fixture PID is not a current Job member'
        }
        if (-not $nativeType::IsProcessInSpecificJob($fixturePid, $jobHandle)) {
            throw 'ownership-validation-failed: recorded fixture process is not in the reopened Job'
        }
        $actualCreationTime = $nativeType::TryGetProcessCreationTimeUtc($fixturePid)
        if (-not $actualCreationTime -or $actualCreationTime.Ticks -ne $expectedCreationTime.Ticks) {
            throw 'ownership-validation-failed: recorded fixture creation time does not match the current process'
        }
        if (-not $nativeType::SignalExistingEvent([string]$record.shutdownEventName)) {
            throw 'ownership-validation-failed: owner-specific shutdown event is unavailable'
        }

        if (Wait-JobEmpty -JobHandle $jobHandle -TimeoutMilliseconds $GraceTimeoutMilliseconds) {
            $terminationMode = 'graceful'
        }
        else {
            $terminationAttempted = $true
            $nativeType::TerminateOwnedJob($jobHandle)
            if (-not (Wait-JobEmpty -JobHandle $jobHandle -TimeoutMilliseconds $ForceTimeoutMilliseconds)) {
                $failureKind = 'forced-stop-timeout'
                throw 'forced-stop-timeout: Job did not become empty within the force timeout'
            }
            $terminationMode = 'forced-job'
        }

        $result = [ordered]@{
            action = 'Finalize'
            success = $true
            failureKind = $null
            observedFacts = [ordered]@{
                runId = $record.runId
                jobName = $record.jobName
                jobReopened = $jobReopened
                ownershipValidated = $true
                memberPidsBefore = $memberPidsBefore
                gracefulShutdownSignaled = $true
                terminationMode = $terminationMode
                terminationAttemptedThroughRetainedJobHandle = $terminationAttempted
                jobEmptyWithinBound = $true
            }
        }
        Write-ResultAndExit -Result $result -ExitCode 0
    }
    catch {
        $result = [ordered]@{
            action = 'Finalize'
            success = $false
            failureKind = $failureKind
            error = $_.Exception.Message
            observedFacts = [ordered]@{
                jobReopened = $jobReopened
                ownershipValidated = $false
                memberPidsBefore = $memberPidsBefore
                terminationAttemptedThroughRetainedJobHandle = $terminationAttempted
            }
        }
        Write-ResultAndExit -Result $result -ExitCode 30
    }
    finally {
        if ($jobHandle -ne [IntPtr]::Zero) {
            $nativeType::Close($jobHandle)
        }
    }
}

if ($Action -eq 'Launch') {
    Invoke-Launch
}
else {
    Invoke-Finalize
}
