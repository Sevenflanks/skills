import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { basename, resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");
const candidateDirectory = resolve(import.meta.dirname, "../agent-process-lifecycle");

test("candidate model fixture scopes runtime reads to its unique project name", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const project = await mkdtemp(resolve(scratchDirectory, "candidate-contract-fixture-"));
  const probe = [
    "import json",
    "import sys",
    "from pathlib import Path",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "from model_visible_execution import ExecutionConfig, MANIFEST_PERMISSION_POLICY, _create_fixture",
    "from model_visible_json import json_text",
    `project = Path(${JSON.stringify(project)})`,
    `fixture = _create_fixture(project, ExecutionConfig(Path(${JSON.stringify(candidateDirectory)}), \"agent-process-lifecycle\", \"openai/gpt-5.6-sol\", \"unused\"))`,
    "files = sorted(path.relative_to(fixture).as_posix() for path in fixture.rglob('*') if path.is_file())",
    "policy = json.loads((project / 'opencode.json').read_text(encoding='utf-8'))['permission']",
    "manifest_policy = json.loads(json_text(MANIFEST_PERMISSION_POLICY))",
    "print(json.dumps({'files': files, 'permission': policy, 'manifest_policy': manifest_policy}))",
  ].join("\n");

  try {
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const projectName = basename(project);
    const fixture = JSON.parse(result.stdout);
    assert.deepEqual(fixture, {
      files: ["SKILL.md", "references/failure-and-handoff.md", "references/windows-self-managed.md"],
      permission: {
        "*": "deny",
        read: {
          "*": "deny",
          [`*${projectName}/.opencode/skills/agent-process-lifecycle/references/windows-self-managed.md`]: "allow",
          [`*${projectName}/.opencode/skills/agent-process-lifecycle/references/failure-and-handoff.md`]: "allow",
        },
        skill: "allow",
      },
      manifest_policy: {
        "*": "deny",
        read: {
          "*": "deny",
          "<fixture>/.opencode/skills/agent-process-lifecycle/references/windows-self-managed.md": "allow",
          "<fixture>/.opencode/skills/agent-process-lifecycle/references/failure-and-handoff.md": "allow",
        },
        skill: "allow",
      },
    });
    const allowPatterns = Object.entries(fixture.permission.read)
      .filter(([, decision]) => decision === "allow")
      .map(([pattern]) => pattern);
    assert.ok(allowPatterns.every((pattern) => pattern.includes(projectName)));
    assert.ok(allowPatterns.every((pattern) => !pattern.includes("evals/")));
  } finally {
    await rm(project, { force: true, recursive: true });
  }
});
