#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { createOpenCodeNoSkillAdapter } from '../adapters/opencode-no-skill.mjs';
import {
  loadTrainingScenarios,
  runBenchmark,
  validateBenchmarkCorpus,
  writeRunArtifact,
} from '../lib/runner.mjs';
import { summarizeNoSkillBaseline } from '../lib/no-skill-summary.mjs';
import { scoreReport, writeScoreArtifact } from '../lib/scorer.mjs';

const execFile = promisify(execFileCallback);
const EXPECTED_OPENCODE_VERSION = '1.18.9';
const BENCHMARK_VERSION = 'self-challenge-foundation-v1';
const TRIALS = 5;
const binDirectory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkDirectory = path.resolve(binDirectory, '..');
const repositoryRoot = path.resolve(benchmarkDirectory, '..', '..');

function usage() {
  return 'Usage: node benchmarks/self-challenge/bin/run-no-skill-baseline.mjs --output <empty directory>\n';
}

function parseArguments(argv) {
  let output = null;
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--help') {
      return { help: true };
    }
    if (option !== '--output' || !argv[index + 1] || argv[index + 1].startsWith('--')) {
      throw new Error(`Unsupported baseline option ${option}`);
    }
    output = path.resolve(process.cwd(), argv[index + 1]);
    index += 1;
  }
  if (!output) {
    throw new Error('--output is required');
  }
  return { output };
}

export async function createEmptyBaselineOutput(outputDirectory) {
  await mkdir(outputDirectory, { recursive: true });
  if ((await readdir(outputDirectory)).length > 0) {
    throw new Error(`Baseline output directory must be empty: ${outputDirectory}`);
  }
  return outputDirectory;
}

async function command(args) {
  const invocation = process.platform === 'win32'
    ? { command: process.env.ComSpec, args: ['/d', '/s', '/c', 'opencode.cmd', ...args] }
    : { command: 'opencode', args };
  return execFile(invocation.command, invocation.args, { cwd: repositoryRoot, maxBuffer: 10 * 1024 * 1024, windowsHide: true });
}

async function writeNewJson(directory, name, value) {
  await writeFile(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

async function loadEnvironment(runtimeVersion) {
  const catalog = JSON.parse(await readFile(path.join(repositoryRoot, 'skills.json'), 'utf8')).skills
    .map((skill) => ({ name: skill.name, version: skill.version }));
  const skillDirectories = await readdir(path.join(repositoryRoot, 'skills'));
  if (catalog.some((skill) => skill.name === 'self-challenge') || skillDirectories.includes('self-challenge')) {
    throw new Error('No-skill baseline refuses a candidate self-challenge skill');
  }
  return {
    schema_version: 'self-challenge-environment.v1',
    model: 'openai/gpt-5.6-sol',
    runtime: { name: 'opencode', version: runtimeVersion },
    skill_catalog: catalog,
    sampling_settings: { seed: null, temperature: null, top_p: null },
    tool_availability: [
      { name: 'native-build-agent', available: true },
      { name: 'opencode-export', available: true },
      { name: 'opencode-run', available: true },
    ],
  };
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const outputDirectory = await createEmptyBaselineOutput(options.output);
  const version = (await command(['--version'])).stdout.trim();
  if (version !== EXPECTED_OPENCODE_VERSION) {
    throw new Error(`Expected OpenCode ${EXPECTED_OPENCODE_VERSION}, received ${version}`);
  }
  const agentList = await command(['agent', 'list', '--pure']);
  if (!agentList.stdout.includes('build')) {
    throw new Error('OpenCode --pure does not resolve the native build agent');
  }
  await writeFile(path.join(outputDirectory, 'opencode-agent-list.txt'), agentList.stdout, { encoding: 'utf8', flag: 'wx' });
  const environment = await loadEnvironment(version);
  await writeNewJson(outputDirectory, 'environment.json', environment);
  await writeNewJson(outputDirectory, 'experiment.json', {
    adapter: 'opencode-no-skill',
    benchmark_version: BENCHMARK_VERSION,
    configuration: 'no-skill',
    model: environment.model,
    opencode_arguments: ['run', '--pure', '--format', 'json', '--model', environment.model, '--agent', 'build', '--variant', 'medium'],
    retry_policy: 'none',
    trials: TRIALS,
  });
  const scenarios = await loadTrainingScenarios(path.join(benchmarkDirectory, 'scenarios', 'training'));
  const manifest = JSON.parse(await readFile(path.join(benchmarkDirectory, 'scenarios', 'true-held-out-manifest.json'), 'utf8'));
  validateBenchmarkCorpus({ scenarios, manifest });
  const report = await runBenchmark({
    scenarios,
    adapter: createOpenCodeNoSkillAdapter({ rawEvidenceDirectory: path.join(outputDirectory, 'raw') }),
    configurations: ['no-skill'],
    trials: TRIALS,
    benchmarkVersion: BENCHMARK_VERSION,
    environment,
  });
  const runArtifact = await writeRunArtifact(report, outputDirectory);
  const score = scoreReport(report);
  const scoreArtifact = await writeScoreArtifact(score, outputDirectory);
  const summary = summarizeNoSkillBaseline({ report, score });
  await writeNewJson(outputDirectory, 'summary.json', summary);
  process.stdout.write(`${JSON.stringify({ run_artifact: runArtifact, score_artifact: scoreArtifact, summary_path: path.join(outputDirectory, 'summary.json'), runs: report.runs.length, failures: summary.failures.length, fresh_sessions: summary.session_evidence.pass })}\n`);
  if (!summary.session_evidence.pass) {
    throw new Error('Baseline evidence does not prove fresh sessions');
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
