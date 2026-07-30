import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ENVIRONMENT_SCHEMA_VERSION,
  validateEnvironment,
} from '../lib/contracts.mjs';
import {
  loadBenchmarkEnvironment,
  loadTrainingScenarios,
  runBenchmark,
} from '../lib/runner.mjs';
import deterministicAdapter from '../fixtures/deterministic-adapter.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkRoot = path.resolve(directory, '..');
const environmentPath = path.join(benchmarkRoot, 'fixtures', 'deterministic-environment.json');
const trainingDirectory = path.join(benchmarkRoot, 'scenarios', 'training');

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

test('Given the deterministic environment fixture, when a benchmark runs, then report metadata survives unchanged', async () => {
  const environment = await loadBenchmarkEnvironment(environmentPath);
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const report = await runBenchmark({
    scenarios,
    adapter: deterministicAdapter,
    configurations: ['no-skill'],
    trials: 1,
    benchmarkVersion: 'test-v1',
    environment,
  });

  assert.equal(environment.schema_version, ENVIRONMENT_SCHEMA_VERSION);
  assert.deepEqual(report.environment, environment);
});

test('Given missing or malformed environment data, when validated, then execution fails explicitly', async () => {
  await assert.rejects(
    () => loadBenchmarkEnvironment(path.join(benchmarkRoot, 'fixtures', 'missing-environment.json')),
    /environment/,
  );

  const environment = await loadBenchmarkEnvironment(environmentPath);
  const malformed = clone(environment);
  delete malformed.model;
  assert.throws(() => validateEnvironment(malformed), /model/);

  const [scenario] = await loadTrainingScenarios(trainingDirectory);
  await assert.rejects(
    () => runBenchmark({
      scenarios: [scenario],
      adapter: deterministicAdapter,
      configurations: ['no-skill'],
      trials: 1,
      benchmarkVersion: 'test-v1',
    }),
    /environment/,
  );
});
