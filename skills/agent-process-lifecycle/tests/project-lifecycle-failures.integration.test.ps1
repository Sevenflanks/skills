[CmdletBinding()]
param(
    [ValidateSet('All', 'NeverReady', 'BlockedCallbackEarlyExit', 'TruthyReadiness', 'DeniedBoundary', 'HarnessFaultPreservesRecord', 'PortConflict', 'MissingRecord', 'StaleRecord', 'MembershipUnknown')]
    [string]$Scenario = 'All',
    [string]$HelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-AgentProcessLifecycle.ps1'),
    [string]$WorkloadPath = (Join-Path $PSScriptRoot 'fixtures\bounded-loopback-workload.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ownedFixtures = [Collections.Generic.List[object]]::new()

$readinessCheck = {
    param([hashtable]$Context)

    if (-not [IO.File]::Exists($Context.ReadyPath)) { return [bool]$false }
    try {
        $ready = [IO.File]::ReadAllText($Context.ReadyPath) | ConvertFrom-Json -AsHashtable
        if (-not [string]::Equals([string]$ready.token, [string]$Context.Token, [StringComparison]::Ordinal)) {
            return [bool]$false
        }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.ConnectAsync([Net.IPAddress]::Loopback, [int]$ready.port)
            $null = $connect.GetAwaiter().GetResult()
            $reader = [IO.StreamReader]::new($client.GetStream(), [Text.Encoding]::UTF8, $false, 1024, $true)
            try {
                return [bool][string]::Equals($reader.ReadLine(), [string]$Context.Token, [StringComparison]::Ordinal)
            }
            finally { $reader.Dispose() }
        }
        finally { $client.Dispose() }
    }
    catch { return [bool]$false }
}

$gracefulStop = {
    param([hashtable]$Binding)

    [IO.File]::WriteAllText([string]$Binding.graceful_context.StopPath, [string]$Binding.graceful_context.Token, [Text.UTF8Encoding]::new($false))
    return [bool]$true
}

function Test-LoopbackToken {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Token)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync([Net.IPAddress]::Loopback, $Port)
        $null = $connect.GetAwaiter().GetResult()
        $reader = [IO.StreamReader]::new($client.GetStream(), [Text.Encoding]::UTF8, $false, 1024, $true)
        try {
            return [bool][string]::Equals($reader.ReadLine(), $Token, [StringComparison]::Ordinal)
        }
        finally { $reader.Dispose() }
    }
    catch { return [bool]$false }
    finally { $client.Dispose() }
}

function Update-VerifiedFixtureStop {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Fixture,
        [Parameter(Mandatory)][Collections.IDictionary]$FinalizeResult
    )

    $rootPid = [int]$Fixture.result.binding.root_process_id
    $holderPid = [int]$Fixture.result.binding.holder_identity.process_id
    $verified = $FinalizeResult.lifecycle_result.status -eq 'success' -and
        $FinalizeResult.final_disposition.status -eq 'completed' -and
        $FinalizeResult.evidence.owned_tree_empty -eq $true -and
        $FinalizeResult.evidence.root_process_absent -eq $true -and
        $FinalizeResult.evidence.job_holder_absent -eq $true -and
        $FinalizeResult.evidence.named_job_absent -eq $true -and
        $FinalizeResult.evidence.record_present -eq $false -and
        $FinalizeResult.evidence.record_cleanup_completed -eq $true -and
        -not [IO.File]::Exists([string]$Fixture.record_path) -and
        $null -eq (Get-Process -Id $rootPid -ErrorAction SilentlyContinue) -and
        $null -eq (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)
    if ($verified) { $Fixture.cleanup_verified = $true }
    return [bool]$verified
}

function Invoke-FixtureStop {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Fixture,
        [Parameter(Mandatory)][string]$Token
    )

    $result = & $HelperPath -Action Finalize -RecordPath $Fixture.record_path -Disposition Stop -GracefulAction $gracefulStop -GracefulContext @{
        StopPath = $Fixture.stop_path
        Token = $Token
    } -GracefulDeadlineMilliseconds 3000
    $null = Update-VerifiedFixtureStop -Fixture $Fixture -FinalizeResult $result
    return $result
}

