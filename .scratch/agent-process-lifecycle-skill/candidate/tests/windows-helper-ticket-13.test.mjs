import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { access, copyFile, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join, parse, resolve } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileCallback } from "node:child_process";
import test from "node:test";
import { mkdtemp } from "./protected-test-fixture.mjs";

const execFile = promisify(execFileCallback);
const helperPath = resolve(import.meta.dirname, "../windows-helper/Invoke-AgentProcessLifecycle.ps1");
const holderPath = resolve(import.meta.dirname, "../windows-helper/JobHandleHolder.ps1");

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function assertProtectedFixtureRecordPath(recordPath) {
  const fixtureRoot = join(process.env.USERPROFILE, ".agent-process-lifecycle", "Tests");
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

async function waitForPath(path, timeoutMilliseconds = 5000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (!(await pathExists(path))) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${path}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function namedJobExists(name) {
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket13Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket13Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket13Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return stdout.trim() === "true";
}

async function signalNamedEvent(eventName) {
  const script = `$event = [Threading.EventWaitHandle]::OpenExisting(${powerShellLiteral(eventName)}); try { $event.Set() | Out-Null } finally { $event.Dispose() }`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
}

async function createInstrumentedHelper(directory, marker) {
  const needle = `# TEST-INJECTION: ${marker}`;
  let helper = await readFile(helperPath, "utf8");
  assert.ok(helper.includes(needle), `missing test injection marker: ${marker}`);
  const injection = marker === "callback-cleanup-invariant"
    ? `if ($Purpose -eq 'graceful') {
$failure = [InvalidOperationException]::new('Ticket 13 injected callback cleanup failure.')
$failure.Data['AgentProcessLifecycle.CallbackCleanupFailure'] = $true
throw $failure
}`
    : "throw 'Ticket 13 injected Finalize failure before Stop.'";
  helper = helper.replace(needle, injection);
  const instrumentedHelperPath = join(directory, "Invoke-AgentProcessLifecycle.instrumented.ps1");
  await writeFile(instrumentedHelperPath, helper, "utf8");
  await copyFile(holderPath, join(directory, "JobHandleHolder.ps1"));
  return instrumentedHelperPath;
}

async function startSentinel(paths) {
  const launcher = join(paths.directory, "start-sentinel.ps1");
  await writeFile(paths.sentinel, `param([string]$ReadyPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $stopEvent.WaitOne(30000) | Out-Null
}
finally { $stopEvent.Dispose() }
`, "utf8");
  await writeFile(launcher, `$event = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.sentinelStopEvent)})
try {
    $sentinel = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.sentinel)}, '-ReadyPath', ${powerShellLiteral(paths.sentinelReady)}, '-StopEventName', ${powerShellLiteral(paths.sentinelStopEvent)}) -WindowStyle Hidden -PassThru
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath ${powerShellLiteral(paths.sentinelReady)}) -and $deadline.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    if (-not (Test-Path -LiteralPath ${powerShellLiteral(paths.sentinelReady)})) { throw 'Sentinel did not become ready.' }
    [pscustomobject]@{ process_id = $sentinel.Id; creation_time_filetime = $sentinel.StartTime.ToUniversalTime().ToFileTimeUtc(); image_path = $sentinel.Path } | ConvertTo-Json -Compress
}
finally { $event.Dispose() }
`, "utf8");
  return runPowerShell(launcher);
}

async function finalizeOwnedRunForFixtureCleanup(paths, activeHelperPath) {
  if (!(await pathExists(paths.record))) return;
  const cleanupScript = join(paths.directory, "fixture-cleanup.ps1");
  await writeFile(cleanupScript, `$result = & ${powerShellLiteral(activeHelperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ stop_event_name = ${powerShellLiteral(paths.workloadStopEvent)} } -GracefulAction {
    param($binding)
    $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
}
$result | ConvertTo-Json -Depth 12 -Compress
`, "utf8");
  const result = await runPowerShell(cleanupScript);
  assert.equal(result.lifecycle_result.status, "success", "fixture cleanup uses the helper's validated current-run binding");
}

async function terminateIdentityBoundFixture({ identities }) {
  const cleanup = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; using System.Text; public static class Ticket13CleanupNative { [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access,bool inherit,uint id); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr p,out FILETIME c,out FILETIME e,out FILETIME k,out FILETIME u); [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool QueryFullProcessImageNameW(IntPtr p,uint f,StringBuilder b,ref uint s); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr p,uint c); [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr p,uint m); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr p); [StructLayout(LayoutKind.Sequential)] public struct FILETIME { public uint Low; public uint High; } }'; $identities=ConvertFrom-Json -AsHashtable ${powerShellLiteral(JSON.stringify(identities))}; foreach($i in $identities){$p=[Ticket13CleanupNative]::OpenProcess(0x101001,$false,[uint32]$i.process_id);if($p -eq [IntPtr]::Zero){continue};try{$c=[Ticket13CleanupNative+FILETIME]::new();$e=[Ticket13CleanupNative+FILETIME]::new();$k=[Ticket13CleanupNative+FILETIME]::new();$u=[Ticket13CleanupNative+FILETIME]::new();if(-not [Ticket13CleanupNative]::GetProcessTimes($p,[ref]$c,[ref]$e,[ref]$k,[ref]$u)){throw 'GetProcessTimes failed.'};$created=([int64]$c.High -shl 32) -bor $c.Low;$s=32768;$image=[Text.StringBuilder]::new($s);if(-not [Ticket13CleanupNative]::QueryFullProcessImageNameW($p,0,$image,[ref]$s)){throw 'QueryFullProcessImageNameW failed.'};if([string]$created -ne [string]$i.creation_time_filetime -or -not [string]::Equals($image.ToString(),[string]$i.image_path,[StringComparison]::OrdinalIgnoreCase)){throw "Refused PID fallback because identity is not proven: $($i.process_id)"};if([Ticket13CleanupNative]::WaitForSingleObject($p,0) -ne 0){if(-not [Ticket13CleanupNative]::TerminateProcess($p,124)){throw 'TerminateProcess failed.'};if([Ticket13CleanupNative]::WaitForSingleObject($p,1000) -ne 0){throw 'Identity-bound fixture process did not exit.'}}}finally{[Ticket13CleanupNative]::CloseHandle($p)|Out-Null}}`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", cleanup], { windowsHide: true });
}

