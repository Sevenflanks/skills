import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { access, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, parse, resolve } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileCallback } from "node:child_process";
import test, { after } from "node:test";
import { cleanupFixtureRoot, fixtureRoot, mkdtemp } from "./protected-test-fixture.mjs";

after(cleanupFixtureRoot);

const execFile = promisify(execFileCallback);
const helperPath = resolve(
  import.meta.dirname,
  "../windows-helper/Invoke-AgentProcessLifecycle.ps1",
);

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function assertProtectedFixtureRecordPath(recordPath) {
  assert.ok(
    recordPath.startsWith(`${fixtureRoot}\\`),
    "Launch exposes its record beneath the protected user-local fixture root",
  );
  assert.notEqual(
    dirname(dirname(recordPath)),
    parse(recordPath).root,
    "Launch fixture directory is not directly beneath a volume root",
  );
}

async function runPowerShell(scriptPath) {
  const { stdout, stderr } = await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", scriptPath],
    { windowsHide: true, maxBuffer: 1024 * 1024 },
  );

  assert.equal(stderr, "", `PowerShell stderr: ${stderr}`);
  return JSON.parse(stdout);
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function isAlive(processId) {
  if (!processId) return false;
  try {
    process.kill(processId, 0);
    return true;
  } catch (error) {
    return error.code !== "ESRCH";
  }
}

async function namedJobExists(name) {
  if (!name) return false;
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket11Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket11Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket11Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return stdout.trim() === "true";
}

async function addObjectInheritWriteAce(directory) {
  const script = `$directory = [IO.DirectoryInfo]::new(${powerShellLiteral(directory)}); $security = [IO.FileSystemAclExtensions]::GetAccessControl($directory); $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User; $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($currentSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]::ObjectInherit, [Security.AccessControl.PropagationFlags]::InheritOnly, [Security.AccessControl.AccessControlType]::Allow)); $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), [Security.AccessControl.FileSystemRights]::Write, [Security.AccessControl.InheritanceFlags]::ObjectInherit, [Security.AccessControl.PropagationFlags]::InheritOnly, [Security.AccessControl.AccessControlType]::Allow)); [IO.FileSystemAclExtensions]::SetAccessControl($directory, $security)`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
}

async function callbackArtifactPaths(directory, purpose) {
  const callbackDirectoryPattern = new RegExp(`^${purpose}-[0-9a-f]{32}\\.callback[\\\\/](?:context\\.xml|result\\.xml|callback\\.ps1|stdout\\.log|stderr\\.log)$`, "u");
  const legacyArtifactPattern = new RegExp(`^${purpose}-[0-9a-f]{32}\\.(?:context\\.xml|result\\.xml|ps1|stdout\\.log|stderr\\.log)$`, "u");
  return (await readdir(directory, { recursive: true }))
    .filter((entry) => callbackDirectoryPattern.test(entry) || legacyArtifactPattern.test(entry))
    .map((entry) => join(directory, entry));
}

async function waitForCallbackArtifacts(directory, purpose, timeoutMilliseconds = 6000) {
  const deadline = Date.now() + timeoutMilliseconds;
  let observedEntries = [];
  while (Date.now() < deadline) {
    const paths = await callbackArtifactPaths(directory, purpose);
    if (paths.length === 5) return paths;
    observedEntries = await readdir(directory, { recursive: true });
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`Timed out waiting for all ${purpose} callback artifacts. Observed: ${observedEntries.join(", ")}`);
}

async function inspectPathSecurity(paths) {
  const literals = paths.map(powerShellLiteral).join(", ");
  const script = `$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User; $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::AppendData -bor [Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership; @(${literals}) | ForEach-Object { $item = Get-Item -LiteralPath $_ -Force; $security = [IO.FileSystemAclExtensions]::GetAccessControl($item); $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])); [pscustomobject]@{ path = $item.FullName; is_directory = $item.PSIsContainer; reparse = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0); protected = $security.AreAccessRulesProtected; owner = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value; current_user = $currentSid.Value; current_user_full_control = @($rules | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -eq $currentSid.Value -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl }).Count -gt 0; other_write_sids = @($rules | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -ne $currentSid.Value -and ($_.FileSystemRights -band $writeRights) -ne 0 } | ForEach-Object { $_.IdentityReference.Value }) } } | ConvertTo-Json -Depth 6 -Compress`;
  const { stdout, stderr } = await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
    { windowsHide: true, maxBuffer: 1024 * 1024 },
  );
  assert.equal(stderr, "", `PowerShell stderr: ${stderr}`);
  const result = JSON.parse(stdout);
  return Array.isArray(result) ? result : [result];
}

