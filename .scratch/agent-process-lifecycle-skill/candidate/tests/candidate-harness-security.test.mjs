import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../../../..");

test("candidate smoke preserves canonical evidence when case loading fails", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const testDirectory = await mkdtemp(resolve(scratchDirectory, "candidate-contract-canonical-"));
  const canonical = resolve(testDirectory, "model-visible-ticket-16");
  const outputArgument = relative(repositoryRoot, canonical);
  const probe = [
    "import sys",
    "from pathlib import Path",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "import run_candidate_smoke",
    `canonical = Path(${JSON.stringify(canonical)})`,
    "canonical.mkdir()",
    "marker = canonical / 'canonical-marker.bin'",
    "marker.write_bytes(b'canonical\\x00marker')",
    "run_candidate_smoke.CANONICAL_EVIDENCE_DIRECTORY = canonical",
    "def fail_case_load(*_):",
    "    raise run_candidate_smoke.HarnessError('case loading failed')",
    "run_candidate_smoke.load_cases = fail_case_load",
    `sys.argv = ["run_candidate_smoke.py", ${JSON.stringify(outputArgument)}]`,
    "try:",
    "    run_candidate_smoke.main()",
    "except run_candidate_smoke.HarnessError:",
    "    pass",
    "else:",
    "    raise AssertionError('expected case loading failure')",
    "assert marker.read_bytes() == b'canonical\\x00marker'",
    "assert tuple(path.name for path in canonical.iterdir()) == ('canonical-marker.bin',)",
    "assert not tuple(canonical.parent.glob(f'{canonical.name}.*'))",
  ].join("\n");

  try {
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally {
    await rm(testDirectory, { force: true, recursive: true });
  }
});

test("candidate smoke rejects assertions before staging canonical evidence", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const testDirectory = await mkdtemp(resolve(scratchDirectory, "candidate-contract-assertion-"));
  const canonical = resolve(testDirectory, "model-visible-ticket-16");
  const outputArgument = relative(repositoryRoot, canonical);
  const probe = [
    "import sys",
    "from pathlib import Path",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "from model_visible_contract import Case",
    "from model_visible_json import JsonObject",
    "import run_candidate_smoke",
    `test_directory = Path(${JSON.stringify(testDirectory)})`,
    `canonical = Path(${JSON.stringify(canonical)})`,
    "canonical.mkdir()",
    "marker = canonical / 'canonical-marker.bin'",
    "marker.write_bytes(b'canonical\\x00marker')",
    "run_candidate_smoke.CANONICAL_EVIDENCE_DIRECTORY = canonical",
    "cases = tuple(Case(identifier, '', (), (), (), frozenset(), ()) for identifier in ('passing', 'first-failure', 'second-failure'))",
    "class Result:",
    "    def __init__(self, identifier, assertions):",
    "        self.identifier = identifier",
    "        self.assertions = assertions",
    "    def evidence(self):",
    "        return JsonObject(())",
    "results = (Result('passing', ()), Result('first-failure', ('first assertion',)), Result('second-failure', ('second assertion', 'third assertion')))",
    "run_candidate_smoke.load_cases = lambda *_: cases",
    "run_candidate_smoke.run_case = lambda case, *_: next(result for result in results if result.identifier == case.identifier)",
    `sys.argv = ["run_candidate_smoke.py", ${JSON.stringify(outputArgument)}]`,
    "try:",
    "    run_candidate_smoke.main()",
    "except run_candidate_smoke.HarnessError as error:",
    "    failure_message = str(error)",
    "else:",
    "    raise AssertionError('expected assertion rejection')",
    "assert failure_message == 'model-visible lifecycle assertions failed: [{\"identifier\": \"first-failure\",\"assertions\": [\"first assertion\"]},{\"identifier\": \"second-failure\",\"assertions\": [\"second assertion\",\"third assertion\"]}]', failure_message",
    "assert str(test_directory) not in failure_message",
    "assert str(canonical) not in failure_message",
    "assert marker.read_bytes() == b'canonical\\x00marker'",
    "assert tuple(path.name for path in canonical.iterdir()) == ('canonical-marker.bin',)",
    "assert not tuple(canonical.parent.glob(f'{canonical.name}.*'))",
  ].join("\n");

  try {
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally {
    await rm(testDirectory, { force: true, recursive: true });
  }
});

