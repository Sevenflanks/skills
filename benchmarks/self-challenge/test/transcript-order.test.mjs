import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { validateExecution } from '../lib/contracts.mjs';
import { loadTrainingScenarios, runBenchmark } from '../lib/runner.mjs';
import { scoreReport } from '../lib/scorer.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const trainingDirectory = path.join(directory, '..', 'scenarios', 'training');
const environment = {
  schema_version: 'self-challenge-environment.v1',
  model: 'test-model',
  runtime: { name: 'node', version: '20.0.0' },
  skill_catalog: [{ name: 'test-skill', version: '1.0.0' }],
  sampling_settings: { seed: 0, temperature: 0, top_p: 1 },
  tool_availability: [{ name: 'file-read', available: true }],
};

function execution(events) {
  return {
    schema_version: 'self-challenge-adapter-execution.v1',
    events: events.map((entry, index) => ({ id: `event-${index + 1}`, sequence: index + 1, ...entry })),
    usage: { input_tokens: 1, output_tokens: 1, turns: 3, tool_calls: 2, elapsed_ms: 1 },
  };
}

function reconstruction(agentId, sourceIds = ['ownership-contract']) {
  return {
    type: 'subagent_reconstruction',
    agent_id: agentId,
    source_ids: sourceIds,
    baseline: 'Keep the baseline.',
    invariants: ['The contract remains stable.'],
    source_conflicts: [],
    source_precedence: 'resolved',
    alternative_hypotheses: ['Repair the implementation.'],
    falsification_conditions: ['A later decision changes the contract.'],
  };
}

function verdict(agentId, sourceIds = ['ownership-contract']) {
  return {
    type: 'verdict',
    agent_id: agentId,
    evidence_source_ids: sourceIds,
    evidence_sufficient: true,
    source_precedence: 'resolved',
    value: 'KEEP_COURSE',
    baseline_steelman: 'The source is explicit.',
    candidate_steelman: 'The change could simplify implementation.',
    main_agent_error_risk: 'A local defect could be mistaken for a direction change.',
    protected_or_invalidated_invariant: 'The contract remains stable.',
    change_condition: 'A later explicit decision changes the contract.',
    reason: 'The source supports the baseline.',
    allowed_next_action: 'keep-private-fixture-location',
  };
}