function assertCurrentUserOnlySecurity(item, expectedDirectory) {
  assert.equal(item.is_directory, expectedDirectory, `${item.path} has the expected artifact type`);
  assert.equal(item.reparse, false, `${item.path} is not a reparse point`);
  assert.equal(item.protected, true, `${item.path} has protected ACL inheritance`);
  assert.equal(item.owner, item.current_user, `${item.path} is owned by the current SID`);
  assert.equal(item.current_user_full_control, true, `${item.path} grants the current SID FullControl`);
  assert.deepEqual(item.other_write_sids, [], `${item.path} grants no other SID callback mutation rights`);
}

async function assertNoCallbackResidue(directory, purpose) {
  assert.deepEqual(await callbackArtifactPaths(directory, purpose), [], `${purpose} callback artifacts are absent`);
  const callbackDirectories = (await readdir(directory)).filter((entry) => new RegExp(`^${purpose}-[0-9a-f]{32}\\.callback$`, "u").test(entry));
  assert.deepEqual(callbackDirectories, [], `${purpose} callback directories are absent`);
}

async function cleanupCurrentRun(recordPath, stopEventName, result) {
  const record = await pathExists(recordPath)
    ? JSON.parse(await readFile(recordPath, "utf8"))
    : undefined;
  const rootProcessId = result?.binding?.root_process_id ?? record?.root?.process_id;
  const holderProcessId = result?.evidence?.job_holder_process_id ?? record?.holder?.process_id;
  const jobName = result?.binding?.job_name ?? record?.job_name;
  const rootIdentity = result?.binding?.root_identity ?? record?.root;
  const holderIdentity = result?.binding?.holder_identity ?? record?.holder;
  const finalizeEventName = record?.events?.finalize;
  const stopSignal = stopEventName
    ? `$stopEvent = [Threading.EventWaitHandle]::OpenExisting(${powerShellLiteral(stopEventName)}); try { $stopEvent.Set() | Out-Null } finally { $stopEvent.Dispose() };`
    : "";
  const resourcesRemain = isAlive(rootProcessId) || isAlive(holderProcessId) || await namedJobExists(jobName);
  const cleanup = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket11CleanupNative { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; ${stopSignal} $jobName = ${powerShellLiteral(jobName ?? "")}; if ($jobName) { $job = [Ticket11CleanupNative]::OpenJobObjectW(0x0010000c, $false, $jobName); if ($job -ne [IntPtr]::Zero) { try { [Ticket11CleanupNative]::TerminateJobObject($job, 124) | Out-Null } finally { [Ticket11CleanupNative]::CloseHandle($job) | Out-Null } } }; $eventName = ${powerShellLiteral(finalizeEventName ?? "")}; if ($eventName) { try { $holderEvent = [Threading.EventWaitHandle]::OpenExisting($eventName); try { $holderEvent.Set() | Out-Null } finally { $holderEvent.Dispose() } } catch { $missingHolderEvent = $_.Exception.Message } }; $identities = @(@{ id=${rootProcessId ?? 0}; creation=${powerShellLiteral(String(rootIdentity?.creation_time_filetime ?? ""))}; image=${powerShellLiteral(rootIdentity?.image_path ?? "")} }, @{ id=${holderProcessId ?? 0}; creation=${powerShellLiteral(String(holderIdentity?.creation_time_filetime ?? ""))}; image=${powerShellLiteral(holderIdentity?.image_path ?? "")} }); foreach ($identity in $identities) { if ($identity.id -gt 0) { $process = Get-Process -Id $identity.id -ErrorAction SilentlyContinue; if ($process -and -not $process.WaitForExit(2000)) { if (-not $identity.creation -or -not $identity.image -or [string]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $identity.creation -or -not [string]::Equals($process.Path, $identity.image, [StringComparison]::OrdinalIgnoreCase)) { throw "Refused PID fallback because identity is not proven: $($identity.id)" }; Stop-Process -Id $identity.id -Force; $process.WaitForExit(2000) | Out-Null } } }`;
  if (resourcesRemain) {
    await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", cleanup], { windowsHide: true });
  }
  assert.equal(isAlive(rootProcessId), false, "test cleanup removed the current-run workload");
  assert.equal(isAlive(holderProcessId), false, "test cleanup removed the current-run holder");
  assert.equal(await namedJobExists(jobName), false, "test cleanup removed the current-run named Job");
  await rm(recordPath, { force: true });
  assert.equal(await pathExists(recordPath), false, "test cleanup removed the current-run record");
  return record;
}

test("Launch and Finalize gracefully manage one Windows run across fresh PowerShell invocations", async () => {
  assert.equal(process.platform, "win32", "ticket 11 is Windows-only");

  const runtimeDirectory = await mkdtemp("agent-process-lifecycle-ticket-11-");
  const runId = randomUUID();
  const paths = {
    actionLog: join(runtimeDirectory, "graceful-actions.log"),
    finalResult: join(runtimeDirectory, "final-result.json"),
    launchResult: join(runtimeDirectory, "launch-result.json"),
    readySignal: join(runtimeDirectory, "ready.signal"),
    record: join(runtimeDirectory, "run-record.json"),
    stderr: join(runtimeDirectory, "workload.stderr.log"),
    stdout: join(runtimeDirectory, "workload.stdout.log"),
    stopEvent: `Local\\AgentProcessLifecycle.Ticket11.Stop.${runId}`,
    stoppedSignal: join(runtimeDirectory, "stopped.signal"),
    workload: join(runtimeDirectory, "workload.ps1"),
  };
  const launchScript = join(runtimeDirectory, "launch.ps1");
  const finalizeScript = join(runtimeDirectory, "finalize.ps1");
  let acceptanceCompleted = false;
  let launch;

  try {
    await writeFile(
      paths.workload,
      `param([string]$ReadySignalPath, [string]$StopEventName, [string]$StoppedSignalPath)
$stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [Console]::Out.WriteLine('workload-started')
    [Console]::Error.WriteLine('workload-stderr-isolated')
    [IO.File]::WriteAllText($ReadySignalPath, 'ready')
    if (-not $stopEvent.WaitOne(15000)) { throw 'graceful signal deadline elapsed' }
    [IO.File]::WriteAllText($StoppedSignalPath, 'stopped')
    [Console]::Out.WriteLine('workload-stopped-gracefully')
}
finally {
    $stopEvent.Dispose()
}
`,
      "utf8",
    );

    await writeFile(
      launchScript,
      `$stopEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.stopEvent)})
