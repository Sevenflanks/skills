import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ADAPTER_REQUEST_SCHEMA_VERSION,
  HELD_OUT_MANIFEST_SCHEMA_VERSION,
  SCENARIO_SCHEMA_VERSION,
  validateAdapterRequest,
  validateCorpus,
  validateExecution,
  validateHeldOutManifest,
  validateRunReport,
  validateScenario,
} from '../lib/contracts.mjs';
import {
  createHarnessRun,
  loadTrainingScenarios,
  sanitizeAdapterRequest,
} from '../lib/runner.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkRoot = path.resolve(directory, '..');
const trainingDirectory = path.join(benchmarkRoot, 'scenarios', 'training');
const heldOutManifestPath = path.join(benchmarkRoot, 'scenarios', 'true-held-out-manifest.json');
const testEnvironment = {
  schema_version: 'self-challenge-environment.v1',
  model: 'test-model',
  runtime: { name: 'node', version: '20.0.0' },
  skill_catalog: [{ name: 'test-skill', version: '1.0.0' }],
  sampling_settings: { seed: 0, temperature: 0, top_p: 1 },
  tool_availability: [{ name: 'file-read', available: true }],
};

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

test('Given the training corpus, when contracts validate it, then every required category is pre-adjudicated', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const manifest = await readJson(heldOutManifestPath);

  assert.equal(scenarios.length, 6);
  assert.deepEqual(
    new Set(scenarios.map((scenario) => scenario.category)),
    new Set([
      'harmful-pivot',
      'necessary-pivot',
      'within-intent-adaptation',
      'routine-near-miss',
      'framing-inversion',
    ]),
  );
  assert.equal(scenarios.filter((scenario) => scenario.category === 'framing-inversion').length, 2);
  for (const scenario of scenarios) {
    assert.equal(scenario.schema_version, SCENARIO_SCHEMA_VERSION);
    assert.doesNotThrow(() => validateScenario(scenario));
  }
  assert.doesNotThrow(() => validateHeldOutManifest(manifest));
  assert.doesNotThrow(() => validateCorpus(scenarios, manifest));
});

test('Given malformed adjudication, when scenario validation runs, then it rejects missing and invalid fields', async () => {
  const [scenario] = await loadTrainingScenarios(trainingDirectory);
  const missingOracle = clone(scenario);
  delete missingOracle.acceptance_oracle;
  assert.throws(() => validateScenario(missingOracle), /acceptance_oracle/);

  const invalidDisposition = clone(scenario);
  invalidDisposition.correct_disposition = 'APPROVE_PIVOT';
  assert.throws(() => validateScenario(invalidDisposition), /correct_disposition/);
});

test('Given a held-out manifest, when corpus isolation is checked, then it exposes only opaque metadata and rejects overlap', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const manifest = await readJson(heldOutManifestPath);
  assert.equal(manifest.schema_version, HELD_OUT_MANIFEST_SCHEMA_VERSION);
  for (const entry of manifest.entries) {
    assert.deepEqual(Object.keys(entry).sort(), ['category', 'family_id', 'id', 'sha256']);
    assert.match(entry.id, /^heldout-[a-z0-9-]+$/);
    assert.match(entry.sha256, /^[a-f0-9]{64}$/);
  }

  const overlappingScenarios = clone(scenarios);
  overlappingScenarios.find((scenario) => scenario.category === 'harmful-pivot').family_id = manifest.entries[0].family_id;
  assert.throws(() => validateCorpus(overlappingScenarios, manifest), /family overlap/);
});

test('Given a framing-inversion held-out pair, when manifest validation runs, then it permits one shared opaque family', async () => {
  const manifest = await readJson(heldOutManifestPath);
  const framing = manifest.entries.filter((entry) => entry.category === 'framing-inversion');
  assert.equal(framing.length, 2);
  assert.equal(framing[0].family_id, framing[1].family_id);
  assert.doesNotThrow(() => validateHeldOutManifest(manifest));

  const unpaired = clone(manifest);
  unpaired.entries.splice(unpaired.entries.findIndex((entry) => entry.id === framing[1].id), 1);
  assert.throws(() => validateHeldOutManifest(unpaired), /opaque pair/);
});

test('Given distorted training coverage, when corpus validation runs, then it rejects missing categories and unpaired framing sources', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const manifest = await readJson(heldOutManifestPath);
  assert.throws(
    () => validateCorpus(scenarios.filter((scenario) => scenario.category !== 'routine-near-miss'), manifest),
    /must cover every category/,
  );

  const mismatchedFraming = clone(scenarios);
  const pivot = mismatchedFraming.find((scenario) => scenario.framing_variant === 'pivot');
  pivot.authoritative_sources[0].content = 'Different source content';
  assert.throws(() => validateCorpus(mismatchedFraming, manifest), /identical authoritative sources/);
});

test('Given a scenario, when an adapter request is built, then private benchmark controls are absent', async () => {
  const [scenario] = await loadTrainingScenarios(trainingDirectory);
  const request = sanitizeAdapterRequest(scenario, 'full-two-stage', 1);
  assert.equal(request.schema_version, ADAPTER_REQUEST_SCHEMA_VERSION);
  assert.equal(request.configuration, 'full-two-stage');
  assert.doesNotThrow(() => validateAdapterRequest(request));

  const serialized = JSON.stringify(request);
  for (const privateField of [
    'confirmed_intent_truth', 'baseline_validity', 'correct_disposition', 'allowed_next_actions',
    'earliest_prohibited_direction_changing_edit', 'acceptance_oracle', 'cost_limits',
    'partition', 'category', 'family_id',
  ]) {
    assert.equal(serialized.includes(privateField), false, `${privateField} leaked`);
  }
});

test('Given adapter-owned acceptance data, when transcript validation runs, then it rejects the forged observation', () => {
  assert.throws(
    () => validateExecution({
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [{ id: 'event-1', sequence: 1, type: 'acceptance_observation' }],
      usage: { input_tokens: 0, output_tokens: 0, tool_calls: 0, elapsed_ms: null },
    }),
    /supported observable event/,
  );
});

test('Given execution usage or reversals that violate the transcript contract, when validation runs, then it rejects them', () => {
  assert.throws(
    () => validateExecution({
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [],
      usage: { input_tokens: 0, output_tokens: 0, tool_calls: 0, elapsed_ms: null },
    }),
    /turns/,
  );
  assert.throws(
    () => validateExecution({
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [
        { id: 'event-1', sequence: 1, type: 'action_reverted', action_event_id: 'event-2' },
        { id: 'event-2', sequence: 2, type: 'agent_action', action_id: 'defer-edit', direction_changing: true },
      ],
      usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: null },
    }),
    /earlier agent_action/,
  );
});

test('Given a forged run-report acceptance flag, when report validation runs, then it rejects the mismatch', async () => {
  const [scenario] = await loadTrainingScenarios(trainingDirectory);
  const run = createHarnessRun({
    scenario,
    configuration: 'no-skill',
    trial: 1,
    benchmarkVersion: 'test-v1',
    execution: {
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [{
        id: 'event-1', sequence: 1, type: 'agent_action',
        action_id: scenario.earliest_prohibited_direction_changing_edit,
        direction_changing: true,
      }],
      usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: null },
    },
  });
  run.harness_acceptance.passed = true;
  assert.throws(
    () => validateRunReport({
      schema_version: 'self-challenge-run-report.v1', benchmark_version: 'test-v1', environment: testEnvironment, runs: [run],
    }),
    /must match its observations/,
  );
});
