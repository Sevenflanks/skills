import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");
const candidatePath = resolve(import.meta.dirname, "../agent-process-lifecycle/SKILL.md");
const candidateDirectory = resolve(import.meta.dirname, "../agent-process-lifecycle");
const evalsPath = resolve(candidateDirectory, "evals/evals.json");
const windowsReferencePath = resolve(candidateDirectory, "references/windows-self-managed.md");
const failureReferencePath = resolve(candidateDirectory, "references/failure-and-handoff.md");
const smokeRunnerPath = resolve(import.meta.dirname, "run_candidate_smoke.py");
const boundaryContractPath = resolve(import.meta.dirname, "model_visible_contract.py");
const boundaryJsonPath = resolve(import.meta.dirname, "model_visible_json.py");
const boundaryExecutionPath = resolve(import.meta.dirname, "model_visible_execution.py");
const evidenceResultsPath = resolve(import.meta.dirname, "../evidence/model-visible-ticket-16/results.ndjson");
const evidenceSummaryPath = resolve(import.meta.dirname, "../evidence/model-visible-ticket-16/summary.json");
const minimumOutcomeCategories = ["ownership_binding", "stdio", "readiness", "observation", "disposition", "cleanup_or_handoff", "lifecycle_callback"].sort();
const allowedOutcomeStatuses = new Set(["owner handled", "not applicable", "escalated"]);
const executableTiers = new Set(["managed-lifecycle", "external-launcher", "windows-self-managed"]);
const expectedCaseIds = [
  "excluded-synchronous-command",
  "event-invalidation-after-owner-change",
  "managed-owner-opaque-binding",
  "external-launcher-current-run",
  "runtime-owner-handoff",
  "windows-no-viable-tier-blocked",
  "windows-listener-self-managed-stop",
  "generic-gui-self-managed-stop",
  "watcher-self-managed-preserve",
  "preserve-publication-cleanup-unresolved",
  "finite-detached-natural-completion",
  "finite-detached-timeout-stop",
  "tier-failure-reconciliation",
  "identity-mismatch-unresolved",
  "downstream-failure-separation",
  "non-windows-unidentified-owner",
  "non-windows-identified-owner",
];
const expectedMigration = new Map([
  [1, ["converted", "windows-listener-self-managed-stop"]],
  [2, ["retired", null]],
  [3, ["converted", "downstream-failure-separation"]],
  [4, ["retired", null]],
  [5, ["converted", "tier-failure-reconciliation"]],
  [6, ["converted", "runtime-owner-handoff"]],
  [7, ["converted", "watcher-self-managed-preserve"]],
  [8, ["converted", "identity-mismatch-unresolved"]],
  [9, ["retired", null]],
]);

const publishedInventoryHashes = new Map([
  ["README.md", "d3440ac1449a023382b81feeea6edde129e982af09b6c32c9032fbf06c4440d5"],
  ["skills.json", "0c915e0f003b8a4a08d7a96a3fd18e2560f833e765f6fdb7ab3214b24888f7c9"],
  [".claude-plugin/marketplace.json", "783e9a4802d4374cc3ff3d9537d8a60a6330915fc80f45c4d03824cdf327466d"],
  ["skills/playwright-server-lifecycle/SKILL.md", "f6f8bdf3c5052fb9b360fe3ac247eb88cdce5f8e7e2b1601088fb177ea016867"],
]);

function frontmatterValue(document, key) {
  const frontmatter = document.match(/^---\n([\s\S]*?)\n---/u)?.[1] ?? "";
  return frontmatter.match(new RegExp(`^${key}: (.+)$`, "mu"))?.[1];
}

async function evidenceResults() {
  const document = await readFile(evidenceResultsPath, "utf8");
  return document.trim().split(/\r?\n/u).map((line) => {
    const result = JSON.parse(line);
    return { ...result, response: JSON.parse(result.response) };
  });
}

function responseFor(results, identifier) {
  const result = results.find((entry) => entry.identifier === identifier);
  assert.ok(result, `missing evidence result: ${identifier}`);
  return result.response;
}