try {
    $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.workload)}, '-ReadySignalPath', ${powerShellLiteral(paths.readySignal)}, '-StopEventName', ${powerShellLiteral(paths.stopEvent)}, '-StoppedSignalPath', ${powerShellLiteral(paths.stoppedSignal)}) -WorkingDirectory ${powerShellLiteral(runtimeDirectory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-11-ready-signal' -ReadinessContext @{ ready_signal_path = ${powerShellLiteral(paths.readySignal)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_signal_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop -DownstreamResult @{ status = 'not-run'; source = 'ticket-11-launch' }
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally {
    $stopEvent.Dispose()
}
`,
      "utf8",
    );

    launch = await runPowerShell(launchScript);
    await writeFile(paths.launchResult, JSON.stringify(launch));

    assert.equal(launch.action, "Launch");
    assert.equal(launch.tier, "windows-self-managed");
    assert.equal(launch.requested_disposition, "Stop");
    assert.equal(launch.stdio.isolated, true);
    assert.equal(launch.readiness.identity, "ticket-11-ready-signal");
    assert.equal(launch.readiness.succeeded, true);
    assert.equal(launch.lifecycle_result.status, "success");
    assert.equal(launch.downstream_result.status, "not-run");
    assert.equal(launch.final_disposition.status, "pending");
    assert.ok(launch.binding.run_id);
    assert.ok(launch.binding.job_name.startsWith("Local\\AgentProcessLifecycle."));
    assertProtectedFixtureRecordPath(launch.binding.record_path);
    assert.equal(isAlive(launch.binding.root_process_id), true, "workload survives the Launch invocation");
    await assertNoCallbackResidue(runtimeDirectory, "readiness");

    await writeFile(
      finalizeScript,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ action_log_path = ${powerShellLiteral(paths.actionLog)}; stop_event_name = ${powerShellLiteral(paths.stopEvent)} } -GracefulAction {
    param($binding)
    [IO.File]::AppendAllText($binding.graceful_context.action_log_path, "called" + [Environment]::NewLine)
    $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name)
    try { $stopEvent.Set() | Out-Null } finally { $stopEvent.Dispose() }
} -DownstreamResult @{ status = 'failed'; source = 'ticket-11-downstream' }
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );

    const finalized = await runPowerShell(finalizeScript);
    await writeFile(paths.finalResult, JSON.stringify(finalized));

    assert.equal(finalized.action, "Finalize");
    assert.equal(finalized.tier, "windows-self-managed");
    assert.equal(finalized.requested_disposition, "Stop");
    assert.equal(finalized.lifecycle_result.status, "success");
    assert.equal(finalized.downstream_result.status, "failed");
    assert.equal(finalized.final_disposition.status, "completed");
    assert.equal(finalized.evidence.graceful_action_invocations, 1);
    assert.equal(finalized.evidence.forced_termination_used, false);
    assert.equal(finalized.evidence.root_process_absent, true);
    assert.equal(finalized.evidence.named_job_absent, true);
    assert.equal(finalized.evidence.job_holder_absent, true);
    assert.equal(isAlive(launch.binding.root_process_id), false, "graceful Stop removes the root process");
    assert.equal(isAlive(launch.evidence.job_holder_process_id), false, "graceful Stop removes the holder process");
    assert.equal(await namedJobExists(launch.binding.job_name), false, "graceful Stop removes the named Job");
    assert.equal((await readFile(paths.actionLog, "utf8")).trim().split(/\r?\n/u).length, 1);
    assert.equal(await pathExists(paths.stoppedSignal), true);
    assert.equal(await pathExists(paths.record), false, "Finalize removes its temporary ownership record");
    assert.match(await readFile(paths.stdout, "utf8"), /workload-stopped-gracefully/u);
    assert.match(await readFile(paths.stderr, "utf8"), /workload-stderr-isolated/u);
    await assertNoCallbackResidue(runtimeDirectory, "graceful");
    acceptanceCompleted = true;
  } finally {
    if (!acceptanceCompleted) await cleanupCurrentRun(paths.record, paths.stopEvent, launch);
    await rm(runtimeDirectory, { recursive: true, force: true });
    if (acceptanceCompleted) {
      assert.equal(await pathExists(runtimeDirectory), false, "ticket fixture leaves no temporary artifacts");
    }
  }
});

test("helper exposes only Launch and Finalize with scoped Job termination only", async () => {
  const helper = await readFile(helperPath, "utf8");

  assert.match(helper, /ValidateSet\('Launch', 'Finalize'\)/u);
  assert.match(helper, /TerminateJobObject\(callback worker\)/u);
  assert.match(helper, /TerminateCallbackJob\(IntPtr job\)[\s\S]*?TerminateJobObject\(job, 124\)/u);
  assert.match(helper, /TerminateFinalizedWorkloadJob\(IntPtr job\)[\s\S]*?TerminateJobObject\(job, 124\)/u);
  assert.match(helper, /\$workerStartedSuspended = \$false[\s\S]*?\$workerAssignedToCallbackJob = \$false[\s\S]*?\$callbackCompleted = \$false/u);
  assert.match(helper, /if \(\$workerAssignedToCallbackJob\)[\s\S]*?Stop-CallbackJob -JobHandle \$callbackJob[\s\S]*?else \{[\s\S]*?TerminateUnassignedCallbackWorker\(\$worker\.ProcessHandle\)/u);
  assert.doesNotMatch(helper, /KILL_ON_JOB_CLOSE|TerminateOwnedJob|Stop-Process|Get-Process|Get-NetTCPConnection/u);
  assert.match(helper, /ValidateSet\('Stop', 'Preserve'\)/u);
});

test("Ticket 11 test-generated callback children stay hidden", async () => {
  const source = await readFile(resolve(import.meta.dirname, "windows-helper-ticket-11.test.mjs"), "utf8");
  const childLaunches = [...source.matchAll(/\$child = Start-Process -FilePath \$PSHOME\\\\pwsh\.exe[^\r\n]*/gu)];

  assert.equal(childLaunches.length, 3, "the three callback child launch sites remain explicit");
  for (const [launch] of childLaunches) {
    assert.match(launch, /-WindowStyle Hidden -PassThru/u);
  }
});

test("callback artifacts reject object-inherited cross-principal write access", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-11-callback-acl-");
  const recordPath = join(directory, "run-record.json");
  const scriptPath = join(directory, "launch.ps1");
  const childReadyPath = join(directory, "callback-child-ready.signal");
  const sentinelPath = join(directory, "unrelated-sentinel.txt");
  const sentinel = "ticket-11-unrelated-sentinel";
  let activeResult;
  let launchSettlement;

  try {
    await writeFile(sentinelPath, sentinel, "utf8");
    await writeFile(
      scriptPath,
      `$result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(recordPath)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, "workload.stdout.log"))} -StderrPath ${powerShellLiteral(join(directory, "workload.stderr.log"))} -ReadinessIdentity 'callback-acl-regression' -ReadinessContext @{ child_ready_path = ${powerShellLiteral(childReadyPath)} } -ReadinessCheck { param($context) $child = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText($context.child_ready_path, 'started'); $true } -ReadinessDeadlineMilliseconds 8000 -RequestedDisposition Stop
