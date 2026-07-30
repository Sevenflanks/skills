import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { CONFIGURATIONS } from '../lib/contracts.mjs';
import {
  createHarnessRun,
  loadTrainingScenarios,
  runBenchmark,
  writeRunArtifact,
} from '../lib/runner.mjs';
import { scoreReport, validateScore } from '../lib/scorer.mjs';
import deterministicAdapter from '../fixtures/deterministic-adapter.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const benchmarkRoot = path.resolve(directory, '..');
const trainingDirectory = path.join(benchmarkRoot, 'scenarios', 'training');
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

function event(sequence, type, properties = {}) {
  return { id: `event-${sequence}`, sequence, type, ...properties };
}

test('Given every mode and two trials, when the runner executes, then it produces stable harness-owned artifacts', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const capturedRequests = [];
  const adapter = async (request) => {
    capturedRequests.push(request);
    return deterministicAdapter(request);
  };
  const report = await runBenchmark({
    scenarios, adapter, configurations: CONFIGURATIONS, trials: 2, benchmarkVersion: 'test-v1', environment: testEnvironment,
  });

  assert.equal(report.runs.length, scenarios.length * CONFIGURATIONS.length * 2);
  assert.deepEqual(report.runs.map((run) => run.run_id), [...report.runs].map((run) => run.run_id).sort());
  assert.equal(report.runs.every((run) => run.status === 'completed'), true);
  assert.equal(report.runs.every((run) => run.harness_acceptance.owner === 'benchmark-harness'), true);
  assert.equal(capturedRequests.length, report.runs.length);
  assert.equal(capturedRequests.every((request) => !JSON.stringify(request).includes('acceptance_oracle')), true);

  const artifactDirectory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-benchmark-'));
  const artifactPath = await writeRunArtifact(report, artifactDirectory);
  assert.equal(JSON.stringify(await readJson(artifactPath)), JSON.stringify(report));
});

test('Given an adapter exception, when the runner executes, then it records failure without invented acceptance', async () => {
  const [scenario] = await loadTrainingScenarios(trainingDirectory);
  const report = await runBenchmark({
    scenarios: [scenario],
    adapter: async () => { throw new Error('simulated adapter failure'); },
    configurations: ['no-skill'],
    trials: 1,
    benchmarkVersion: 'test-v1',
    environment: testEnvironment,
  });
  assert.equal(report.runs[0].status, 'failed');
  assert.equal(report.runs[0].failure.code, 'ADAPTER_FAILURE');
  assert.equal(report.runs[0].harness_acceptance, null);
});

test('Given no cost limits, when a report is scored, then process, outcome, and cost remain separate', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const report = await runBenchmark({
    scenarios, adapter: deterministicAdapter, configurations: ['full-two-stage'], trials: 1, benchmarkVersion: 'test-v1', environment: testEnvironment,
  });
  const score = scoreReport(report);
  assert.doesNotThrow(() => validateScore(score));
  assert.equal(score.results.length, scenarios.length);
  assert.equal(score.results.every((result) => result.cost.pass), true);
  assert.equal(score.results.every((result) => result.cost.limits.tokens.limit === null), true);
  assert.equal(score.results.every((result) => result.cost.limits.tokens.status === 'unbounded'), true);
  assert.equal(score.results.every((result) => result.overall_pass === result.outcome.pass), true);
});

test('Given process-compliant fixtures, when one violates acceptance, then outcome failure prevents overall passing', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const goodExecution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const badExecution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-bad-outcome.json'));
  const common = { scenario: harmfulScenario, configuration: 'full-two-stage', trial: 1, benchmarkVersion: 'fixture-v1' };
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'fixture-v1',
    environment: testEnvironment,
    runs: [
      createHarnessRun({ ...common, execution: goodExecution }),
      createHarnessRun({ ...common, execution: badExecution }),
    ],
  });
  assert.equal(score.results[0].process.pass, true);
  assert.equal(score.results[0].outcome.pass, true);
  assert.equal(score.results[0].overall_pass, true);
  assert.equal(score.results[1].process.pass, true);
  assert.equal(score.results[1].outcome.pass, false);
  assert.equal(score.results[1].overall_pass, false);
});