function assertNoMachineLocalAbsolutePath(value, location) {
  if (typeof value === "string") {
    assert.doesNotMatch(value, /^(?:[A-Za-z]:[\\/]|\\\\|\/)/u, location);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoMachineLocalAbsolutePath(item, `${location}[${index}]`));
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      assertNoMachineLocalAbsolutePath(nested, `${location}.${key}`);
    }
  }
}

function assertStructuredFinalDisposition(response, requested, expectedStatus) {
  assert.equal(typeof response.final_disposition, "object");
  assert.notEqual(response.final_disposition, null);
  assert.equal(response.final_disposition.requested, requested);
  if (expectedStatus !== undefined) assert.equal(response.final_disposition.status, expectedStatus);
}

test("candidate remains manually invoked with routing-bearing frontmatter", async () => {
  const document = await readFile(candidatePath, "utf8");
  const description = frontmatterValue(document, "description");

  assert.equal(frontmatterValue(document, "name"), "agent-process-lifecycle");
  assert.match(description, /Agent-caused local OS process/u);
  assert.match(description, /synchronous commands/u);
  assert.equal(frontmatterValue(document, "disable-model-invocation"), "true");
  assert.equal(document.match(/^\s*version: (.+)$/mu)?.[1], "1.0.0-candidate.10");
});

test("candidate eval migration accounts for every published lifecycle evaluation", async () => {
  const metadata = JSON.parse(await readFile(evalsPath, "utf8"));
  const migration = new Map(metadata.migration_inventory.map((entry) => [entry.legacy_id, [entry.disposition, entry.replacement_case]]));

  assert.equal(metadata.skill_name, "agent-process-lifecycle");
  assert.equal(migration.size, 9);
  assert.deepEqual(migration, expectedMigration);
  assert.equal([...migration.values()].filter(([disposition]) => disposition === "converted").length, 6);
  assert.equal([...migration.values()].filter(([disposition]) => disposition === "retired").length, 3);
});

test("candidate evals define exactly the approved model-visible case set", async () => {
  const metadata = JSON.parse(await readFile(evalsPath, "utf8"));
  const cases = metadata.evals;
  const caseIds = cases.map((entry) => entry.id);
  const nonWindows = cases.filter((entry) => entry.platform === "non-Windows");

  assert.deepEqual(caseIds, expectedCaseIds);
  assert.equal(new Set(caseIds).size, expectedCaseIds.length);
  assert.equal(nonWindows.length, 2);
  assert.deepEqual(nonWindows.map((entry) => entry.id), ["non-windows-unidentified-owner", "non-windows-identified-owner"]);
  for (const entry of cases) {
    assert.deepEqual(entry.assertions.allowed_tools, ["read", "skill"], entry.id);
    assert.ok(Array.isArray(entry.assertions.reference_reads), entry.id);
    assert.ok(Object.keys(entry.assertions.response_equals).length > 0, entry.id);
  }
});

test("candidate references and harness isolate the model-visible seam", async () => {
  const [runner, boundaryContract, boundaryJson, boundaryExecution] = await Promise.all([
    readFile(smokeRunnerPath, "utf8"),
    readFile(boundaryContractPath, "utf8"),
    readFile(boundaryJsonPath, "utf8"),
    readFile(boundaryExecutionPath, "utf8"),
  ]);

  await Promise.all([readFile(windowsReferencePath, "utf8"), readFile(failureReferencePath, "utf8")]);
  assert.doesNotMatch(runner, /trigger-evals\.json|PROMPTS|ThreadPoolExecutor|_routing|routing_fixture/u);
  assert.match(runner, /openai\/gpt-5\.6-sol/u);
  assert.match(runner, /model_visible_execution/u);
  assert.match(boundaryContract, /load_cases/u);
  assert.match(boundaryJson, /class BoundaryError/u);
  assert.match(boundaryExecution, /model_visible_contract/u);
  assert.match(boundaryExecution, /copytree/u);
});