$result | ConvertTo-Json -Depth 12 -Compress`,
      "utf8",
    );
    await addObjectInheritWriteAce(directory);

    launchSettlement = runPowerShell(scriptPath).then(
      (value) => ({ value }),
      (error) => ({ error }),
    );
    const firstOutcome = await Promise.race([
      waitForCallbackArtifacts(directory, "readiness").then((artifactPaths) => ({ artifactPaths })),
      launchSettlement.then((settled) => ({ settled })),
    ]);
    if (firstOutcome.settled) {
      if (firstOutcome.settled.error) throw firstOutcome.settled.error;
      assert.fail(`Launch completed before callback artifacts could be inspected: ${JSON.stringify(firstOutcome.settled.value)}`);
    }
    const { artifactPaths } = firstOutcome;
    const artifacts = await inspectPathSecurity(artifactPaths);
    assert.equal(artifacts.length, 5, "the blocked callback exposes all five protected leaves for inspection");
    for (const artifact of artifacts) assertCurrentUserOnlySecurity(artifact, false);

    const callbackDirectories = [...new Set(artifactPaths.map(dirname))];
    assert.equal(callbackDirectories.length, 1, "one callback invocation owns one private directory");
    assert.notEqual(callbackDirectories[0], directory, "callback artifacts are not created beside the record");
    assert.match(basename(callbackDirectories[0]), /^readiness-[0-9a-f]{32}\.callback$/u);
    const [callbackDirectorySecurity] = await inspectPathSecurity(callbackDirectories);
    assertCurrentUserOnlySecurity(callbackDirectorySecurity, true);
    assert.deepEqual(
      artifactPaths.map((artifactPath) => basename(artifactPath)).sort(),
      ["callback.ps1", "context.xml", "result.xml", "stderr.log", "stdout.log"],
      "the private directory contains the exact callback artifact set",
    );

    const settled = await launchSettlement;
    if (settled.error) throw settled.error;
    activeResult = settled.value;
    assert.equal(activeResult.lifecycle_result.status, "failed");
    assert.equal(activeResult.lifecycle_result.failure_kind, "readiness");
    assert.equal(activeResult.lifecycle_result.cleanup.status, "completed");
    await assertNoCallbackResidue(directory, "readiness");
    assert.equal(await readFile(sentinelPath, "utf8"), sentinel, "callback cleanup does not alter an unrelated sentinel");
  } finally {
    if (launchSettlement && !activeResult) {
      const settled = await launchSettlement;
      if (!settled.error) activeResult = settled.value;
    }
    await cleanupCurrentRun(recordPath, undefined, activeResult);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false, "callback ACL fixture leaves no temporary artifacts");
  }
});

test("blocking readiness callbacks return within their configured deadline", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-11-timeout-");
  const script = join(directory, "launch.ps1");
  let activeRecord;
  let activeResult;
  let warmupRecord;
  let descendantCleanupProven = false;
  try {
    for (const attempt of [0, 1, 2]) {
      activeRecord = join(directory, `run-record-${attempt}.json`);
      warmupRecord = join(directory, `callback-warmup-record-${attempt}.json`);
      const workerPidPath = join(directory, `readiness-worker-${attempt}.pid`);
      const childPidPath = join(directory, `readiness-child-${attempt}.pid`);
      const childReadyPath = join(directory, `readiness-child-ready-${attempt}.signal`);
      const timeoutStartedPath = join(directory, `readiness-timeout-started-${attempt}.txt`);
      await writeFile(script, `$warmup = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(warmupRecord)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, `warmup-${attempt}.stdout.log`))} -StderrPath ${powerShellLiteral(join(directory, `warmup-${attempt}.stderr.log`))} -ReadinessIdentity 'blocking-regression-warmup' -ReadinessCheck { param($context) $true } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop
