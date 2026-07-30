import assert from "node:assert/strict";
import { access, readFile, readdir, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { dirname, join, parse, resolve } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
import test, { after } from "node:test";
import { cleanupFixtureRoot, fixtureRoot, mkdtemp } from "./protected-test-fixture.mjs";

after(cleanupFixtureRoot);

const execFile = promisify(execFileCallback);
const helperPath = resolve(
  import.meta.dirname,
  "../windows-helper/Invoke-AgentProcessLifecycle.ps1",
);
const holderPath = resolve(import.meta.dirname, "../windows-helper/JobHandleHolder.ps1");

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
    {
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    },
  );

  assert.equal(stderr, "", `PowerShell stderr: ${stderr}`);
  return JSON.parse(stdout);
}

async function createInstrumentedHelper(directory, markers) {
  let helper = await readFile(helperPath, "utf8");
  for (const marker of markers) {
    const needle = `# TEST-INJECTION: ${marker}`;
    assert.ok(helper.includes(needle), `missing test injection marker: ${marker}`);
    const injection = marker === "cleanup-verification"
      ? "$errors.Add('Ticket 12 injected incomplete cleanup verification.')"
      : marker === "preparing-before-create"
        ? "[IO.File]::WriteAllText($Path, '{\"winner\":\"concurrent-launch\"}')"
        : marker === "parent-owner-check"
          ? "$trustedSids = @('S-1-5-18')"
          : marker === "workload-job-handle-probe"
            ? "$ArgumentList = @($ArgumentList) + @('-JobHandleValue', [string]$jobHandle.ToInt64())"
        : `throw 'Ticket 12 injected failure at ${marker}.'`;
    helper = helper.replace(needle, injection);
  }
  const instrumentedPath = join(directory, "Invoke-AgentProcessLifecycle.instrumented.ps1");
  await writeFile(instrumentedPath, helper, "utf8");
  await writeFile(join(directory, "JobHandleHolder.ps1"), await readFile(holderPath, "utf8"), "utf8");
  return instrumentedPath;
}

