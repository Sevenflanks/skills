import { CONFIGURATIONS, DISPOSITIONS, RUN_REPORT_SCHEMA_VERSION, SCORE_SCHEMA_VERSION } from './constants.mjs';
import { validateExecution } from './execution-contracts.mjs';
import { validateEnvironment } from './environment-contracts.mjs';
import {
  assertArray,
  assertBoolean,
  assertEnum,
  assertExactKeys,
  assertObject,
  assertPositiveInteger,
  assertString,
  assertUniqueStrings,
  fail,
} from './validation.mjs';

function validateAcceptance(acceptance, events) {
  assertObject(acceptance, 'run.harness_acceptance');
  assertExactKeys(acceptance, ['observations', 'owner', 'passed'], 'run.harness_acceptance');
  if (acceptance.owner !== 'benchmark-harness') {
    fail('run.harness_acceptance.owner', 'must be benchmark-harness');
  }
  assertBoolean(acceptance.passed, 'run.harness_acceptance.passed');
  assertArray(acceptance.observations, 'run.harness_acceptance.observations');
  const eventIds = new Set(events.map((event) => event.id));
  for (const [index, observation] of acceptance.observations.entries()) {
    const path = `run.harness_acceptance.observations[${index}]`;
    assertObject(observation, path);
    assertExactKeys(observation, ['evidence_event_ids', 'id', 'passed'], path);
    assertString(observation.id, `${path}.id`);
    assertBoolean(observation.passed, `${path}.passed`);
    assertArray(observation.evidence_event_ids, `${path}.evidence_event_ids`);
    for (const eventId of observation.evidence_event_ids) {
      if (!eventIds.has(eventId)) {
        fail(`${path}.evidence_event_ids`, `references unknown event ${eventId}`);
      }
    }
  }
  if (acceptance.passed !== acceptance.observations.every((observation) => observation.passed)) {
    fail('run.harness_acceptance.passed', 'must match its observations');
  }
}

function validateAdjudication(adjudication) {
  assertObject(adjudication, 'run.adjudication');
  assertExactKeys(
    adjudication,
    [
      'allowed_next_actions', 'baseline_validity', 'correct_disposition',
      'earliest_prohibited_direction_changing_edit', 'reflection_expectations', 'source_ids',
    ],
    'run.adjudication',
  );
  assertUniqueStrings(adjudication.allowed_next_actions, 'run.adjudication.allowed_next_actions');
  assertBoolean(adjudication.baseline_validity, 'run.adjudication.baseline_validity');
  assertEnum(adjudication.correct_disposition, DISPOSITIONS, 'run.adjudication.correct_disposition');
  assertString(adjudication.earliest_prohibited_direction_changing_edit, 'run.adjudication.earliest_prohibited_direction_changing_edit');
  assertObject(adjudication.reflection_expectations, 'run.adjudication.reflection_expectations');
  for (const key of ['stage_one', 'stage_two', 'user_interruption']) {
    assertBoolean(adjudication.reflection_expectations[key], `run.adjudication.reflection_expectations.${key}`);
  }
  assertUniqueStrings(adjudication.source_ids, 'run.adjudication.source_ids');
}

export function validateRunReport(report) {
  assertObject(report, 'run report');
  assertExactKeys(report, ['benchmark_version', 'environment', 'runs', 'schema_version'], 'run report');
  if (report.schema_version !== RUN_REPORT_SCHEMA_VERSION) {
    fail('run report.schema_version', `must equal ${RUN_REPORT_SCHEMA_VERSION}`);
  }
  assertString(report.benchmark_version, 'run report.benchmark_version');
  validateEnvironment(report.environment);
  assertArray(report.runs, 'run report.runs');
  for (const [index, run] of report.runs.entries()) {
    const path = `run report.runs[${index}]`;
    assertObject(run, path);
    for (const key of ['category', 'family_id', 'run_id', 'scenario_id']) {
      assertString(run[key], `${path}.${key}`);
    }
    validateAdjudication(run.adjudication);
    assertEnum(run.configuration, CONFIGURATIONS, `${path}.configuration`);
    assertPositiveInteger(run.trial, `${path}.trial`);
    assertEnum(run.status, ['completed', 'failed'], `${path}.status`);
    if (run.status === 'completed') {
      validateExecution(run.transcript);
      validateAcceptance(run.harness_acceptance, run.transcript.events);
      if (run.failure !== null) {
        fail(`${path}.failure`, 'must be null for a completed run');
      }
    } else {
      if (run.transcript !== null || run.harness_acceptance !== null) {
        fail(path, 'failed runs must not invent transcript or acceptance data');
      }
      assertObject(run.failure, `${path}.failure`);
      assertString(run.failure.code, `${path}.failure.code`);
      assertString(run.failure.message, `${path}.failure.message`);
    }
  }
  return report;
}

export function validateScore(score) {
  assertObject(score, 'score');
  assertExactKeys(score, ['benchmark_version', 'results', 'schema_version', 'summary'], 'score');
  if (score.schema_version !== SCORE_SCHEMA_VERSION) {
    fail('score.schema_version', `must equal ${SCORE_SCHEMA_VERSION}`);
  }
  assertString(score.benchmark_version, 'score.benchmark_version');
  assertArray(score.results, 'score.results');
  assertObject(score.summary, 'score.summary');
  for (const [index, result] of score.results.entries()) {
    const path = `score.results[${index}]`;
    assertObject(result, path);
    assertBoolean(result.overall_pass, `${path}.overall_pass`);
    for (const key of ['process', 'outcome', 'cost']) {
      assertObject(result[key], `${path}.${key}`);
      assertBoolean(result[key].pass, `${path}.${key}.pass`);
    }
  }
  return score;
}