test("candidate smoke preserves canonical evidence during execution and failed publication", async () => {
  const scratchDirectory = resolve(repositoryRoot, ".scratch/agent-process-lifecycle-skill");
  const testDirectory = await mkdtemp(resolve(scratchDirectory, "candidate-contract-transaction-"));
  const probe = [
    "import sys",
    "from pathlib import Path",
    `sys.path.insert(0, ${JSON.stringify(import.meta.dirname)})`,
    "from model_visible_contract import Case",
    "from model_visible_json import JsonObject",
    "import run_candidate_smoke",
    `test_directory = Path(${JSON.stringify(testDirectory)})`,
    "case = Case('accepted', '', (), (), (), frozenset(), ())",
    "class PassingResult:",
    "    identifier = 'accepted'",
    "    assertions = ()",
    "    def evidence(self):",
    "        return JsonObject(())",
    "def invoke(canonical):",
    "    run_candidate_smoke.CANONICAL_EVIDENCE_DIRECTORY = canonical",
    "    sys.argv = ['run_candidate_smoke.py', str(canonical.relative_to(run_candidate_smoke.ROOT))]",
    "    run_candidate_smoke.main()",
    "def marker_directory(name):",
    "    canonical = test_directory / name",
    "    canonical.mkdir()",
    "    marker = canonical / 'canonical-marker.bin'",
    "    marker.write_bytes(b'canonical\\x00marker')",
    "    return canonical, marker",
    "def assert_preserved(canonical, marker):",
    "    assert marker.read_bytes() == b'canonical\\x00marker'",
    "    assert tuple(path.name for path in canonical.iterdir()) == ('canonical-marker.bin',)",
    "    assert not tuple(canonical.parent.glob(f'{canonical.name}.*'))",
    "run_candidate_smoke.load_cases = lambda *_: (case,)",
    "execution_canonical, execution_marker = marker_directory('execution')",
    "def fail_execution(*_):",
    "    raise run_candidate_smoke.HarnessError('model execution failed')",
    "run_candidate_smoke.run_case = fail_execution",
    "try:",
    "    invoke(execution_canonical)",
    "except run_candidate_smoke.HarnessError:",
    "    pass",
    "else:",
    "    raise AssertionError('expected model execution failure')",
    "assert_preserved(execution_canonical, execution_marker)",
    "publication_canonical, publication_marker = marker_directory('publication')",
    "run_candidate_smoke.run_case = lambda *_: PassingResult()",
    "def fail_staging_promotion(source, destination):",
    "    if '.staging-' in source.name:",
    "        raise OSError('publication rename failed')",
    "    source.replace(destination)",
    "run_candidate_smoke._replace = fail_staging_promotion",
    "try:",
    "    invoke(publication_canonical)",
    "except OSError:",
    "    pass",
    "else:",
    "    raise AssertionError('expected publication failure')",
    "assert_preserved(publication_canonical, publication_marker)",
    "success_canonical = test_directory / 'success'",
    "staged_sets = []",
    "def publish(source, destination):",
    "    if '.staging-' in source.name:",
    "        staged_sets.append(tuple(sorted(path.name for path in source.iterdir())))",
    "    source.replace(destination)",
    "run_candidate_smoke._replace = publish",
    "invoke(success_canonical)",
    "assert staged_sets == [('manifest.json', 'results.ndjson', 'summary.json')]",
    "assert tuple(sorted(path.name for path in success_canonical.iterdir())) == ('manifest.json', 'results.ndjson', 'summary.json')",
    "assert not tuple(success_canonical.parent.glob(f'{success_canonical.name}.*'))",
  ].join("\n");

  try {
    const result = spawnSync("py", ["-3.12", "-c", probe], { cwd: repositoryRoot, encoding: "utf8" });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally {
    await rm(testDirectory, { force: true, recursive: true });
  }
});

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
