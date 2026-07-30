import {
  ADAPTER_REQUEST_SCHEMA_VERSION,
  CATEGORIES,
  CONFIGURATIONS,
  HELD_OUT_MANIFEST_SCHEMA_VERSION,
} from './constants.mjs';
import { validateScenario, validateSources } from './scenario-contracts.mjs';
import {
  assertArray,
  assertEnum,
  assertExactKeys,
  assertObject,
  assertPositiveInteger,
  assertString,
  assertUniqueStrings,
  fail,
} from './validation.mjs';

export function validateHeldOutManifest(manifest) {
  assertObject(manifest, 'held-out manifest');
  assertExactKeys(manifest, ['entries', 'schema_version'], 'held-out manifest');
  if (manifest.schema_version !== HELD_OUT_MANIFEST_SCHEMA_VERSION) {
    fail('held-out manifest.schema_version', `must equal ${HELD_OUT_MANIFEST_SCHEMA_VERSION}`);
  }
  assertArray(manifest.entries, 'held-out manifest.entries');
  if (manifest.entries.length === 0) {
    fail('held-out manifest.entries', 'must not be empty');
  }
  const ids = new Set();
  const families = new Map();
  for (const [index, entry] of manifest.entries.entries()) {
    const entryPath = `held-out manifest.entries[${index}]`;
    assertObject(entry, entryPath);
    assertExactKeys(entry, ['category', 'family_id', 'id', 'sha256'], entryPath);
    assertString(entry.id, `${entryPath}.id`);
    if (!/^heldout-[a-z0-9-]+$/.test(entry.id)) {
      fail(`${entryPath}.id`, 'must be an opaque heldout identifier');
    }
    assertEnum(entry.category, CATEGORIES, `${entryPath}.category`);
    assertString(entry.family_id, `${entryPath}.family_id`);
    if (!/^family-ht-[a-z0-9-]+$/.test(entry.family_id)) {
      fail(`${entryPath}.family_id`, 'must be an opaque held-out family identifier');
    }
    assertString(entry.sha256, `${entryPath}.sha256`);
    if (!/^[a-f0-9]{64}$/.test(entry.sha256)) {
      fail(`${entryPath}.sha256`, 'must be a lowercase SHA-256 digest');
    }
    if (ids.has(entry.id)) {
      fail('held-out manifest.entries', 'must not repeat IDs');
    }
    ids.add(entry.id);
    const family = families.get(entry.family_id) ?? [];
    family.push(entry);
    families.set(entry.family_id, family);
  }
  if (CATEGORIES.some((category) => !manifest.entries.some((entry) => entry.category === category))) {
    fail('held-out manifest.entries', 'must cover every category');
  }
  for (const [familyId, entries] of families) {
    const framing = entries.filter((entry) => entry.category === 'framing-inversion');
    if (framing.length > 0 && (entries.length !== 2 || framing.length !== 2)) {
      fail('held-out manifest.entries', `framing-inversion family ${familyId} must represent one opaque pair`);
    }
    if (framing.length === 0 && entries.length !== 1) {
      fail('held-out manifest.entries', `non-framing family ${familyId} must remain a singleton`);
    }
  }
  return manifest;
}

function sourceFingerprint(scenario) {
  return scenario.authoritative_sources
    .map((source) => `${source.id}\u0000${source.content}`)
    .sort()
    .join('\u0001');
}

function oracleTruthFingerprint(scenario) {
  return JSON.stringify({
    acceptance_oracle: scenario.acceptance_oracle,
    allowed_next_actions: scenario.allowed_next_actions,
    baseline_validity: scenario.baseline_validity,
    confirmed_intent_truth: scenario.confirmed_intent_truth,
    correct_disposition: scenario.correct_disposition,
    earliest_prohibited_direction_changing_edit: scenario.earliest_prohibited_direction_changing_edit,
    reflection_expectations: scenario.reflection_expectations,
  });
}

