import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");
const scratchRoot = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
const candidateRoot = resolve(scratchRoot, "candidate");
const candidatePath = resolve(candidateRoot, "agent-process-lifecycle/SKILL.md");
const candidateReadmePath = resolve(candidateRoot, "agent-process-lifecycle/README.md");
const candidateRelativePath = ".scratch/agent-process-lifecycle-skill/candidate/agent-process-lifecycle/SKILL.md";
const modelEvidenceRoot = resolve(candidateRoot, "evidence/model-visible-ticket-16");
const benchmarkRoot = resolve(scratchRoot, "benchmarks/02-trigger-baseline");
const gateRoot = resolve(benchmarkRoot, "results/ticket-17-release-gate-20260731T162044Z");
const helperPath = resolve(candidateRoot, "windows-helper/Invoke-AgentProcessLifecycle.ps1");
const holderPath = resolve(candidateRoot, "windows-helper/JobHandleHolder.ps1");
const archivedCandidateCommit = "e5d26484b731424d47841440fb658c6a1bda5450";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function normalizedTextHash(document) {
  return sha256(normalizeLineEndings(document));
}

function normalizeLineEndings(document) {
  return document.replace(/\r\n/gu, "\n");
}

function reconstructSingleLfLine(document, lineNumber) {
  let line = 1;
  return normalizeLineEndings(document).replace(/\n/gu, () => {
    const lineEnding = line === lineNumber ? "\n" : "\r\n";
    line += 1;
    return lineEnding;
  });
}

function frontmatterValue(document, key) {
  const frontmatter = document.match(/^---\r?\n([\s\S]*?)\r?\n---/u)?.[1] ?? "";
  return frontmatter.match(new RegExp(`^${key}: (.+?)\r?$`, "mu"))?.[1];
}

function descriptionLine(description) {
  return `description: ${description}`;
}

function readJson(path) {
  return readFile(path, "utf8").then(JSON.parse);
}

async function hashFile(path) {
  return sha256(await readFile(path));
}

function archivedCandidateSkill() {
  return execFileSync("git", ["show", `${archivedCandidateCommit}:${candidateRelativePath}`], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: { ...process.env, GIT_MASTER: "1" },
  });
}

function routingSourcePath(relativePath) {
  if (relativePath === "inputs/trigger-evals.json") return resolve(benchmarkRoot, "trigger-evals.json");
  if (relativePath === "inputs/variants.json") return resolve(benchmarkRoot, "variants.json");
  if (relativePath === "variants/current/SKILL.md") return resolve(repositoryRoot, "skills/playwright-server-lifecycle/SKILL.md");
  if (relativePath === "variants/candidate/SKILL.md") return candidatePath;
  return resolve(benchmarkRoot, relativePath);
}

