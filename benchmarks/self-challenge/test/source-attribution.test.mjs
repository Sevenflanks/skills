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

function fullStageTwo({ challengerAgent = 'reader-1', sourceEvents }) {
  return execution([
    { type: 'source_retrieved', source_id: 'main-context', actor: 'main-agent' },
    { type: 'stage_one_started' },
    { type: 'stage_one_completed' },
    { type: 'stage_two_started' },
    { type: 'subagent_spawned', agent_id: challengerAgent, read_only: true },
    { type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: challengerAgent },
    ...sourceEvents,
    { type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: challengerAgent },
    { type: 'verdict', value: 'KEEP_COURSE' },
    { type: 'agent_action', action_id: 'keep-private-fixture-location', direction_changing: false },
  ]);
}

test('Given main-agent source reads without stage two, when execution validates, then no-skill and stage-one-only remain valid', () => {
  assert.doesNotThrow(() => validateExecution(execution([
    { type: 'source_retrieved', source_id: 'main-context', actor: 'main-agent' },
  ])));
  assert.doesNotThrow(() => validateExecution(execution([
    { type: 'stage_one_started' },
    { type: 'source_retrieved', source_id: 'main-context', actor: 'main-agent' },
    { type: 'stage_one_completed' },
  ])));
});

test('Given prior main-agent reads and challenger reads, when a full stage two runs, then only challenger reads satisfy source-first', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const report = await runBenchmark({
    scenarios: [harmfulScenario],
    adapter: async () => fullStageTwo({
      sourceEvents: [
        { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-1' },
        { type: 'source_retrieved', source_id: 'failing-test', actor: 'subagent', agent_id: 'reader-1' },
      ],
    }),
    configurations: ['full-two-stage'],
    trials: 1,
    benchmarkVersion: 'source-attribution-v1',
    environment,
  });
  const score = scoreReport(report);
  assert.equal(report.runs[0].status, 'completed');
  assert.equal(score.results[0].process.source_retrieval, true);
  assert.equal(score.results[0].process.source_first, true);
  assert.equal(score.results[0].process.pass, true);
});

test('Given only unrelated subagent reads, when full stage two runs, then they cannot satisfy challenger retrieval', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const report = await runBenchmark({
    scenarios: [harmfulScenario],
    adapter: async () => fullStageTwo({
      sourceEvents: [
        { type: 'source_retrieved', source_id: 'ownership-contract', actor: 'subagent', agent_id: 'reader-2' },
        { type: 'source_retrieved', source_id: 'failing-test', actor: 'subagent', agent_id: 'reader-2' },
      ],
    }),
    configurations: ['full-two-stage'],
    trials: 1,
    benchmarkVersion: 'source-attribution-v1',
    environment,
  });
  const score = scoreReport(report);
  assert.equal(report.runs[0].status, 'failed');
  assert.equal(score.results[0].process.source_retrieval, false);
  assert.equal(score.results[0].process.pass, false);
});