function Remove-VerifiedRunRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fixtures
    )

    if (-not [IO.Directory]::Exists($Root)) { return [bool]$true }
    $unresolvedFixtures = @($Fixtures | Where-Object { -not $_.cleanup_verified })
    $remainingRecords = @([IO.Directory]::EnumerateFiles($Root, 'run.json', [IO.SearchOption]::AllDirectories))
    if ($unresolvedFixtures.Count -eq 0 -and $remainingRecords.Count -eq 0) {
        Remove-Item -LiteralPath $Root -Recurse -Force
        return [bool]$true
    }

    Write-Warning "Preserving runtime root because owned cleanup is unresolved: root=$Root records=$($remainingRecords -join ',')"
    return [bool]$false
}

function Invoke-LaunchFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('server', 'never-ready', 'delayed-exit')][string]$Mode,
        [Parameter(Mandatory)][string]$Token,
        [int]$Port = 0,
        [int]$DeadlineMilliseconds = 5000,
        [scriptblock]$Check = $readinessCheck
    )

    $control = Join-Path $Root "control-$Name"
    $readyPath = Join-Path $Root "$Name-ready.json"
    $stopPath = Join-Path $Root "$Name-stop.token"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = & $HelperPath -Action Launch -RecordPath (Join-Path $control 'run.json') -Executable "$PSHOME\pwsh.exe" -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkloadPath,
        '-Mode', $Mode, '-ReadyPath', $readyPath, '-StopPath', $stopPath,
        '-Token', $Token, '-Port', [string]$Port, '-MaxLifetimeSeconds', '30'
    ) -WorkingDirectory $Root -StdoutPath (Join-Path $control 'stdout.log') -StderrPath (Join-Path $control 'stderr.log') -ReadinessCheck $Check -ReadinessContext @{
        ReadyPath = $readyPath
        Token = $Token
    } -ReadinessIdentity "loopback-token:$Token" -ReadinessDeadlineMilliseconds $DeadlineMilliseconds -RequestedDisposition Stop
    $watch.Stop()
    $cleanupVerified = $false
    if ($result.lifecycle_result.status -eq 'failed') {
        $cleanup = $result.lifecycle_result.cleanup
        $cleanupVerified = $cleanup.status -eq 'completed' -and $cleanup.root_absent -eq $true -and
            $cleanup.holder_absent -eq $true -and $cleanup.named_job_absent -eq $true -and $cleanup.record_absent -eq $true
    }
    $fixture = [ordered]@{
        result = $result
        elapsed_milliseconds = $watch.ElapsedMilliseconds
        record_path = Join-Path $control 'run.json'
        stderr_path = Join-Path $control 'stderr.log'
        ready_path = $readyPath
        stop_path = $stopPath
        cleanup_verified = $cleanupVerified
    }
    $script:ownedFixtures.Add($fixture)
    return $fixture
}

