#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { createOpenCodeStageOneAdapter } from '../adapters/opencode-stage-one.mjs';
import { normalizeOpenCodeRejection } from '../adapters/opencode-evidence.mjs';
import { executeOpenCode, OPENCODE_EXECUTABLE } from '../lib/opencode-runtime.mjs';
import { loadTrainingScenarios, runBenchmark, validateBenchmarkCorpus, writeRunArtifact } from '../lib/runner.mjs';
import { scoreReport, writeScoreArtifact } from '../lib/scorer.mjs';

const BENCHMARK_VERSION = 'self-challenge-foundation-v1';
const CANDIDATE = { injection_mode: 'prompt-attachment', name: 'self-challenge', source: 'skills/self-challenge/SKILL.md', version: '0.1.0' };
const EXPECTED_OPENCODE_VERSION = '1.18.9';
const MODEL = 'openai/gpt-5.6-sol';
const TRIALS = 5;
const binDirectory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkDirectory = path.resolve(binDirectory, '..');
const repositoryRoot = path.resolve(benchmarkDirectory, '..', '..');

function usage() {
  return 'Usage: node benchmarks/self-challenge/bin/run-stage-one-training.mjs --output <empty directory>\n';
}

function parseArguments(argv) {
  let output = null;
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--help') {
      return { help: true };
    }
    if (option !== '--output') {
      throw new Error(`Unsupported stage-one training option ${option}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new Error('--output requires a directory');
    }
    output = path.resolve(process.cwd(), value);
    index += 1;
  }
  if (!output) {
    throw new Error('--output is required');
  }
  return { output };
}

async function writeNewJson(directory, name, value) {
  await writeFile(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

async function createEmptyOutput(outputDirectory) {
  await mkdir(outputDirectory, { recursive: true });
  if ((await readdir(outputDirectory)).length > 0) {
    throw new Error(`Stage-one training output directory must be empty: ${outputDirectory}`);
  }
  return outputDirectory;
}

async function loadEnvironment(runtimeVersion) {
  const [catalogContent, candidateContent] = await Promise.all([
    readFile(path.join(repositoryRoot, 'skills.json'), 'utf8'),
    readFile(path.join(repositoryRoot, 'skills', 'self-challenge', 'SKILL.md'), 'utf8'),
  ]);
  if (!/^name:\s*self-challenge\s*$/m.test(candidateContent) || !/^  version:\s*0\.1\.0\s*$/m.test(candidateContent)) {
    throw new Error('Stage-one training candidate metadata must remain self-challenge 0.1.0');
  }
  const catalog = JSON.parse(catalogContent).skills
    .map((skill) => ({ name: skill.name, version: skill.version }));
  if (catalog.some((skill) => skill.name === CANDIDATE.name)) {
    throw new Error('Stage-one training requires an unpublished self-challenge candidate');
  }
  return {
    candidate: { ...CANDIDATE, sha256: createHash('sha256').update(candidateContent).digest('hex') },
    environment: {
      schema_version: 'self-challenge-environment.v1',
      model: MODEL,
      runtime: { name: 'opencode', version: runtimeVersion },
      skill_catalog: catalog,
      sampling_settings: { seed: null, temperature: null, top_p: null },
      tool_availability: [
        { name: 'native-build-agent', available: true },
        { name: 'opencode-export', available: true },
        { name: 'opencode-run', available: true },
      ],
    },
  };
}

function countEvents(run, type) {
  return run.transcript.events.filter((event) => event.type === type).length;
}

function expectedReflectionBehavior(run) {
  const expectations = run.adjudication.reflection_expectations;
  const stageOneStarts = countEvents(run, 'stage_one_started');
  const stageOneCompletions = countEvents(run, 'stage_one_completed');
  const interruptions = countEvents(run, 'user_interruption');
  const expectedStageOne = expectations.stage_one
    ? stageOneStarts === 1 && stageOneCompletions === 1
    : stageOneStarts === 0 && stageOneCompletions === 0;
  const expectedInterruption = expectations.user_interruption ? interruptions === 1 : interruptions === 0;
  return expectedStageOne && expectedInterruption;
}

function sessionSummary(report) {
  const sessions = report.runs
    .filter((run) => run.status === 'completed')
    .map((run) => run.transcript.usage.session_id)
    .filter((sessionId) => typeof sessionId === 'string');
  return { count: sessions.length, unique: new Set(sessions).size };
}

function familySummary(report, score) {
  const results = new Map(score.results.map((result) => [result.run_id, result]));
  const families = new Map();
  for (const run of report.runs) {
    const entries = families.get(run.family_id) ?? [];
    entries.push({ run, result: results.get(run.run_id) });
    families.set(run.family_id, entries);
  }
  return [...families.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([family_id, entries]) => {
    const passed = entries.filter((entry) => entry.result?.overall_pass && expectedReflectionBehavior(entry.run)).length;
    return { family_id, total: entries.length, passed, correctness: entries.length === 0 ? 0 : passed / entries.length };
  });
}

function framingConsistency(report) {
  const groups = new Map();
  for (const run of report.runs.filter((item) => item.category === 'framing-inversion')) {
    if (run.status !== 'completed') {
      return false;
    }
    const key = `${run.family_id}:${run.trial}`;
    const actions = groups.get(key) ?? [];
    actions.push(run.transcript.events.find((event) => event.type === 'agent_action')?.action_id);
    groups.set(key, actions);
  }
  return groups.size === TRIALS && [...groups.values()].every((actions) => actions.length === 2 && new Set(actions).size === 1);
}

async function preflight(command, outputDirectory) {
  async function capture(argumentsForRun, evidenceName, purpose) {
    try {
      const result = await command(argumentsForRun);
      await writeNewJson(outputDirectory, evidenceName, { executable: OPENCODE_EXECUTABLE, arguments: argumentsForRun, exit_code: result.exitCode, stderr: result.stderr, stdout: result.stdout, timed_out: result.timedOut });
      return result;
    } catch (error) {
      await writeNewJson(outputDirectory, evidenceName, { executable: OPENCODE_EXECUTABLE, arguments: argumentsForRun, error: normalizeOpenCodeRejection(error) });
      throw new Error(`OpenCode ${purpose} command rejected`);
    }
  }
  const versionArguments = ['--pure', '--version'];
  const version = await capture(versionArguments, 'opencode-version.json', 'version');
  if (version.timedOut || version.exitCode !== 0 || version.stdout.trim() !== EXPECTED_OPENCODE_VERSION) {
    throw new Error(`Expected OpenCode ${EXPECTED_OPENCODE_VERSION} preflight`);
  }
  const agentListArguments = ['agent', 'list', '--pure'];
  const agentList = await capture(agentListArguments, 'opencode-agent-list.json', 'agent list');
  if (agentList.timedOut || agentList.exitCode !== 0 || !/^build \(primary\)\r?$/m.test(agentList.stdout)) {
    throw new Error('OpenCode --pure does not resolve the native build agent');
  }
  return version.stdout.trim();
}

function strictSummary(report, score) {
  const sessions = sessionSummary(report);
  const families = familySummary(report, score);
  const expectedRuns = 6 * TRIALS;
  const completed = report.runs.filter((run) => run.status === 'completed').length;
  const stageTwoEventTypes = new Set(['stage_two_started', 'subagent_spawned', 'subagent_prompt', 'verdict']);
  const noStageTwo = report.runs.every((run) => run.status === 'completed' && run.transcript.events.every((event) => !stageTwoEventTypes.has(event.type)));
  const scorePass = score.results.every((result) => result.overall_pass);
  const pass = report.runs.length === expectedRuns && completed === expectedRuns && scorePass && sessions.count === expectedRuns && sessions.unique === expectedRuns && families.length === 5 && families.every((family) => family.correctness === 1) && framingConsistency(report) && noStageTwo;
  return { pass, expected_runs: expectedRuns, completed_runs: completed, unique_sessions: sessions.unique, families, framing_consistent: framingConsistency(report), no_stage_two: noStageTwo };
}

export async function runStageOneTraining({ outputDirectory, command = executeOpenCode, executor = executeOpenCode }) {
  await createEmptyOutput(outputDirectory);
  const runtimeVersion = await preflight(command, outputDirectory);
  const { candidate, environment } = await loadEnvironment(runtimeVersion);
  await writeNewJson(outputDirectory, 'environment.json', environment);
  await writeNewJson(outputDirectory, 'experiment.json', {
    adapter: 'opencode-stage-one',
    benchmark_version: BENCHMARK_VERSION,
    candidate,
    configuration: 'stage-one-only',
    model: MODEL,
    opencode_executable: OPENCODE_EXECUTABLE,
    pure_mode_commands: [
      { purpose: 'version', arguments: ['--pure', '--version'] },
      { purpose: 'agent-list', arguments: ['agent', 'list', '--pure'] },
      { purpose: 'run', arguments: ['run', '<stage-one-message>', '--pure', '--format', 'json', '--model', MODEL, '--agent', 'build', '--variant', 'medium', '--file', '<prompt-file>'] },
      { purpose: 'export', arguments: ['export', '--pure', '<session-id>'] },
    ],
    runtime: environment.runtime,
    retry_policy: 'none',
    trials: TRIALS,
  });
  const [scenarios, manifestContent] = await Promise.all([
    loadTrainingScenarios(path.join(benchmarkDirectory, 'scenarios', 'training')),
    readFile(path.join(benchmarkDirectory, 'scenarios', 'true-held-out-manifest.json'), 'utf8'),
  ]);
  validateBenchmarkCorpus({ scenarios, manifest: JSON.parse(manifestContent) });
  if (scenarios.length !== 6) {
    throw new Error('Stage-one training requires exactly six tracked training scenarios');
  }
  const report = await runBenchmark({
    scenarios,
    adapter: createOpenCodeStageOneAdapter({ candidateSkillPath: path.join(repositoryRoot, CANDIDATE.source), rawEvidenceDirectory: path.join(outputDirectory, 'raw'), executor }),
    configurations: ['stage-one-only'],
    trials: TRIALS,
    benchmarkVersion: BENCHMARK_VERSION,
    environment,
  });
  const score = scoreReport(report);
  const strict = strictSummary(report, score);
  await writeRunArtifact(report, outputDirectory);
  await writeScoreArtifact(score, outputDirectory);
  await writeNewJson(outputDirectory, 'summary.json', {
    schema_version: 'self-challenge-stage-one-training-summary.v1',
    benchmark_version: BENCHMARK_VERSION,
    configuration: 'stage-one-only',
    strict,
  });
  if (!strict.pass) {
    throw new Error('Strict stage-one training gate failed');
  }
  return { report, score, strict };
}

export async function main(argv = process.argv.slice(2), { command = executeOpenCode, executor = executeOpenCode } = {}) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(usage());
    return null;
  }
  const result = await runStageOneTraining({ outputDirectory: options.output, command, executor });
  process.stdout.write(`${JSON.stringify({ runs: result.report.runs.length, strict_pass: result.strict.pass, summary_path: path.join(options.output, 'summary.json') })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
