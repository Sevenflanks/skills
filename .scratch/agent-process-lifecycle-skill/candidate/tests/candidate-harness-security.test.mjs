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

test("candidate model fixture exposes only approved files with deny-by-default reads", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const project = await mkdtemp(resolve(scratchDirectory, "candidate-contract-fixture-"));
  const probe = [
    "import json",
    "import sys",
    "from pathlib import Path",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "from model_visible_execution import ExecutionConfig, _create_fixture",
    `project = Path(${JSON.stringify(project)})`,
    `fixture = _create_fixture(project, ExecutionConfig(Path(${JSON.stringify(candidateDirectory)}), \"agent-process-lifecycle\", \"openai/gpt-5.6-sol\", \"unused\"))`,
    "files = sorted(path.relative_to(fixture).as_posix() for path in fixture.rglob('*') if path.is_file())",
    "policy = json.loads((project / 'opencode.json').read_text(encoding='utf-8'))['permission']",
    "print(json.dumps({'files': files, 'permission': policy}))",
  ].join("\n");

  try {
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.deepEqual(JSON.parse(result.stdout), {
      files: ["SKILL.md", "references/failure-and-handoff.md", "references/windows-self-managed.md"],
      permission: {
        "*": "deny",
        read: {
          "*": "deny",
          "*.opencode/skills/agent-process-lifecycle/references/windows-self-managed.md": "allow",
          "*.opencode/skills/agent-process-lifecycle/references/failure-and-handoff.md": "allow",
        },
        skill: "allow",
      },
    });
  } finally {
    await rm(project, { force: true, recursive: true });
  }
});