test("Ticket 18 composes Ticket 16 evidence only through the approved description substitution", async () => {
  const [manifest, summary, resultsDocument, candidateDocument] = await Promise.all([
    readJson(resolve(modelEvidenceRoot, "manifest.json")),
    readJson(resolve(modelEvidenceRoot, "summary.json")),
    readFile(resolve(modelEvidenceRoot, "results.ndjson"), "utf8"),
    readFile(candidatePath, "utf8"),
  ]);
  const results = resultsDocument.trim().split(/\r?\n/gu).map(JSON.parse);

  assert.equal(summary.case_count, 17);
  assert.equal(summary.passed_case_count, 17);
  assert.equal(summary.failed_case_count, 0);
  assert.equal(summary.archived_evidence_rerun, false);
  assert.equal(summary.archived_evidence_recalculated, false);
  assert.equal(results.length, 17);
  for (const result of results) {
    assert.equal(result.valid_stream, true, result.identifier);
    assert.equal(result.candidate_loaded, true, result.identifier);
    assert.deepEqual(result.assertions, [], result.identifier);
    assert.equal(result.passed, true, result.identifier);
  }

  assert.equal(manifest.input_hash_mode, "sha256-lf-normalized-text");
  assert.equal(manifest.archived_evidence_policy, "Archived routing and Windows runtime evidence were hashed only; neither was rerun or recalculated.");
  for (const [relativePath, expectedHash] of Object.entries(manifest.inputs)) {
    if (relativePath === candidateRelativePath) continue;
    assert.equal(normalizedTextHash(await readFile(resolve(repositoryRoot, relativePath), "utf8")), expectedHash, relativePath);
  }

  const archivedDocument = archivedCandidateSkill();
  const archivedDescription = frontmatterValue(archivedDocument, "description");
  const currentDescription = frontmatterValue(candidateDocument, "description");
  assert.ok(archivedDescription);
  assert.ok(currentDescription);
  assert.notEqual(currentDescription, archivedDescription);
  // The description is the only approved composition seam; every other LF-normalized byte must retain Ticket 16 evidence.
  const reconstructed = candidateDocument.replace(descriptionLine(currentDescription), descriptionLine(archivedDescription));
  assert.equal(normalizeLineEndings(reconstructed), archivedDocument);
  assert.equal(normalizedTextHash(reconstructed), "ae94ff183aa566dac5f32379530d449709288c7d6617ff73ed5868e97ce68a16");
  assert.equal(normalizedTextHash(reconstructed), manifest.inputs[candidateRelativePath]);
});