if ($warmup.lifecycle_result.status -ne 'success') { throw 'Callback warmup Launch did not succeed.' }
$warmupFinal = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(warmupRecord)} -Disposition Stop -GracefulDeadlineMilliseconds 1000
if ($warmupFinal.lifecycle_result.status -ne 'success') { throw 'Callback warmup Finalize did not succeed.' }
[IO.File]::WriteAllText(${powerShellLiteral(timeoutStartedPath)}, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(activeRecord)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, `stdout-${attempt}.log`))} -StderrPath ${powerShellLiteral(join(directory, `stderr-${attempt}.log`))} -ReadinessIdentity 'blocking-regression' -ReadinessContext @{ worker_pid_path = ${powerShellLiteral(workerPidPath)}; child_pid_path = ${powerShellLiteral(childPidPath)}; child_ready_path = ${powerShellLiteral(childReadyPath)} } -ReadinessCheck { param($context) [IO.File]::WriteAllText($context.worker_pid_path, [string]$PID); $child = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText($context.child_pid_path, [string]$child.Id); [IO.File]::WriteAllText($context.child_ready_path, 'started'); Start-Sleep -Seconds 8; $false } -ReadinessDeadlineMilliseconds 1000 -RequestedDisposition Stop
$result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
      activeResult = await runPowerShell(script);
      assert.ok(Date.now() - Number(await readFile(timeoutStartedPath, "utf8")) < 3500, "blocking readiness callback exceeded its coarse deadline bound");
      assert.equal(activeResult.lifecycle_result.status, "failed");
      assert.equal(activeResult.lifecycle_result.failure_kind, "readiness");
      assert.equal(activeResult.lifecycle_result.cleanup.status, "completed");
      assert.equal(activeResult.lifecycle_result.cleanup.root_absent, true, "ticket 12 cleanup removes the workload after readiness failure");
      assert.equal(await pathExists(activeRecord), false, "ticket 12 cleanup removes the preparing record after readiness failure");
      assert.equal(isAlive(Number(await readFile(workerPidPath, "utf8"))), false, "timed-out readiness worker is absent");
      if (await pathExists(childReadyPath)) {
        assert.equal(await pathExists(childPidPath), true, "callback records its descendant before entering the bounded blocking portion");
        assert.equal(isAlive(Number(await readFile(childPidPath, "utf8"))), false, "timed-out readiness child is absent");
        descendantCleanupProven = true;
      }
      await cleanupCurrentRun(activeRecord, undefined, activeResult);
      activeRecord = undefined;
      activeResult = undefined;
      if (descendantCleanupProven) break;
    }
    assert.equal(descendantCleanupProven, true, "at least one bounded callback run creates and cleans its descendant");
  } finally {
    if (activeRecord) await cleanupCurrentRun(activeRecord, undefined, activeResult);
    if (warmupRecord && await pathExists(warmupRecord)) await cleanupCurrentRun(warmupRecord, undefined, undefined);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
});

