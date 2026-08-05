import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
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
const archivedCandidateCommit = "c9c1ba47bbe6f94dde323a65d676bec1e0201da3";
const publicationBaseCommit = "762e80165a6cc0d739144ff9d7cdab277564430f";
const publishedSkillRoot = resolve(repositoryRoot, "skills/agent-process-lifecycle");
const oldPublishedSkillRoot = resolve(repositoryRoot, "skills/playwright-server-lifecycle");
const publishedSkillPath = resolve(publishedSkillRoot, "SKILL.md");
const publishedReadmePath = resolve(publishedSkillRoot, "README.md");
const publishedArtifactPaths = {
  "README.md": publishedReadmePath,
  "evals/evals.json": resolve(publishedSkillRoot, "evals/evals.json"),
  "references/failure-and-handoff.md": resolve(publishedSkillRoot, "references/failure-and-handoff.md"),
  "references/windows-self-managed.md": resolve(publishedSkillRoot, "references/windows-self-managed.md"),
  "scripts/Invoke-AgentProcessLifecycle.ps1": resolve(publishedSkillRoot, "scripts/Invoke-AgentProcessLifecycle.ps1"),
  "scripts/JobHandleHolder.ps1": resolve(publishedSkillRoot, "scripts/JobHandleHolder.ps1"),
};
const candidateArtifactPaths = {
  "README.md": candidateReadmePath,
  "evals/evals.json": resolve(candidateRoot, "agent-process-lifecycle/evals/evals.json"),
  "references/failure-and-handoff.md": resolve(candidateRoot, "agent-process-lifecycle/references/failure-and-handoff.md"),
  "references/windows-self-managed.md": resolve(candidateRoot, "agent-process-lifecycle/references/windows-self-managed.md"),
  "scripts/Invoke-AgentProcessLifecycle.ps1": helperPath,
  "scripts/JobHandleHolder.ps1": holderPath,
};
const expectedPublishedArtifacts = [
  "README.md",
  "SKILL.md",
  "evals/evals.json",
  "references/failure-and-handoff.md",
  "references/windows-self-managed.md",
  "scripts/Invoke-AgentProcessLifecycle.ps1",
  "scripts/JobHandleHolder.ps1",
];
const publishedDescription = "Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation, or the task explicitly requests a lifecycle decision for an Agent-started or managed current-run binding. On Windows, select the first viable execution tier and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify an Agent-caused local process only to hand off or block before launch; do not perform lifecycle execution. Do not use for a command that remains synchronous until normal exit, regardless of duration. Do not load this skill merely to classify, Preserve, observe, check status, or use a resource when the prompt already identifies a framework, IDE, Kubernetes, Docker, Windows Service, CI, or other external or runtime owner and states its complete lifecycle contract; follow that owner's contract directly.";
const catalogSummary = "管理 Agent 啟動之本機 OS process 的 ownership、execution tier、readiness、Stop、Preserve、handoff 與 reconciliation；Windows 提供 self-managed helper，non-Windows 僅分類、handoff 或 launch 前 blocked。";
const catalogTags = ["agent", "process-lifecycle", "ownership", "powershell", "windows", "opencode", "readiness", "cleanup", "preserve", "handoff", "reconciliation"];

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
  const line = key.includes(".") ? `\\s{2}${key.split(".").at(-1)}` : key;
  return frontmatter.match(new RegExp(`^${line}: (.+?)\\r?$`, "mu"))?.[1];
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

async function exists(path) {
  try {
    await lstat(path);
    return true;
  } catch {
    return false;
  }
}

