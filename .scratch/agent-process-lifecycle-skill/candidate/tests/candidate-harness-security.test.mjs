import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");
const candidateDirectory = resolve(import.meta.dirname, "../agent-process-lifecycle");

test("candidate smoke rejects destructive non-canonical output paths before deletion", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const output = await mkdtemp(resolve(scratchDirectory, "candidate-contract-output-"));
  const marker = resolve(output, "must-survive.txt");
  const outputArgument = relative(repositoryRoot, output);
  const probe = [
    "import sys",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "import run_candidate_smoke",
    `sys.argv = [\"run_candidate_smoke.py\", ${JSON.stringify(outputArgument)}]`,
    "try:",
    "    run_candidate_smoke._output_path()",
    "except run_candidate_smoke.HarnessError:",
    "    raise SystemExit(0)",
    "raise SystemExit(1)",
  ].join("\n");

  try {
    await writeFile(marker, "candidate-contract-marker", "utf8");
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(await readFile(marker, "utf8"), "candidate-contract-marker");
  } finally {
    await rm(output, { force: true, recursive: true });
  }
});

test("candidate grading rejects every incomplete reference read while retaining read evidence", () => {
  const probe = [
    "import sys",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "from model_visible_contract import Case, ModelResponse",
    "from model_visible_execution import CaseResult, RunObservation, ToolEvent, _grade",
    "from model_visible_json import JsonArray, JsonObject, record",
    "case = Case('read-status', '', (), (), (), frozenset({'read'}), ('references/windows-self-managed.md',))",
    "input_value = record(('filePath', 'references/windows-self-managed.md'))",
    "def observation(status):",
    "    return RunObservation(True, True, (ToolEvent(0, 'read', status, input_value),), ('references/windows-self-managed.md',), ModelResponse('{}', JsonObject(())))",
    "for status in (None, 'pending', 'error'):",
    "    failures = _grade(case, observation(status))",
    "    assert failures == (f'read event 0 did not complete: {status!r}',)",
    "assert _grade(case, observation('completed')) == ()",
    "evidence = CaseResult('read-status', observation('completed'), ()).evidence()",
    "assert evidence.required('reference_reads', 'evidence') == JsonArray(('references/windows-self-managed.md',))",
  ].join("\n");
  const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});