function Invoke-BlockedCallbackEarlyExitCase {
    param([Parameter(Mandatory)][string]$Root)

    $blockedCheck = {
        param([hashtable]$Context)

        [Threading.Thread]::Sleep(1800)
        [IO.File]::WriteAllText($Context.ReadyPath, 'callback-completed', [Text.UTF8Encoding]::new($false))
        return $false
    }
    $case = Invoke-LaunchFixture -Root $Root -Name 'blocked-callback-exit' -Mode delayed-exit -Token ([guid]::NewGuid().ToString('N')) -DeadlineMilliseconds 2000 -Check $blockedCheck
    if ($case.result.lifecycle_result.status -ne 'failed' -or $case.result.lifecycle_result.failure_kind -ne 'candidate-bind-error') {
        throw "Blocked callback hid the candidate early exit: $($case.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($case.result.lifecycle_result.exit_code -ne 42 -or $case.result.lifecycle_result.stderr_diagnostic -notmatch 'AddressAlreadyInUse') {
        throw "Blocked callback did not preserve exit/stderr evidence: $($case.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }
    if (Test-Path -LiteralPath $case.ready_path) {
        throw 'Blocked readiness callback was allowed to finish after the candidate root exited.'
    }
    if ($case.elapsed_milliseconds -ge 5000) {
        throw "Blocked callback cleanup was not bounded: $($case.elapsed_milliseconds) ms"
    }
    if ($case.result.lifecycle_result.cleanup.status -ne 'completed') {
        throw "Blocked callback candidate cleanup was incomplete: $($case.result.lifecycle_result.cleanup | ConvertTo-Json -Depth 8 -Compress)"
    }
}

function Invoke-TruthyReadinessCase {
    param([Parameter(Mandatory)][string]$Root)

    $truthyCheck = {
        param([hashtable]$Context)

        if ([IO.File]::Exists($Context.ReadyPath)) { return 'ready' }
        return $null
    }
    $token = [guid]::NewGuid().ToString('N')
    $fixture = Invoke-LaunchFixture -Root $Root -Name 'truthy-readiness' -Mode server -Token $token -Check $truthyCheck
    $finalized = $false
    try {
        if ($fixture.result.lifecycle_result.status -ne 'success') {
            throw "Truthy readiness callback lost compatibility: $($fixture.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $finalize = Invoke-FixtureStop -Fixture $fixture -Token $token
        if (-not $fixture.cleanup_verified) {
            throw "Truthy readiness fixture did not finalize: $($finalize | ConvertTo-Json -Depth 8 -Compress)"
        }
        $finalized = $true
    }
    finally {
        if ($fixture.result.lifecycle_result.status -eq 'success' -and -not $finalized -and (Test-Path -LiteralPath $fixture.record_path)) {
            $fallback = Invoke-FixtureStop -Fixture $fixture -Token $token
            if (-not $fixture.cleanup_verified) {
                Write-Warning "Truthy fixture cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
            }
        }
    }
}

function Invoke-DeniedBoundaryCase {
    param([Parameter(Mandatory)][string]$Root)

    $boundary = [IO.Directory]::CreateDirectory((Join-Path $Root 'denied-boundary'))
    $originalSecurity = [IO.FileSystemAclExtensions]::GetAccessControl($boundary)
    $originalSddl = $originalSecurity.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $deniedSecurity = [IO.FileSystemAclExtensions]::GetAccessControl($boundary)
    $deniedSecurity.SetAccessRuleProtection($true, $false)
    $deniedRights = [Security.AccessControl.FileSystemRights]::CreateFiles -bor [Security.AccessControl.FileSystemRights]::CreateDirectories
    $deniedRule = [Security.AccessControl.FileSystemAccessRule]::new($currentSid, $deniedRights, [Security.AccessControl.AccessControlType]::Deny)
    $deniedSecurity.AddAccessRule($deniedRule)
    $fixtureControlRights = [Security.AccessControl.FileSystemRights]::FullControl
    $fixtureControlRule = [Security.AccessControl.FileSystemAccessRule]::new($currentSid, $fixtureControlRights, [Security.AccessControl.AccessControlType]::Allow)
    $deniedSecurity.AddAccessRule($fixtureControlRule)
    try {
        [IO.FileSystemAclExtensions]::SetAccessControl($boundary, $deniedSecurity)
    }
    catch {
        throw "Denied fixture ACL setup failed: $($_.Exception.Message)"
    }
    $deniedSddl = [IO.FileSystemAclExtensions]::GetAccessControl($boundary).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    try {
        $recordPath = Join-Path $boundary.FullName 'run.json'
        $result = & $HelperPath -Action Launch -RecordPath $recordPath -Executable "$PSHOME\pwsh.exe" -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkloadPath,
            '-Mode', 'never-ready', '-ReadyPath', (Join-Path $Root 'denied-ready.json'), '-StopPath', (Join-Path $Root 'denied-stop.token'),
            '-Token', ([guid]::NewGuid().ToString('N')), '-Port', '0', '-MaxLifetimeSeconds', '30'
        ) -WorkingDirectory $Root -StdoutPath (Join-Path $boundary.FullName 'stdout.log') -StderrPath (Join-Path $boundary.FullName 'stderr.log') -ReadinessCheck $readinessCheck -ReadinessContext @{} -ReadinessIdentity 'denied-boundary' -ReadinessDeadlineMilliseconds 1000 -RequestedDisposition Stop
        if ($result.lifecycle_result.status -ne 'failed' -or $result.lifecycle_result.error -notmatch '(?i)denied|unauthorized|拒') {
            throw "Denied boundary did not fail clearly: $($result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $afterSddl = [IO.FileSystemAclExtensions]::GetAccessControl($boundary).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        if (-not [string]::Equals($deniedSddl, $afterSddl, [StringComparison]::Ordinal)) {
            throw 'Launch changed the ACL of the denied fixture boundary.'
        }
        if (Test-Path -LiteralPath $recordPath) {
            throw 'Denied boundary unexpectedly contains a run record.'
        }
    }
    finally {
        # 這個 ACL 是測試在本次新建的 boundary 上加的；只還原這個精確 fixture，絕不改既有 project root。
        try {
            $restoreSecurity = [IO.FileSystemAclExtensions]::GetAccessControl($boundary)
            $restoreSecurity.SetSecurityDescriptorSddlForm($originalSddl, [Security.AccessControl.AccessControlSections]::Access)
            [IO.FileSystemAclExtensions]::SetAccessControl($boundary, $restoreSecurity)
        }
        catch {
            throw "Denied fixture ACL restore failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-NeverReadyCase {
    param([Parameter(Mandatory)][string]$Root)

    $case = Invoke-LaunchFixture -Root $Root -Name 'never-ready' -Mode never-ready -Token ([guid]::NewGuid().ToString('N')) -DeadlineMilliseconds 1500
    if ($case.result.lifecycle_result.status -ne 'failed') {
        throw "Never-ready Launch status was not failed: $($case.result.lifecycle_result.status)"
    }
    if ($case.result.lifecycle_result.failure_kind -ne 'readiness-timeout') {
        throw "Never-ready failure was not classified as readiness-timeout: $($case.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($case.elapsed_milliseconds -lt 1000 -or $case.elapsed_milliseconds -ge 6000) {
        throw "Never-ready cleanup was not bounded around its 1500 ms deadline: $($case.elapsed_milliseconds) ms"
    }
    if ($case.result.lifecycle_result.cleanup.status -ne 'completed' -or
        -not $case.result.lifecycle_result.cleanup.root_absent -or
        -not $case.result.lifecycle_result.cleanup.holder_absent -or
        -not $case.result.lifecycle_result.cleanup.named_job_absent -or
        -not $case.result.lifecycle_result.cleanup.record_absent) {
        throw "Never-ready cleanup evidence is incomplete: $($case.result.lifecycle_result.cleanup | ConvertTo-Json -Depth 8 -Compress)"
    }
}

function Invoke-HarnessFaultPreservesRecordCase {
    param([Parameter(Mandatory)][string]$Root)

    $faultRoot = Join-Path $Root 'harness-fault'
    $recordPath = Join-Path $faultRoot 'control\run.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $recordPath)) | Out-Null
    [IO.File]::WriteAllText($recordPath, '{"status":"unresolved-fixture-evidence"}', [Text.UTF8Encoding]::new($false))
    $fixture = [ordered]@{ cleanup_verified = $false }

    $removed = Remove-VerifiedRunRoot -Root $faultRoot -Fixtures @($fixture) -WarningAction SilentlyContinue
    if ($removed -or -not [IO.File]::Exists($recordPath)) {
        throw 'Harness fault cleanup deleted an unresolved fixture record.'
    }

    $fixture.cleanup_verified = $true
    [IO.File]::Delete($recordPath)
    if (-not (Remove-VerifiedRunRoot -Root $faultRoot -Fixtures @($fixture))) {
        throw 'Harness fault cleanup did not remove the root after cleanup was verified.'
    }
}

function Invoke-PortConflictCase {
    param([Parameter(Mandatory)][string]$Root)

    $sentinelToken = [guid]::NewGuid().ToString('N')
    $candidateToken = [guid]::NewGuid().ToString('N')
    $sentinel = Invoke-LaunchFixture -Root $Root -Name 'sentinel' -Mode server -Token $sentinelToken
    $sentinelFinalized = $false
    try {
        if ($sentinel.result.lifecycle_result.status -ne 'success') {
            throw "Sentinel Launch failed: $($sentinel.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $sentinelRecordHash = (Get-FileHash -LiteralPath $sentinel.record_path -Algorithm SHA256).Hash
        $sentinelReady = [IO.File]::ReadAllText($sentinel.ready_path) | ConvertFrom-Json -AsHashtable
        $sentinelPid = [int]$sentinel.result.binding.root_process_id
        $port = [int]$sentinelReady.port

        $candidate = Invoke-LaunchFixture -Root $Root -Name 'candidate' -Mode server -Token $candidateToken -Port $port -DeadlineMilliseconds 5000
        if ($candidate.result.lifecycle_result.status -ne 'failed') {
            throw "Port-conflict candidate status was not failed: $($candidate.result.lifecycle_result.status)"
        }
        if ($candidate.result.lifecycle_result.failure_kind -ne 'candidate-bind-error') {
            throw "Port-conflict failure was not classified as candidate-bind-error: $($candidate.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        if ($candidate.elapsed_milliseconds -ge 4000) {
            throw "Port-conflict candidate waited for the readiness timeout: $($candidate.elapsed_milliseconds) ms"
        }
        if ($candidate.result.lifecycle_result.error -notmatch 'AddressAlreadyInUse') {
            throw "Port-conflict result did not preserve the bind diagnostic: $($candidate.result.lifecycle_result.error)"
        }
        if ($candidate.result.lifecycle_result.cleanup.status -ne 'completed') {
            throw "Port-conflict candidate cleanup was not complete: $($candidate.result.lifecycle_result.cleanup | ConvertTo-Json -Depth 8 -Compress)"
        }

        $positive = Test-LoopbackToken -Port $port -Token $sentinelToken
        $negative = Test-LoopbackToken -Port $port -Token $candidateToken
        if ($positive -isnot [bool] -or $negative -isnot [bool] -or -not $positive -or $negative) {
            throw "Token probe was not scalar Boolean true/false: positive=$positive negative=$negative"
        }
        if (-not (Get-Process -Id $sentinelPid -ErrorAction SilentlyContinue)) {
            throw 'Candidate cleanup terminated the independent sentinel.'
        }
        if ((Get-FileHash -LiteralPath $sentinel.record_path -Algorithm SHA256).Hash -ne $sentinelRecordHash) {
            throw 'Candidate cleanup changed the independent sentinel record.'
        }

        $finalize = Invoke-FixtureStop -Fixture $sentinel -Token $sentinelToken
        if (-not $sentinel.cleanup_verified) {
            throw "Sentinel Finalize failed: $($finalize.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $sentinelFinalized = $true
    }
    finally {
        if ($sentinel.result.lifecycle_result.status -eq 'success' -and -not $sentinelFinalized -and (Test-Path -LiteralPath $sentinel.record_path)) {
            try {
                $fallback = Invoke-FixtureStop -Fixture $sentinel -Token $sentinelToken
                if (-not $sentinel.cleanup_verified) {
                    Write-Warning "Sentinel cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
                }
            }
            catch {
                Write-Warning "Sentinel fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-MissingRecordCase {
    param([Parameter(Mandatory)][string]$Root)

    $missingRecord = Join-Path $Root 'missing-control\run.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $missingRecord)) | Out-Null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = & $HelperPath -Action Finalize -RecordPath $missingRecord -Disposition Stop
    $watch.Stop()
    if ($result.lifecycle_result.status -ne 'unresolved' -or $result.evidence.termination_attempted -ne $false) {
        throw "Missing record was not a no-kill unresolved result: $($result | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($watch.ElapsedMilliseconds -ge 3000) {
        throw "Missing-record Finalize was not bounded: $($watch.ElapsedMilliseconds) ms"
    }
}

function Invoke-StaleRecordCase {
    param([Parameter(Mandatory)][string]$Root)

    $token = [guid]::NewGuid().ToString('N')
    $fixture = Invoke-LaunchFixture -Root $Root -Name 'stale-record' -Mode server -Token $token
    $finalized = $false
    $originalBytes = $null
    try {
        if ($fixture.result.lifecycle_result.status -ne 'success') {
            throw "Stale-record fixture Launch failed: $($fixture.result.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $originalBytes = [IO.File]::ReadAllBytes($fixture.record_path)
        $record = [Text.Encoding]::UTF8.GetString($originalBytes) | ConvertFrom-Json -AsHashtable -DateKind String
        $record.root.creation_time_filetime = [int64]$record.root.creation_time_filetime + 1
        [IO.File]::WriteAllText($fixture.record_path, ($record | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $staleHash = (Get-FileHash -LiteralPath $fixture.record_path -Algorithm SHA256).Hash

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $rejected = & $HelperPath -Action Finalize -RecordPath $fixture.record_path -Disposition Stop
        $watch.Stop()
        if (Update-VerifiedFixtureStop -Fixture $fixture -FinalizeResult $rejected) {
            throw 'Stale-record unresolved Finalize was incorrectly marked as verified cleanup.'
        }
        if ($rejected.lifecycle_result.status -ne 'unresolved' -or
            $rejected.evidence.reason_code -ne 'root-creation-time-mismatch' -or
            $rejected.evidence.termination_attempted -ne $false) {
            throw "Stale record was not a no-kill identity mismatch: $($rejected | ConvertTo-Json -Depth 8 -Compress)"
        }
        if ($watch.ElapsedMilliseconds -ge 3000) {
            throw "Stale-record Finalize was not bounded: $($watch.ElapsedMilliseconds) ms"
        }
        if ((Get-FileHash -LiteralPath $fixture.record_path -Algorithm SHA256).Hash -ne $staleHash) {
            throw 'Rejected Finalize changed the stale record.'
        }
        if (-not (Get-Process -Id ([int]$fixture.result.binding.root_process_id) -ErrorAction SilentlyContinue)) {
            throw 'Rejected Finalize terminated the still-owned fixture.'
        }
        $ready = [IO.File]::ReadAllText($fixture.ready_path) | ConvertFrom-Json -AsHashtable
        if (-not (Test-LoopbackToken -Port ([int]$ready.port) -Token $token)) {
            throw 'Rejected Finalize disrupted the still-owned fixture.'
        }

        [IO.File]::WriteAllBytes($fixture.record_path, $originalBytes)
        $finalize = Invoke-FixtureStop -Fixture $fixture -Token $token
        if (-not $fixture.cleanup_verified) {
            throw "Restored stale-record fixture did not finalize: $($finalize.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $finalized = $true
    }
    finally {
        if ($fixture.result.lifecycle_result.status -eq 'success' -and -not $finalized -and (Test-Path -LiteralPath $fixture.record_path)) {
            try {
                if ($originalBytes) { [IO.File]::WriteAllBytes($fixture.record_path, $originalBytes) }
                $fallback = Invoke-FixtureStop -Fixture $fixture -Token $token
                if (-not $fixture.cleanup_verified) {
                    Write-Warning "Stale-record cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
                }
            }
            catch {
                Write-Warning "Stale-record fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-MembershipUnknownCase {
    param([Parameter(Mandatory)][string]$Root)

    $ownedToken = [guid]::NewGuid().ToString('N')
    $foreignToken = [guid]::NewGuid().ToString('N')
    $owned = Invoke-LaunchFixture -Root $Root -Name 'membership-owned' -Mode server -Token $ownedToken
    $foreign = Invoke-LaunchFixture -Root $Root -Name 'membership-foreign' -Mode server -Token $foreignToken
    $ownedFinalized = $false
    $foreignFinalized = $false
    $originalBytes = $null
    try {
        if ($owned.result.lifecycle_result.status -ne 'success' -or $foreign.result.lifecycle_result.status -ne 'success') {
            throw 'Membership fixtures did not both launch successfully.'
        }
        $originalBytes = [IO.File]::ReadAllBytes($owned.record_path)
        $record = [Text.Encoding]::UTF8.GetString($originalBytes) | ConvertFrom-Json -AsHashtable -DateKind String
        $foreignRecord = [IO.File]::ReadAllText($foreign.record_path) | ConvertFrom-Json -AsHashtable -DateKind String
        $record.run_id = $foreignRecord.run_id
        $record.job_name = $foreignRecord.job_name
        $record.events.finalize = $foreignRecord.events.finalize
        $record.events.holder_exited = $foreignRecord.events.holder_exited
        [IO.File]::WriteAllText($owned.record_path, ($record | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $mismatchedHash = (Get-FileHash -LiteralPath $owned.record_path -Algorithm SHA256).Hash

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $rejected = & $HelperPath -Action Finalize -RecordPath $owned.record_path -Disposition Stop
        $watch.Stop()
        if (Update-VerifiedFixtureStop -Fixture $owned -FinalizeResult $rejected) {
            throw 'Membership-unresolved Finalize was incorrectly marked as verified cleanup.'
        }
        if ($rejected.lifecycle_result.status -ne 'unresolved' -or
            $rejected.evidence.reason_code -ne 'root-not-job-member' -or
            $rejected.evidence.termination_attempted -ne $false) {
            throw "Unknown membership was not a no-kill unresolved result: $($rejected | ConvertTo-Json -Depth 8 -Compress)"
        }
        if ($watch.ElapsedMilliseconds -ge 3000) {
            throw "Membership-unverifiable Finalize was not bounded: $($watch.ElapsedMilliseconds) ms"
        }
        if ((Get-FileHash -LiteralPath $owned.record_path -Algorithm SHA256).Hash -ne $mismatchedHash) {
            throw 'Rejected Finalize changed the membership-mismatched record.'
        }
        foreach ($fixture in @($owned, $foreign)) {
            if (-not (Get-Process -Id ([int]$fixture.result.binding.root_process_id) -ErrorAction SilentlyContinue)) {
                throw 'Rejected Finalize terminated an independently owned fixture.'
            }
        }
        $ownedReady = [IO.File]::ReadAllText($owned.ready_path) | ConvertFrom-Json -AsHashtable
        $foreignReady = [IO.File]::ReadAllText($foreign.ready_path) | ConvertFrom-Json -AsHashtable
        if (-not (Test-LoopbackToken -Port ([int]$ownedReady.port) -Token $ownedToken) -or
            -not (Test-LoopbackToken -Port ([int]$foreignReady.port) -Token $foreignToken)) {
            throw 'Rejected Finalize disrupted an independently owned fixture.'
        }

        [IO.File]::WriteAllBytes($owned.record_path, $originalBytes)
        $ownedStop = Invoke-FixtureStop -Fixture $owned -Token $ownedToken
        if (-not $owned.cleanup_verified) {
            throw "Membership-owned fixture did not finalize successfully: $($ownedStop | ConvertTo-Json -Depth 8 -Compress)"
        }
        $ownedFinalized = $true
        $foreignStop = Invoke-FixtureStop -Fixture $foreign -Token $foreignToken
        if (-not $foreign.cleanup_verified) {
            throw "Membership-foreign fixture did not finalize successfully: $($foreignStop | ConvertTo-Json -Depth 8 -Compress)"
        }
        $foreignFinalized = $true
        if ($ownedStop.lifecycle_result.status -ne 'success' -or $foreignStop.lifecycle_result.status -ne 'success') {
            throw 'Membership fixtures did not both finalize successfully.'
        }
    }
    finally {
        if ($owned.result.lifecycle_result.status -eq 'success' -and -not $ownedFinalized -and (Test-Path -LiteralPath $owned.record_path)) {
            try {
                if ($originalBytes) { [IO.File]::WriteAllBytes($owned.record_path, $originalBytes) }
                $fallback = Invoke-FixtureStop -Fixture $owned -Token $ownedToken
                if (-not $owned.cleanup_verified) {
                    Write-Warning "Membership-owned cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
                }
            }
            catch { Write-Warning "Membership-owned fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)" }
        }
        if ($foreign.result.lifecycle_result.status -eq 'success' -and -not $foreignFinalized -and (Test-Path -LiteralPath $foreign.record_path)) {
            try {
                $fallback = Invoke-FixtureStop -Fixture $foreign -Token $foreignToken
                if (-not $foreign.cleanup_verified) {
                    Write-Warning "Membership-foreign cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
                }
            }
            catch { Write-Warning "Membership-foreign fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)" }
        }
    }
}

$runRoot = Join-Path $PSScriptRoot ".runtime-failures-$([guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    if ($Scenario -in @('All', 'NeverReady')) { Invoke-NeverReadyCase -Root $runRoot }
    if ($Scenario -in @('All', 'BlockedCallbackEarlyExit')) { Invoke-BlockedCallbackEarlyExitCase -Root $runRoot }
    if ($Scenario -in @('All', 'TruthyReadiness')) { Invoke-TruthyReadinessCase -Root $runRoot }
    if ($Scenario -in @('All', 'DeniedBoundary')) { Invoke-DeniedBoundaryCase -Root $runRoot }
    if ($Scenario -in @('All', 'HarnessFaultPreservesRecord')) { Invoke-HarnessFaultPreservesRecordCase -Root $runRoot }
    if ($Scenario -in @('All', 'PortConflict')) { Invoke-PortConflictCase -Root $runRoot }
    if ($Scenario -in @('All', 'MissingRecord')) { Invoke-MissingRecordCase -Root $runRoot }
    if ($Scenario -in @('All', 'StaleRecord')) { Invoke-StaleRecordCase -Root $runRoot }
    if ($Scenario -in @('All', 'MembershipUnknown')) { Invoke-MembershipUnknownCase -Root $runRoot }
    Write-Host "Project lifecycle failure integration test passed: $Scenario"
}
finally {
    if (Test-Path -LiteralPath $runRoot) {
        $null = Remove-VerifiedRunRoot -Root $runRoot -Fixtures @($ownedFixtures)
    }
}