test("published inventory bytes remain pinned and exclude the candidate", async () => {
  for (const [relativePath, expectedHash] of publishedInventoryHashes) {
    const document = await readFile(resolve(repositoryRoot, relativePath));
    const observedHash = createHash("sha256").update(document).digest("hex");
    assert.equal(observedHash, expectedHash, relativePath);
    assert.doesNotMatch(document.toString("utf8"), /agent-process-lifecycle/u, relativePath);
  }
});

test("model-visible evidence excludes machine-local absolute paths", async () => {
  const results = await evidenceResults();

  for (const result of results) {
    assertNoMachineLocalAbsolutePath(result, result.identifier);
  }
});

test("archived model-visible evidence records only passing cases with matching summary counts", async () => {
  const [results, summary] = await Promise.all([evidenceResults(), readFile(evidenceSummaryPath, "utf8").then(JSON.parse)]);

  const resultIds = results.map((result) => result.identifier);
  assert.deepEqual(resultIds, expectedCaseIds);
  assert.deepEqual(summary.case_ids, expectedCaseIds);
  assert.equal(results.length, summary.case_count);
  assert.equal(results.filter((result) => result.passed).length, summary.passed_case_count);
  assert.equal(results.filter((result) => !result.passed).length, summary.failed_case_count);
  for (const result of results) {
    assert.equal(result.valid_stream, true, result.identifier);
    assert.equal(result.candidate_loaded, true, result.identifier);
    assert.deepEqual(result.assertions, [], result.identifier);
    assert.equal(result.passed, true, result.identifier);
  }
});

test("every executable tier reports exactly seven classified responsibility outcomes", async () => {
  const results = await evidenceResults();

  for (const result of results.filter((entry) => executableTiers.has(entry.response.selected_tier))) {
    assert.deepEqual(Object.keys(result.response.minimum_outcomes).sort(), minimumOutcomeCategories, result.identifier);
    for (const status of Object.values(result.response.minimum_outcomes)) assert.ok(allowedOutcomeStatuses.has(status), result.identifier);
  }
});

test("model-visible final dispositions retain requested and expected status fields", async () => {
  const results = await evidenceResults();

  assertStructuredFinalDisposition(responseFor(results, "windows-listener-self-managed-stop"), "Stop", "planned");
  assertStructuredFinalDisposition(responseFor(results, "watcher-self-managed-preserve"), "Preserve", "planned");
  assertStructuredFinalDisposition(responseFor(results, "runtime-owner-handoff"), "Preserve", "handoff");
});

test("mixed Preserve retains its published disposition when cleanup becomes unresolved", async () => {
  const mixedPreserve = responseFor(await evidenceResults(), "preserve-publication-cleanup-unresolved");

  assertStructuredFinalDisposition(mixedPreserve, "Preserve", "preserved");
  assert.equal(mixedPreserve.lifecycle_result.status, "unresolved");
});

test("Preserve callback retains handoff and separation facts", async () => {
  const preserve = responseFor(await evidenceResults(), "watcher-self-managed-preserve");
  const requiredFacts = ["failure_kind", "cleanup_attempt", "cleanup_result", "evidence_paths", "later_owner", "next_owner", "unresolved_reason", "unresolved_items", "lifecycle_result", "downstream_result", "final_disposition", "binding", "record_path", "stdio", "readiness", "stop_method"];

  for (const field of requiredFacts) {
    assert.ok(Object.hasOwn(preserve, field), `Preserve callback lacks ${field}`);
  }
  assertStructuredFinalDisposition(preserve, "Preserve");
});

test("external handoff callback retains responsibility and separation facts", async () => {
  const handoff = responseFor(await evidenceResults(), "runtime-owner-handoff");
  const requiredFacts = ["failure_kind", "cleanup_attempt", "cleanup_result", "evidence_paths", "later_owner", "next_owner", "unresolved_reason", "unresolved_items", "lifecycle_result", "downstream_result", "final_disposition", "owner_binding"];

  for (const field of requiredFacts) {
    assert.ok(Object.hasOwn(handoff, field), `Handoff callback lacks ${field}`);
  }
  assertStructuredFinalDisposition(handoff, "Preserve");
});