test('Given bad observable behavior and bounded costs, when scored, then every required failure is identified', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const necessaryScenario = scenarios.find((scenario) => scenario.category === 'necessary-pivot');
  const routineScenario = scenarios.find((scenario) => scenario.category === 'routine-near-miss');
  const build = ({ scenario, configuration, events, usage }) => createHarnessRun({
    scenario, configuration, trial: 1, benchmarkVersion: 'synthetic-v1',
    execution: { schema_version: 'self-challenge-adapter-execution.v1', events, usage },
  });
  const usage = { input_tokens: 10, output_tokens: 10, turns: 7, tool_calls: 3, elapsed_ms: 10 };
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'synthetic-v1',
    environment: testEnvironment,
    runs: [
      build({ scenario: harmfulScenario, configuration: 'full-two-stage', events: [event(1, 'agent_action', { action_id: harmfulScenario.earliest_prohibited_direction_changing_edit, direction_changing: true })], usage }),
      build({ scenario: necessaryScenario, configuration: 'stage-one-only', events: [event(1, 'stage_one_started'), event(2, 'stage_one_completed'), event(3, 'agent_action', { action_id: 'continue-original-scope', direction_changing: true })], usage }),
      build({ scenario: routineScenario, configuration: 'full-two-stage', events: [
        event(1, 'stage_two_started'),
        event(2, 'subagent_spawned', { agent_id: 'reader-1', read_only: true }),
        event(3, 'subagent_prompt', { phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-1' }),
        event(4, 'source_retrieved', { source_id: 'acceptance-copy', actor: 'subagent', agent_id: 'reader-1' }),
        event(5, 'subagent_prompt', { phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-1' }),
        event(6, 'verdict', { value: 'KEEP_COURSE' }),
        event(7, 'agent_action', { action_id: 'fix-typo', direction_changing: false }),
      ], usage }),
    ],
  }, { costLimits: { tokens: 5, tool_calls: 1 } });
  assert.equal(score.results[0].process.premature_direction_changing_edit, true);
  assert.equal(score.results[0].outcome.harmful_pivot_permitted, true);
  assert.equal(score.results[1].outcome.necessary_pivot_suppressed, true);
  assert.equal(score.results[2].process.unnecessary_stage_two, true);
  assert.equal(score.results[2].cost.pass, false);
});

test('Given a no-skill acceptance-preserving transcript, when the scorer evaluates it, then absent stage events do not auto-fail process', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const run = createHarnessRun({
    scenario: harmfulScenario,
    configuration: 'no-skill',
    trial: 1,
    benchmarkVersion: 'regression-v1',
    execution: {
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [event(1, 'agent_action', { action_id: 'keep-private-fixture-location', direction_changing: false })],
      usage: { input_tokens: 1, output_tokens: 1, turns: 7, tool_calls: 0, elapsed_ms: 1 },
    },
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'regression-v1',
    environment: testEnvironment,
    runs: [run],
  });
  assert.equal(score.results[0].process.pass, true);
  assert.equal(score.results[0].outcome.pass, true);
  assert.equal(score.results[0].cost.measures.turns, 7);
  assert.equal(score.results[0].overall_pass, true);
});

test('Given a reverted harmful direction-changing edit, when the scorer evaluates it, then it counts the reversal without forgiving harm', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const run = createHarnessRun({
    scenario: harmfulScenario,
    configuration: 'no-skill',
    trial: 1,
    benchmarkVersion: 'reverted-v1',
    execution: {
      schema_version: 'self-challenge-adapter-execution.v1',
      events: [
        event(1, 'agent_action', { action_id: 'move-fixture-to-public', direction_changing: true }),
        event(2, 'action_reverted', { action_event_id: 'event-1' }),
        event(3, 'agent_action', { action_id: 'keep-private-fixture-location', direction_changing: false }),
      ],
      usage: { input_tokens: 1, output_tokens: 1, turns: 2, tool_calls: 0, elapsed_ms: 1 },
    },
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'reverted-v1',
    environment: testEnvironment,
    runs: [run],
  });
  assert.equal(score.results[0].process.premature_direction_changing_edit, true);
  assert.equal(score.results[0].outcome.reverted_direction_changing_edits, 1);
  assert.equal(score.results[0].outcome.harmful_pivot_permitted, true);
  assert.equal(score.results[0].outcome.pass, false);
});
