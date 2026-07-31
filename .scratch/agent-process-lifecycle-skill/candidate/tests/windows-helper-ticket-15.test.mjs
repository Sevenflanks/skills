import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { randomUUID } from "node:crypto";
import { access, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import test, { after } from "node:test";
import { cleanupFixtureRoot, fixtureRoot, mkdtemp } from "./protected-test-fixture.mjs";

after(cleanupFixtureRoot);

const execFile = promisify(execFileCallback);
const helperPath = resolve(import.meta.dirname, "../windows-helper/Invoke-AgentProcessLifecycle.ps1");
const holderPath = resolve(import.meta.dirname, "../windows-helper/JobHandleHolder.ps1");
const expectedNonGuarantees = [
  "abrupt-host-crash-before-recoverable-record-publication",
  "same-user-malicious-record-or-named-object-tamper",
];

function assertLifecycleNonGuarantees(result, context) {
  assert.deepEqual(result.non_guarantees, expectedNonGuarantees, context);
}

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
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
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket15Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket15Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket15Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
    { windowsHide: true },
  );
  return stdout.trim() === "true";
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

async function signalNamedEvent(eventName) {
  const script = `$event = [Threading.EventWaitHandle]::OpenExisting(${powerShellLiteral(eventName)}); try { $event.Set() | Out-Null } finally { $event.Dispose() }`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
}

async function signalAndWaitForProcessExit(processId, stopEvent, exitedEvent) {
  const script = `$process = Get-Process -Id ${processId} -ErrorAction SilentlyContinue; $exited = [Threading.EventWaitHandle]::OpenExisting(${powerShellLiteral(exitedEvent)}); $stop = [Threading.EventWaitHandle]::OpenExisting(${powerShellLiteral(stopEvent)}); try { $stop.Set() | Out-Null; if (-not $exited.WaitOne(5000)) { throw 'Fixture process did not signal exit.' }; if ($process -and -not $process.WaitForExit(5000)) { throw 'Fixture process did not exit.' } } finally { $stop.Dispose(); $exited.Dispose() }`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  assert.equal(isAlive(processId), false, "signalled fixture process exits");
}

async function startHiddenSentinel(directory) {
  const token = randomUUID();
  const script = join(directory, "sentinel.ps1");
  const launcher = join(directory, "start-sentinel.ps1");
  const stopEvent = `Local\\AgentProcessLifecycle.Ticket15.Sentinel.${token}`;
  const readyEvent = `Local\\AgentProcessLifecycle.Ticket15.SentinelReady.${token}`;
  const exitedEvent = `Local\\AgentProcessLifecycle.Ticket15.SentinelExited.${token}`;
  await writeFile(
    script,
    `param([string]$ReadyEventName, [string]$StopEventName, [string]$ExitedEventName)
$ready = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
$stop = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
$exited = [Threading.EventWaitHandle]::OpenExisting($ExitedEventName)
try {
    $ready.Set() | Out-Null
    $stop.WaitOne(120000) | Out-Null
}
finally { $exited.Set() | Out-Null; $exited.Dispose(); $stop.Dispose(); $ready.Dispose() }
`,
    "utf8",
  );
  await writeFile(
    launcher,
`$stop = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(stopEvent)})
$ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(readyEvent)})
$exited = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(exitedEvent)})
try {
    $sentinel = Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(script)}, '-ReadyEventName', ${powerShellLiteral(readyEvent)}, '-StopEventName', ${powerShellLiteral(stopEvent)}, '-ExitedEventName', ${powerShellLiteral(exitedEvent)}) -WindowStyle Hidden -PassThru
    if (-not $ready.WaitOne(5000)) { throw 'Sentinel did not become ready.' }
    [pscustomobject]@{ process_id = $sentinel.Id; creation_time_filetime = $sentinel.StartTime.ToUniversalTime().ToFileTimeUtc(); image_path = $sentinel.Path; stop_event = ${powerShellLiteral(stopEvent)}; exited_event = ${powerShellLiteral(exitedEvent)} } | ConvertTo-Json -Compress
}
finally { $exited.Dispose(); $ready.Dispose(); $stop.Dispose() }
`,
    "utf8",
  );
  return runPowerShell(launcher);
}

async function createInstrumentedHelper(directory, marker, injection) {
  const source = await readFile(helperPath, "utf8");
  const needle = `# TEST-INJECTION: ${marker}`;
  assert.ok(source.includes(needle), `missing Ticket 15 injection marker: ${marker}`);
  const instrumentedHelper = join(directory, `Invoke-AgentProcessLifecycle.${marker}.ps1`);
  const markerPattern = new RegExp(
    `${needle.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}(?=\\r?\\n)`,
    "u",
  );
  await writeFile(instrumentedHelper, source.replace(markerPattern, injection), "utf8");
  await writeFile(join(directory, "JobHandleHolder.ps1"), await readFile(holderPath, "utf8"), "utf8");
  return instrumentedHelper;
}

async function createArtifactValidationFailureHelper(directory, validationInjection) {
  const source = await readFile(helperPath, "utf8");
  const inject = (currentSource, marker, injection) => {
    const needle = `# TEST-INJECTION: ${marker}`;
    assert.ok(currentSource.includes(needle), `missing Ticket 15 injection marker: ${marker}`);
    const markerPattern = new RegExp(
      `${needle.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}(?=\\r?\\n)`,
      "u",
    );
    return currentSource.replace(markerPattern, injection);
  };
  const artifactLeaf = ".run-record.json.0123456789abcdef0123456789abcdef.tmp";
  const publicationFailure = `$directory = [IO.Path]::GetDirectoryName($recordPathForFinalize)
$artifact = Join-Path $directory '${artifactLeaf}'
Write-ProtectedJsonFile -Record @{ artifact = 'ticket-15-validation' } -Path $artifact
$failure = [InvalidOperationException]::new("Ticket 15 injected Preserve publication failure at $recordPathForFinalize")
$failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @($artifact)
throw $failure`;
  const instrumentedSource = inject(
    inject(source, "preserve-record-publication", publicationFailure),
    "finalize-publication-artifact-validation",
    validationInjection,
  );
  const instrumentedHelper = join(directory, "Invoke-AgentProcessLifecycle.validation-failure.ps1");
  await writeFile(instrumentedHelper, instrumentedSource, "utf8");
  await writeFile(join(directory, "JobHandleHolder.ps1"), await readFile(holderPath, "utf8"), "utf8");
  return { artifactLeaf, instrumentedHelper };
}

async function launchFixture({
  requestedDisposition = "Preserve",
  requestedLaterOwner = "ticket-15-later-owner",
} = {}) {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-15-");
  const paths = {
    directory,
    laterStop: join(directory, "later-stop.ps1"),
    launch: join(directory, "launch.ps1"),
    preserve: join(directory, "preserve.ps1"),
    ready: join(directory, "ready.signal"),
    record: join(directory, "run-record.json"),
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
    stopEvent: `Local\\AgentProcessLifecycle.Ticket15.Stop.${randomUUID()}`,
    workload: join(directory, "workload.ps1"),
  };

  const requestedOwnerParameter = requestedDisposition === "Preserve"
    ? ` -RequestedLaterOwner ${powerShellLiteral(requestedLaterOwner)}`
    : "";
  await writeFile(
    paths.workload,
    `param([string]$ReadyPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $stopEvent.WaitOne(120000) | Out-Null
}
finally { $stopEvent.Dispose() }
`,
    "utf8",
  );
  await writeFile(
    paths.launch,
    `$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.stopEvent)})
try {
    $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.workload)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-StopEventName', ${powerShellLiteral(paths.stopEvent)}) -WorkingDirectory ${powerShellLiteral(paths.directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-15-preserve-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition ${requestedDisposition}${requestedOwnerParameter}
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $stopEvent.Dispose() }
`,
    "utf8",
  );

  const launch = await runPowerShell(paths.launch);
  return { launch, paths };
}