async function writeLaunchScript(directory, recordPath, launchHelperPath = helperPath, readinessCheck = "$false") {
  const scriptPath = join(directory, "launch.ps1");
  await writeFile(
    scriptPath,
    `$result = & ${powerShellLiteral(launchHelperPath)} -Action Launch -RecordPath ${powerShellLiteral(recordPath)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 20') -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, "stdout.log"))} -StderrPath ${powerShellLiteral(join(directory, "stderr.log"))} -ReadinessIdentity 'ticket-12-never-ready' -ReadinessCheck { param($context) ${readinessCheck} } -ReadinessDeadlineMilliseconds 1000 -RequestedDisposition Stop
$result | ConvertTo-Json -Depth 12 -Compress
`,
    "utf8",
  );
  return scriptPath;
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
  const script = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket12Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $handle = [Ticket12Native]::OpenJobObjectW(4, $false, ${powerShellLiteral(name)}); if ($handle -eq [IntPtr]::Zero) { 'false' } else { [Ticket12Native]::CloseHandle($handle) | Out-Null; 'true' }`;
  const { stdout } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return stdout.trim() === "true";
}

async function assertFailedRunAbsent(result, recordPath) {
  assert.equal(isAlive(result.binding.root_process_id), false, "exact current-run root is absent");
  assert.equal(isAlive(result.evidence.job_holder_process_id), false, "exact current-run holder is absent");
  assert.equal(await namedJobExists(result.binding.job_name), false, "exact current-run Job is absent");
  assert.equal(await pathExists(recordPath), false, "exact current-run record is absent");
}

async function cleanupCurrentRun({ directory, recordPath, result }) {
  recordPath ??= join(directory, "run-record.json");
  let record;
  if (await pathExists(recordPath)) {
    record = JSON.parse(await readFile(recordPath, "utf8"));
  }
  const binding = result?.binding ?? {};
  const rootProcessId = binding.root_process_id ?? record?.root?.process_id;
  const holderProcessId = result?.evidence?.job_holder_process_id ?? record?.holder?.process_id;
  const rootIdentity = binding.root_identity ?? result?.evidence?.root_identity ?? record?.root;
  const holderIdentity = binding.holder_identity ?? result?.evidence?.holder_identity ?? record?.holder;
  const jobName = binding.job_name ?? record?.job_name;
  const finalizeEvent = record?.events?.finalize;
  const resourcesRemain = isAlive(rootProcessId) || isAlive(holderProcessId) || await namedJobExists(jobName) || await pathExists(recordPath);
  const cleanupScript = `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket12CleanupNative { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle); }'; $jobName = ${powerShellLiteral(jobName ?? "")}; if ($jobName) { $job = [Ticket12CleanupNative]::OpenJobObjectW(0x0010000c, $false, $jobName); if ($job -ne [IntPtr]::Zero) { try { [Ticket12CleanupNative]::TerminateJobObject($job, 124) | Out-Null } finally { [Ticket12CleanupNative]::CloseHandle($job) | Out-Null } } }; $eventName = ${powerShellLiteral(finalizeEvent ?? "")}; if ($eventName) { $eventFailure = $null; try { $event = [Threading.EventWaitHandle]::OpenExisting($eventName); try { $event.Set() | Out-Null } finally { $event.Dispose() } } catch { $eventFailure = $_.Exception.Message }; if ($eventFailure) { Write-Verbose "Exact holder event was already absent: $eventFailure" } }; $identities = @(@{ id=${rootProcessId ?? 0}; creation=${powerShellLiteral(String(rootIdentity?.creation_time_filetime ?? ""))}; image=${powerShellLiteral(rootIdentity?.image_path ?? "")} }, @{ id=${holderProcessId ?? 0}; creation=${powerShellLiteral(String(holderIdentity?.creation_time_filetime ?? ""))}; image=${powerShellLiteral(holderIdentity?.image_path ?? "")} }); foreach ($identity in $identities) { if ($identity.id -gt 0) { $process = Get-Process -Id $identity.id -ErrorAction SilentlyContinue; if ($process -and -not $process.WaitForExit(1000)) { if (-not $identity.creation -or -not $identity.image -or [string]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $identity.creation -or -not [string]::Equals($process.Path, $identity.image, [StringComparison]::OrdinalIgnoreCase)) { throw "Refused PID fallback because current process identity is not proven: $($identity.id)" }; Stop-Process -Id $identity.id -Force; $process.WaitForExit(1000) | Out-Null } } }`;
  if (resourcesRemain) await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", cleanupScript], { windowsHide: true });
  assert.equal(isAlive(rootProcessId), false, "emergency cleanup removed the exact root");
  assert.equal(isAlive(holderProcessId), false, "emergency cleanup removed the exact holder");
  assert.equal(await namedJobExists(jobName), false, "emergency cleanup removed the exact named Job");
  if (await pathExists(recordPath)) await unlink(recordPath);
  assert.equal(await pathExists(recordPath), false, "emergency cleanup removed the exact record");
  for (const entry of await readdir(directory, { recursive: true })) {
    if (/\.(tmp|backup)$/u.test(entry) || /(?:readiness|graceful)-.*\.(?:context|result|stdout|stderr|ps1)$/u.test(entry) || /Invoke-AgentProcessLifecycle\.instrumented\.ps1$/u.test(entry)) {
      await rm(join(directory, entry), { force: true });
    }
  }
  await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  assert.equal(await pathExists(directory), false, "fixture directory is absent after emergency cleanup");
}

async function cleanupFixtureWithoutOwnedRun({ directory, recordPath }) {
  recordPath ??= join(directory, "run-record.json");
  if (await pathExists(recordPath)) {
    try {
      const record = JSON.parse(await readFile(recordPath, "utf8"));
      assert.equal(record.schema_version, undefined, "pre-resource fixture must not contain an owned lifecycle binding");
    } catch (error) {
      assert.equal(error.code, "EISDIR", "pre-resource reparse target is a directory, not an owned record");
    }
  }
  await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  assert.equal(await pathExists(directory), false, "pre-resource fixture directory is absent");
}

