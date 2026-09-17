[CmdletBinding()]
param(
    [string]$HelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-AgentProcessLifecycle.ps1'),
    [string]$WorkloadPath = (Join-Path $PSScriptRoot 'fixtures\bounded-loopback-workload.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CurrentUserProtectedArtifact {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    $acl = if ($item -is [IO.DirectoryInfo]) {
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$item)
    }
    else {
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$item)
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne $currentSid -or $rules.Count -ne 1 -or
        $rules[0].IdentityReference.Value -ne $currentSid -or $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        -not $rules[0].FileSystemRights.HasFlag([Security.AccessControl.FileSystemRights]::FullControl)) {
        throw "Artifact is not protected for only the current user: $Path"
    }
}

function Test-VerifiedStop {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$LaunchResult,
        [Parameter(Mandatory)][Collections.IDictionary]$FinalizeResult,
        [Parameter(Mandatory)][string]$RecordPath
    )

    $rootPid = [int]$LaunchResult.binding.root_process_id
    $holderPid = [int]$LaunchResult.binding.holder_identity.process_id
    return [bool]($FinalizeResult.lifecycle_result.status -eq 'success' -and
        $FinalizeResult.final_disposition.status -eq 'completed' -and
        $FinalizeResult.evidence.owned_tree_empty -eq $true -and
        $FinalizeResult.evidence.root_process_absent -eq $true -and
        $FinalizeResult.evidence.job_holder_absent -eq $true -and
        $FinalizeResult.evidence.named_job_absent -eq $true -and
        $FinalizeResult.evidence.record_present -eq $false -and
        $FinalizeResult.evidence.record_cleanup_completed -eq $true -and
        -not [IO.File]::Exists($RecordPath) -and
        $null -eq (Get-Process -Id $rootPid -ErrorAction SilentlyContinue) -and
        $null -eq (Get-Process -Id $holderPid -ErrorAction SilentlyContinue))
}

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
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $client.Dispose()
        }
    }
    catch {
        return [bool]$false
    }
}

$gracefulStop = {
    param([hashtable]$Binding)

    [IO.File]::WriteAllText([string]$Binding.graceful_context.StopPath, [string]$Binding.graceful_context.Token, [Text.UTF8Encoding]::new($false))
    return [bool]$true
}

$runRoot = Join-Path $PSScriptRoot ".runtime-$([guid]::NewGuid().ToString('N'))"
$recordPath = Join-Path $runRoot 'control\run.json'
$stdoutPath = Join-Path $runRoot 'control\stdout.log'
$stderrPath = Join-Path $runRoot 'control\stderr.log'
$readyPath = Join-Path $runRoot 'ready.json'
$stopPath = Join-Path $runRoot 'stop.token'
$token = [guid]::NewGuid().ToString('N')
$launch = $null
$finalized = $false
$preserveRecordPath = Join-Path $runRoot 'preserve-control\run.json'
$preserveStdoutPath = Join-Path $runRoot 'preserve-control\stdout.log'
$preserveStderrPath = Join-Path $runRoot 'preserve-control\stderr.log'
$preserveReadyPath = Join-Path $runRoot 'preserve-ready.json'
$preserveStopPath = Join-Path $runRoot 'preserve-stop.token'
$preserveToken = [guid]::NewGuid().ToString('N')
$laterOwner = 'integration-test-later-owner'
$preserveLaunch = $null
$preserveFinalized = $false

