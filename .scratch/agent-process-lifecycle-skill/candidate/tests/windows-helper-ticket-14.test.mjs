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
const downstreamResult = { source: "ticket-14", status: "unchanged" };

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function jobNameFor(runId) {
  return `Local\\AgentProcessLifecycle.${runId}.Job`;
}

function finalizeEventFor(runId) {
  return `Local\\AgentProcessLifecycle.${runId}.Finalize`;
}

function holderExitedEventFor(runId) {
  return `Local\\AgentProcessLifecycle.${runId}.HolderExited`;
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

async function runPowerShell(scriptPath) {
  const { stdout, stderr } = await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", scriptPath],
    { windowsHide: true, maxBuffer: 1024 * 1024 },
  );
  assert.equal(stderr, "", `PowerShell stderr: ${stderr}`);
  return JSON.parse(stdout);
}

async function namedJobExists(name) {
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket14Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket14Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket14Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
    { windowsHide: true },
  );
  return stdout.trim() === "true";
}

async function attempt(errors, operation) {
  try {
    await operation();
  } catch (error) {
    errors.push(error);
  }
}

function replaceOnce(source, pattern, replacement, description) {
  const result = source.replace(pattern, replacement);
  assert.notEqual(result, source, `fixture mutation replaced ${description}`);
  return result;
}

function replaceJsonString(source, key, value) {
  const escapedValue = JSON.stringify(value).slice(1, -1);
  return replaceOnce(
    source,
    new RegExp(`("${key}":")[^"]*(")`, "u"),
    `$1${escapedValue}$2`,
    key,
  );
}

function mutateJson(source, mutation) {
  const record = JSON.parse(source);
  mutation(record);
  return JSON.stringify(record);
}

async function createInstrumentedHelper(directory, marker, injection) {
  const needle = `# TEST-INJECTION: ${marker}`;
  const source = await readFile(helperPath, "utf8");
  const escapedNeedle = needle.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const markerPattern = new RegExp(`${escapedNeedle}(?=\\r?\\n)`, "u");
  assert.match(source, markerPattern, `missing Ticket 14 injection marker: ${marker}`);
  const instrumentedPath = join(directory, `Invoke-AgentProcessLifecycle.${marker}.ps1`);
  await writeFile(instrumentedPath, source.replace(markerPattern, () => injection), "utf8");
  return instrumentedPath;
}

async function launchFixture() {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-14-");
  const runToken = randomUUID();
  const paths = {
    directory,
    gracefulMarker: join(directory, "graceful-invoked.marker"),
    launch: join(directory, "launch.ps1"),
    ready: join(directory, "ready.signal"),
    record: join(directory, "run-record.json"),
    root: join(directory, "root.ps1"),
    stderr: join(directory, "workload.stderr.log"),
    stdout: join(directory, "workload.stdout.log"),
    workloadStopEvent: `Local\\AgentProcessLifecycle.Ticket14.Stop.${runToken}`,
  };

  await writeFile(paths.root, `param([string]$ReadyPath, [string]$StopEventName)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    $stopEvent.WaitOne(120000) | Out-Null
}
finally { $stopEvent.Dispose() }
`, "utf8");
  await writeFile(paths.launch, `$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(paths.workloadStopEvent)})
try {
    $result = & ${powerShellLiteral(helperPath)} -Action Launch -RecordPath ${powerShellLiteral(paths.record)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(paths.root)}, '-ReadyPath', ${powerShellLiteral(paths.ready)}, '-StopEventName', ${powerShellLiteral(paths.workloadStopEvent)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(paths.stdout)} -StderrPath ${powerShellLiteral(paths.stderr)} -ReadinessIdentity 'ticket-14-owned-root-ready' -ReadinessContext @{ ready_path = ${powerShellLiteral(paths.ready)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop -DownstreamResult @{ source = 'ticket-14-launch'; status = 'not-run' }
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $stopEvent.Dispose() }
`, "utf8");

  const launch = await runPowerShell(paths.launch);
  assert.equal(launch.lifecycle_result.status, "success");
  assert.equal(isAlive(launch.binding.root_process_id), true, "fixture root is live");
  assert.equal(isAlive(launch.binding.holder_identity.process_id), true, "fixture holder is live");
  assert.equal(await namedJobExists(launch.binding.job_name), true, "fixture Job is retained");
  return { launch, paths };
}

