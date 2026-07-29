import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { access, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileCallback } from "node:child_process";
import test from "node:test";

const execFile = promisify(execFileCallback);
const helperPath = resolve(
  import.meta.dirname,
  "../windows-helper/Invoke-AgentProcessLifecycle.ps1",
);

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

async function mkdtemp(prefix) {
  const baseName = prefix.split(/[\\/]/u).at(-1).replace(/[^a-z0-9-]/giu, "");
  const directory = join("C:\\", `${baseName}${randomUUID()}`);
  const script = `$directory = ${powerShellLiteral(directory)}; $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User; $security = [Security.AccessControl.DirectorySecurity]::new(); $security.SetOwner($sid); $security.SetAccessRuleProtection($true, $false); $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)); [IO.FileSystemAclExtensions]::CreateDirectory($security, $directory) | Out-Null`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return directory;
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
  try {
    process.kill(processId, 0);
    return true;
  } catch (error) {
    return error.code !== "ESRCH";
  }
}

async function namedJobExists(name) {
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket11Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket11Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket11Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return stdout.trim() === "true";
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

  const runtimeDirectory = await mkdtemp(join(tmpdir(), "agent-process-lifecycle-ticket-11-"));
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
    assert.equal(isAlive(launch.binding.root_process_id), true, "workload survives the Launch invocation");

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
    acceptanceCompleted = true;
  } finally {
    if (!acceptanceCompleted) await cleanupCurrentRun(paths.record, paths.stopEvent, launch);
    await rm(runtimeDirectory, { recursive: true, force: true });
    if (acceptanceCompleted) {
      assert.equal(await pathExists(runtimeDirectory), false, "ticket fixture leaves no temporary artifacts");
    }
  }
});

test("ticket 11 helper exposes only Launch and Finalize without forced termination", async () => {
  const helper = await readFile(helperPath, "utf8");

  assert.match(helper, /ValidateSet\('Launch', 'Finalize'\)/u);
  assert.match(helper, /TerminateJobObject\(callback worker\)/u);
  assert.match(helper, /TerminateCallbackJob\(IntPtr job\)[\s\S]*?TerminateJobObject\(job, 124\)/u);
  assert.match(helper, /\$workerStartedSuspended = \$false[\s\S]*?\$workerAssignedToCallbackJob = \$false[\s\S]*?\$callbackCompleted = \$false/u);
  assert.match(helper, /if \(\$workerAssignedToCallbackJob\)[\s\S]*?TerminateCallbackJob\(\$callbackJob\)[\s\S]*?else \{[\s\S]*?TerminateUnassignedCallbackWorker\(\$worker\.ProcessHandle\)/u);
  assert.doesNotMatch(helper, /KILL_ON_JOB_CLOSE|TerminateOwnedJob|Stop-Process|Get-Process|Get-NetTCPConnection/u);
  assert.doesNotMatch(helper, /ValidateSet\([^)]*Preserve/u);
});

test("blocking readiness callbacks return within their configured deadline", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-process-lifecycle-ticket-11-timeout-"));
  const record = join(directory, "run-record.json");
  const script = join(directory, "launch.ps1");
  const workerPidPath = join(directory, "readiness-worker.pid");
  const childPidPath = join(directory, "readiness-child.pid");
  const timeoutStartedPath = join(directory, "readiness-timeout-started.txt");
  let launchFailure;
  try {
    await writeFile(script, `try { & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(join(directory, "warmup-missing.json"))} -GracefulAction {} } catch { $warmupFailure = $_.Exception.Message }; [IO.File]::WriteAllText(${powerShellLiteral(timeoutStartedPath)}, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, "stdout.log"))} -StderrPath ${powerShellLiteral(join(directory, "stderr.log"))} -ReadinessIdentity 'blocking-regression' -ReadinessContext @{ worker_pid_path = ${powerShellLiteral(workerPidPath)}; child_pid_path = ${powerShellLiteral(childPidPath)} } -ReadinessCheck { param($context) [IO.File]::WriteAllText($context.worker_pid_path, [string]$PID); $child = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -PassThru; [IO.File]::WriteAllText($context.child_pid_path, [string]$child.Id); Start-Sleep -Seconds 8; $false } -ReadinessDeadlineMilliseconds 1000 -RequestedDisposition Stop; $result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
    launchFailure = await runPowerShell(script);
    assert.ok(Date.now() - Number(await readFile(timeoutStartedPath, "utf8")) < 3500, "blocking readiness callback exceeded its coarse deadline bound");
    assert.equal(launchFailure.lifecycle_result.status, "failed");
    assert.equal(launchFailure.lifecycle_result.failure_kind, "readiness");
    assert.equal(launchFailure.lifecycle_result.cleanup.status, "completed");
    assert.equal(launchFailure.lifecycle_result.cleanup.root_absent, true, "ticket 12 cleanup removes the workload after readiness failure");
    assert.equal(await pathExists(record), false, "ticket 12 cleanup removes the preparing record after readiness failure");
    assert.equal(isAlive(Number(await readFile(workerPidPath, "utf8"))), false, "timed-out readiness worker is absent");
    assert.equal(isAlive(Number(await readFile(childPidPath, "utf8"))), false, "timed-out readiness child is absent");
  } finally {
    await cleanupCurrentRun(record, undefined, launchFailure);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
});

test("blocking graceful callbacks stop at their deadline and leave only test-scoped cleanup", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-process-lifecycle-ticket-11-graceful-timeout-"));
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
    await writeFile(finalizePath, `try { & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(join(directory, "warmup-missing.json"))} -GracefulAction {} } catch { $warmupFailure = $_.Exception.Message }; [IO.File]::WriteAllText(${powerShellLiteral(timeoutStartedPath)}, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(recordPath)} -Disposition Stop -GracefulDeadlineMilliseconds 1000 -GracefulContext @{ action_log_path = ${powerShellLiteral(actionLog)}; worker_pid_path = ${powerShellLiteral(workerPidPath)}; child_pid_path = ${powerShellLiteral(childPidPath)} } -GracefulAction { param($binding) [IO.File]::AppendAllText($binding.graceful_context.action_log_path, "called" + [Environment]::NewLine); [IO.File]::WriteAllText($binding.graceful_context.worker_pid_path, [string]$PID); $child = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20') -PassThru; [IO.File]::WriteAllText($binding.graceful_context.child_pid_path, [string]$child.Id); Start-Sleep -Seconds 8 }`, "utf8");
    await assert.rejects(runPowerShell(finalizePath));
    assert.ok(Date.now() - Number(await readFile(timeoutStartedPath, "utf8")) < 3500, "blocking graceful callback exceeded its millisecond deadline bound");
    assert.equal((await readFile(actionLog, "utf8")).trim().split(/\r?\n/u).length, 1, "graceful callback ran exactly once");
    assert.equal(isAlive(Number(await readFile(workerPidPath, "utf8"))), false, "timed-out graceful worker is absent");
    assert.equal(isAlive(Number(await readFile(childPidPath, "utf8"))), false, "timed-out graceful child is absent");
    assert.equal(isAlive(launch.binding.root_process_id), true, "helper did not force-stop the workload");
    assert.equal(await namedJobExists(launch.binding.job_name), true, "helper did not terminate the named Job");
  } finally {
    await cleanupCurrentRun(recordPath, stopEventName, launch);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false, "graceful callback fixture leaves no temporary artifacts");
  }
});