async function listRelativeFiles(root, relativePath = "") {
  const entries = await readdir(resolve(root, relativePath), { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryRelativePath = relativePath ? `${relativePath}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      files.push(...await listRelativeFiles(root, entryRelativePath));
    } else if (entry.isFile()) {
      files.push(entryRelativePath);
    } else {
      assert.fail(`published inventory contains unsupported entry: ${entryRelativePath}`);
    }
  }
  return files.sort();
}

function productionSkillFromCandidate(candidateDocument) {
  return normalizeLineEndings(candidateDocument)
    .replace("disable-model-invocation: true\n", "")
    .replace("version: 1.0.0-candidate.10", "version: 1.0.0")
    .replace("# Agent Process Lifecycle Candidate", "# Agent Process Lifecycle")
    .replace("This is a scratch-only, manually invoked candidate for ticket 16. It is not a\npublished skill, production helper, alias, compatibility path, or release\ncandidate. Do not add it to a catalog, marketplace, published skill directory,\nor automatic model-invocation inventory.\n\n", "")
    .replace("## Candidate Test Entry\n\nUse this entry only after a maintainer explicitly loads\n`agent-process-lifecycle` for a supplied lifecycle scenario. Apply the ordered\nflow below and return one concise, machine-readable lifecycle decision. A\nrestricted evaluation fixture may prohibit execution tools; in that fixture,\nreturn the selected lifecycle plan and its public facts rather than attempting\nan unavailable operation.\n\n", "## Lifecycle Decision Contract\n\nApply the ordered flow below to lifecycle decisions for Agent-caused local OS\nprocesses. Return concise machine-readable lifecycle facts where practical, and\nkeep the lifecycle result separate from the caller-owned downstream result.\n\n")
    .replace(" A restricted model-visible fixture plans\nrather than performs lifecycle work, so `planned` is its valid final status.\n", "\n");
}

function archivedCandidateSkill() {
  return execFileSync("git", ["show", `${archivedCandidateCommit}:${candidateRelativePath}`], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: { ...process.env, GIT_MASTER: "1" },
  });
}

function publicationBaseCurrentSkill() {
  return execFileSync("git", ["show", `${publicationBaseCommit}:skills/playwright-server-lifecycle/SKILL.md`], {
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
  const normalizedReadme = normalizeLineEndings(readme);

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
    const actualHash = relativePath === "variants/current/SKILL.md"
      ? sha256(publicationBaseCurrentSkill())
      : await hashFile(sourcePath);
    assert.equal(actualHash, expectedHash, relativePath);
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
  assert.match(windowsReceipt, /PR 11 review remediation addendum（2026-08-05）/u);
  assert.match(windowsReceipt, /inline review comment `3717512146`/u);
  assert.match(windowsReceipt, /runtime 修正 commit 為 `cf1aa20`/u);
  assert.match(windowsReceipt, /Focused RED/u);
  assert.match(windowsReceipt, /Focused GREEN：相同命令在修正後為 tests 3、pass 3、fail 0/u);
  assert.match(windowsReceipt, /Serialized Windows Ticket 11 至 15 runtime：tests 65、pass 65、fail 0/u);
  assert.match(windowsReceipt, /b24ea67d08e765000e4b880b99cdc8ac92a54e62ead1c65537a3905ce9ddcc73/u);
  assert.match(windowsReceipt, /untracked `.omo\/run-continuation\/\*\.json` 始終排除/u);
  assert.match(windowsReceipt, /abrupt host.*crash/u);
  assert.match(windowsReceipt, /same-user.*tamper/u);
  assert.equal(normalizedTextHash(await readFile(helperPath, "utf8")), "b24ea67d08e765000e4b880b99cdc8ac92a54e62ead1c65537a3905ce9ddcc73");
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
    assert.match(normalizedReadme, new RegExp(`^${heading}$`, "mu"));
  }
  assert.match(normalizedReadme, /1\.0\.0/u);
  assert.match(normalizedReadme, /Windows-only execution/u);
  assert.match(normalizedReadme, /non-Windows.*分類.*handoff.*launch 前 blocked/su);
  assert.match(normalizedReadme, /第一個 viable tier/u);
  assert.match(normalizedReadme, /Launch.*Finalize/u);
  assert.match(normalizedReadme, /Stop.*Preserve/su);
  assert.match(normalizedReadme, /caller.*workload-specific readiness/su);
  assert.match(normalizedReadme, /不負責.*Browser QA/su);
  assert.match(normalizedReadme, /npm run validate.*structural/su);
  assert.match(normalizedReadme, /Ticket 16.*Ticket 17.*Windows.*重用.*不重跑/su);
  assert.match(normalizedReadme, /Windows self-managed.*Launch.*recoverable record atomic publication.*abrupt host crash.*non-guarantee/su);
  assert.match(normalizedReadme, /same-user malicious tamper.*non-guarantee/su);
  assert.doesNotMatch(normalizedReadme, /alternate-account|cross-platform execution|Linux|macOS/iu);

  const expectedArtifacts = [
    "README.md",
    "SKILL.md",
    "evals/evals.json",
    "references/failure-and-handoff.md",
    "references/windows-self-managed.md",
    "scripts/Invoke-AgentProcessLifecycle.ps1",
    "scripts/JobHandleHolder.ps1",
  ];
  const fileSection = normalizedReadme.split("## 檔案\n")[1]?.split("\n## 驗證證據與限制")[0] ?? "";
  assert.equal((fileSection.match(/\[[^\]]+\]\([^\)]+\)/gu) ?? []).length, expectedArtifacts.length);
  for (const artifact of expectedArtifacts) {
    assert.match(fileSection, new RegExp(`\\[${artifact.replaceAll("/", "\\/")}\\]\\(${artifact.replaceAll("/", "\\/")}\\)`, "u"));
  }
});

test("Ticket 18 publishes one complete agent-process-lifecycle inventory", async () => {
  const [candidateDocument, productionDocument, catalog, marketplace, rootReadme, publishedFiles] = await Promise.all([
    readFile(candidatePath, "utf8"),
    readFile(publishedSkillPath, "utf8"),
    readJson(resolve(repositoryRoot, "skills.json")),
    readJson(resolve(repositoryRoot, ".claude-plugin/marketplace.json")),
    readFile(resolve(repositoryRoot, "README.md"), "utf8"),
    listRelativeFiles(publishedSkillRoot),
  ]);
  const normalizedRootReadme = normalizeLineEndings(rootReadme);

  assert.equal(await exists(oldPublishedSkillRoot), false, "old published skill directory must be absent");
  assert.deepEqual(publishedFiles, expectedPublishedArtifacts);
  assert.deepEqual((await readdir(resolve(publishedSkillRoot, "references"))).sort(), ["failure-and-handoff.md", "windows-self-managed.md"]);
  assert.deepEqual((await readdir(resolve(publishedSkillRoot, "scripts"))).sort(), ["Invoke-AgentProcessLifecycle.ps1", "JobHandleHolder.ps1"]);

  for (const artifact of Object.keys(candidateArtifactPaths)) {
    assert.equal(await hashFile(publishedArtifactPaths[artifact]), await hashFile(candidateArtifactPaths[artifact]), `${artifact} must be byte-identical to its candidate source`);
  }
  assert.equal(normalizeLineEndings(productionDocument), productionSkillFromCandidate(candidateDocument));
  assert.equal(frontmatterValue(productionDocument, "name"), "agent-process-lifecycle");
  assert.equal(frontmatterValue(productionDocument, "description"), publishedDescription);
  assert.equal(frontmatterValue(productionDocument, "license"), "MIT");
  assert.equal(frontmatterValue(productionDocument, "metadata.author"), "sevenflankse");
  assert.equal(frontmatterValue(productionDocument, "metadata.version"), "1.0.0");
  assert.doesNotMatch(productionDocument, /^disable-model-invocation:/mu);
  assert.doesNotMatch(productionDocument, /\b(?:alias|stub|deprecated(?:\s+shell)?|compatibility\s+(?:shell|path)|dual publication)\b/iu);
  for (const forbiddenText of ["scratch-only", "Candidate Test Entry", "restricted model-visible fixture", "candidate"]) {
    assert.doesNotMatch(productionDocument, new RegExp(forbiddenText, "iu"));
  }

  const expectedCatalogEntry = {
    name: "agent-process-lifecycle",
    path: "skills/agent-process-lifecycle",
    summary: catalogSummary,
    version: "1.0.0",
    license: "MIT",
    author: "sevenflankse",
    tags: catalogTags,
    status: "stable",
  };
  const expectedMarketplaceEntry = {
    name: "agent-process-lifecycle",
    source: "skills/agent-process-lifecycle",
    description: catalogSummary,
    version: "1.0.0",
    keywords: catalogTags,
  };
  assert.deepEqual(catalog.skills.filter(({ name }) => name === "agent-process-lifecycle"), [expectedCatalogEntry]);
  assert.equal(catalog.skills.some(({ name, path }) => name === "playwright-server-lifecycle" || path === "skills/playwright-server-lifecycle"), false);
  assert.deepEqual(marketplace.skills.filter(({ name }) => name === "agent-process-lifecycle"), [expectedMarketplaceEntry]);
  assert.equal(marketplace.skills.some(({ name, source }) => name === "playwright-server-lifecycle" || source === "skills/playwright-server-lifecycle"), false);

  assert.match(normalizedRootReadme, /^\| `agent-process-lifecycle` \| `1\.0\.0` \| stable \| 管理 Agent 啟動之本機 OS process 的 ownership、execution tier、readiness、Stop、Preserve、handoff 與 reconciliation；Windows 提供 self-managed helper，non-Windows 僅分類、handoff 或 launch 前 blocked。 \| \[`skills\/agent-process-lifecycle\/`\]\(skills\/agent-process-lifecycle\/\) \|$/mu);
  assert.match(normalizedRootReadme, /^## agent-process-lifecycle$/mu);
  assert.match(normalizedRootReadme, /不負責 Browser QA/u);
  assert.match(normalizedRootReadme, /Windows.*第一個 viable tier/su);
  assert.match(normalizedRootReadme, /non-Windows.*分類.*handoff.*launch 前 blocked/su);
  assert.match(normalizedRootReadme, /Stop.*Preserve.*handoff/su);
  assert.match(normalizedRootReadme, /└── agent-process-lifecycle\//u);
  for (const artifact of expectedPublishedArtifacts) {
    assert.match(normalizedRootReadme, new RegExp(`\\]\\(skills\\/agent-process-lifecycle\\/${artifact.replaceAll("/", "\\/")}\\)`, "u"));
  }
  assert.doesNotMatch(normalizedRootReadme, /playwright-server-lifecycle/u);
});