async function invokeFinalize({ activeHelperPath = helperPath, paths }) {
  const scriptPath = join(paths.directory, `finalize-${randomUUID()}.ps1`);
  await writeFile(scriptPath, `$gracefulAction = {
    param($binding)
    [IO.File]::WriteAllText(${powerShellLiteral(paths.gracefulMarker)}, $binding.run_id)
    $true
}
$result = & ${powerShellLiteral(activeHelperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulAction $gracefulAction -DownstreamResult @{ source = 'ticket-14'; status = 'unchanged' }
$result | ConvertTo-Json -Depth 12 -Compress
`, "utf8");
  return runPowerShell(scriptPath);
}

async function cleanupWithValidatedFinalize(paths) {
  if (!(await pathExists(paths.record))) return;
  const scriptPath = join(paths.directory, "validated-fixture-cleanup.ps1");
  await writeFile(scriptPath, `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(paths.record)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ stop_event_name = ${powerShellLiteral(paths.workloadStopEvent)} } -GracefulAction {
    param($binding)
    $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
} -DownstreamResult @{ source = 'ticket-14-cleanup'; status = 'not-run' }
$result | ConvertTo-Json -Depth 12 -Compress
`, "utf8");
  const result = await runPowerShell(scriptPath);
  assert.equal(result.lifecycle_result.status, "success", `validated fixture cleanup succeeds: ${JSON.stringify(result)}`);
}

async function fallbackCleanupWithExactFixtureAuthority(paths) {
  if (!(await pathExists(paths.record))) return;
  const scriptPath = join(paths.directory, "identity-bound-fixture-cleanup.ps1");
  await writeFile(scriptPath, `param([string]$RecordPath)
Add-Type -TypeDefinition 'using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text; public static class Ticket14CleanupNative { [StructLayout(LayoutKind.Sequential)] public struct FILETIME { public uint Low; public uint High; } [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint id); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user); [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref uint size); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint exitCode); [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'
$record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json -AsHashtable
$errors = [Collections.Generic.List[string]]::new()
$job = [IntPtr]::Zero
$root = [IntPtr]::Zero
$holder = [IntPtr]::Zero
function Test-Identity([IntPtr]$Handle, $Identity) {
    $creation = [Ticket14CleanupNative+FILETIME]::new(); $exit = [Ticket14CleanupNative+FILETIME]::new(); $kernel = [Ticket14CleanupNative+FILETIME]::new(); $user = [Ticket14CleanupNative+FILETIME]::new()
    if (-not [Ticket14CleanupNative]::GetProcessTimes($Handle, [ref]$creation, [ref]$exit, [ref]$kernel, [ref]$user)) { return $false }
    $actualCreation = ([int64]$creation.High -shl 32) -bor $creation.Low
    $size = 32768; $image = [Text.StringBuilder]::new($size)
    if (-not [Ticket14CleanupNative]::QueryFullProcessImageNameW($Handle, 0, $image, [ref]$size)) { return $false }
    return [string]$actualCreation -eq [string]$Identity.creation_time_filetime -and [string]::Equals($image.ToString(), [string]$Identity.image_path, [StringComparison]::OrdinalIgnoreCase)
}
try {
    try {
        $job = [Ticket14CleanupNative]::OpenJobObjectW(0x0010000c, $false, [string]$record.job_name)
        $root = [Ticket14CleanupNative]::OpenProcess(0x101000, $false, [uint32]$record.root.process_id)
        $member = $false
        if ($job -eq [IntPtr]::Zero -or $root -eq [IntPtr]::Zero -or -not (Test-Identity $root $record.root) -or -not [Ticket14CleanupNative]::IsProcessInJob($root, $job, [ref]$member) -or -not $member) { throw 'Root Job authority could not be re-proven for fixture cleanup.' }
        if (-not [Ticket14CleanupNative]::TerminateJobObject($job, 124)) { throw 'Fixture Job termination failed.' }
    } catch { $errors.Add($_.Exception.Message) }
    try {
        $holder = [Ticket14CleanupNative]::OpenProcess(0x101001, $false, [uint32]$record.holder.process_id)
        if ($holder -eq [IntPtr]::Zero -or -not (Test-Identity $holder $record.holder)) { throw 'Holder identity could not be re-proven for fixture cleanup.' }
        $finalize = [Threading.EventWaitHandle]::OpenExisting([string]$record.events.finalize)
        $exited = [Threading.EventWaitHandle]::OpenExisting([string]$record.events.holder_exited)
        try { $finalize.Set() | Out-Null; $exited.WaitOne(1000) | Out-Null } finally { $finalize.Dispose(); $exited.Dispose() }
        if ([Ticket14CleanupNative]::WaitForSingleObject($holder, 1000) -ne 0 -and -not [Ticket14CleanupNative]::TerminateProcess($holder, 124)) { throw 'Exact-identity holder termination failed.' }
    } catch { $errors.Add($_.Exception.Message) }
} finally {
    if ($holder -ne [IntPtr]::Zero) { [Ticket14CleanupNative]::CloseHandle($holder) | Out-Null }
    if ($root -ne [IntPtr]::Zero) { [Ticket14CleanupNative]::CloseHandle($root) | Out-Null }
    if ($job -ne [IntPtr]::Zero) { [Ticket14CleanupNative]::CloseHandle($job) | Out-Null }
}
if ($errors.Count -gt 0) { throw ($errors -join ' ') }
`, "utf8");
  await execFile(
    "pwsh",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", scriptPath, "-RecordPath", paths.record],
    { windowsHide: true, maxBuffer: 1024 * 1024 },
  );
}