test("Ticket 18 preflight validates Ticket 17, Windows acceptance, and structural-only validation", async () => {
  const [finalDecision, baseAggregate, workerCalibration, baseManifest, variants, issue17, windowsReceipt, packageJson, validator, candidateDocument, spec, benchmarkSpec, readme] = await Promise.all([
    readJson(resolve(gateRoot, "final-decision/decision.json")),
    readJson(resolve(gateRoot, "base/aggregate.json")),
    readJson(resolve(gateRoot, "worker-calibration.json")),
    readJson(resolve(gateRoot, "base/manifest.json")),
    readJson(resolve(benchmarkRoot, "variants.json")),
    readFile(resolve(scratchRoot, "issues/17-routing-release-gate.md"), "utf8"),
    readFile(resolve(candidateRoot, "evidence/windows-helper-acceptance.md"), "utf8"),
    readJson(resolve(repositoryRoot, "package.json")),
    readFile(resolve(repositoryRoot, "scripts/validate-skills.mjs"), "utf8"),
    readFile(candidatePath, "utf8"),
    readFile(resolve(scratchRoot, "spec.md"), "utf8"),
    readFile(resolve(benchmarkRoot, "trigger_benchmark/spec.py"), "utf8"),
    readFile(candidateReadmePath, "utf8"),
  ]);

  assert.equal(finalDecision.status, "passed");
  assert.equal(finalDecision.outcome, "pass");
  assert.equal(finalDecision.exit_code, 0);
  assert.equal(finalDecision.total_invalid_attempts, 0);
  assert.deepEqual(finalDecision.required_targeted_prompt_ids, []);
  assert.deepEqual(finalDecision.targeted, {});
  assert.equal(finalDecision.parity_status, "matched");
  assert.equal(finalDecision.safety_status, "passed");
  assert.deepEqual((await readdir(gateRoot)).sort(), ["base", "base-decision", "calibration-w1", "calibration-w2", "calibration-w4", "final-decision", "worker-calibration.json"]);
  assert.deepEqual(finalDecision.fixed_base_counts, {
    current: {
      positive: { triggered: 24, valid: 24, invalid_attempts: 0 },
      negative: { triggered: 23, valid: 24, invalid_attempts: 0 },
    },
    candidate: {
      positive: { triggered: 24, valid: 24, invalid_attempts: 0 },
      negative: { triggered: 0, valid: 24, invalid_attempts: 0 },
    },
  });
  assert.equal(baseAggregate.variants.current.positive.triggered_trials, 24);
  assert.equal(baseAggregate.variants.current.negative.triggered_trials, 23);
  assert.equal(baseAggregate.variants.candidate.positive.triggered_trials, 24);
  assert.equal(baseAggregate.variants.candidate.negative.triggered_trials, 0);

  assert.equal(workerCalibration.status, "passed");
  assert.deepEqual(workerCalibration.entries.map(({ workers, complete, parity }) => ({ workers, complete, parity })), [
    { workers: 1, complete: true, parity: "match" },
    { workers: 2, complete: true, parity: "match" },
    { workers: 4, complete: true, parity: "match" },
  ]);
  assert.deepEqual(workerCalibration.selected, {
    workers: 4,
    complete: true,
    parity: "match",
    run_path: "calibration-w4",
    manifest_sha256: "44d89c610ed239e4be7cc43f86878655ec7b9f1c5ca7a3d9415f95d6ccaa0dd9",
    reason_codes: [],
  });
  for (const entry of workerCalibration.entries) {
    assert.equal(await hashFile(resolve(gateRoot, entry.run_path, "manifest.json")), entry.manifest_sha256, entry.run_path);
  }

  assert.deepEqual(variants.variants, [
    { id: "current", skill_path: "../../../../skills/playwright-server-lifecycle/SKILL.md" },
    { id: "candidate", skill_path: "../../candidate/agent-process-lifecycle/SKILL.md" },
  ]);
  const gateBoundSources = [
    "evaluate_routing_release_gate.py",
    "run_trigger_baseline.py",
    "inputs/trigger-evals.json",
    "inputs/variants.json",
    "variants/current/SKILL.md",
  ];
  for (const relativePath of gateBoundSources) {
    const expectedHash = finalDecision.source_hashes[relativePath];
    const sourcePath = routingSourcePath(relativePath);
    assert.equal(await hashFile(sourcePath), expectedHash, relativePath);
  }
  // This reconstructs only Git checkout line endings, not a semantic evidence exception.
  assert.equal(sha256(reconstructSingleLfLine(benchmarkSpec, 9)), finalDecision.source_hashes["trigger_benchmark/spec.py"]);
  assert.equal(sha256(reconstructSingleLfLine(candidateDocument, 3)), finalDecision.source_hashes["variants/candidate/SKILL.md"]);
  const candidateDescription = frontmatterValue(candidateDocument, "description");
  const benchmarkCandidateDescription = benchmarkSpec.match(/^CANDIDATE_DESCRIPTION = "(.+)"$/mu)?.[1];
  assert.equal(benchmarkCandidateDescription, candidateDescription);
  assert.ok(spec.includes(candidateDescription));
  for (const [relativePath, expectedHash] of Object.entries(finalDecision.artifact_hashes)) {
    assert.equal(await hashFile(resolve(gateRoot, relativePath)), expectedHash, relativePath);
  }
  assert.equal(await hashFile(resolve(gateRoot, "base/aggregate.json")), baseManifest.artifact_hashes["aggregate.json"]);
  assert.equal(await hashFile(resolve(gateRoot, "base/manifest.json")), finalDecision.artifact_hashes["base/manifest.json"]);
  assert.match(issue17, /privacy scan clean；fixture residue `0`/u);
  assert.match(issue17, /Gate：`ticket-17-release-gate-20260731T162044Z`/u);
  assert.equal(variants.variants.find(({ id }) => id === "candidate")?.skill_path, "../../candidate/agent-process-lifecycle/SKILL.md");
  assert.match(issue17, /exact model-facing description.*僅為 classify、Preserve、observe、check status 或 use/u);

  assert.match(windowsReceipt, /PowerShell parser：PASS/u);
  assert.match(windowsReceipt, /Node syntax：PASS，6\/6/u);
  assert.match(windowsReceipt, /Ticket 15 targeted runtime：PASS/u);
  assert.match(windowsReceipt, /Node 45 including nested，pass 45／fail 0/u);
  assert.match(windowsReceipt, /Protected fixture residue：PASS/u);
  assert.match(windowsReceipt, /Volume-root lifecycle residue：PASS/u);
  assert.match(windowsReceipt, /Holder comparison：PASS/u);
  assert.match(windowsReceipt, /審查收據（Review receipts）/u);
  assert.match(windowsReceipt, /Standards review：PASS，session `ses_04e46a539ffemsWhvoHi7xbC30`/u);
  assert.match(windowsReceipt, /Spec review：PASS，session `ses_04e46a22affeB35iTh8iK2mJGR`/u);
  assert.match(windowsReceipt, /Final review addendum（2026-07-31）/u);
  assert.match(windowsReceipt, /PowerShell parser：PASS；`Invoke-AgentProcessLifecycle\.ps1` 與 `JobHandleHolder\.ps1` 均無 parser errors/u);
  assert.match(windowsReceipt, /受影響 serialized suites：PASS，Ticket 12／14／15 共 44\/44、fail 0/u);
  assert.match(windowsReceipt, /abrupt host.*crash/u);
  assert.match(windowsReceipt, /same-user.*tamper/u);
  assert.equal(normalizedTextHash(await readFile(helperPath, "utf8")), "24e0005c68241f63e0881c0e99055480403523a6d02ddd412c7f9beee17372d0");
  assert.equal(normalizedTextHash(await readFile(holderPath, "utf8")), "bfbe26edea0f7450f87c05dd6b0e4300cfadee0532a2c39264a751b04c161924");

  assert.deepEqual(packageJson.scripts, { validate: "node scripts/validate-skills.mjs" });
  for (const structuralCheck of ["skills.json", "marketplace.json", "frontmatter", "evals.json"]) {
    assert.match(validator, new RegExp(structuralCheck.replace(".", "\\."), "u"));
  }
  assert.doesNotMatch(validator, /(opencode|powershell|model|routing|runtime|evidence|behavioral|spawn|exec)/iu);
  for (const heading of [
    "# agent-process-lifecycle",
    "## 解決的問題",
    "## 使用時機",
    "## 不適用情境",
    "## 平台與 execution tier",
    "## Stop、Preserve 與 handoff",
    "## Windows self-managed helper",
    "## 檔案",
    "## 驗證證據與限制",
  ]) {
    assert.match(readme, new RegExp(`^${heading}$`, "mu"));
  }
  assert.match(readme, /1\.0\.0/u);
  assert.match(readme, /Windows-only execution/u);
  assert.match(readme, /non-Windows.*分類.*handoff.*launch 前 blocked/su);
  assert.match(readme, /第一個 viable tier/u);
  assert.match(readme, /Launch.*Finalize/u);
  assert.match(readme, /Stop.*Preserve/su);
  assert.match(readme, /caller.*workload-specific readiness/su);
  assert.match(readme, /不負責.*Browser QA/su);
  assert.match(readme, /npm run validate.*structural/su);
  assert.match(readme, /Ticket 16.*Ticket 17.*Windows.*重用.*不重跑/su);
  assert.match(readme, /Windows self-managed.*Launch.*recoverable record atomic publication.*abrupt host crash.*non-guarantee/su);
  assert.match(readme, /same-user malicious tamper.*non-guarantee/su);
  assert.doesNotMatch(readme, /alternate-account|cross-platform execution|Linux|macOS/iu);

  const expectedArtifacts = [
    "README.md",
    "SKILL.md",
    "evals/evals.json",
    "references/failure-and-handoff.md",
    "references/windows-self-managed.md",
    "scripts/Invoke-AgentProcessLifecycle.ps1",
    "scripts/JobHandleHolder.ps1",
  ];
  const fileSection = readme.split("## 檔案\n")[1]?.split("\n## 驗證證據與限制")[0] ?? "";
  assert.equal((fileSection.match(/\[[^\]]+\]\([^\)]+\)/gu) ?? []).length, expectedArtifacts.length);
  for (const artifact of expectedArtifacts) {
    assert.match(fileSection, new RegExp(`\\[${artifact.replaceAll("/", "\\/")}\\]\\(${artifact.replaceAll("/", "\\/")}\\)`, "u"));
  }
});