async function terminateValidatedFixtureJob(jobName, rootIdentity, creationTimeFileTime = String(rootIdentity?.creation_time_filetime)) {
  if (!jobName || !rootIdentity || !isAlive(rootIdentity.process_id) || !(await namedJobExists(jobName))) return;
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; using System.Text; public static class Ticket13JobAuthority { [StructLayout(LayoutKind.Sequential)] public struct FILETIME { public uint Low; public uint High; } [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint id); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr p,out FILETIME c,out FILETIME e,out FILETIME k,out FILETIME u); [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool QueryFullProcessImageNameW(IntPtr p,uint f,StringBuilder b,ref uint s); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode); [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h,uint ms); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h); }'; $job=[Ticket13JobAuthority]::OpenJobObjectW(0x0010000c,$false,${powerShellLiteral(jobName)}); if($job -eq [IntPtr]::Zero){return}; $root=[Ticket13JobAuthority]::OpenProcess(0x101000,$false,[uint32]${rootIdentity.process_id}); if($root -eq [IntPtr]::Zero){[Ticket13JobAuthority]::CloseHandle($job)|Out-Null;return}; try { $c=[Ticket13JobAuthority+FILETIME]::new();$e=[Ticket13JobAuthority+FILETIME]::new();$k=[Ticket13JobAuthority+FILETIME]::new();$u=[Ticket13JobAuthority+FILETIME]::new(); if(-not [Ticket13JobAuthority]::GetProcessTimes($root,[ref]$c,[ref]$e,[ref]$k,[ref]$u)){throw 'GetProcessTimes failed.'}; $created=([int64]$c.High -shl 32) -bor $c.Low; $size=32768;$image=[Text.StringBuilder]::new($size); if(-not [Ticket13JobAuthority]::QueryFullProcessImageNameW($root,0,$image,[ref]$size)){throw 'QueryFullProcessImageNameW failed.'}; $member=$false; if([string]$created -ne ${powerShellLiteral(creationTimeFileTime)} -or -not [string]::Equals($image.ToString(),${powerShellLiteral(rootIdentity.image_path)},[StringComparison]::OrdinalIgnoreCase) -or -not [Ticket13JobAuthority]::IsProcessInJob($root,$job,[ref]$member) -or -not $member){throw 'Refused Job termination because retained root authority is not proven.'}; if(-not [Ticket13JobAuthority]::TerminateJobObject($job,124)){throw 'TerminateJobObject failed.'}; if([Ticket13JobAuthority]::WaitForSingleObject($root,1000) -ne 0){throw 'Owned root did not exit.'} } finally {[Ticket13JobAuthority]::CloseHandle($root)|Out-Null;[Ticket13JobAuthority]::CloseHandle($job)|Out-Null}`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
}