async function runFaultedLaunch(directory, markers) {
  const recordPath = join(directory, "run-record.json");
  const instrumentedHelper = await createInstrumentedHelper(directory, markers);
  const scriptPath = await writeLaunchScript(directory, recordPath, instrumentedHelper, "$true");
  return {
    recordPath,
    result: await runPowerShell(scriptPath),
  };
}

test("Launch rejects an existing record without overwriting it and returns a machine-readable failure", async () => {
  assert.equal(process.platform, "win32", "ticket 12 is Windows-only");

  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-existing-");
  const recordPath = join(directory, "existing-record.json");
  const originalRecord = '{"owner":"unrelated"}';

  try {
    await writeFile(recordPath, originalRecord, "utf8");
    const result = await runPowerShell(await writeLaunchScript(directory, recordPath));

    assert.equal(result.action, "Launch");
    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(await readFile(recordPath, "utf8"), originalRecord);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("Launch creates a missing safe record parent before establishing ownership", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-new-parent-");
  const recordPath = join(directory, "new", "nested", "run-record.json");
  let result;

  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["stdio-isolation"]);
    result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));

    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "stdio-isolation");
    assert.equal(await pathExists(join(directory, "new", "nested")), true);
    assert.equal(await pathExists(recordPath), false, "fail-closed cleanup removes the new preparing record");
  } finally {
    await cleanupCurrentRun({ directory, recordPath, result });
  }
});

test("Launch rejects an existing directory and concurrent attempts at the same record path", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-exclusive-");
  const directoryTarget = join(directory, "record-directory");
  const concurrentRecord = join(directory, "concurrent-record.json");
  let results = [];

  try {
    await (await import("node:fs/promises")).mkdir(directoryTarget);
    const directoryResult = await runPowerShell(await writeLaunchScript(directory, directoryTarget));
    assert.equal(directoryResult.lifecycle_result.status, "failed");
    assert.equal(directoryResult.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(directoryResult.lifecycle_result.cleanup.attempted, false);

    const firstScript = await writeLaunchScript(directory, concurrentRecord);
    const secondScript = join(directory, "concurrent-launch.ps1");
    await writeFile(secondScript, await readFile(firstScript, "utf8"), "utf8");
    const [first, second] = await Promise.all([
      runPowerShell(firstScript),
      runPowerShell(secondScript),
    ]);
    results = [first, second];
    assert.equal(results.filter((result) => result.lifecycle_result.failure_kind === "record-preparation").length, 1);
    assert.equal(results.filter((result) => result.lifecycle_result.failure_kind === "readiness").length, 1);
    assert.equal(await pathExists(concurrentRecord), false, "both concurrent Launch results clean their temporary ownership state");
  } finally {
    await cleanupCurrentRun({ directory, recordPath: concurrentRecord, result: results.find((item) => item.binding.root_process_id) });
  }
});

test("Launch failure injection cleans retained current-run authority for stdio, assignment, and record publication", async () => {
  for (const [faultPoint, failureKind] of [
    [["stdio-isolation"], "stdio-isolation"],
    [["job-assignment"], "job-assignment"],
    [["bound-record-publication"], "record-publication"],
    [["ready-record-publication"], "record-publication"],
  ]) {
    const directory = await mkdtemp(`agent-process-lifecycle-ticket-12-${faultPoint}-`);
    let result;
    let recordPath;
    try {
      ({ recordPath, result } = await runFaultedLaunch(directory, faultPoint));

      assert.equal(result.action, "Launch");
      assert.equal(result.lifecycle_result.status, "failed");
      assert.equal(result.lifecycle_result.failure_kind, failureKind);
      assert.equal(result.lifecycle_result.cleanup.attempted, true);
      assert.equal(result.lifecycle_result.cleanup.status, "completed");
      assert.equal(result.lifecycle_result.cleanup.root_absent, true);
      assert.equal(result.lifecycle_result.cleanup.holder_absent, true);
      assert.equal(result.lifecycle_result.cleanup.named_job_absent, true);
      assert.equal(result.lifecycle_result.cleanup.record_absent, true);
      assert.equal(result.binding.root_identity.process_id, result.binding.root_process_id);
      assert.ok(result.binding.root_identity.creation_time_filetime);
      assert.ok(result.binding.root_identity.image_path);
      assert.equal(result.binding.holder_identity.process_id, result.evidence.job_holder_process_id);
      assert.ok(result.binding.holder_identity.creation_time_filetime);
      assert.ok(result.binding.holder_identity.image_path);
      await assertFailedRunAbsent(result, recordPath);
    } finally {
      await cleanupCurrentRun({ directory, recordPath, result });
    }
  }
});