test("blocking graceful callbacks stop at their deadline and enter scoped forced cleanup", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-11-graceful-timeout-");
  const recordPath = join(directory, "run-record.json");
  const readyPath = join(directory, "ready.signal");
  const actionLog = join(directory, "graceful-actions.log");
  const workerPidPath = join(directory, "graceful-worker.pid");
  const childPidPath = join(directory, "graceful-child.pid");
  const timeoutStartedPath = join(directory, "graceful-timeout-started.txt");
  const stopEventName = `Local\\AgentProcessLifecycle.Ticket11.GracefulTimeout.${randomUUID()}`;
  const workloadPath = join(directory, "workload.ps1");
  const launchPath = join(directory, "launch.ps1");
  const finalizePath = join(directory, "finalize.ps1");
  let record;
  let launch;
  try {
    await writeFile(workloadPath, `param([string]$ReadyPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try { [IO.File]::WriteAllText($ReadyPath, 'ready'); $stopEvent.WaitOne(15000) | Out-Null } finally { $stopEvent.Dispose() }`, "utf8");
    await writeFile(launchPath, `$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(stopEventName)})
try { & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(recordPath)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',${powerShellLiteral(workloadPath)},'-ReadyPath',${powerShellLiteral(readyPath)},'-StopEventName',${powerShellLiteral(stopEventName)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, "stdout.log"))} -StderrPath ${powerShellLiteral(join(directory, "stderr.log"))} -ReadinessIdentity 'graceful-timeout-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(readyPath)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop | ConvertTo-Json -Depth 12 -Compress } finally { $stopEvent.Dispose() }`, "utf8");
    launch = await runPowerShell(launchPath);
    record = JSON.parse(await readFile(recordPath, "utf8"));
    await writeFile(finalizePath, `try { $null = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(join(directory, "warmup-missing.json"))} -GracefulAction {} } catch { $warmupFailure = $_.Exception.Message }; [IO.File]::WriteAllText(${powerShellLiteral(timeoutStartedPath)}, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); $result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(recordPath)} -Disposition Stop -GracefulDeadlineMilliseconds 1000 -GracefulContext @{ action_log_path = ${powerShellLiteral(actionLog)}; worker_pid_path = ${powerShellLiteral(workerPidPath)}; child_pid_path = ${powerShellLiteral(childPidPath)} } -GracefulAction { param($binding) [IO.File]::AppendAllText($binding.graceful_context.action_log_path, "called" + [Environment]::NewLine); [IO.File]::WriteAllText($binding.graceful_context.worker_pid_path, [string]$PID); $child = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText($binding.graceful_context.child_pid_path, [string]$child.Id); Start-Sleep -Seconds 8 }; $result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
    const finalized = await runPowerShell(finalizePath);
    assert.ok(Date.now() - Number(await readFile(timeoutStartedPath, "utf8")) < 3500, "blocking graceful callback exceeded its millisecond deadline bound");
    assert.equal((await readFile(actionLog, "utf8")).trim().split(/\r?\n/u).length, 1, "graceful callback ran exactly once");
    assert.equal(isAlive(Number(await readFile(workerPidPath, "utf8"))), false, "timed-out graceful worker is absent");
    assert.equal(isAlive(Number(await readFile(childPidPath, "utf8"))), false, "timed-out graceful child is absent");
    assert.equal(finalized.lifecycle_result.status, "success");
    assert.equal(finalized.evidence.graceful_action_invocations, 1);
    assert.equal(finalized.evidence.forced_termination_used, true);
    assert.equal(finalized.evidence.owned_tree_empty, true);
    assert.equal(isAlive(launch.binding.root_process_id), false, "forced Stop removes the owned workload");
    assert.equal(await namedJobExists(launch.binding.job_name), false, "forced Stop removes the named Job");
    assert.equal(await pathExists(recordPath), false, "forced Stop removes the ownership record");
  } finally {
    await cleanupCurrentRun(recordPath, stopEventName, launch);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false, "graceful callback fixture leaves no temporary artifacts");
  }
});
