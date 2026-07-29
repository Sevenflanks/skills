import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");
const candidatePath = resolve(import.meta.dirname, "../agent-process-lifecycle/SKILL.md");
const smokeRunnerPath = resolve(import.meta.dirname, "run_candidate_smoke.py");
const exactDescription = "Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, or a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation. On Windows, classify owner, select the first viable execution tier, and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify only to hand off or block before launch; do not perform lifecycle execution. Do not use for synchronous commands or when merely observing or using an external or runtime-managed resource whose owner and lifecycle contract are already clear.";

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

test("candidate remains manually invoked with the exact routing description", async () => {
  const document = await readFile(candidatePath, "utf8");

  assert.equal(frontmatterValue(document, "name"), "agent-process-lifecycle");
  assert.equal(frontmatterValue(document, "description"), exactDescription);
  assert.equal(frontmatterValue(document, "disable-model-invocation"), "true");
  assert.match(document, /## Reasoning-Only Entry Check/u);
  assert.match(document, /do not create a lifecycle fact bundle/u);
  assert.match(document, /"lifecycle_fact_bundle_created": false/u);
});

test("candidate blocks helper-required work before any lifecycle action", async () => {
  const document = await readFile(candidatePath, "utf8");

  assert.match(document, /production-helper-unavailable/u);
  assert.match(document, /"launch_performed": false/u);
  assert.match(document, /"termination_performed": false/u);
  assert.match(document, /"os_inspection_performed": false/u);
  assert.match(document, /"lifecycle_shell_calls": \[\]/u);
  assert.match(document, /Prototype feasibility is not production acceptance/u);
});

test("candidate classifies every platform path without executing it", async () => {
  const document = await readFile(candidatePath, "utf8");

  assert.match(document, /This candidate never executes a managed or external lifecycle operation/u);
  assert.match(document, /"platform": "non-Windows"/u);
  assert.match(document, /"identified_owner": null/u);
  assert.match(document, /"action": "handoff"/u);
  assert.match(document, /"identified_owner": "managed-or-external"/u);
  assert.match(document, /"lifecycle_shell_calls": \[\]/u);
});

test("smoke counts only completed exact candidate skill events", async () => {
  const runner = await readFile(smokeRunnerPath, "utf8");

  assert.match(runner, /"status": "completed"/u);
  assert.match(runner, /"name": NAME/u);
});

test("published inventory bytes remain pinned and exclude the candidate", async () => {
  for (const [relativePath, expectedHash] of publishedInventoryHashes) {
    const document = await readFile(resolve(repositoryRoot, relativePath));
    const observedHash = createHash("sha256").update(document).digest("hex");
    assert.equal(observedHash, expectedHash, relativePath);
    assert.doesNotMatch(document.toString("utf8"), /agent-process-lifecycle/u, relativePath);
  }
});