test("Write-Record artifact failure markers publish exact cleanup evidence and leave no fixture residue", async () => {
  for (const [markers, label, expectsArtifactEvidence] of [
    [["write-record-after-temp-create"], "write-record-after-temp-create", false],
    [["write-record-before-replace"], "write-record-before-replace", false],
    [["write-record-before-replace", "write-record-temp-delete"], "write-record-temp-delete", true],
    [["write-record-backup-delete"], "write-record-backup-delete", true],
  ]) {
    const directory = await mkdtemp(`agent-process-lifecycle-ticket-12-${label}-`);
    const recordPath = join(directory, "run-record.json");
    let result;
    try {
      const instrumentedHelper = await createInstrumentedHelper(directory, markers);
      result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper, "$true"));

      assert.equal(result.lifecycle_result.status, "failed", label);
      assert.equal(result.lifecycle_result.failure_kind, "record-publication", label);
      assert.equal(result.lifecycle_result.cleanup.status, "completed", label);
      const artifacts = result.lifecycle_result.cleanup.publication_artifacts;
      if (expectsArtifactEvidence) {
        assert.equal(artifacts.length, 2, label);
        assert.ok(artifacts.some((artifact) => artifact.existed_before_cleanup === true), label);
        assert.ok(artifacts.every((artifact) => artifact.absent === true), label);
        assert.ok(artifacts.every((artifact) => /\.tmp(?:\.backup)?$/u.test(artifact.path)), label);
      } else {
        assert.equal(artifacts.length, 0, label);
      }
      await assertFailedRunAbsent(result, recordPath);
    } finally {
      await cleanupCurrentRun({ directory, recordPath, result });
    }
  }
});

test("publication artifact that survives Write-Record and outer cleanup is unresolved with exact evidence", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-artifact-unresolved-");
  const recordPath = join(directory, "run-record.json");
  let result;
  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["write-record-before-replace", "write-record-temp-delete", "launch-cleanup-artifact-delete"]);
    result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper, "$true"));
    assert.equal(result.lifecycle_result.status, "unresolved");
    assert.equal(result.lifecycle_result.cleanup.status, "unresolved");
    const artifact = result.lifecycle_result.cleanup.publication_artifacts.find((item) => item.existed_before_cleanup === true);
    assert.ok(artifact);
    assert.equal(artifact.absent, false);
    assert.match(artifact.path, /\.tmp$/u);
    assert.match(result.lifecycle_result.unresolved_reason, /Publication artifact cleanup failed/u);
    assert.equal(isAlive(result.binding.root_process_id), false);
    assert.equal(isAlive(result.evidence.job_holder_process_id), false);
    assert.equal(await namedJobExists(result.binding.job_name), false);
    assert.equal(await pathExists(recordPath), false);
    assert.equal(await pathExists(artifact.path), true, "the artifact remains until test-owned cleanup");
  } finally {
    await cleanupCurrentRun({ directory, recordPath, result });
  }
});