function validateFramingPairs(scenarios, label) {
  const pairs = new Map();
  for (const scenario of scenarios.filter((item) => item.category === 'framing-inversion')) {
    const pair = pairs.get(scenario.family_id) ?? [];
    pair.push(scenario);
    pairs.set(scenario.family_id, pair);
  }
  for (const [familyId, pair] of pairs) {
    const variants = new Set(pair.map((scenario) => scenario.framing_variant));
    const sourceFingerprints = new Set(pair.map(sourceFingerprint));
    const oracleFingerprints = new Set(pair.map(oracleTruthFingerprint));
    const pairIds = new Set(pair.map((scenario) => scenario.framing_pair_id));
    if (pair.length !== 2 || variants.size !== 2 || !variants.has('baseline') || !variants.has('pivot') || pairIds.size !== 1) {
      fail(label, `framing family ${familyId} must contain one baseline and one pivot`);
    }
    if (sourceFingerprints.size !== 1 || oracleFingerprints.size !== 1) {
      fail(label, `framing family ${familyId} must use identical authoritative sources and oracle truth`);
    }
  }
}

function validateTrainingCoverage(scenarios) {
  const categories = new Set(scenarios.map((scenario) => scenario.category));
  if (categories.size !== CATEGORIES.length || CATEGORIES.some((category) => !categories.has(category))) {
    fail('training scenarios', 'must cover every category');
  }
  validateFramingPairs(scenarios, 'training scenarios');
}

export function validateHeldOutScenarioCorpus(scenarios) {
  assertArray(scenarios, 'private held-out scenarios');
  if (scenarios.length === 0) {
    fail('private held-out scenarios', 'must not be empty');
  }
  const ids = new Set();
  for (const scenario of scenarios) {
    validateScenario(scenario);
    if (scenario.partition !== 'true-held-out') {
      fail('private held-out scenarios', 'must contain only true-held-out scenarios');
    }
    if (ids.has(scenario.id)) {
      fail('private held-out scenarios', `must not repeat scenario ${scenario.id}`);
    }
    ids.add(scenario.id);
  }
  if (CATEGORIES.some((category) => !scenarios.some((scenario) => scenario.category === category))) {
    fail('private held-out scenarios', 'must cover every category');
  }
  validateFramingPairs(scenarios, 'private held-out scenarios');
  return scenarios;
}

export function validateCorpus(scenarios, manifest) {
  assertArray(scenarios, 'training scenarios');
  if (scenarios.length === 0) {
    fail('training scenarios', 'must not be empty');
  }
  const ids = new Set();
  const families = new Set();
  for (const scenario of scenarios) {
    validateScenario(scenario);
    if (scenario.partition !== 'training') {
      fail('training scenarios', 'must contain only training scenarios');
    }
    if (ids.has(scenario.id)) {
      fail('training scenarios', `must not repeat scenario ${scenario.id}`);
    }
    ids.add(scenario.id);
    families.add(scenario.family_id);
  }
  validateTrainingCoverage(scenarios);
  validateHeldOutManifest(manifest);
  for (const entry of manifest.entries) {
    if (families.has(entry.family_id)) {
      fail('scenario corpus', `family overlap detected for ${entry.family_id}`);
    }
  }
  return { scenarios, manifest };
}

export function validateAdapterRequest(request) {
  assertObject(request, 'adapter request');
  assertExactKeys(request, ['configuration', 'scenario', 'schema_version', 'trial'], 'adapter request');
  if (request.schema_version !== ADAPTER_REQUEST_SCHEMA_VERSION) {
    fail('adapter request.schema_version', `must equal ${ADAPTER_REQUEST_SCHEMA_VERSION}`);
  }
  assertEnum(request.configuration, CONFIGURATIONS, 'adapter request.configuration');
  assertPositiveInteger(request.trial, 'adapter request.trial');
  assertObject(request.scenario, 'adapter request.scenario');
  assertExactKeys(request.scenario, ['authoritative_sources', 'evidence_reveal_order', 'id', 'prompt'], 'adapter request.scenario');
  assertString(request.scenario.id, 'adapter request.scenario.id');
  assertString(request.scenario.prompt, 'adapter request.scenario.prompt');
  const sourceIds = validateSources(request.scenario.authoritative_sources, 'adapter request.scenario.authoritative_sources');
  assertUniqueStrings(request.scenario.evidence_reveal_order, 'adapter request.scenario.evidence_reveal_order');
  for (const sourceId of request.scenario.evidence_reveal_order) {
    if (!sourceIds.has(sourceId)) {
      fail('adapter request.scenario.evidence_reveal_order', `references unknown source ${sourceId}`);
    }
  }
  return request;
}