async function cleanupFixture(fixture) {
  const errors = [];
  const { launch, paths } = fixture;
  await attempt(errors, async () => cleanupWithValidatedFinalize(paths));
  await attempt(errors, async () => fallbackCleanupWithExactFixtureAuthority(paths));
  await attempt(errors, async () => {
    assert.equal(isAlive(launch.binding.root_process_id), false, "fixture root is absent after teardown");
    assert.equal(isAlive(launch.binding.holder_identity.process_id), false, "fixture holder is absent after teardown");
    assert.equal(await namedJobExists(launch.binding.job_name), false, "fixture Job is absent after teardown");
  });
  await attempt(errors, async () => {
    await rm(paths.directory, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
    assert.equal(await pathExists(paths.directory), false, "fixture directory is absent after teardown");
  });
  if (errors.length > 0) throw new AggregateError(errors, "Ticket 14 fixture teardown failed after all cleanup attempts.");
}

function expectedResponsibility(category) {
  if (category === "caller") return { laterOwner: null, responsibilityStatus: "retained-by-caller" };
  if (category === "security") {
    return {
      laterOwner: "compatible-session-security-context-owner",
      responsibilityStatus: "transfer-required-not-completed",
    };
  }
  return {
    laterOwner: "lifecycle-reconciliation-owner",
    responsibilityStatus: "transfer-required-not-completed",
  };
}

async function assertRejectedFinalize({ fixture, result, beforeRecord, expected, shapeTrusted }) {
  const { launch, paths } = fixture;
  const responsibility = expectedResponsibility(expected.category);
  assert.equal(result.action, "Finalize");
  assert.equal(result.tier, "windows-self-managed");
  assert.equal(result.requested_disposition, "Stop");
  assert.equal(result.binding, null);
  assert.equal(result.stdio, null);
  assert.equal(result.readiness, null);
  assert.equal(result.lifecycle_result.status, "unresolved");
  assert.equal(result.lifecycle_result.operation, "finalize-rejected");
  assert.equal(result.lifecycle_result.failure_kind, expected.failureKind);
  assert.equal(result.lifecycle_result.cleanup.attempted, false);
  assert.equal(result.lifecycle_result.cleanup.status, "not-attempted");
  assert.equal(result.lifecycle_result.cleanup.result, "authority-unverified");
  assert.match(result.lifecycle_result.unresolved_reason, /./u);
  assert.deepEqual(result.downstream_result, downstreamResult, "Finalize leaves downstream state unchanged");
  assert.equal(result.final_disposition.requested, "Stop");
  assert.equal(result.final_disposition.status, "unresolved");
  assert.equal(result.later_owner, responsibility.laterOwner);
  assert.equal(result.evidence.validation_stage, expected.stage);
  assert.equal(result.evidence.reason_code, expected.reasonCode);
  assert.deepEqual(result.evidence.missing_evidence, expected.missingEvidence);
  assert.equal(result.evidence.record_path, paths.record);
  assert.equal(result.evidence.record_present, true);
  assert.equal(result.evidence.record_unchanged, true);
  assert.equal(result.evidence.authority_verified, false);
  assert.equal(result.evidence.graceful_action_invocations, 0);
  assert.equal(result.evidence.termination_attempted, false);
  assert.equal(result.evidence.forced_termination_used, false);
  assert.equal(result.evidence.responsibility_status, responsibility.responsibilityStatus);
  if (shapeTrusted) {
    assert.equal(result.evidence.record_claims.run_id, expected.runId, "trusted claims retain the parsed run_id");
  } else {
    assert.equal(result.evidence.record_claims, null, "untrusted record shape is not surfaced as authority evidence");
  }
  assert.equal(await readFile(paths.record, "utf8"), beforeRecord, "rejection leaves the record byte-for-byte unchanged");
  assert.equal(await pathExists(paths.gracefulMarker), false, "rejection does not invoke GracefulAction");
  assert.equal(isAlive(launch.binding.root_process_id), true, "rejection does not terminate the root");
  assert.equal(isAlive(launch.binding.holder_identity.process_id), true, "rejection does not signal or terminate the holder");
  assert.equal(await namedJobExists(launch.binding.job_name), true, "rejection does not terminate the Job");
}

async function assertScenario(fixture, { expected, hook, mutate = (source) => source, shapeTrusted = true }) {
  const { paths } = fixture;
  const original = await readFile(paths.record, "utf8");
  const mutated = mutate(original);
  const activeHelperPath = hook
    ? await createInstrumentedHelper(paths.directory, hook.marker, hook.injection)
    : helperPath;
  await writeFile(paths.record, mutated, "utf8");
  try {
    const result = await invokeFinalize({ activeHelperPath, paths });
    await assertRejectedFinalize({
      fixture,
      result,
      beforeRecord: mutated,
      expected,
      shapeTrusted,
    });
  } finally {
    await writeFile(paths.record, original, "utf8");
    await rm(activeHelperPath === helperPath ? join(paths.directory, "not-created") : activeHelperPath, { force: true });
  }
}

async function assertMissingRecordRejection() {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-14-missing-");
  const paths = {
    directory,
    gracefulMarker: join(directory, "graceful-invoked.marker"),
    record: join(directory, "run-record.json"),
  };
  try {
    const result = await invokeFinalize({ paths });
    const responsibility = expectedResponsibility("caller");
    assert.equal(result.action, "Finalize");
    assert.equal(result.lifecycle_result.status, "unresolved");
    assert.equal(result.lifecycle_result.operation, "finalize-rejected");
    assert.equal(result.lifecycle_result.failure_kind, "record-unavailable");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(result.lifecycle_result.cleanup.status, "not-attempted");
    assert.equal(result.lifecycle_result.cleanup.result, "authority-unverified");
    assert.equal(result.binding, null);
    assert.equal(result.stdio, null);
    assert.equal(result.readiness, null);
    assert.deepEqual(result.downstream_result, downstreamResult);
    assert.equal(result.final_disposition.status, "unresolved");
    assert.equal(result.later_owner, responsibility.laterOwner);
    assert.equal(result.evidence.validation_stage, "protected-path-read-json");
    assert.equal(result.evidence.reason_code, "record-absent");
    assert.equal(result.evidence.record_path, paths.record);
    assert.equal(result.evidence.record_present, false);
    assert.equal(result.evidence.record_unchanged, true);
    assert.equal(result.evidence.record_claims, null);
    assert.equal(result.evidence.authority_verified, false);
    assert.equal(result.evidence.graceful_action_invocations, 0);
    assert.equal(result.evidence.termination_attempted, false);
    assert.equal(result.evidence.forced_termination_used, false);
    assert.equal(result.evidence.responsibility_status, responsibility.responsibilityStatus);
    assert.equal(await pathExists(paths.gracefulMarker), false);
  } finally {
    await rm(directory, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
  }
}

test("Finalize rejects unverifiable authority before graceful or termination side effects", async () => {
  assert.equal(process.platform, "win32", "Ticket 14 is Windows-only");
  await assertMissingRecordRejection();

  const fixture = await launchFixture();
  try {
    const currentRunId = fixture.launch.binding.run_id;
    const noAuthorityRunId = randomUUID().replaceAll("-", "");
    const reconciliation = "reconciliation";
    const nativeAccessDenied = "throw [ComponentModel.Win32Exception]::new(5, 'Ticket 14 injected authority reopen access denied.')";

    await assertScenario(fixture, {
      expected: { category: "caller", failureKind: "record-invalid", missingEvidence: ["parseable-record"], reasonCode: "record-json-invalid", runId: null, stage: "protected-path-read-json" },
      mutate: () => "{not-json",
      shapeTrusted: false,
    });
    await assertScenario(fixture, {
      expected: { category: "caller", failureKind: "record-invalid", missingEvidence: ["complete-record-schema"], reasonCode: "schema-or-type-invalid", runId: null, stage: "schema-types" },
      mutate: (source) => replaceOnce(source, /"schema_version":1/u, '"schema_version":"1"', "schema type"),
      shapeTrusted: false,
    });
    for (const [label, mutation] of [
      ["missing executable", (record) => { delete record.executable; }],
      ["arguments are not an array", (record) => { record.arguments = "not-an-array"; }],
      ["arguments contain a non-string", (record) => { record.arguments[0] = 1; }],
      ["working directory is blank", (record) => { record.working_directory = ""; }],
      ["root identity process id is not an integer", (record) => { record.root.process_id = "not-an-integer"; }],
      ["stdio stdout path has the wrong type", (record) => { record.stdio.stdout_path = false; }],
      ["readiness identity is blank", (record) => { record.readiness.identity = ""; }],
      ["readiness deadline has the wrong type", (record) => { record.readiness.deadline_milliseconds = "5000"; }],
      ["ready completion timestamp has the wrong type", (record) => { record.readiness.completed_at_utc = false; }],
      ["ready completion timestamp is not round-trip", (record) => { record.readiness.completed_at_utc = "not-a-timestamp"; }],
      ["ready elapsed time has the wrong type", (record) => { record.readiness.elapsed_milliseconds = null; }],
      ["requested disposition has the wrong type", (record) => { record.requested_disposition = false; }],
      ["requested later owner has the wrong type", (record) => { record.requested_later_owner = {}; }],
      ["later owner has the wrong type", (record) => { record.later_owner = {}; }],
      ["Finalize event has the wrong type", (record) => { record.events.finalize = false; }],
    ]) {
      await assertScenario(fixture, {
        expected: { category: "caller", failureKind: "record-invalid", missingEvidence: ["complete-record-schema"], reasonCode: "schema-or-type-invalid", runId: null, stage: "schema-types" },
        hook: { marker: "finalize-job-query", injection: "throw 'Ticket 14 schema guard must reject before authority lookup.'" },
        mutate: (source) => mutateJson(source, mutation),
        shapeTrusted: false,
      });
    }
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "record-state", missingEvidence: ["ready-stop-state"], reasonCode: "record-not-ready", runId: currentRunId, stage: "state-readiness-disposition" },
      mutate: (source) => mutateJson(source, (record) => {
        record.state = "bound";
        record.job_name = "not-a-derived-job";
        record.readiness.result = null;
        record.readiness.completed_at_utc = null;
        delete record.readiness.elapsed_milliseconds;
      }),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "record-state", missingEvidence: ["readiness-success"], reasonCode: "readiness-not-succeeded", runId: currentRunId, stage: "state-readiness-disposition" },
      mutate: (source) => replaceJsonString(source, "result", "pending"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "record-state", missingEvidence: ["stop-disposition"], reasonCode: "record-disposition-not-stop", runId: currentRunId, stage: "state-readiness-disposition" },
      mutate: (source) => replaceJsonString(source, "requested_disposition", "Preserve"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "binding-inconsistent", missingEvidence: ["derived-run-id"], reasonCode: "run-id-invalid", runId: "not-a-run-id", stage: "binding-consistency" },
      mutate: (source) => replaceJsonString(source, "run_id", "not-a-run-id"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "binding-inconsistent", missingEvidence: ["derived-job-name"], reasonCode: "job-name-mismatch", runId: currentRunId, stage: "binding-consistency" },
      mutate: (source) => replaceJsonString(source, "job_name", "Local\\AgentProcessLifecycle.not-the-recorded-run.Job"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "binding-inconsistent", missingEvidence: ["derived-finalize-event"], reasonCode: "finalize-event-mismatch", runId: currentRunId, stage: "binding-consistency" },
      mutate: (source) => replaceJsonString(source, "finalize", "Local\\AgentProcessLifecycle.not-the-recorded-run.Finalize"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "job-unverifiable", missingEvidence: ["retained-job-handle"], reasonCode: "job-unavailable", runId: noAuthorityRunId, stage: "job-retain-query" },
      mutate: (source) => replaceJsonString(
        replaceJsonString(
          replaceJsonString(
            replaceJsonString(source, "run_id", noAuthorityRunId),
            "job_name",
            jobNameFor(noAuthorityRunId),
          ),
          "finalize",
          finalizeEventFor(noAuthorityRunId),
        ),
        "holder_exited",
        holderExitedEventFor(noAuthorityRunId),
      ),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "job-unverifiable", missingEvidence: ["queryable-job-handle"], reasonCode: "job-retain-or-query-failed", runId: currentRunId, stage: "job-retain-query" },
      hook: { marker: "finalize-job-query", injection: "throw 'Ticket 14 injected Job query failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: "security", failureKind: "job-unverifiable", missingEvidence: ["queryable-job-handle"], reasonCode: "job-retain-or-query-failed", runId: currentRunId, stage: "job-retain-query" },
      hook: { marker: "finalize-job-query", injection: nativeAccessDenied },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["live-root-instance"], reasonCode: "root-unavailable", runId: currentRunId, stage: "root-retain-verify" },
      mutate: (source) => replaceOnce(source, /("root":\{"process_id":)\d+/u, "$14294967294", "root process id"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["queryable-root-instance"], reasonCode: "root-retain-or-query-failed", runId: currentRunId, stage: "root-retain-verify" },
      hook: { marker: "finalize-root-query", injection: "throw 'Ticket 14 injected root query failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: "security", failureKind: "root-unverifiable", missingEvidence: ["queryable-root-instance"], reasonCode: "root-retain-or-query-failed", runId: currentRunId, stage: "root-retain-verify" },
      hook: { marker: "finalize-root-query", injection: nativeAccessDenied },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["matching-root-creation-time"], reasonCode: "root-creation-time-mismatch", runId: currentRunId, stage: "root-retain-verify" },
      mutate: (source) => replaceOnce(source, /("root":\{"process_id":\d+,"creation_time_filetime":)\d+/u, "$11", "root creation time"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["matching-root-image"], reasonCode: "root-image-mismatch", runId: currentRunId, stage: "root-retain-verify" },
      mutate: (source) => replaceJsonString(source, "image_path", "C:\\Ticket14\\wrong-root.exe"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["live-root-instance"], reasonCode: "root-not-live", runId: currentRunId, stage: "root-retain-verify" },
      hook: { marker: "finalize-root-live", injection: "$rootIsLive = $false" },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["root-job-membership"], reasonCode: "root-not-job-member", runId: currentRunId, stage: "root-retain-verify" },
      hook: { marker: "finalize-root-membership", injection: "$rootIsMember = $false" },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "root-unverifiable", missingEvidence: ["queryable-root-membership"], reasonCode: "root-retain-or-query-failed", runId: currentRunId, stage: "root-retain-verify" },
      hook: { marker: "finalize-root-membership-query", injection: "throw 'Ticket 14 injected membership query failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "holder-unverifiable", missingEvidence: ["live-holder-instance"], reasonCode: "holder-unavailable", runId: currentRunId, stage: "holder-retain-verify" },
      mutate: (source) => replaceOnce(source, /("holder":\{"process_id":)\d+/u, "$14294967294", "holder process id"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "holder-unverifiable", missingEvidence: ["queryable-holder-instance"], reasonCode: "holder-retain-or-query-failed", runId: currentRunId, stage: "holder-retain-verify" },
      hook: { marker: "finalize-holder-query", injection: "throw 'Ticket 14 injected holder query failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: "security", failureKind: "holder-unverifiable", missingEvidence: ["queryable-holder-instance"], reasonCode: "holder-retain-or-query-failed", runId: currentRunId, stage: "holder-retain-verify" },
      hook: { marker: "finalize-holder-query", injection: nativeAccessDenied },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "holder-unverifiable", missingEvidence: ["matching-holder-creation-time"], reasonCode: "holder-creation-time-mismatch", runId: currentRunId, stage: "holder-retain-verify" },
      mutate: (source) => replaceOnce(source, /("holder":\{"process_id":\d+,"creation_time_filetime":)\d+/u, "$11", "holder creation time"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "holder-unverifiable", missingEvidence: ["matching-holder-image"], reasonCode: "holder-image-mismatch", runId: currentRunId, stage: "holder-retain-verify" },
      mutate: (source) => replaceOnce(source, /("holder":\{"process_id":\d+,"creation_time_filetime":\d+,"image_path":")[^"]+/u, `$1${JSON.stringify("C:\\Ticket14\\wrong-holder.exe").slice(1, -1)}`, "holder image"),
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "holder-unverifiable", missingEvidence: ["live-holder-instance"], reasonCode: "holder-not-live", runId: currentRunId, stage: "holder-retain-verify" },
      hook: { marker: "finalize-holder-live", injection: "$holderIsLive = $false" },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "event-unverifiable", missingEvidence: ["exact-finalize-event"], reasonCode: "finalize-event-unavailable", runId: currentRunId, stage: "event-retain-verify" },
      hook: { marker: "finalize-finalize-event-open", injection: "throw 'Ticket 14 injected Finalize event reopen failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: "security", failureKind: "event-unverifiable", missingEvidence: ["exact-finalize-event"], reasonCode: "finalize-event-unavailable", runId: currentRunId, stage: "event-retain-verify" },
      hook: { marker: "finalize-finalize-event-open", injection: "throw [UnauthorizedAccessException]::new('Ticket 14 injected event reopen access denied.')" },
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "event-unverifiable", missingEvidence: ["exact-holder-exited-event"], reasonCode: "holder-exited-event-unavailable", runId: currentRunId, stage: "event-retain-verify" },
      hook: { marker: "finalize-holder-exited-event-open", injection: "throw 'Ticket 14 injected HolderExited event reopen failure.'" },
    });
    await assertScenario(fixture, {
      expected: { category: "security", failureKind: "record-access", missingEvidence: ["readable-protected-record"], reasonCode: "record-read-failed", runId: null, stage: "protected-path-read-json" },
      hook: { marker: "finalize-record-read", injection: "throw 'Ticket 14 injected record reopen failure.'" },
      shapeTrusted: false,
    });
    await assertScenario(fixture, {
      expected: { category: reconciliation, failureKind: "preflight-unexpected", missingEvidence: ["complete-finalize-authority"], reasonCode: "unexpected-preflight-failure", runId: currentRunId, stage: "unexpected-preflight" },
      hook: { marker: "finalize-unexpected-preflight", injection: "throw 'Ticket 14 injected unexpected preflight failure.'" },
    });
  } finally {
    await cleanupFixture(fixture);
  }
});

test("Ticket 14 public invocations remain hidden and protected-fixture scoped", async () => {
  const source = await readFile(resolve(import.meta.dirname, "windows-helper-ticket-14.test.mjs"), "utf8");
  assert.match(source, /windowsHide: true/gu);
  assert.match(source, /from "\.\/protected-test-fixture\.mjs"/u);
  assert.match(source, /cleanupFixtureRoot, fixtureRoot, mkdtemp/u);
  assert.match(source, /after\(cleanupFixtureRoot\)/u);
});

test("Ticket 14 leaves the protected fixture root empty", async () => {
  const entries = await readdir(fixtureRoot);
  assert.deepEqual(entries, []);
});