function launchPreserveFixture() {
  return launchFixture();
}

async function launchOwnedTreePreserveFixture() {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-15-tree-");
  const token = randomUUID();
  const paths = {
    child: join(directory, "child.ps1"),
    childPid: join(directory, "child.pid"),
    childReadyEvent: `Local\\AgentProcessLifecycle.Ticket15.ChildReady.${token}`,
    directory,
    launch: join(directory, "launch.ps1"),
    ready: join(directory, "ready.signal"),
    record: join(directory, "run-record.json"),
    root: join(directory, "root.ps1"),
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
    stopEvent: `Local\\AgentProcessLifecycle.Ticket15.TreeStop.${token}`,
  };
  await writeFile(
    paths.child,
    `param([string]$ChildPidPath, [string]$ChildReadyEventName, [string]$StopEventName)
$ready = [Threading.EventWaitHandle]::OpenExisting($ChildReadyEventName)
$stop = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [IO.File]::WriteAllText($ChildPidPath, [string]$PID)
    $ready.Set() | Out-Null
    $stop.WaitOne(120000) | Out-Null
}
finally { $stop.Dispose(); $ready.Dispose() }
`,
    "utf8",
  );
  await writeFile(
    paths.root,
    `param([string]$ChildPath, [string]$ChildPidPath, [string]$ChildReadyEventName, [string]$ReadyPath, [string]$StopEventName)
$ready = [Threading.EventWaitHandle]::OpenExisting($ChildReadyEventName)
$stop = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ChildPath, '-ChildPidPath', $ChildPidPath, '-ChildReadyEventName', $ChildReadyEventName, '-StopEventName', $StopEventName) -WindowStyle Hidden | Out-Null
    if (-not $ready.WaitOne(5000)) { throw 'Owned child did not become ready.' }
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $stop.WaitOne(120000) | Out-Null
}
finally { $stop.Dispose(); $ready.Dispose() }
`,
    "utf8",
  );
  await writeFile(
    paths.launch,
    `$stop = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.stopEvent)})
$childReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.childReadyEvent)})
try {
    $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.root)}, '-ChildPath', ${powerShellLiteral(paths.child)}, '-ChildPidPath', ${powerShellLiteral(paths.childPid)}, '-ChildReadyEventName', ${powerShellLiteral(paths.childReadyEvent)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-StopEventName', ${powerShellLiteral(paths.stopEvent)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-15-owned-tree-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)}; child_pid_path = ${powerShellLiteral(paths.childPid)} } -ReadinessCheck { param($context) (Test-Path -LiteralPath $context.ready_path) -and (Test-Path -LiteralPath $context.child_pid_path) } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Preserve -RequestedLaterOwner 'ticket-15-later-owner'
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $childReady.Dispose(); $stop.Dispose() }
`,
    "utf8",
  );
  const launch = await runPowerShell(paths.launch);
  return { launch, paths, childProcessId: Number(await readFile(paths.childPid, "utf8")) };
}

