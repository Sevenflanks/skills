import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp as makeTemporaryDirectory, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

const fixtureModuleUrl = new URL("./protected-test-fixture.mjs", import.meta.url).href;

function runNode(argumentsList, environment = process.env) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(process.execPath, argumentsList, {
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("close", (code, signal) => {
      resolveResult({ code, signal, stderr, stdout });
    });
  });
}

function environmentWithRunId(runId) {
  const environment = {
    ...process.env,
    AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID: runId,
  };
  delete environment.NODE_TEST_CONTEXT;
  return environment;
}

function environmentWithoutRunId() {
  const environment = { ...process.env };
  delete environment.AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID;
  delete environment.NODE_TEST_CONTEXT;
  return environment;
}

function parseFixtureRoot(output) {
  return JSON.parse(output.trim()).fixtureRoot;
}

function testRunnerFixtureRoot(output) {
  const match = output.match(/FIXTURE_ROOT_JSON=(\{.+\})/u);
  assert.ok(match, `child suite did not report its fixture root:\n${output}`);
  return JSON.parse(match[1]).fixtureRoot;
}

test("separate processes receive distinct protected run roots beneath USERPROFILE", async () => {
  const probe = `import { fixtureRoot } from ${JSON.stringify(fixtureModuleUrl)}; console.log(JSON.stringify({ fixtureRoot }));`;
  const [first, second] = await Promise.all([
    runNode(["--input-type=module", "--eval", probe], environmentWithoutRunId()),
    runNode(["--input-type=module", "--eval", probe], environmentWithoutRunId()),
  ]);

  assert.equal(first.code, 0, first.stderr);
  assert.equal(second.code, 0, second.stderr);

  const firstRunRoot = dirname(parseFixtureRoot(first.stdout));
  const secondRunRoot = dirname(parseFixtureRoot(second.stdout));

  assert.notEqual(firstRunRoot, secondRunRoot, "separate processes must not share a fixture run root");
  assert.match(basename(firstRunRoot), /^\.agent-process-lifecycle-test-[A-Za-z0-9][A-Za-z0-9-]{0,63}$/u);
  assert.match(basename(secondRunRoot), /^\.agent-process-lifecycle-test-[A-Za-z0-9][A-Za-z0-9-]{0,63}$/u);
});

test("separate suites under one explicit run ID receive distinct suite roots", async () => {
  const temporaryRoot = await makeTemporaryDirectory(join(tmpdir(), "agent-process-lifecycle-fixture-suites-"));
  const runId = `fixture-suite-${process.pid}`;
  const suiteSource = `
import test, { after } from "node:test";
import { rm } from "node:fs/promises";
import { cleanupFixtureRoot, fixtureRoot, mkdtemp } from ${JSON.stringify(fixtureModuleUrl)};

test("reports fixture root", async () => {
  const directory = await mkdtemp("suite-namespace-");
  await rm(directory, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
  console.log("FIXTURE_ROOT_JSON=" + JSON.stringify({ fixtureRoot }));
});

after(cleanupFixtureRoot);
`;
  const firstSuite = join(temporaryRoot, "suite-alpha.test.mjs");
  const secondSuite = join(temporaryRoot, "suite-beta.test.mjs");

  try {
    await Promise.all([writeFile(firstSuite, suiteSource, "utf8"), writeFile(secondSuite, suiteSource, "utf8")]);
    const [first, second] = await Promise.all([
      runNode(["--test", firstSuite], environmentWithRunId(runId)),
      runNode(["--test", secondSuite], environmentWithRunId(runId)),
    ]);

    assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
    assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);

    const firstSuiteRoot = testRunnerFixtureRoot(`${first.stdout}\n${first.stderr}`);
    const secondSuiteRoot = testRunnerFixtureRoot(`${second.stdout}\n${second.stderr}`);
    const expectedRunRoot = join(process.env.USERPROFILE, `.agent-process-lifecycle-test-${runId}`);

    assert.equal(dirname(firstSuiteRoot), expectedRunRoot);
    assert.equal(dirname(secondSuiteRoot), expectedRunRoot);
    assert.notEqual(firstSuiteRoot, secondSuiteRoot, "separate suites must not share a fixture namespace");
  } finally {
    await rm(temporaryRoot, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
  }
});

test("invalid explicit run IDs are rejected before a fixture namespace is exposed", async () => {
  const probe = `import ${JSON.stringify(fixtureModuleUrl)};`;
  const result = await runNode(["--input-type=module", "--eval", probe], environmentWithRunId("invalid/run-id"));

  assert.notEqual(result.code, 0, "a slash in AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID must reject module initialization");
  assert.match(result.stderr, /AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID|run ID/u);
});

test("nonempty suite cleanup preserves evidence and fails without deleting its namespace", async () => {
  const runId = `fixture-cleanup-${process.pid}`;
  const exercise = `
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { cleanupFixtureRoot, fixtureRoot, mkdtemp } from ${JSON.stringify(fixtureModuleUrl)};

const directory = await mkdtemp("cleanup-evidence-");
const evidencePath = join(directory, "evidence.txt");
await writeFile(evidencePath, "preserve me", "utf8");
await assert.rejects(cleanupFixtureRoot(), /not empty/u);
assert.equal(existsSync(evidencePath), true, "cleanup must preserve nonempty fixture evidence");
await rm(directory, { force: true, maxRetries: 10, recursive: true, retryDelay: 50 });
await cleanupFixtureRoot();
console.log(JSON.stringify({ fixtureRoot }));
`;
  const result = await runNode(["--input-type=module", "--eval", exercise], environmentWithRunId(runId));

  assert.equal(result.code, 0, `${result.stdout}\n${result.stderr}`);
  assert.equal(dirname(parseFixtureRoot(result.stdout)), join(process.env.USERPROFILE, `.agent-process-lifecycle-test-${runId}`));
});
