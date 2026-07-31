#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { CONFIGURATIONS } from '../lib/contracts.mjs';
import {
  loadPrivateHeldOutScenarios,
  loadBenchmarkEnvironment,
  loadTrainingScenarios,
  runBenchmark,
  validateBenchmarkCorpus,
  writeRunArtifact,
} from '../lib/runner.mjs';

const binDirectory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkDirectory = path.resolve(binDirectory, '..');
const defaultAdapter = path.join(benchmarkDirectory, 'fixtures', 'deterministic-adapter.mjs');
const defaultTrainingDirectory = path.join(benchmarkDirectory, 'scenarios', 'training');
const defaultManifest = path.join(benchmarkDirectory, 'scenarios', 'true-held-out-manifest.json');
const defaultEnvironment = path.join(benchmarkDirectory, 'fixtures', 'deterministic-environment.json');

function usage() {
  return `Usage: node benchmarks/self-challenge/bin/run.mjs [options]

Options:
  --adapter <module>              ESM adapter module with a default function
  --configuration <name>          Repeatable: ${CONFIGURATIONS.join(', ')}
  --trials <positive integer>     Repetitions per scenario/configuration (default: 1)
  --output <directory>            Artifact directory (default: .benchmark-artifacts/self-challenge)
  --private-scenarios <directory> Load a private true-held-out directory verified by the manifest
  --held-out-manifest <file>      Manifest used with --private-scenarios
  --environment <file>            Required environment metadata; only fixture smoke runs default to deterministic fixture
  --benchmark-version <value>     Stable report version label (default: self-challenge-foundation-v1)
  --help                          Show this help
`;
}

function nextValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function parseArguments(argv) {
  const options = {
    adapter: defaultAdapter,
    configurations: [],
    trials: 1,
    output: path.resolve(process.cwd(), '.benchmark-artifacts', 'self-challenge'),
    privateScenarios: null,
    heldOutManifest: defaultManifest,
    environment: null,
    benchmarkVersion: 'self-challenge-foundation-v1',
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--help') {
      return { help: true };
    }
    if (option === '--adapter') {
      options.adapter = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--configuration') {
      const configuration = nextValue(argv, index, option);
      if (!CONFIGURATIONS.includes(configuration)) {
        throw new Error(`--configuration must be one of: ${CONFIGURATIONS.join(', ')}`);
      }
      options.configurations.push(configuration);
      index += 1;
    } else if (option === '--trials') {
      const trials = Number(nextValue(argv, index, option));
      if (!Number.isInteger(trials) || trials < 1) {
        throw new Error('--trials must be a positive integer');
      }
      options.trials = trials;
      index += 1;
    } else if (option === '--output') {
      options.output = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--private-scenarios') {
      options.privateScenarios = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--held-out-manifest') {
      options.heldOutManifest = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--benchmark-version') {
      options.benchmarkVersion = nextValue(argv, index, option);
      index += 1;
    } else if (option === '--environment') {
      options.environment = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else {
      throw new Error(`Unknown option ${option}`);
    }
  }
  return options;
}

async function loadAdapter(adapterPath) {
  const module = await import(pathToFileURL(adapterPath).href);
  if (typeof module.default !== 'function') {
    throw new Error(`Adapter ${adapterPath} must export a default function`);
  }
  return module.default;
}

async function readManifest(manifestPath) {
  return JSON.parse(await readFile(manifestPath, 'utf8'));
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const fixtureSmokeRun = options.adapter === defaultAdapter && options.privateScenarios === null;
  const environmentPath = options.environment ?? (fixtureSmokeRun ? defaultEnvironment : null);
  if (!environmentPath) {
    throw new Error('--environment is required unless the deterministic fixture adapter is used without private scenarios');
  }
  const environment = await loadBenchmarkEnvironment(environmentPath);
  const trainingScenarios = await loadTrainingScenarios(defaultTrainingDirectory);
  const manifest = await readManifest(options.heldOutManifest);
  const privateScenarios = options.privateScenarios
    ? await loadPrivateHeldOutScenarios({ directory: options.privateScenarios, manifest })
    : [];
  validateBenchmarkCorpus({ scenarios: trainingScenarios, manifest });
  const report = await runBenchmark({
    scenarios: [...trainingScenarios, ...privateScenarios],
    adapter: await loadAdapter(options.adapter),
    configurations: options.configurations.length === 0 ? CONFIGURATIONS : options.configurations,
    trials: options.trials,
    benchmarkVersion: options.benchmarkVersion,
    environment,
  });
  const artifactPath = await writeRunArtifact(report, options.output);
  process.stdout.write(`${JSON.stringify({ artifact_path: artifactPath, run_count: report.runs.length })}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