test("Launch rejects a reparse parent before creating ownership state", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-reparse-");
  const target = join(directory, "target");
  const redirect = join(directory, "redirect");
  const recordPath = join(redirect, "run-record.json");

  try {
    await (await import("node:fs/promises")).mkdir(target);
    await symlink(target, redirect, "junction");
    const result = await runPowerShell(await writeLaunchScript(directory, recordPath));

    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.match(result.lifecycle_result.error, /reparse point/u);
    assert.equal(await pathExists(join(target, "run-record.json")), false);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("Launch rejects a target-path junction without altering its sentinel or creating ownership", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-target-reparse-");
  const target = join(directory, "unrelated-target");
  const recordPath = join(directory, "run-record.json");
  const original = '{"owner":"unrelated"}';
  let result;
  try {
    await (await import("node:fs/promises")).mkdir(target);
    await writeFile(join(target, "sentinel.json"), original, "utf8");
    await symlink(target, recordPath, "junction");
    result = await runPowerShell(await writeLaunchScript(directory, recordPath));

    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(result.binding.root_process_id, null);
    assert.equal(result.evidence.job_holder_process_id, null);
    assert.equal(result.binding.job_name, null);
    assert.match(result.lifecycle_result.error, /RecordPath target is a reparse point/u);
    assert.equal(await readFile(join(target, "sentinel.json"), "utf8"), original);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("Launch rejects a parent that grants an untrusted principal record-entry mutation rights", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-unsafe-parent-");
  const unsafeParent = join(directory, "unsafe");
  const recordPath = join(unsafeParent, "run-record.json");

  try {
    const aclScript = `$parent = ${powerShellLiteral(unsafeParent)}; [IO.Directory]::CreateDirectory($parent) | Out-Null; $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($parent)); $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0'); $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles, [Security.AccessControl.AccessControlType]::Allow)); [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($parent), $security)`;
    await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", aclScript], { windowsHide: true });
    const result = await runPowerShell(await writeLaunchScript(directory, recordPath));

    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.match(result.lifecycle_result.error, /untrusted principal/u);
    assert.equal(await pathExists(recordPath), false);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("preparing-record validation failure removes the exact newly created record", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-preparing-");
  const recordPath = join(directory, "run-record.json");

  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["preparing-record-validation"]);
    const result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));

    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(await pathExists(recordPath), false);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("preparing-record-after-create failure removes only the current invocation record", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-preparing-after-create-");
  const recordPath = join(directory, "run-record.json");
  let result;
  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["preparing-record-after-create"]);
    result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));
    assert.equal(result.lifecycle_result.status, "failed");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(await pathExists(recordPath), false, "the exact CreateNew record is removed before Launch creates authority");
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("a concurrent CreateNew winner remains untouched when this Launch loses the creation race", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-create-race-");
  const recordPath = join(directory, "run-record.json");

  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["preparing-before-create"]);
    const result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));

    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(result.lifecycle_result.cleanup.attempted, false);
    assert.equal(await readFile(recordPath, "utf8"), '{"winner":"concurrent-launch"}');
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("outer Launch reports unresolved when the exact preparing record remains through retry cleanup", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-preparing-unresolved-");
  const recordPath = join(directory, "run-record.json");
  let result;
  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["preparing-record-validation", "preparing-record-delete", "launch-cleanup-record-delete"]);
    result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));
    assert.equal(result.lifecycle_result.status, "unresolved");
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.equal(await pathExists(recordPath), true);
  } finally {
    await cleanupCurrentRun({ directory, recordPath, result });
  }
});

test("instrumented owner-check boundary proves an untrusted parent owner is rejected", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-owner-");
  const recordPath = join(directory, "run-record.json");
  let result;
  try {
    const instrumentedHelper = await createInstrumentedHelper(directory, ["parent-owner-check"]);
    result = await runPowerShell(await writeLaunchScript(directory, recordPath, instrumentedHelper));
    assert.equal(result.lifecycle_result.failure_kind, "record-preparation");
    assert.match(result.lifecycle_result.error, /untrusted owner/u);
  } finally {
    await cleanupFixtureWithoutOwnedRun({ directory, recordPath });
  }
});