async function cleanupFixture(fixture) {
  if (!fixture) return;
  const { launch, paths } = fixture;
  try {
    if (await pathExists(paths.record)) {
      const record = JSON.parse(await readFile(paths.record, "utf8"));
      const finalize = join(paths.directory, "fixture-cleanup.ps1");
      const preserveBeforeStop = record.state === "ready" && record.requested_disposition === "Preserve"
        ? `$preserved = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner ${powerShellLiteral(record.requested_later_owner)}
if ($preserved.lifecycle_result.status -ne 'success') { throw "Fixture cleanup Preserve failed: $($preserved | ConvertTo-Json -Depth 12 -Compress)" }
`
        : "";
      await writeFile(
        finalize,
        `${preserveBeforeStop}$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
        "utf8",
      );
      const finalized = await runPowerShell(finalize);
      assert.equal(finalized.lifecycle_result.status, "success", "fixture cleanup Stop completes");
    }
    assert.equal(isAlive(launch.binding.root_process_id), false, "fixture cleanup removes the root");
    assert.equal(isAlive(launch.binding.holder_identity.process_id), false, "fixture cleanup removes the holder");
    assert.equal(await namedJobExists(launch.binding.job_name), false, "fixture cleanup removes the Job");
  } finally {
    await rm(paths.directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(paths.directory), false, "fixture cleanup removes its exact protected directory");
  }
}

test("Launch Preserve records the requested later owner while retaining its live binding", async () => {
  assert.equal(process.platform, "win32", "Ticket 15 is Windows-only");
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    const record = JSON.parse(await readFile(paths.record, "utf8"));

    assert.equal(launch.action, "Launch");
    assert.equal(launch.requested_disposition, "Preserve");
    assert.equal(launch.lifecycle_result.status, "success");
    assert.equal(launch.final_disposition.status, "pending");
    assert.equal(record.schema_version, 1);
    assert.equal(record.requested_disposition, "Preserve");
    assert.equal(record.requested_later_owner, "ticket-15-later-owner");
    assert.equal(record.later_owner, null);
    assert.equal(isAlive(launch.binding.root_process_id), true, "Launch retains the workload for Preserve");

    await writeFile(
      paths.preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const preserved = await runPowerShell(paths.preserve);
    const preservedRecord = JSON.parse(await readFile(paths.record, "utf8"));

    assert.equal(preserved.lifecycle_result.status, "success");
    assert.equal(preserved.final_disposition.status, "preserved");
    assert.equal(preserved.later_owner, "ticket-15-later-owner");
    assert.deepEqual(preserved.stop_method, {
      action: "Finalize",
      disposition: "Stop",
      record_path: paths.record,
    });
    assert.equal(preservedRecord.state, "preserved");
    assert.equal(preservedRecord.later_owner, "ticket-15-later-owner");
    assert.equal(isAlive(launch.binding.root_process_id), true, "Preserve keeps the workload live");
    assert.equal(isAlive(launch.binding.holder_identity.process_id), true, "Preserve does not signal the holder");
    assert.equal(await namedJobExists(launch.binding.job_name), true, "Preserve retains Job authority");

    await writeFile(
      paths.laterStop,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const stopped = await runPowerShell(paths.laterStop);
    assert.equal(stopped.lifecycle_result.status, "success");
    assert.equal(stopped.final_disposition.status, "completed");
    assert.equal(stopped.evidence.forced_termination_used, true);
    assert.equal(await pathExists(paths.record), false, "later Stop removes the handoff record");
    assertLifecycleNonGuarantees(launch, "Launch success discloses only the accepted limitations");
    assertLifecycleNonGuarantees(preserved, "Preserve discloses only the accepted limitations");
    assertLifecycleNonGuarantees(stopped, "later Stop discloses only the accepted limitations");
  } finally {
    await cleanupFixture(fixture);
  }
});

test("public parameters and transitions reject invalid Preserve and Stop calls without side effects", async (t) => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-15-launch-contract-");
  const record = join(directory, "run-record.json");
  const missingOwner = join(directory, "missing-owner.ps1");
  const stopOwner = join(directory, "stop-owner.ps1");
  try {
    await writeFile(
      missingOwner,
      `& ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(record)} -RequestedDisposition Preserve
`,
      "utf8",
    );
    await assert.rejects(
      execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", missingOwner], { windowsHide: true }),
      /RequestedLaterOwner is required/u,
    );
    assert.equal(await pathExists(record), false, "missing Preserve owner creates no ownership record");

    await writeFile(
      stopOwner,
      `& ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(record)} -RequestedDisposition Stop -RequestedLaterOwner 'not-allowed'
`,
      "utf8",
    );
    await assert.rejects(
      execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", stopOwner], { windowsHide: true }),
      /RequestedLaterOwner is only valid/u,
    );
    assert.equal(await pathExists(record), false, "Stop with a later owner creates no ownership record");
  } finally {
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }

  await t.test("matching owner is required", assertPreserveMismatchRejection);
  await t.test("Preserve rejects graceful inputs", assertPreserveGracefulInputRejection);
  await t.test("only approved disposition transitions are accepted", assertFinalizeTransitions);
  await t.test("later Stop rejects LaterOwner", assertLaterStopOwnerRejection);
});

async function assertPreserveMismatchRejection() {
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    const before = await readFile(paths.record, "utf8");
    const finalize = join(paths.directory, "preserve-wrong-owner.ps1");
    await writeFile(
      finalize,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'wrong-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );

    const rejected = await runPowerShell(finalize);

    assertLifecycleNonGuarantees(rejected, "Finalize rejection discloses only the accepted limitations");
    assert.equal(rejected.lifecycle_result.status, "unresolved");
    assert.equal(rejected.lifecycle_result.operation, "finalize-rejected");
    assert.equal(rejected.lifecycle_result.failure_kind, "record-state");
    assert.equal(rejected.evidence.reason_code, "later-owner-mismatch");
    assert.equal(rejected.evidence.graceful_action_invocations, 0);
    assert.equal(rejected.evidence.termination_attempted, false);
    assert.equal(await readFile(paths.record, "utf8"), before, "rejection leaves the record byte-for-byte unchanged");
    assert.equal(isAlive(launch.binding.root_process_id), true, "rejection keeps the workload live");
    assert.equal(isAlive(launch.binding.holder_identity.process_id), true, "rejection keeps the holder live");
    assert.equal(await namedJobExists(launch.binding.job_name), true, "rejection keeps the Job live");
  } finally {
    await cleanupFixture(fixture);
  }
}

async function assertPreserveGracefulInputRejection() {
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    const before = await readFile(paths.record, "utf8");
    const marker = join(paths.directory, "graceful-invoked.marker");
    const finalize = join(paths.directory, "preserve-graceful-input.ps1");
    await writeFile(
      finalize,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner' -GracefulDeadlineMilliseconds 1000 -GracefulContext @{ marker_path = ${powerShellLiteral(marker)} } -GracefulAction {
    param($binding)
    [IO.File]::WriteAllText($binding.graceful_context.marker_path, 'called')
}
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );

    const rejected = await runPowerShell(finalize);

    assert.equal(rejected.lifecycle_result.status, "unresolved");
    assert.equal(rejected.lifecycle_result.failure_kind, "record-state");
    assert.equal(rejected.evidence.reason_code, "preserve-prohibits-graceful-inputs");
    assert.equal(rejected.evidence.graceful_action_invocations, 0);
    assert.equal(await pathExists(marker), false, "Preserve never invokes a supplied graceful action");
    assert.equal(await readFile(paths.record, "utf8"), before);
    assert.equal(isAlive(launch.binding.root_process_id), true);
    assert.equal(isAlive(launch.binding.holder_identity.process_id), true);
    assert.equal(await namedJobExists(launch.binding.job_name), true);
  } finally {
    await cleanupFixture(fixture);
  }
}

async function assertFinalizeTransitions() {
  let readyStopFixture;
  let preservedFixture;
  try {
    readyStopFixture = await launchFixture({ requestedDisposition: "Stop" });
    const stopPaths = readyStopFixture.paths;
    const readyStopBefore = await readFile(stopPaths.record, "utf8");
    const readyStopPreserve = join(stopPaths.directory, "ready-stop-preserve.ps1");
    await writeFile(
      readyStopPreserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(stopPaths.record)} -Disposition Preserve -LaterOwner 'not-allowed'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const readyStopRejected = await runPowerShell(readyStopPreserve);
    assert.equal(readyStopRejected.lifecycle_result.status, "unresolved");
    assert.equal(readyStopRejected.evidence.reason_code, "ready-stop-requires-stop");
    assert.equal(await readFile(stopPaths.record, "utf8"), readyStopBefore);
    assert.equal(isAlive(readyStopFixture.launch.binding.root_process_id), true);

    const stopWithOwner = join(stopPaths.directory, "stop-with-owner.ps1");
    await writeFile(
      stopWithOwner,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(stopPaths.record)} -Disposition Stop -LaterOwner 'not-allowed'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const stopWithOwnerRejected = await runPowerShell(stopWithOwner);
    assert.equal(stopWithOwnerRejected.lifecycle_result.status, "unresolved");
    assert.equal(stopWithOwnerRejected.evidence.reason_code, "stop-prohibits-later-owner");
    assert.equal(await readFile(stopPaths.record, "utf8"), readyStopBefore);

    preservedFixture = await launchPreserveFixture();
    const preservePaths = preservedFixture.paths;
    const preserve = join(preservePaths.directory, "initial-preserve.ps1");
    await writeFile(
      preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(preservePaths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const initialPreserve = await runPowerShell(preserve);
    assert.equal(initialPreserve.lifecycle_result.status, "success");
    const preservedBefore = await readFile(preservePaths.record, "utf8");
    const repeatedPreserve = join(preservePaths.directory, "repeated-preserve.ps1");
    await writeFile(
      repeatedPreserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(preservePaths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const repeatedPreserveRejected = await runPowerShell(repeatedPreserve);
    assert.equal(repeatedPreserveRejected.lifecycle_result.status, "unresolved");
    assert.equal(repeatedPreserveRejected.evidence.reason_code, "preserved-requires-stop");
    assert.equal(await readFile(preservePaths.record, "utf8"), preservedBefore);
    assert.equal(isAlive(preservedFixture.launch.binding.root_process_id), true);
    assert.equal(isAlive(preservedFixture.launch.binding.holder_identity.process_id), true);
    assert.equal(await namedJobExists(preservedFixture.launch.binding.job_name), true);
  } finally {
    await cleanupFixture(preservedFixture);
    await cleanupFixture(readyStopFixture);
  }
}

test("inaccessible Preserve and later Stop authority checks reject without side effects", async () => {
  const accessDenied = "throw [ComponentModel.Win32Exception]::new(5, 'Ticket 15 injected access denied.')";
  let preserveFixture;
  let laterStopFixture;
  try {
    preserveFixture = await launchPreserveFixture();
    const preserveBefore = await readFile(preserveFixture.paths.record, "utf8");
    const preserveHelper = await createInstrumentedHelper(
      preserveFixture.paths.directory,
      "finalize-job-query",
      accessDenied,
    );
    const preserveScript = join(preserveFixture.paths.directory, "preserve-access-denied.ps1");
    await writeFile(
      preserveScript,
      `$result = & ${powerShellLiteral(preserveHelper)} -Action Finalize -RecordPath ${powerShellLiteral(preserveFixture.paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const preserveRejected = await runPowerShell(preserveScript);
    assert.equal(preserveRejected.lifecycle_result.failure_kind, "job-unverifiable");
    assert.equal(preserveRejected.evidence.reason_code, "job-retain-or-query-failed");
    assert.equal(preserveRejected.later_owner, "compatible-session-security-context-owner");
    assert.equal(preserveRejected.evidence.graceful_action_invocations, 0);
    assert.equal(preserveRejected.evidence.termination_attempted, false);
    assert.equal(await readFile(preserveFixture.paths.record, "utf8"), preserveBefore);
    assert.equal(isAlive(preserveFixture.launch.binding.root_process_id), true);
    assert.equal(isAlive(preserveFixture.launch.binding.holder_identity.process_id), true);

    laterStopFixture = await launchPreserveFixture();
    const preserveScriptPath = join(laterStopFixture.paths.directory, "initial-preserve.ps1");
    await writeFile(
      preserveScriptPath,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(laterStopFixture.paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    assert.equal((await runPowerShell(preserveScriptPath)).lifecycle_result.status, "success");
    const laterStopBefore = await readFile(laterStopFixture.paths.record, "utf8");
    const laterStopHelper = await createInstrumentedHelper(
      laterStopFixture.paths.directory,
      "finalize-job-query",
      accessDenied,
    );
    const laterStopScript = join(laterStopFixture.paths.directory, "later-stop-access-denied.ps1");
    await writeFile(
      laterStopScript,
      `$result = & ${powerShellLiteral(laterStopHelper)} -Action Finalize -RecordPath ${powerShellLiteral(laterStopFixture.paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const laterStopRejected = await runPowerShell(laterStopScript);
    assert.equal(laterStopRejected.lifecycle_result.failure_kind, "job-unverifiable");
    assert.equal(laterStopRejected.evidence.reason_code, "job-retain-or-query-failed");
    assert.equal(laterStopRejected.later_owner, "compatible-session-security-context-owner");
    assert.equal(laterStopRejected.evidence.graceful_action_invocations, 0);
    assert.equal(laterStopRejected.evidence.termination_attempted, false);
    assert.equal(await readFile(laterStopFixture.paths.record, "utf8"), laterStopBefore);
    assert.equal(isAlive(laterStopFixture.launch.binding.root_process_id), true);
    assert.equal(isAlive(laterStopFixture.launch.binding.holder_identity.process_id), true);
  } finally {
    await cleanupFixture(laterStopFixture);
    await cleanupFixture(preserveFixture);
  }
});

test("a fresh later graceful Stop completes without forced termination", async () => {
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    const preserve = join(paths.directory, "initial-preserve.ps1");
    await writeFile(
      preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    assert.equal((await runPowerShell(preserve)).lifecycle_result.status, "success");
    const laterStop = join(paths.directory, "later-graceful-stop.ps1");
    await writeFile(
      laterStop,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ stop_event_name = ${powerShellLiteral(paths.stopEvent)} } -GracefulAction {
    param($binding)
    $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
}
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const stopped = await runPowerShell(laterStop);
    assert.equal(stopped.lifecycle_result.status, "success");
    assert.equal(stopped.lifecycle_result.operation, "graceful-stop");
    assert.equal(stopped.evidence.graceful_action_invocations, 1);
    assert.equal(stopped.evidence.forced_termination_used, false);
    assert.equal(isAlive(launch.binding.root_process_id), false);
    assert.equal(isAlive(launch.binding.holder_identity.process_id), false);
    assert.equal(await namedJobExists(launch.binding.job_name), false);
    assert.equal(await pathExists(paths.record), false);
  } finally {
    await cleanupFixture(fixture);
  }
});

test("a fresh later forced Stop removes the owned tree and preserves an unrelated sentinel", async () => {
  let fixture;
  let sentinel;
  try {
    fixture = await launchOwnedTreePreserveFixture();
    sentinel = await startHiddenSentinel(fixture.paths.directory);
    assert.equal(isAlive(fixture.launch.binding.root_process_id), true);
    assert.equal(isAlive(fixture.childProcessId), true);
    assert.equal(isAlive(sentinel.process_id), true);
    const preserve = join(fixture.paths.directory, "initial-preserve.ps1");
    await writeFile(
      preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(fixture.paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    assert.equal((await runPowerShell(preserve)).lifecycle_result.status, "success");
    const laterStop = join(fixture.paths.directory, "later-forced-stop.ps1");
    await writeFile(
      laterStop,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(fixture.paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const stopped = await runPowerShell(laterStop);
    assert.equal(stopped.lifecycle_result.status, "success");
    assert.equal(stopped.lifecycle_result.operation, "forced-stop");
    assert.equal(stopped.evidence.forced_termination_used, true);
    assert.equal(stopped.evidence.owned_tree_empty, true);
    assert.equal(isAlive(fixture.launch.binding.root_process_id), false);
    assert.equal(isAlive(fixture.childProcessId), false);
    assert.equal(await namedJobExists(fixture.launch.binding.job_name), false);
    assert.equal(await pathExists(fixture.paths.record), false);
    assert.equal(isAlive(sentinel.process_id), true, "forced Stop leaves the unrelated sentinel live");
  } finally {
    await cleanupFixture(fixture);
    if (sentinel && isAlive(sentinel.process_id)) {
      await signalAndWaitForProcessExit(sentinel.process_id, sentinel.stop_event, sentinel.exited_event);
    }
  }
});

test("deterministic PID-reuse safety model rejects a live unrelated process with mismatched identity", async () => {
  let fixture;
  let sentinel;
  let preservedRecord;
  try {
    fixture = await launchPreserveFixture();
    sentinel = await startHiddenSentinel(fixture.paths.directory);
    const preserve = join(fixture.paths.directory, "initial-preserve.ps1");
    await writeFile(
      preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(fixture.paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    assert.equal((await runPowerShell(preserve)).lifecycle_result.status, "success");
    preservedRecord = await readFile(fixture.paths.record, "utf8");
    const modeledReuse = JSON.parse(preservedRecord);
    modeledReuse.root.process_id = sentinel.process_id;
    const mismatchedRecord = JSON.stringify(modeledReuse);
    await writeFile(fixture.paths.record, mismatchedRecord, "utf8");
    const laterStop = join(fixture.paths.directory, "pid-reuse-model-stop.ps1");
    await writeFile(
      laterStop,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(fixture.paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const rejected = await runPowerShell(laterStop);
    assert.equal(rejected.lifecycle_result.status, "unresolved");
    assert.equal(rejected.lifecycle_result.failure_kind, "root-unverifiable");
    assert.equal(rejected.evidence.reason_code, "root-creation-time-mismatch");
    assert.equal(rejected.evidence.termination_attempted, false);
    assert.equal(await readFile(fixture.paths.record, "utf8"), mismatchedRecord);
    assert.equal(isAlive(fixture.launch.binding.root_process_id), true, "the owned root remains live after rejection");
    assert.equal(isAlive(sentinel.process_id), true, "the live unrelated process is never terminated");
  } finally {
    if (fixture && preservedRecord) await writeFile(fixture.paths.record, preservedRecord, "utf8");
    await cleanupFixture(fixture);
    if (sentinel && isAlive(sentinel.process_id)) {
      await signalAndWaitForProcessExit(sentinel.process_id, sentinel.stop_event, sentinel.exited_event);
    }
  }
});

test("early root exit after Preserve leaves its owned child for explicit reconciliation", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-15-early-root-");
  const token = randomUUID();
  const paths = {
    child: join(directory, "child.ps1"),
    childExitedEvent: `Local\\AgentProcessLifecycle.Ticket15.EarlyChildExited.${token}`,
    childPid: join(directory, "child.pid"),
    childReadyEvent: `Local\\AgentProcessLifecycle.Ticket15.EarlyChildReady.${token}`,
    childStopEvent: `Local\\AgentProcessLifecycle.Ticket15.EarlyChildStop.${token}`,
    directory,
    launch: join(directory, "launch.ps1"),
    ready: join(directory, "ready.signal"),
    record: join(directory, "run-record.json"),
    root: join(directory, "root.ps1"),
    rootExitedEvent: `Local\\AgentProcessLifecycle.Ticket15.EarlyRootExited.${token}`,
    rootExitEvent: `Local\\AgentProcessLifecycle.Ticket15.EarlyRootExit.${token}`,
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
  };
  let launch;
  let childProcessId;
  let record;
  try {
    await writeFile(
      paths.child,
      `param([string]$ChildPidPath, [string]$ChildReadyEventName, [string]$ChildStopEventName, [string]$ChildExitedEventName)
$ready = [Threading.EventWaitHandle]::OpenExisting($ChildReadyEventName)
$stop = [Threading.EventWaitHandle]::OpenExisting($ChildStopEventName)
$exited = [Threading.EventWaitHandle]::OpenExisting($ChildExitedEventName)
try {
    [IO.File]::WriteAllText($ChildPidPath, [string]$PID)
    $ready.Set() | Out-Null
    $stop.WaitOne(120000) | Out-Null
}
finally { $exited.Set() | Out-Null; $exited.Dispose(); $stop.Dispose(); $ready.Dispose() }
`,
      "utf8",
    );
    await writeFile(
      paths.root,
      `param([string]$ChildPath, [string]$ChildPidPath, [string]$ChildReadyEventName, [string]$ChildStopEventName, [string]$ChildExitedEventName, [string]$ReadyPath, [string]$RootExitEventName, [string]$RootExitedEventName)
$childReady = [Threading.EventWaitHandle]::OpenExisting($ChildReadyEventName)
$rootExit = [Threading.EventWaitHandle]::OpenExisting($RootExitEventName)
$rootExited = [Threading.EventWaitHandle]::OpenExisting($RootExitedEventName)
try {
    Start-Process -FilePath $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ChildPath, '-ChildPidPath', $ChildPidPath, '-ChildReadyEventName', $ChildReadyEventName, '-ChildStopEventName', $ChildStopEventName, '-ChildExitedEventName', $ChildExitedEventName) -WindowStyle Hidden | Out-Null
    if (-not $childReady.WaitOne(5000)) { throw 'Owned child did not become ready.' }
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $rootExit.WaitOne(120000) | Out-Null
}
finally { $rootExited.Set() | Out-Null; $rootExited.Dispose(); $rootExit.Dispose(); $childReady.Dispose() }
`,
      "utf8",
    );
    await writeFile(
      paths.launch,
      `$childReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.childReadyEvent)})
$childStop = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.childStopEvent)})
$childExited = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.childExitedEvent)})
$rootExit = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.rootExitEvent)})
$rootExited = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.rootExitedEvent)})
try {
    $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.root)}, '-ChildPath', ${powerShellLiteral(paths.child)}, '-ChildPidPath', ${powerShellLiteral(paths.childPid)}, '-ChildReadyEventName', ${powerShellLiteral(paths.childReadyEvent)}, '-ChildStopEventName', ${powerShellLiteral(paths.childStopEvent)}, '-ChildExitedEventName', ${powerShellLiteral(paths.childExitedEvent)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-RootExitEventName', ${powerShellLiteral(paths.rootExitEvent)}, '-RootExitedEventName', ${powerShellLiteral(paths.rootExitedEvent)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-15-early-root-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)}; child_pid_path = ${powerShellLiteral(paths.childPid)} } -ReadinessCheck { param($context) (Test-Path -LiteralPath $context.ready_path) -and (Test-Path -LiteralPath $context.child_pid_path) } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Preserve -RequestedLaterOwner 'ticket-15-later-owner'
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $rootExited.Dispose(); $rootExit.Dispose(); $childExited.Dispose(); $childStop.Dispose(); $childReady.Dispose() }
`,
      "utf8",
    );
    launch = await runPowerShell(paths.launch);
    childProcessId = Number(await readFile(paths.childPid, "utf8"));
    const preserve = join(directory, "initial-preserve.ps1");
    await writeFile(preserve, `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'; $result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
    assert.equal((await runPowerShell(preserve)).lifecycle_result.status, "success");
    record = JSON.parse(await readFile(paths.record, "utf8"));
    await signalAndWaitForProcessExit(launch.binding.root_process_id, paths.rootExitEvent, paths.rootExitedEvent);
    assert.equal(isAlive(childProcessId), true, "the inherited owned child survives the root exit");
    const before = await readFile(paths.record, "utf8");
    const laterStop = join(directory, "later-stop-after-root-exit.ps1");
    await writeFile(laterStop, `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop; $result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
    const rejected = await runPowerShell(laterStop);
    assert.equal(rejected.lifecycle_result.status, "unresolved");
    assert.equal(rejected.lifecycle_result.failure_kind, "root-unverifiable");
    assert.equal(rejected.evidence.termination_attempted, false);
    assert.equal(await readFile(paths.record, "utf8"), before);
    assert.equal(isAlive(childProcessId), true, "rejected later Stop does not guess or kill the child");
  } finally {
    if (childProcessId && isAlive(childProcessId)) {
      await signalAndWaitForProcessExit(childProcessId, paths.childStopEvent, paths.childExitedEvent);
    }
    if (record && isAlive(record.holder.process_id)) {
      await signalAndWaitForProcessExit(record.holder.process_id, record.events.finalize, record.events.holder_exited);
    }
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false, "early-root fixture leaves no residue");
  }
});

test("hidden same-session same-SID outer Job supports nested assignment without exposing its handle", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-15-outer-job-");
  const token = randomUUID();
  const paths = {
    directory,
    launch: join(directory, "launch-under-outer-job.ps1"),
    ready: join(directory, "ready.json"),
    record: join(directory, "run-record.json"),
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
    stopEvent: `Local\\AgentProcessLifecycle.Ticket15.OuterJobStop.${token}`,
    workload: join(directory, "workload.ps1"),
  };
  let fixture;
  try {
    const instrumentedHelper = await createInstrumentedHelper(
      directory,
      "workload-job-handle-probe",
      "$ArgumentList = @($ArgumentList) + @('-JobHandleValue', [string]$jobHandle.ToInt64())",
    );
    await writeFile(
      paths.workload,
      `param([string]$ReadyPath, [string]$StopEventName, [Int64]$JobHandleValue)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket15WorkloadNative { [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length, IntPtr returnedLength); }'
$stop = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    $querySucceeded = [Ticket15WorkloadNative]::QueryInformationJobObject([IntPtr]$JobHandleValue, 1, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    [IO.File]::WriteAllText($ReadyPath, ([pscustomobject]@{ sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; session_id = (Get-Process -Id $PID).SessionId; job_query_succeeded = $querySucceeded } | ConvertTo-Json -Compress))
    $stop.WaitOne(120000) | Out-Null
}
finally { $stop.Dispose() }
`,
      "utf8",
    );
    await writeFile(
      paths.launch,
      `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket15OuterJobNative { [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObjectW(IntPtr attributes, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'
$outer = [Ticket15OuterJobNative]::CreateJobObjectW([IntPtr]::Zero, $null)
$self = [Ticket15OuterJobNative]::OpenProcess(0x1f0fff, $false, [uint32]$PID)
$root = [IntPtr]::Zero
$stop = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.stopEvent)})
try {
    if ($outer -eq [IntPtr]::Zero -or $self -eq [IntPtr]::Zero -or -not [Ticket15OuterJobNative]::AssignProcessToJobObject($outer, $self)) { throw 'Explicit outer Job assignment failed.' }
    $launch = & ${powerShellLiteral(instrumentedHelper)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.workload)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-StopEventName', ${powerShellLiteral(paths.stopEvent)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-15-outer-job-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop
    $root = [Ticket15OuterJobNative]::OpenProcess(0x101000, $false, [uint32]$launch.binding.root_process_id)
    $outerMember = $false
    if ($root -eq [IntPtr]::Zero -or -not [Ticket15OuterJobNative]::IsProcessInJob($root, $outer, [ref]$outerMember) -or -not $outerMember) { throw 'Launched root was not nested in the explicit outer Job.' }
    $finalized = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ stop_event_name = ${powerShellLiteral(paths.stopEvent)} } -GracefulAction { param($binding) $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name); try { $event.Set() | Out-Null } finally { $event.Dispose() } }
    [pscustomobject]@{ sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; session_id = (Get-Process -Id $PID).SessionId; outer_member = $outerMember; launch = $launch; finalized = $finalized } | ConvertTo-Json -Depth 12 -Compress
}
finally {
    if ($root -ne [IntPtr]::Zero) { [Ticket15OuterJobNative]::CloseHandle($root) | Out-Null }
    $stop.Dispose()
    if ($self -ne [IntPtr]::Zero) { [Ticket15OuterJobNative]::CloseHandle($self) | Out-Null }
    if ($outer -ne [IntPtr]::Zero) { [Ticket15OuterJobNative]::CloseHandle($outer) | Out-Null }
}
`,
      "utf8",
    );
    const result = await runPowerShell(paths.launch);
    fixture = { launch: result.launch, paths };
    const observed = JSON.parse(await readFile(paths.ready, "utf8"));
    assert.equal(result.launch.lifecycle_result.status, "success");
    assert.equal(result.outer_member, true, "the root is actually nested in the explicit outer Job");
    assert.equal(observed.sid, result.sid, "workload shares the caller SID");
    assert.equal(observed.session_id, result.session_id, "workload shares the caller session");
    assert.equal(observed.job_query_succeeded, false, "the workload cannot query the numeric parent Job handle");
    assert.equal(result.finalized.lifecycle_result.status, "success");
    assert.equal(result.finalized.evidence.forced_termination_used, false);
    assert.equal(await pathExists(paths.record), false);
  } finally {
    await cleanupFixture(fixture);
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false, "outer-Job fixture leaves no residue");
  }
});

test("Preserve publication failures distinguish absent, published, and unknown handoff outcomes", async (t) => {
  const scenarios = [
    {
      name: "original-unchanged",
      injection: "throw 'Ticket 15 injected Preserve publication failure.'",
      expectedStatus: "failed",
      restoreBeforeCleanup: false,
    },
    {
      name: "preserved-with-artifact-residue",
      injection: "Write-Record -Record $record -DestinationPath $recordPathForFinalize; $directory = [IO.Path]::GetDirectoryName($recordPathForFinalize); $leaf = Split-Path -Leaf $recordPathForFinalize; $artifact = Join-Path $directory \".$leaf.$([Guid]::NewGuid().ToString('N')).tmp\"; Write-ProtectedJsonFile -Record @{ artifact = 'ticket-15' } -Path $artifact; [IO.File]::WriteAllText((Join-Path $directory \".$leaf.notes.tmpkeep\"), 'decoy'); $failure = [InvalidOperationException]::new('Ticket 15 injected publication residue.'); $failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @($artifact); throw $failure",
      expectedStatus: "unresolved",
      restoreBeforeCleanup: false,
    },
    {
      name: "unknown",
      injection: "Write-Record -Record $record -DestinationPath $recordPathForFinalize; [IO.File]::WriteAllText($recordPathForFinalize, '{not-json'); throw 'Ticket 15 injected unknown publication state.'",
      expectedStatus: "unresolved",
      restoreBeforeCleanup: true,
    },
  ];

  for (const scenario of scenarios) {
    let fixture;
    let before;
    try {
      fixture = await launchPreserveFixture();
      const { launch, paths } = fixture;
      before = await readFile(paths.record, "utf8");
      const instrumentedHelper = await createInstrumentedHelper(
        paths.directory,
        "preserve-record-publication",
        scenario.injection,
      );
      const finalize = join(paths.directory, `${scenario.name}.ps1`);
      await writeFile(
        finalize,
        `$result = & ${powerShellLiteral(instrumentedHelper)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
        "utf8",
      );

      const failed = await runPowerShell(finalize);

      assertLifecycleNonGuarantees(failed, `${scenario.name} mixed Preserve result discloses only the accepted limitations`);
      assert.equal(failed.lifecycle_result.status, scenario.expectedStatus, scenario.name);
      assert.equal(failed.lifecycle_result.failure_kind, "record-publication", scenario.name);
      assert.equal(failed.evidence.publication_outcome, scenario.name, scenario.name);
      assert.equal(failed.evidence.graceful_action_invocations, 0, scenario.name);
      assert.equal(failed.evidence.termination_attempted, false, scenario.name);
      assert.equal(isAlive(launch.binding.root_process_id), true, scenario.name);
      assert.equal(isAlive(launch.binding.holder_identity.process_id), true, scenario.name);
      assert.equal(await namedJobExists(launch.binding.job_name), true, scenario.name);
      if (scenario.name === "original-unchanged") {
        assert.equal(failed.evidence.handoff_published, false, scenario.name);
        assert.equal(failed.later_owner, null, scenario.name);
        assert.equal("stop_method" in failed, false, scenario.name);
        assert.equal(await readFile(paths.record, "utf8"), before, scenario.name);
      } else if (scenario.name === "preserved-with-artifact-residue") {
        const published = JSON.parse(await readFile(paths.record, "utf8"));
        assert.equal(published.state, "preserved");
        assert.equal(published.later_owner, "ticket-15-later-owner");
        assert.equal(failed.final_disposition.status, "preserved");
        assert.equal(failed.later_owner, "ticket-15-later-owner");
        assert.equal(failed.evidence.handoff_published, true);
        assert.deepEqual(failed.stop_method, {
          action: "Finalize",
          disposition: "Stop",
          record_path: paths.record,
        });
        assert.equal(failed.evidence.publication_artifacts.length, 1);
        const artifactPath = failed.evidence.publication_artifacts[0];
        const decoyPath = join(paths.directory, ".run-record.json.notes.tmpkeep");
        assert.equal(await pathExists(artifactPath), true);
        const laterStop = join(paths.directory, "later-stop-after-residue.ps1");
        await writeFile(
          laterStop,
          `$result = & ${powerShellLiteral(helperPath)} -Action ${powerShellLiteral(failed.stop_method.action)} -RecordPath ${powerShellLiteral(failed.stop_method.record_path)} -Disposition ${powerShellLiteral(failed.stop_method.disposition)}
$result | ConvertTo-Json -Depth 12 -Compress
`,
          "utf8",
        );
        assert.equal((await runPowerShell(laterStop)).lifecycle_result.status, "success");
        assert.equal(await pathExists(paths.record), false, "returned handoff can be finalized later");
        assert.equal(await pathExists(artifactPath), false, "later Stop removes the exact Preserve publication artifact");
        assert.equal(await readFile(decoyPath, "utf8"), "decoy", "later Stop preserves the tmp-like decoy");
        assert.equal(isAlive(launch.binding.root_process_id), false);
        assert.equal(isAlive(launch.binding.holder_identity.process_id), false);
        assert.equal(await namedJobExists(launch.binding.job_name), false);
      } else {
        assert.equal(failed.evidence.handoff_published, false, scenario.name);
        assert.equal(failed.later_owner, null, scenario.name);
        assert.equal("stop_method" in failed, false, scenario.name);
        assert.notEqual(await readFile(paths.record, "utf8"), before, scenario.name);
      }
    } finally {
      if (fixture && scenario.restoreBeforeCleanup && before) {
        await writeFile(fixture.paths.record, before, "utf8");
      }
      await cleanupFixture(fixture);
    }
  }

  await t.test("later Stop reports unresolved when exact publication artifact cleanup fails", async () => {
    let fixture;
    try {
      fixture = await launchPreserveFixture();
      const { launch, paths } = fixture;
      const preserveHelper = await createInstrumentedHelper(
        paths.directory,
        "preserve-record-publication",
        "Write-Record -Record $record -DestinationPath $recordPathForFinalize; $directory = [IO.Path]::GetDirectoryName($recordPathForFinalize); $leaf = Split-Path -Leaf $recordPathForFinalize; $artifact = Join-Path $directory \".$leaf.$([Guid]::NewGuid().ToString('N')).tmp\"; Write-ProtectedJsonFile -Record @{ artifact = 'ticket-15' } -Path $artifact; $failure = [InvalidOperationException]::new('Ticket 15 injected publication residue.'); $failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @($artifact); throw $failure",
      );
      const preserve = join(paths.directory, "preserve-with-residue.ps1");
      await writeFile(
        preserve,
        `$result = & ${powerShellLiteral(preserveHelper)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
        "utf8",
      );
      const handoff = await runPowerShell(preserve);
      const artifactPath = handoff.evidence.publication_artifacts[0];
      assert.equal(await pathExists(artifactPath), true);
      const stopHelper = await createInstrumentedHelper(
        paths.directory,
        "finalize-publication-artifact-delete",
        "throw 'Ticket 15 injected exact publication artifact deletion failure.'",
      );
      const laterStop = join(paths.directory, "later-stop-artifact-cleanup-failure.ps1");
      await writeFile(
        laterStop,
        `$result = & ${powerShellLiteral(stopHelper)} -Action Finalize -RecordPath ${powerShellLiteral(handoff.stop_method.record_path)} -Disposition Stop -DownstreamResult @{ source = 'ticket-15-artifact-cleanup'; status = 'unchanged' }
$result | ConvertTo-Json -Depth 12 -Compress
`,
        "utf8",
      );

      const unresolved = await runPowerShell(laterStop);

      assertLifecycleNonGuarantees(unresolved, "artifact-cleanup unresolved result discloses only the accepted limitations");
      assert.equal(unresolved.lifecycle_result.status, "unresolved");
      assert.equal(unresolved.lifecycle_result.failure_kind, "publication-artifact-cleanup");
      assert.equal(unresolved.lifecycle_result.cleanup.attempted, true);
      assert.equal(unresolved.lifecycle_result.cleanup.status, "unresolved");
      assert.equal(unresolved.lifecycle_result.cleanup.result, "artifact-cleanup-incomplete");
      assert.match(unresolved.lifecycle_result.unresolved_reason, /publication artifact/u);
      assert.deepEqual(unresolved.downstream_result, { source: "ticket-15-artifact-cleanup", status: "unchanged" });
      assert.equal(unresolved.final_disposition.status, "unresolved");
      assert.equal(unresolved.later_owner, "lifecycle-reconciliation-owner");
      assert.equal(unresolved.evidence.authority_verified, true);
      assert.equal(unresolved.evidence.owned_tree_empty, true);
      assert.equal(unresolved.evidence.root_process_absent, true);
      assert.equal(unresolved.evidence.job_holder_absent, true);
      assert.equal(unresolved.evidence.named_job_absent, true);
      assert.equal(unresolved.evidence.record_present, true);
      assert.equal(unresolved.evidence.record_state, "preserved");
      assert.deepEqual(unresolved.evidence.publication_artifacts, [artifactPath]);
      assert.equal(unresolved.evidence.responsibility_status, "transfer-required-not-completed");
      assert.equal(await pathExists(paths.record), true);
      assert.equal(await pathExists(artifactPath), true);
      assert.equal(isAlive(launch.binding.root_process_id), false);
      assert.equal(isAlive(launch.binding.holder_identity.process_id), false);
      assert.equal(await namedJobExists(launch.binding.job_name), false);
    } finally {
      if (fixture && isAlive(fixture.launch.binding.root_process_id)) {
        await cleanupFixture(fixture);
      } else if (fixture) {
        await rm(fixture.paths.directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
        assert.equal(await pathExists(fixture.paths.directory), false, "artifact-cleanup failure fixture leaves no residue");
      }
    }
  });
});

test("Preserve artifact validation failures retain truthful live authority", async (t) => {
  const scenarios = [
    {
      name: "unprotected replacement",
      validationInjection: "$artifact = [string]$candidates[0]; [IO.File]::Delete($artifact); [IO.File]::WriteAllText($artifact, 'unprotected')",
      validationReason: /The record ACL is not protected for the current user\./u,
    },
    {
      name: "reparse replacement",
      validationInjection: "$artifact = [string]$candidates[0]; $target = Join-Path ([IO.Path]::GetDirectoryName($artifact)) 'validation-reparse-target'; [IO.Directory]::CreateDirectory($target) | Out-Null; [IO.File]::Delete($artifact); New-Item -ItemType Junction -Path $artifact -Target $target | Out-Null",
      validationReason: /Publication artifact is not a file/u,
    },
    {
      name: "validation-time disappearance",
      validationInjection: "[IO.File]::Delete([string]$candidates[0])",
      validationReason: /Publication artifact is not a file/u,
    },
  ];

  for (const scenario of scenarios) {
    await t.test(scenario.name, async () => {
      let fixture;
      let artifactPath;
      try {
        fixture = await launchPreserveFixture();
        const { launch, paths } = fixture;
        const before = await readFile(paths.record, "utf8");
        const { artifactLeaf, instrumentedHelper } = await createArtifactValidationFailureHelper(
          paths.directory,
          scenario.validationInjection,
        );
        artifactPath = join(paths.directory, artifactLeaf);
        const finalize = join(paths.directory, "preserve-artifact-validation-failure.ps1");
        await writeFile(
          finalize,
          `$result = & ${powerShellLiteral(instrumentedHelper)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
          "utf8",
        );

        const failed = await runPowerShell(finalize);

        assertLifecycleNonGuarantees(failed, `${scenario.name} reports only accepted lifecycle limits`);
        assert.equal(failed.requested_disposition, "Preserve");
        assert.equal(failed.lifecycle_result.status, "unresolved");
        assert.equal(failed.lifecycle_result.operation, "preserve");
        assert.equal(failed.lifecycle_result.failure_kind, "record-publication");
        assert.deepEqual(failed.lifecycle_result.cleanup, {
          attempted: false,
          status: "not-attempted",
          result: "workload-retained",
        });
        assert.match(failed.lifecycle_result.error, /Ticket 15 injected Preserve publication failure/u);
        assert.match(failed.lifecycle_result.error, scenario.validationReason);
        assert.equal(failed.lifecycle_result.error.includes(paths.directory), false, "error redacts fixture paths");
        assert.equal(failed.lifecycle_result.error.includes(artifactPath), false, "error redacts artifact paths outside evidence");
        assert.equal(failed.final_disposition.requested, "Preserve");
        assert.equal(failed.final_disposition.status, "unresolved");
        assert.equal(failed.evidence.authority_verified, true);
        assert.equal(failed.evidence.handoff_published, false);
        assert.equal(failed.evidence.publication_outcome, "unknown");
        assert.deepEqual(failed.evidence.publication_artifacts, [artifactPath]);
        assert.equal(failed.evidence.graceful_action_invocations, 0);
        assert.equal(failed.evidence.termination_attempted, false);
        assert.equal(failed.evidence.forced_termination_used, false);
        assert.equal("stop_method" in failed, false);
        assert.equal("owned_tree_empty" in failed.evidence, false);
        assert.equal("root_process_absent" in failed.evidence, false);
        assert.equal("job_holder_absent" in failed.evidence, false);
        assert.equal("named_job_absent" in failed.evidence, false);
        assert.equal(isAlive(launch.binding.root_process_id), true, "Preserve keeps the root live");
        assert.equal(isAlive(launch.binding.holder_identity.process_id), true, "Preserve keeps the holder live");
        assert.equal(await namedJobExists(launch.binding.job_name), true, "Preserve keeps the Job live");
        assert.equal(await pathExists(paths.record), true, "Preserve keeps the record live");
        assert.equal(await readFile(paths.record, "utf8"), before, "failed publication does not invent a handoff record");
      } finally {
        if (fixture) {
          await rm(artifactPath, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
          await rm(join(fixture.paths.directory, "validation-reparse-target"), { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
        }
        await cleanupFixture(fixture);
      }
    });
  }
});

test("later Stop refuses an unprotected exact-name publication artifact with unresolved evidence", async () => {
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    await writeFile(
      paths.preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    assert.equal((await runPowerShell(paths.preserve)).lifecycle_result.status, "success");

    const artifactPath = join(paths.directory, ".run-record.json.abcdef0123456789abcdef0123456789.tmp");
    const stopHelper = await createInstrumentedHelper(
      paths.directory,
      "finalize-before-stop",
      `$artifact = ${powerShellLiteral(artifactPath)}; [IO.File]::WriteAllText($artifact, 'unprotected')`,
    );
    const laterStop = join(paths.directory, "later-stop-unprotected-artifact.ps1");
    await writeFile(
      laterStop,
      `$result = & ${powerShellLiteral(stopHelper)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const unresolved = await runPowerShell(laterStop);

    assert.equal(unresolved.lifecycle_result.status, "unresolved");
    assert.equal(unresolved.lifecycle_result.failure_kind, "publication-artifact-cleanup");
    assert.equal(unresolved.lifecycle_result.cleanup.status, "unresolved");
    assert.deepEqual(unresolved.evidence.publication_artifacts, [artifactPath]);
    assert.equal(unresolved.evidence.record_present, true);
    assert.equal(await readFile(artifactPath, "utf8"), "unprotected");
    assert.equal(await pathExists(paths.record), true);
    assert.equal(isAlive(launch.binding.root_process_id), false);
    assert.equal(isAlive(launch.binding.holder_identity.process_id), false);
    assert.equal(await namedJobExists(launch.binding.job_name), false);
  } finally {
    if (fixture && isAlive(fixture.launch.binding.root_process_id)) {
      await cleanupFixture(fixture);
    } else if (fixture) {
      await rm(fixture.paths.directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
      assert.equal(await pathExists(fixture.paths.directory), false, "unprotected artifact fixture leaves no residue");
    }
  }
});

async function assertLaterStopOwnerRejection() {
  let fixture;
  try {
    fixture = await launchPreserveFixture();
    const { launch, paths } = fixture;
    const preserve = join(paths.directory, "initial-preserve.ps1");
    await writeFile(
      preserve,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Preserve -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );
    const preserved = await runPowerShell(preserve);
    assert.equal(preserved.lifecycle_result.status, "success");
    const before = await readFile(paths.record, "utf8");
    const laterStop = join(paths.directory, "later-stop-with-owner.ps1");
    await writeFile(
      laterStop,
      `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -LaterOwner 'ticket-15-later-owner'
$result | ConvertTo-Json -Depth 12 -Compress
`,
      "utf8",
    );

    const rejected = await runPowerShell(laterStop);

    assert.equal(rejected.lifecycle_result.status, "unresolved");
    assert.equal(rejected.lifecycle_result.failure_kind, "record-state");
    assert.equal(rejected.evidence.reason_code, "stop-prohibits-later-owner");
    assert.equal(rejected.evidence.graceful_action_invocations, 0);
    assert.equal(rejected.evidence.termination_attempted, false);
    assert.equal(await readFile(paths.record, "utf8"), before);
    assert.equal(isAlive(launch.binding.root_process_id), true);
    assert.equal(isAlive(launch.binding.holder_identity.process_id), true);
    assert.equal(await namedJobExists(launch.binding.job_name), true);
  } finally {
    await cleanupFixture(fixture);
  }
}

test("Ticket 15 runtime invocations stay hidden in protected fixture scope", async () => {
  const source = await readFile(resolve(import.meta.dirname, "windows-helper-ticket-15.test.mjs"), "utf8");
  const helper = await readFile(helperPath, "utf8");

  assert.match(source, /windowsHide: true/gu);
  assert.match(source, /from "\.\/protected-test-fixture\.mjs"/u);
  assert.match(source, /cleanupFixtureRoot, fixtureRoot, mkdtemp/u);
  assert.match(source, /after\(cleanupFixtureRoot\)/u);
  assert.match(helper, /ValidateSet\('Launch', 'Finalize'\)/u);
  assert.doesNotMatch(helper, /KILL_ON_JOB_CLOSE|Stop-Process|Get-NetTCPConnection|TerminateOwnedJob/u);
  assert.deepEqual(await readdir(fixtureRoot), []);
});
