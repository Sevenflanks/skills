import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  HELD_OUT_MANIFEST_SCHEMA_VERSION,
  validateHeldOutScenarioCorpus,
} from '../lib/contracts.mjs';
import { loadPrivateHeldOutScenarios, loadTrainingScenarios } from '../lib/runner.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const trainingDirectory = path.join(directory, '..', 'scenarios', 'training');

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function privateScenario(source, id, familyId) {
  const scenario = clone(source);
  scenario.id = id;
  scenario.partition = 'true-held-out';
  scenario.family_id = familyId;
  if (scenario.category === 'framing-inversion') {
    scenario.framing_pair_id = 'private-framing-pair';
  }
  return scenario;
}

function manifestFor(scenarios) {
  return {
    schema_version: HELD_OUT_MANIFEST_SCHEMA_VERSION,
    entries: scenarios.map((scenario) => ({
      id: scenario.id,
      category: scenario.category,
      family_id: scenario.family_id,
      sha256: createHash('sha256').update(JSON.stringify(scenario)).digest('hex'),
    })),
  };
}

test('Given a balanced private corpus, when loaded against its manifest, then paired framing truth remains source-first compatible', async () => {
  const training = await loadTrainingScenarios(trainingDirectory);
  const byId = new Map(training.map((scenario) => [scenario.id, scenario]));
  const scenarios = [
    privateScenario(byId.get('train-harmful-fixture-ownership'), 'heldout-test-1', 'family-ht-test-1'),
    privateScenario(byId.get('train-necessary-user-correction'), 'heldout-test-2', 'family-ht-test-2'),
    privateScenario(byId.get('train-within-intent-parser'), 'heldout-test-3', 'family-ht-test-3'),
    privateScenario(byId.get('train-routine-typo'), 'heldout-test-4', 'family-ht-test-4'),
    privateScenario(byId.get('train-framing-baseline'), 'heldout-test-5', 'family-ht-test-5'),
    privateScenario(byId.get('train-framing-pivot'), 'heldout-test-6', 'family-ht-test-5'),
  ];
  const manifest = manifestFor(scenarios);
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-held-out-'));
  await Promise.all(scenarios.map((scenario) => writeFile(
    path.join(temporaryDirectory, `${scenario.id}.json`),
    `${JSON.stringify(scenario)}\n`,
    'utf8',
  )));

  const loaded = await loadPrivateHeldOutScenarios({ directory: temporaryDirectory, manifest });
  assert.equal(loaded.length, 6);

  const mismatchedTruth = clone(scenarios);
  mismatchedTruth.find((scenario) => scenario.framing_variant === 'pivot').confirmed_intent_truth = 'different truth';
  assert.throws(() => validateHeldOutScenarioCorpus(mismatchedTruth), /oracle truth/);
});