try {
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $aclBefore = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($runRoot)).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $launch = & $HelperPath -Action Launch -RecordPath $recordPath -Executable "$PSHOME\pwsh.exe" -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkloadPath,
        '-Mode', 'server', '-ReadyPath', $readyPath, '-StopPath', $stopPath,
        '-Token', $token, '-Port', '0', '-MaxLifetimeSeconds', '30'
    ) -WorkingDirectory $runRoot -StdoutPath $stdoutPath -StderrPath $stderrPath -ReadinessCheck $readinessCheck -ReadinessContext @{
        ReadyPath = $readyPath
        Token = $token
    } -ReadinessIdentity "loopback-token:$token" -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop -DownstreamResult ([ordered]@{ status = 'not-run' })
    $watch.Stop()

    if ($launch.lifecycle_result.status -ne 'success') {
        throw "Launch failed: $($launch.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($watch.ElapsedMilliseconds -ge 10000) {
        throw "Launch exceeded its bounded deadline: $($watch.ElapsedMilliseconds) ms"
    }
    if (-not (Get-Process -Id ([int]$launch.binding.root_process_id) -ErrorAction SilentlyContinue)) {
        throw 'Launch returned success after the owned root exited.'
    }
    if ($launch.downstream_result.status -ne 'not-run') {
        throw 'Launch changed the caller-owned downstream result.'
    }
    foreach ($artifact in @((Split-Path -Parent $recordPath), $recordPath, $stdoutPath, $stderrPath)) {
        Assert-CurrentUserProtectedArtifact -Path $artifact
    }

    $finalize = & $HelperPath -Action Finalize -RecordPath $recordPath -Disposition Stop -GracefulAction $gracefulStop -GracefulContext @{
        StopPath = $stopPath
        Token = $token
    } -GracefulDeadlineMilliseconds 3000 -DownstreamResult ([ordered]@{ status = 'passed' })
    if (-not (Test-VerifiedStop -LaunchResult $launch -FinalizeResult $finalize -RecordPath $recordPath)) {
        throw "Finalize failed: $($finalize.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }
    $finalized = $true
    if ($finalize.downstream_result.status -ne 'passed') {
        throw 'Finalize changed the caller-owned downstream result.'
    }
    if (Test-Path -LiteralPath $recordPath) {
        throw 'Finalize left the exact run record behind.'
    }

    $aclAfter = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($runRoot)).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    if (-not [string]::Equals($aclBefore, $aclAfter, [StringComparison]::Ordinal)) {
        throw 'The helper changed the ACL of the pre-existing project test root.'
    }

    $preserveLaunch = & $HelperPath -Action Launch -RecordPath $preserveRecordPath -Executable "$PSHOME\pwsh.exe" -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkloadPath,
        '-Mode', 'server', '-ReadyPath', $preserveReadyPath, '-StopPath', $preserveStopPath,
        '-Token', $preserveToken, '-Port', '0', '-MaxLifetimeSeconds', '30'
    ) -WorkingDirectory $runRoot -StdoutPath $preserveStdoutPath -StderrPath $preserveStderrPath -ReadinessCheck $readinessCheck -ReadinessContext @{
        ReadyPath = $preserveReadyPath
        Token = $preserveToken
    } -ReadinessIdentity "loopback-token:$preserveToken" -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Preserve -RequestedLaterOwner $laterOwner
    if ($preserveLaunch.lifecycle_result.status -ne 'success') {
        throw "Preserve Launch failed: $($preserveLaunch.lifecycle_result | ConvertTo-Json -Depth 8 -Compress)"
    }

    $preserved = & $HelperPath -Action Finalize -RecordPath $preserveRecordPath -Disposition Preserve -LaterOwner $laterOwner
    if ($preserved.lifecycle_result.status -ne 'success' -or $preserved.final_disposition.status -ne 'preserved') {
        throw "Preserve Finalize failed: $($preserved | ConvertTo-Json -Depth 8 -Compress)"
    }
    if (-not (Get-Process -Id ([int]$preserveLaunch.binding.root_process_id) -ErrorAction SilentlyContinue)) {
        throw 'Preserve terminated the owned root instead of handing it off.'
    }

    $preserveStop = & $HelperPath -Action Finalize -RecordPath $preserveRecordPath -Disposition Stop -GracefulAction $gracefulStop -GracefulContext @{
        StopPath = $preserveStopPath
        Token = $preserveToken
    } -GracefulDeadlineMilliseconds 3000
    if (-not (Test-VerifiedStop -LaunchResult $preserveLaunch -FinalizeResult $preserveStop -RecordPath $preserveRecordPath)) {
        throw "Preserved fixture did not Stop: $($preserveStop | ConvertTo-Json -Depth 8 -Compress)"
    }
    $preserveFinalized = $true

    Write-Host 'Project-scope Launch/Finalize integration test passed.'
}
finally {
    if ($launch -and $launch.lifecycle_result.status -eq 'success' -and -not $finalized -and (Test-Path -LiteralPath $recordPath)) {
        try {
            $fallback = & $HelperPath -Action Finalize -RecordPath $recordPath -Disposition Stop -GracefulAction $gracefulStop -GracefulContext @{
                StopPath = $stopPath
                Token = $token
            } -GracefulDeadlineMilliseconds 3000
            if (Test-VerifiedStop -LaunchResult $launch -FinalizeResult $fallback -RecordPath $recordPath) {
                $finalized = $true
            }
            else {
                Write-Warning "Fixture cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
            }
        }
        catch {
            Write-Warning "Fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)"
        }
    }
    if ($preserveLaunch -and $preserveLaunch.lifecycle_result.status -eq 'success' -and -not $preserveFinalized -and (Test-Path -LiteralPath $preserveRecordPath)) {
        try {
            $fallback = & $HelperPath -Action Finalize -RecordPath $preserveRecordPath -Disposition Stop -GracefulAction $gracefulStop -GracefulContext @{
                StopPath = $preserveStopPath
                Token = $preserveToken
            } -GracefulDeadlineMilliseconds 3000
            if (Test-VerifiedStop -LaunchResult $preserveLaunch -FinalizeResult $fallback -RecordPath $preserveRecordPath) {
                $preserveFinalized = $true
            }
            else {
                Write-Warning "Preserve fixture cleanup remained unresolved; preserving record/evidence: $($fallback | ConvertTo-Json -Depth 8 -Compress)"
            }
        }
        catch {
            Write-Warning "Preserve fixture watchdog remains the bounded cleanup fallback: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $runRoot) {
        $ownedCleanupUnresolved = ($launch -and $launch.lifecycle_result.status -eq 'success' -and -not $finalized) -or
            ($preserveLaunch -and $preserveLaunch.lifecycle_result.status -eq 'success' -and -not $preserveFinalized)
        $remainingRecords = @([IO.Directory]::EnumerateFiles($runRoot, 'run.json', [IO.SearchOption]::AllDirectories))
        if (-not $ownedCleanupUnresolved -and $remainingRecords.Count -eq 0) {
            Remove-Item -LiteralPath $runRoot -Recurse -Force
        }
        else {
            Write-Warning "Preserving runtime root because owned cleanup is unresolved: root=$runRoot records=$($remainingRecords -join ',')"
        }
    }
}