test("Launch reports unresolved when its test-only cleanup verification seam cannot confirm completion", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-unresolved-");
  const recordPath = join(directory, "run-record.json");
  let result;
  try {
    ({ result } = await runFaultedLaunch(
      directory,
      ["job-assignment", "cleanup-verification"],
    ));

    assert.equal(result.lifecycle_result.status, "unresolved");
    assert.equal(result.lifecycle_result.failure_kind, "job-assignment");
    assert.equal(result.lifecycle_result.cleanup.status, "unresolved");
    assert.match(result.lifecycle_result.unresolved_reason, /incomplete cleanup verification/u);
    assert.equal(await pathExists(recordPath), false, "the simulation does not leak a fixture");
  } finally {
    await cleanupCurrentRun({ directory, recordPath, result });
  }
});

test("Launch publishes a protected bound record before resuming a stdio-isolated workload", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-ordering-");
  const recordPath = join(directory, "run-record.json");
  const readyPath = join(directory, "ready.json");
  const stopEventName = `Local\\AgentProcessLifecycle.Ticket12.Stop.${Date.now()}`;
  const workloadPath = join(directory, "workload.ps1");
  const launchPath = join(directory, "launch.ps1");
  const finalizePath = join(directory, "finalize.ps1");
  let launch;

  try {
    await writeFile(workloadPath, `param([string]$RecordPath, [string]$ReadyPath, [string]$StopEventName, [Int64]$JobHandleValue)
$stopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
try {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Ticket12WorkloadNative { [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length, IntPtr returnedLength); }'
    $record = [IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json -AsHashtable
    $jobQuerySucceeded = [Ticket12WorkloadNative]::QueryInformationJobObject([IntPtr]$JobHandleValue, 1, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    [IO.File]::WriteAllText($ReadyPath, ([pscustomobject]@{ record = $record; job_query_succeeded = $jobQuerySucceeded; job_query_error = [Runtime.InteropServices.Marshal]::GetLastWin32Error() } | ConvertTo-Json -Compress))
    [Console]::Error.WriteLine('ticket-12-stdio-isolated')
    $stopEvent.WaitOne(15000) | Out-Null
}
finally { $stopEvent.Dispose() }
`, "utf8");
    const instrumentedHelper = await createInstrumentedHelper(directory, ["workload-job-handle-probe"]);
    await writeFile(launchPath, `$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ${powerShellLiteral(stopEventName)})
try {
    $result = & ${powerShellLiteral(instrumentedHelper)} -Action Launch -RecordPath ${powerShellLiteral(recordPath)} -Executable $PSHOME\\pwsh.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ${powerShellLiteral(workloadPath)}, '-RecordPath', ${powerShellLiteral(recordPath)}, '-ReadyPath', ${powerShellLiteral(readyPath)}, '-StopEventName', ${powerShellLiteral(stopEventName)}) -WorkingDirectory ${powerShellLiteral(directory)} -StdoutPath ${powerShellLiteral(join(directory, "stdout.log"))} -StderrPath ${powerShellLiteral(join(directory, "stderr.log"))} -ReadinessIdentity 'ticket-12-bound-record' -ReadinessContext @{ ready_path = ${powerShellLiteral(readyPath)} } -ReadinessCheck { param($context) Test-Path -LiteralPath $context.ready_path } -ReadinessDeadlineMilliseconds 5000 -RequestedDisposition Stop
    $result | ConvertTo-Json -Depth 12 -Compress
}
finally { $stopEvent.Dispose() }
`, "utf8");
    launch = await runPowerShell(launchPath);
    const observedRecord = JSON.parse(await readFile(readyPath, "utf8"));
    assert.equal(launch.lifecycle_result.status, "success");
    assertProtectedFixtureRecordPath(launch.binding.record_path);
    assert.equal(observedRecord.record.state, "bound", "the workload sees the bound record at its first instruction");
    assert.equal(observedRecord.record.root.process_id, launch.binding.root_process_id);
    assert.equal(observedRecord.job_query_succeeded, false, "workload cannot query the parent Job from its numeric handle value");

    const readyRecord = JSON.parse(await readFile(recordPath, "utf8"));
    const { stdout: expectedExecutable } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "[IO.Path]::GetFullPath(\"$PSHOME\\pwsh.exe\")"], { windowsHide: true });
    assert.equal(readyRecord.state, "ready");
    assert.equal(readyRecord.executable, expectedExecutable.trim());
    assert.deepEqual(readyRecord.arguments.slice(0, -2), ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", workloadPath, "-RecordPath", recordPath, "-ReadyPath", readyPath, "-StopEventName", stopEventName]);
    assert.equal(readyRecord.arguments.at(-2), "-JobHandleValue");
    assert.match(readyRecord.arguments.at(-1), /^\d+$/u);
    assert.equal(readyRecord.working_directory, directory);
    assert.equal(readyRecord.readiness.result, "succeeded");
    assert.ok(Date.parse(readyRecord.readiness.completed_at_utc));
    assert.equal(readyRecord.later_owner, null);

    const aclScript = `$security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new(${powerShellLiteral(recordPath)})); $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; [pscustomobject]@{ protected = $security.AreAccessRulesProtected; owner = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value; current_user = $sid; allow_sids = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq ([Security.AccessControl.AccessControlType]::Allow) | ForEach-Object { $_.IdentityReference.Value }); allow_rights = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq ([Security.AccessControl.AccessControlType]::Allow) | ForEach-Object { [string]$_.FileSystemRights }) } | ConvertTo-Json -Compress`;
    const { stdout } = await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", aclScript], { windowsHide: true });
    const acl = JSON.parse(stdout);
    assert.equal(acl.protected, true);
    assert.equal(acl.owner, acl.current_user);
    assert.deepEqual(acl.allow_sids, [acl.current_user]);
    assert.match(acl.allow_rights[0], /FullControl/u);

    await writeFile(finalizePath, `$result = & ${powerShellLiteral(helperPath)} -Action Finalize -RecordPath ${powerShellLiteral(recordPath)} -Disposition Stop -GracefulDeadlineMilliseconds 5000 -GracefulContext @{ stop_event_name = ${powerShellLiteral(stopEventName)} } -GracefulAction { param($binding) $event = [Threading.EventWaitHandle]::OpenExisting($binding.graceful_context.stop_event_name); try { $event.Set() | Out-Null } finally { $event.Dispose() } }; $result | ConvertTo-Json -Depth 12 -Compress`, "utf8");
    const finalized = await runPowerShell(finalizePath);
    assert.equal(finalized.lifecycle_result.status, "success");
    assert.equal(await pathExists(recordPath), false);
    assert.match(await readFile(join(directory, "stderr.log"), "utf8"), /ticket-12-stdio-isolated/u);
  } finally {
    await cleanupCurrentRun({ directory, recordPath, result: launch });
  }
});