function malformedFullStageTwo() {
  return execution([
    { type: 'stage_one_started' },
    { type: 'stage_one_completed' },
    { type: 'stage_two_started' },
    { type: 'subagent_spawned', agent_id: 'reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true },
    { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-1' },
    { type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-1' },
    { type: 'source_retrieved', source_id: 'failing-test', actor: 'subagent', agent_id: 'reader-1' },
    reconstruction('reader-1', ['ownership-contract', 'failing-test']),
    { type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-1' },
    verdict('reader-1', ['ownership-contract', 'failing-test']),
    { type: 'agent_action', action_id: 'keep-private-fixture-location', direction_changing: false },
  ]);
}

function completeFullStageTwo() {
  return [
    { type: 'stage_one_started' },
    { type: 'stage_one_completed' },
    { type: 'stage_two_started' },
    { type: 'subagent_spawned', agent_id: 'reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true },
    { type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-1' },
    { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-1' },
    reconstruction('reader-1'),
    { type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-1' },
    verdict('reader-1'),
    { type: 'agent_action', action_id: 'keep-private-fixture-location', direction_changing: false },
  ];
}

test('Given out-of-order stage observables, when transcript validation runs, then it rejects every invalid order', () => {
  assert.throws(() => validateExecution(malformedFullStageTwo()), /after reconstruction/);
  assert.throws(
    () => validateExecution(execution([
      { type: 'stage_one_started' },
      { type: 'stage_one_completed' },
      { type: 'stage_two_started' },
      { type: 'subagent_spawned', agent_id: 'reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true },
      { type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-1' },
      { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-1' },
      reconstruction('reader-1'),
      { type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-1' },
      { type: 'source_retrieved', source_id: 'failing-test', actor: 'subagent', agent_id: 'reader-1' },
      verdict('reader-1'),
    ])),
    /candidate disclosure/,
  );
  assert.throws(
    () => validateExecution(execution([{ type: 'stage_one_completed' }, { type: 'stage_one_started' }])),
    /stage_one_started/,
  );
});

test('Given source retrieval from another agent, when stage-two validation runs, then it rejects the broken source context', () => {
  assert.throws(
    () => validateExecution(execution([
      { type: 'stage_one_started' },
      { type: 'stage_one_completed' },
      { type: 'stage_two_started' },
      { type: 'subagent_spawned', agent_id: 'reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true },
      { type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-2' },
      { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-1' },
      reconstruction('reader-2'),
      { type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-2' },
      verdict('reader-2'),
    ])),
    /spawned agent/,
  );
});

test('Given stage two without completed stage one, when transcript validation runs, then it rejects missing and late completion', () => {
  const missingStageOne = completeFullStageTwo().filter((entry) => !entry.type.startsWith('stage_one_'));
  assert.throws(() => validateExecution(execution(missingStageOne)), /stage_one_completed before stage_two_started/);

  const lateCompletion = completeFullStageTwo();
  const [completion] = lateCompletion.splice(1, 1);
  lateCompletion.splice(2, 0, completion);
  assert.throws(() => validateExecution(execution(lateCompletion)), /stage_one_completed before stage_two_started/);
});

test('Given an action or user interruption before the stage-two verdict, when transcript validation runs, then it rejects both transcripts', () => {
  const actionBeforeStageTwo = completeFullStageTwo();
  actionBeforeStageTwo.splice(2, 0, { type: 'agent_action', action_id: 'keep-private-fixture-location', direction_changing: false });
  assert.throws(() => validateExecution(execution(actionBeforeStageTwo)), /verdict before agent_action or user_interruption/);

  const interruptionBeforeStageTwo = completeFullStageTwo();
  interruptionBeforeStageTwo.splice(2, 0, { type: 'user_interruption' });
  assert.throws(() => validateExecution(execution(interruptionBeforeStageTwo)), /verdict before agent_action or user_interruption/);

  const withEarlyAction = completeFullStageTwo();
  withEarlyAction.splice(8, 0, { type: 'agent_action', action_id: 'keep-private-fixture-location', direction_changing: false });
  assert.throws(() => validateExecution(execution(withEarlyAction)), /verdict before agent_action or user_interruption/);

  const withEarlyInterruption = completeFullStageTwo();
  withEarlyInterruption.splice(8, 0, { type: 'user_interruption' });
  assert.throws(() => validateExecution(execution(withEarlyInterruption)), /verdict before agent_action or user_interruption/);
});

test('Given MORE_EVIDENCE followed by an explicit direction-changing action, when execution validates, then it rejects the action', () => {
  const withDirectionChange = completeFullStageTwo();
  const reconstructionEvent = withDirectionChange.find((entry) => entry.type === 'subagent_reconstruction');
  const verdictEvent = withDirectionChange.find((entry) => entry.type === 'verdict');
  reconstructionEvent.source_precedence = 'unresolved';
  verdictEvent.source_precedence = 'unresolved';
  verdictEvent.evidence_sufficient = false;
  verdictEvent.value = 'MORE_EVIDENCE';
  withDirectionChange.at(-1).direction_changing = true;
  assert.throws(() => validateExecution(execution(withDirectionChange)), /MORE_EVIDENCE blocks direction-changing agent_action/);
});

test('Given malformed full stage-two output, when the runner and scorer execute, then it cannot process-pass', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const scenario = scenarios.find((item) => item.category === 'harmful-pivot');
  const report = await runBenchmark({
    scenarios: [scenario],
    adapter: async () => malformedFullStageTwo(),
    configurations: ['full-two-stage'],
    trials: 1,
    benchmarkVersion: 'order-test-v1',
    environment,
  });
  const score = scoreReport(report);
  assert.equal(report.runs[0].status, 'failed');
  assert.equal(score.results[0].process.pass, false);
});