async function attempt(teardownErrors, operation) {
  try {
    await operation();
  } catch (error) {
    teardownErrors.push(error);
  }
}

async function runStopScenario(kind, { activeHelperPath = helperPath, cleanupHelperPath = helperPath, expectUnresolved = false, skipHelperCleanup = false } = {}) {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-13-");
  const runId = randomUUID();
  const paths = {
    child: join(directory, "child.ps1"),
    childPid: join(directory, "child.pid"),
    directory,
    finalize: join(directory, "finalize.ps1"),
    launch: join(directory, "launch.ps1"),
    ready: join(directory, "ready.signal"),
    record: join(directory, "run-record.json"),
    root: join(directory, "root.ps1"),
    sentinel: join(directory, "sentinel.ps1"),
    sentinelReady: join(directory, "sentinel-ready.pid"),
    sentinelStopEvent: `Local\\AgentProcessLifecycle.Ticket13.Sentinel.${runId}`,
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
    workloadStopEvent: `Local\\AgentProcessLifecycle.Ticket13.Workload.${runId}`,
  };
  let sentinel;
  let launch;
  let childProcessId;
  let rootCreationTimeFileTime;
  let holderCreationTimeFileTime;

  try {
    await writeFile(paths.child, `param([string]$ChildPidPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [IO.File]::WriteAllText($ChildPidPath, [string]$PID)
    $stopEvent.WaitOne(30000) | Out-Null
}
finally { $stopEvent.Dispose() }
`, "utf8");
    await writeFile(paths.root, `param([string]$ChildPath, [string]$ChildPidPath, [string]$ReadyPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ChildPath, '-ChildPidPath', $ChildPidPath, '-StopEventName', $StopEventName) -WindowStyle Hidden | Out-Null
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ChildPidPath) -and $deadline.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    if (-not (Test-Path -LiteralPath $ChildPidPath)) { throw 'Owned child did not become ready.' }
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $stopEvent.WaitOne(30000) | Out-Null
}
finally { $stopEvent.Dispose() }
`, "utf8");
    sentinel = await startSentinel(paths);
    assert.equal(isAlive(sentinel.process_id), true, "same-command unrelated sentinel is alive before Stop");

    await writeFile(paths.launch, `$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.workloadStopEvent)})
try {
    $result = & ${powerShellLiteral(activeHelperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.root)}, '-ChildPath', ${powerShellLiteral(paths.child)}, '-ChildPidPath', ${powerShellLiteral(paths.childPid)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-StopEventName', ${powerShellLiteral(paths.workloadStopEvent)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-13-owned-tree-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)}; child_pid_path = ${powerShellLiteral(paths.childPid)} } -ReadinessCheck { param($context) (Test-Path -LiteralPath $context.ready_path) -and (Test-Path -LiteralPath $context.child_pid_path) } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop -DownstreamResult @{ status = 'not-run' }
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $stopEvent.Dispose() }
`, "utf8");
    launch = await runPowerShell(paths.launch);
    assertProtectedFixtureRecordPath(launch.binding.record_path);
    const rawRecord = await readFile(paths.record, "utf8");
    rootCreationTimeFileTime = rawRecord.match(/"root":\{"process_id":\d+,"creation_time_filetime":(\d+)/u)?.[1];
    holderCreationTimeFileTime = rawRecord.match(/"holder":\{"process_id":\d+,"creation_time_filetime":(\d+)/u)?.[1];
    childProcessId = Number(await readFile(paths.childPid, "utf8"));
    assert.equal(isAlive(launch.binding.root_process_id), true, "owned root survives the Launch invocation");
    assert.equal(isAlive(childProcessId), true, "owned child survives the Launch invocation");

    const action = kind === "graceful"
      ? `-GracefulContext @{ stop_event_name = ${powerShellLiteral(paths.workloadStopEvent)} } -GracefulAction { param($binding) $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name); try { $event.Set() | Out-Null } finally { $event.Dispose() } }`
      : kind === "failed"
        ? "-GracefulAction { param($binding) throw 'ticket-13 graceful callback failure' }"
        : kind === "timed-out"
          ? "-GracefulAction { param($binding) Start-Sleep -Seconds 5 }"
          : "";
    const gracefulDeadlineMilliseconds = kind === "graceful" ? 5000 : 250;
    await writeFile(paths.finalize, `$result = & ${powerShellLiteral(activeHelperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds ${gracefulDeadlineMilliseconds} ${action} -DownstreamResult @{ status = 'failed'; source = 'ticket-13-downstream' }
$result | ConvertTo-Json -Depth 12 -Compress
`, "utf8");
    const finalized = await runPowerShell(paths.finalize);

    assert.equal(finalized.lifecycle_result.status, expectUnresolved ? "unresolved" : "success");
    assert.equal(finalized.downstream_result.status, "failed", "lifecycle Stop does not overwrite downstream state");
    assert.equal(finalized.final_disposition.status, expectUnresolved ? "unresolved" : "completed");
    assert.equal(finalized.evidence.owned_tree_empty, true);
    assert.equal(finalized.evidence.root_process_absent, true);
    assert.equal(finalized.evidence.job_holder_absent, true);
    assert.equal(finalized.evidence.named_job_absent, true);
    assert.equal(isAlive(launch.binding.root_process_id), false, "Stop removes the owned root");
    assert.equal(isAlive(childProcessId), false, "Stop removes the owned child");
    assert.equal(await namedJobExists(launch.binding.job_name), false, "Stop removes the named ownership object");
    assert.equal(await pathExists(paths.record), false, "Stop removes the run record");
    assert.equal(isAlive(sentinel.process_id), true, "Stop preserves the same-command unrelated sentinel");
    const residualCallbackArtifacts = (await readdir(directory, { recursive: true })).filter((entry) => entry.startsWith("graceful-"));
    assert.deepEqual(residualCallbackArtifacts, [], "Finalize removes its callback artifacts");

    if (expectUnresolved) {
      assert.equal(finalized.lifecycle_result.failure_kind, "graceful-callback-cleanup");
      assert.match(finalized.lifecycle_result.unresolved_reason, /callback cleanup failure/u);
    } else if (kind === "graceful") {
      assert.equal(finalized.evidence.graceful_action_invocations, 1);
      assert.equal(finalized.evidence.forced_termination_used, false);
    } else {
      assert.equal(finalized.evidence.graceful_action_invocations, kind === "missing" ? 0 : 1);
      assert.equal(finalized.evidence.forced_termination_used, true);
    }
  } finally {
    const teardownErrors = [];
    if (!skipHelperCleanup) await attempt(teardownErrors, async () => finalizeOwnedRunForFixtureCleanup(paths, cleanupHelperPath));
    await attempt(teardownErrors, async () => {
      await terminateValidatedFixtureJob(launch?.binding?.job_name, launch?.binding?.root_identity, rootCreationTimeFileTime);
    });
    await attempt(teardownErrors, async () => terminateIdentityBoundFixture({ identities: [launch?.binding?.root_identity].filter(Boolean) }));
    await attempt(teardownErrors, async () => terminateIdentityBoundFixture({ identities: launch?.binding?.holder_identity ? [{ ...launch.binding.holder_identity, creation_time_filetime: holderCreationTimeFileTime }] : [] }));
    await attempt(teardownErrors, async () => {
      if (sentinel && isAlive(sentinel.process_id)) await signalNamedEvent(paths.sentinelStopEvent);
    });
    await attempt(teardownErrors, async () => {
      const deadline = Date.now() + 5000;
      while (sentinel && isAlive(sentinel.process_id) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
    });
    await attempt(teardownErrors, async () => {
      if (sentinel && isAlive(sentinel.process_id)) await terminateIdentityBoundFixture({ identities: [sentinel] });
    });
    await attempt(teardownErrors, async () => {
      if (sentinel && isAlive(sentinel.process_id)) throw new Error("Fixture sentinel remained after identity-bound teardown.");
    });
    await attempt(teardownErrors, async () => {
      if (!skipHelperCleanup) return;
      await rm(paths.record, { force: true });
    });
    await attempt(teardownErrors, async () => {
      if (!skipHelperCleanup) return;
      assert.equal(isAlive(launch?.binding?.root_process_id), false, "fallback removed owned root");
      assert.equal(isAlive(childProcessId), false, "fallback removed owned child");
      assert.equal(isAlive(launch?.binding?.holder_identity?.process_id), false, "fallback removed holder");
      assert.equal(await namedJobExists(launch?.binding?.job_name), false, "fallback removed named Job");
      assert.equal(await pathExists(paths.record), false, "fallback removed record");
      assert.deepEqual((await readdir(directory, { recursive: true })).filter((entry) => /(?:graceful|readiness)-.*\.(?:context|result|stdout|stderr|ps1)$/u.test(entry)), [], "fallback removed callback artifacts");
    });
    await attempt(teardownErrors, async () => {
      await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
      if (await pathExists(directory)) throw new Error("Ticket 13 fixture directory remained.");
    });
    if (teardownErrors.length > 0) throw new AggregateError(teardownErrors, "Ticket 13 teardown failed after all cleanup attempts.");
  }
}

test("Finalize Stop uses retained Job authority for graceful and forced owned-tree cleanup", async () => {
  assert.equal(process.platform, "win32", "ticket 13 is Windows-only");

  for (const kind of ["graceful", "missing", "failed", "timed-out"]) {
    await runStopScenario(kind);
  }
});

test("Ticket 13 test-generated sentinel and owned child stay hidden", async () => {
  const source = await readFile(resolve(import.meta.dirname, "windows-helper-ticket-13.test.mjs"), "utf8");
  const sentinelLaunch = source.match(/\$sentinel = Start-Process -FilePath \$PSHOME\\\\pwsh\.exe[^\r\n]*/u)?.[0];
  const ownedChildLaunch = source.match(/Start-Process -FilePath \$PSHOME\\\\pwsh\.exe -ArgumentList @\('-NoLogo', '-NoProfile', '-NonInteractive', '-File', \$ChildPath, '-ChildPidPath', \$ChildPidPath, '-StopEventName', \$StopEventName\) -WindowStyle Hidden \| Out-Null/u)?.[0];

  assert.ok(sentinelLaunch, "the sentinel launch site remains explicit");
  assert.match(sentinelLaunch, /-WindowStyle Hidden -PassThru/u);
  assert.ok(ownedChildLaunch, "the owned child launch site remains hidden");
});

test("callback cleanup invariant failure is unresolved rather than a successful Stop", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-13-callback-invariant-");
  try {
    const instrumentedHelperPath = await createInstrumentedHelper(directory, "callback-cleanup-invariant");
    await runStopScenario("graceful", { activeHelperPath: instrumentedHelperPath, expectUnresolved: true });
  } finally {
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
});

test("fixture teardown independently reclaims a run after Finalize fails before Stop", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-13-teardown-");
  try {
    const instrumentedHelperPath = await createInstrumentedHelper(directory, "finalize-before-stop");
    await assert.rejects(
      runStopScenario("missing", { activeHelperPath: instrumentedHelperPath, cleanupHelperPath: helperPath, skipHelperCleanup: true }),
      (error) => error.constructor.name !== "AggregateError" && error.message.includes("Ticket 13 injected Finalize failure before Stop."),
    );
  } finally {
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
});