test("Ticket 12 emergency cleanup refuses a mismatched PID identity without terminating an unrelated process", async () => {
  const directory = await mkdtemp("agent-process-lifecycle-ticket-12-pid-mismatch-");
  const fixture = spawn(process.env.SystemRoot ? join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe") : "pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 20"], { windowsHide: true });
  try {
    assert.ok(fixture.pid);
    await assert.rejects(
      cleanupCurrentRun({
        directory,
        result: {
          binding: { root_process_id: fixture.pid, root_identity: { process_id: fixture.pid, creation_time_filetime: "1", image_path: "C:\\mismatch.exe" } },
          evidence: {},
        },
      }),
      /Refused PID fallback/u,
    );
    assert.equal(isAlive(fixture.pid), true, "mismatched identity leaves unrelated fixture process alive");
  } finally {
    if (isAlive(fixture.pid)) {
      fixture.kill();
      await once(fixture, "exit");
    }
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    assert.equal(await pathExists(directory), false);
  }
});

test("Launch keeps the Job handle outside the workload inheritance allowlist", async () => {
  const helper = await readFile(helperPath, "utf8");

  assert.match(helper, /StartSuspended[\s\S]*?new IntPtr\[\] \{ input, output, error \}/u);
  assert.match(helper, /StartHolder[\s\S]*?new IntPtr\[\] \{ jobHandle \}/u);
  assert.doesNotMatch(helper, /StartSuspended[\s\S]*?new IntPtr\[\] \{[^}]*jobHandle/u);
});
