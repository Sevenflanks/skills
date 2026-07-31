import { CATEGORIES, DISPOSITIONS, SCENARIO_SCHEMA_VERSION } from './constants.mjs';
import {
  assertArray,
  assertBoolean,
  assertEnum,
  assertExactKeys,
  assertObject,
  assertString,
  assertUniqueStrings,
  fail,
} from './validation.mjs';

export function validateSources(sources, path) {
  assertArray(sources, path);
  if (sources.length === 0) {
    fail(path, 'must not be empty');
  }
  const ids = new Set();
  for (const [index, source] of sources.entries()) {
    const sourcePath = `${path}[${index}]`;
    assertObject(source, sourcePath);
    assertExactKeys(source, ['content', 'id'], sourcePath);
    assertString(source.id, `${sourcePath}.id`);
    assertString(source.content, `${sourcePath}.content`);
    if (ids.has(source.id)) {
      fail(path, `must not repeat source ${source.id}`);
    }
    ids.add(source.id);
  }
  return ids;
}

function validateOracle(oracle, path) {
  assertObject(oracle, path);
  assertExactKeys(oracle, ['forbidden_action_ids', 'id', 'required_action_ids'], path);
  assertString(oracle.id, `${path}.id`);
  assertUniqueStrings(oracle.required_action_ids, `${path}.required_action_ids`);
  assertArray(oracle.forbidden_action_ids, `${path}.forbidden_action_ids`);
  for (const [index, action] of oracle.forbidden_action_ids.entries()) {
    assertString(action, `${path}.forbidden_action_ids[${index}]`);
  }
}

export function validateScenario(scenario) {
  assertObject(scenario, 'scenario');
  assertExactKeys(
    scenario,
    [
      'acceptance_oracle', 'allowed_next_actions', 'authoritative_sources', 'baseline_validity',
      'category', 'confirmed_intent_truth', 'correct_disposition',
      'earliest_prohibited_direction_changing_edit', 'evidence_reveal_order', 'family_id',
      'framing_pair_id', 'framing_variant', 'id', 'partition', 'prompt',
      'reflection_expectations', 'schema_version',
    ],
    'scenario',
  );
  if (scenario.schema_version !== SCENARIO_SCHEMA_VERSION) {
    fail('scenario.schema_version', `must equal ${SCENARIO_SCHEMA_VERSION}`);
  }
  assertString(scenario.id, 'scenario.id');
  assertEnum(scenario.partition, ['training', 'true-held-out'], 'scenario.partition');
  assertEnum(scenario.category, CATEGORIES, 'scenario.category');
  assertString(scenario.family_id, 'scenario.family_id');
  assertString(scenario.prompt, 'scenario.prompt');
  const sourceIds = validateSources(scenario.authoritative_sources, 'scenario.authoritative_sources');
  assertUniqueStrings(scenario.evidence_reveal_order, 'scenario.evidence_reveal_order');
  for (const sourceId of scenario.evidence_reveal_order) {
    if (!sourceIds.has(sourceId)) {
      fail('scenario.evidence_reveal_order', `references unknown source ${sourceId}`);
    }
  }
  assertString(scenario.confirmed_intent_truth, 'scenario.confirmed_intent_truth');
  assertBoolean(scenario.baseline_validity, 'scenario.baseline_validity');
  assertEnum(scenario.correct_disposition, DISPOSITIONS, 'scenario.correct_disposition');
  assertUniqueStrings(scenario.allowed_next_actions, 'scenario.allowed_next_actions');
  assertString(scenario.earliest_prohibited_direction_changing_edit, 'scenario.earliest_prohibited_direction_changing_edit');
  validateOracle(scenario.acceptance_oracle, 'scenario.acceptance_oracle');
  assertObject(scenario.reflection_expectations, 'scenario.reflection_expectations');
  assertExactKeys(scenario.reflection_expectations, ['stage_one', 'stage_two', 'user_interruption'], 'scenario.reflection_expectations');
  for (const key of ['stage_one', 'stage_two', 'user_interruption']) {
    assertBoolean(scenario.reflection_expectations[key], `scenario.reflection_expectations.${key}`);
  }
  if (scenario.reflection_expectations.stage_two && !scenario.reflection_expectations.stage_one) {
    fail('scenario.reflection_expectations', 'cannot require stage two without stage one');
  }
  if (scenario.category === 'framing-inversion') {
    assertString(scenario.framing_pair_id, 'scenario.framing_pair_id');
    assertEnum(scenario.framing_variant, ['baseline', 'pivot'], 'scenario.framing_variant');
  } else if (scenario.framing_pair_id !== null || scenario.framing_variant !== null) {
    fail('scenario.framing_pair_id', 'must be null outside framing-inversion');
  }
  return scenario;
}
