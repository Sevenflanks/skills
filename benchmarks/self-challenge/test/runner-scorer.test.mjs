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

function reconstruction(sequence, agentId, sourceIds) {
  return event(sequence, 'subagent_reconstruction', {
    agent_id: agentId,
    source_ids: sourceIds,
    baseline: 'Keep the baseline.',
    invariants: ['The contract remains stable.'],
    source_conflicts: [],
    source_precedence: 'resolved',
    alternative_hypotheses: ['Repair the implementation.'],
    falsification_conditions: ['A later decision changes the contract.'],
  });
}

function verdict(sequence, agentId, sourceIds, allowedNextAction) {
  return event(sequence, 'verdict', {
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
    allowed_next_action: allowedNextAction,
  });
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
  assert.equal(score.results[0].process.reconstruction_complete, true);
  assert.equal(score.results[0].process.source_first, true);
  assert.equal(score.results[0].process.freshness, true);
  assert.equal(score.results[0].process.read_only_assurance, 'observed-no-write');
  assert.equal(score.results[0].process.evidence_first, true);
  assert.equal(score.results[0].process.verdict_next_action_allowed, true);
  assert.equal(score.results[0].outcome.pass, true);
  assert.equal(score.results[0].overall_pass, true);
  assert.equal(score.results[1].process.pass, true);
  assert.equal(score.results[1].outcome.pass, false);
  assert.equal(score.results[1].overall_pass, false);
});

test('Given absent, false, or legacy freshness, when a full stage two is scored, then it cannot process-pass', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const goodExecution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const executions = [
    structuredClone(goodExecution),
    structuredClone(goodExecution),
    structuredClone(goodExecution),
  ];
  const spawns = executions.map((execution) => execution.events.find((event) => event.type === 'subagent_spawned'));
  delete spawns[0].fresh;
  spawns[1].fresh = false;
  delete spawns[2].fresh;
  delete spawns[2].read_only_assurance;
  spawns[2].read_only = true;
  const report = {
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'freshness-v1',
    environment: testEnvironment,
    runs: executions.map((execution, index) => createHarnessRun({
      scenario: harmfulScenario,
      configuration: 'full-two-stage',
      trial: index + 1,
      benchmarkVersion: 'freshness-v1',
      execution,
    })),
  };

  const score = scoreReport(report);
  for (const result of score.results) {
    assert.equal(result.process.freshness, false);
    assert.equal(result.process.fresh_read_only_subagent, false);
    assert.equal(result.process.pass, false);
  }
});

test('Given observed challenger writes or recursion, when the scorer evaluates a full stage two, then it reports the assurance and fails process', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const goodExecution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const withObservedViolation = (type) => {
    const execution = structuredClone(goodExecution);
    execution.events.splice(-1, 0, { id: 'temporary', sequence: 0, type, agent_id: 'fixture-reader-1' });
    execution.events.forEach((entry, index) => {
      entry.id = `event-${index + 1}`;
      entry.sequence = index + 1;
    });
    return execution;
  };
  const report = {
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'stage-two-assurance-v1',
    environment: testEnvironment,
    runs: [
      createHarnessRun({ scenario: harmfulScenario, configuration: 'full-two-stage', trial: 1, benchmarkVersion: 'stage-two-assurance-v1', execution: withObservedViolation('subagent_write_observed') }),
      createHarnessRun({ scenario: harmfulScenario, configuration: 'full-two-stage', trial: 2, benchmarkVersion: 'stage-two-assurance-v1', execution: withObservedViolation('recursive_self_challenge_invoked') }),
    ],
  };

  const score = scoreReport(report);
  assert.equal(score.results[0].process.read_only_assurance, 'observed-no-write');
  assert.equal(score.results[0].process.observed_subagent_write, true);
  assert.equal(score.results[0].process.pass, false);
  assert.equal(score.results[1].process.recursive_self_challenge, true);
  assert.equal(score.results[1].process.pass, false);
});

test('Given a later typed stage-two failure, when the scorer evaluates attempts, then it reports the safe failure without reusing an earlier verdict', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const stageTwoTypes = new Set([
    'stage_two_started', 'subagent_spawned', 'source_retrieved', 'subagent_prompt',
    'subagent_reconstruction', 'verdict', 'subagent_write_observed',
    'recursive_self_challenge_invoked', 'failure',
  ]);
  for (const entry of execution.events) {
    if (stageTwoTypes.has(entry.type)) {
      entry.attempt_id = 'stage-two-1';
    }
  }
  const actionIndex = execution.events.findIndex((entry) => entry.type === 'agent_action');
  execution.events.splice(actionIndex, 0,
    { id: 'temporary-start', sequence: 0, type: 'stage_two_started', attempt_id: 'stage-two-2' },
    {
      id: 'temporary-failure', sequence: 0, type: 'failure', attempt_id: 'stage-two-2',
      stage: 'stage_two', scope: 'stage_two_protocol', phase: 'source_retrieval',
      code: 'SOURCE_RETRIEVAL_FAILURE', baseline_preserved: true,
      safe_fallback: { kind: 'PRESERVE_BASELINE' }, handoff: 'NONE',
    },
  );
  execution.events.forEach((entry, index) => {
    entry.id = `event-${index + 1}`;
    entry.sequence = index + 1;
  });
  const run = createHarnessRun({
    scenario: harmfulScenario, configuration: 'full-two-stage', trial: 1,
    benchmarkVersion: 'failure-reentry-v1', execution,
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1', benchmark_version: 'failure-reentry-v1',
    environment: testEnvironment, runs: [run],
  });

  assert.equal(score.results[0].process.safe_stage_two_failure, true);
  assert.equal(score.results[0].process.verdict_correct, false);
  assert.equal(score.results[0].process.pass, false);
});

test('Given an early safe failure and a later successful reentry, when scored, then the latest verdict releases the action barrier but cannot erase the process failure', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const stageTwoTypes = new Set([
    'stage_two_started', 'subagent_spawned', 'source_retrieved', 'subagent_prompt',
    'subagent_reconstruction', 'verdict', 'subagent_write_observed',
    'recursive_self_challenge_invoked', 'failure',
  ]);
  for (const entry of execution.events) {
    if (stageTwoTypes.has(entry.type)) {
      entry.attempt_id = 'stage-two-2';
    }
  }
  const stageTwoStartIndex = execution.events.findIndex((entry) => entry.type === 'stage_two_started');
  execution.events.splice(stageTwoStartIndex, 0,
    { id: 'temporary-start', sequence: 0, type: 'stage_two_started', attempt_id: 'stage-two-1' },
    {
      id: 'temporary-failure', sequence: 0, type: 'failure', attempt_id: 'stage-two-1',
      stage: 'stage_two', scope: 'stage_two_protocol', phase: 'source_retrieval',
      code: 'SOURCE_RETRIEVAL_FAILURE', baseline_preserved: true,
      safe_fallback: { kind: 'PRESERVE_BASELINE' }, handoff: 'NONE',
    },
  );
  execution.events.forEach((entry, index) => {
    entry.id = `event-${index + 1}`;
    entry.sequence = index + 1;
  });
  const run = createHarnessRun({
    scenario: harmfulScenario,
    configuration: 'full-two-stage',
    trial: 1,
    benchmarkVersion: 'early-failure-reentry-v1',
    execution,
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'early-failure-reentry-v1',
    environment: testEnvironment,
    runs: [run],
  });

  assert.equal(score.results[0].process.more_evidence_blocks_direction_change, true);
  assert.equal(score.results[0].process.safe_stage_two_failure, true);
  assert.equal(score.results[0].process.verdict_correct, false);
  assert.equal(score.results[0].process.pass, false);
});

test('Given an old MORE_EVIDENCE attempt and a later successful verdict, when an action follows, then the scorer uses the latest terminal barrier', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const sourceIds = ['ownership-contract', 'failing-test'];
  const attemptEvents = (attemptId, agentId, terminal) => [
    event(0, 'stage_two_started', { attempt_id: attemptId }),
    event(0, 'subagent_spawned', { attempt_id: attemptId, agent_id: agentId, candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true }),
    event(0, 'subagent_prompt', { attempt_id: attemptId, phase: 'reconstruct', candidate_disclosed: false, agent_id: agentId }),
    ...sourceIds.map((sourceId) => event(0, 'source_retrieved', { attempt_id: attemptId, source_id: sourceId, actor: 'subagent', agent_id: agentId })),
    { ...reconstruction(0, agentId, sourceIds), attempt_id: attemptId },
    event(0, 'subagent_prompt', { attempt_id: attemptId, phase: 'candidate', candidate_disclosed: true, agent_id: agentId }),
    { ...terminal, attempt_id: attemptId },
  ];
  const firstVerdict = {
    ...verdict(0, 'reader-1', sourceIds, 'keep-private-fixture-location'),
    evidence_sufficient: false,
    source_precedence: 'unresolved',
    value: 'MORE_EVIDENCE',
    more_evidence: {
      decision_relevant_question: 'Does the ownership contract permit relocation?',
      minimal_read_only_investigation: 'Read the current ownership decision.',
      completion_signal: 'The decision explicitly permits or rejects relocation.',
      non_expansion_scope: 'Do not edit files or inspect unrelated sources.',
    },
  };
  const firstReconstructionIndex = 2 + 1 + 1 + 1 + sourceIds.length;
  const events = [
    event(0, 'stage_one_started'),
    event(0, 'stage_one_completed'),
    ...attemptEvents('stage-two-1', 'reader-1', firstVerdict),
    ...attemptEvents('stage-two-2', 'reader-2', verdict(0, 'reader-2', sourceIds, 'keep-private-fixture-location')),
    event(0, 'agent_action', { action_id: 'keep-private-fixture-location', direction_changing: true }),
  ];
  events[firstReconstructionIndex].source_precedence = 'unresolved';
  events.forEach((entry, index) => {
    entry.id = `event-${index + 1}`;
    entry.sequence = index + 1;
  });
  const run = createHarnessRun({
    scenario: harmfulScenario,
    configuration: 'full-two-stage',
    trial: 1,
    benchmarkVersion: 'latest-terminal-v1',
    execution: {
      schema_version: 'self-challenge-adapter-execution.v1',
      events,
      usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: 0 },
    },
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'latest-terminal-v1',
    environment: testEnvironment,
    runs: [run],
  });

  assert.equal(score.results[0].process.more_evidence_blocks_direction_change, true);
  assert.equal(score.results[0].process.safe_stage_two_failure, false);
});

test('Given a malformed no-skill transcript with a safe stage-two failure, when scored, then process cannot pass in that configuration', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = {
    schema_version: 'self-challenge-adapter-execution.v1',
    events: [
      event(1, 'stage_one_started'),
      event(2, 'stage_one_completed'),
      event(3, 'stage_two_started', { attempt_id: 'stage-two-1' }),
      event(4, 'failure', {
        attempt_id: 'stage-two-1', stage: 'stage_two', scope: 'stage_two_protocol',
        phase: 'open_challenger', code: 'OPEN_CHALLENGER_FAILURE', baseline_preserved: true,
        safe_fallback: { kind: 'PRESERVE_BASELINE' }, handoff: 'NONE',
      }),
    ],
    usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: 0 },
  };
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1', benchmark_version: 'no-skill-safe-failure-v1',
    environment: testEnvironment,
    runs: [createHarnessRun({ scenario: harmfulScenario, configuration: 'no-skill', trial: 1, benchmarkVersion: 'no-skill-safe-failure-v1', execution })],
  });
  assert.equal(score.results[0].process.safe_stage_two_failure, true);
  assert.equal(score.results[0].process.pass, false);
});

test('Given a successful stage-two transcript in no-skill mode, when scored, then it is rejected as an unnecessary invocation', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'no-skill-stage-two-v1',
    environment: testEnvironment,
    runs: [createHarnessRun({
      scenario: harmfulScenario,
      configuration: 'no-skill',
      trial: 1,
      benchmarkVersion: 'no-skill-stage-two-v1',
      execution,
    })],
  });

  assert.equal(score.results[0].process.stage_two_invocations, 1);
  assert.equal(score.results[0].process.unnecessary_stage_two, true);
  assert.equal(score.results[0].process.pass, false);
});

test('Given a source-first verdict that conflicts with locked adjudication, when the scorer evaluates it, then process fails without deriving a replacement verdict', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const verdictEvent = execution.events.find((event) => event.type === 'verdict');
  verdictEvent.value = 'REPLAN_REQUIRED';
  verdictEvent.allowed_next_action = 'unapproved-next-action';
  const run = createHarnessRun({
    scenario: harmfulScenario,
    configuration: 'full-two-stage',
    trial: 1,
    benchmarkVersion: 'locked-adjudication-v1',
    execution,
  });
  const score = scoreReport({
    schema_version: 'self-challenge-run-report.v1',
    benchmark_version: 'locked-adjudication-v1',
    environment: testEnvironment,
    runs: [run],
  });

  assert.equal(score.results[0].process.verdict_correct, false);
  assert.equal(score.results[0].process.verdict_next_action_allowed, false);
  assert.equal(score.results[0].process.pass, false);
  assert.equal(score.results[0].outcome.pass, true);
});

test('Given a verdict forged against its reconstruction, when the runner and scorer evaluate it, then it cannot process-pass', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  execution.events.find((event) => event.type === 'subagent_reconstruction').source_precedence = 'unresolved';
  const report = await runBenchmark({
    scenarios: [harmfulScenario],
    adapter: async () => execution,
    configurations: ['full-two-stage'],
    trials: 1,
    benchmarkVersion: 'reconstruction-precedence-v1',
    environment: testEnvironment,
  });
  const score = scoreReport(report);

  assert.equal(report.runs[0].status, 'failed');
  assert.equal(score.results[0].process.pass, false);
});

test('Given MORE_EVIDENCE followed by a harness-derived direction change, when the runner and scorer evaluate it, then it cannot process-pass', async () => {
  const scenarios = await loadTrainingScenarios(trainingDirectory);
  const harmfulScenario = scenarios.find((scenario) => scenario.category === 'harmful-pivot');
  const execution = await readJson(path.join(benchmarkRoot, 'fixtures', 'transcripts', 'process-compliant-good.json'));
  const reconstructionEvent = execution.events.find((event) => event.type === 'subagent_reconstruction');
  const verdictEvent = execution.events.find((event) => event.type === 'verdict');
  reconstructionEvent.source_precedence = 'unresolved';
  verdictEvent.source_precedence = 'unresolved';
  verdictEvent.evidence_sufficient = false;
  verdictEvent.value = 'MORE_EVIDENCE';
  const actionEvent = execution.events.find((event) => event.type === 'agent_action');
  actionEvent.action_id = 'move-fixture-to-public';
  delete actionEvent.direction_changing;
  const report = await runBenchmark({
    scenarios: [harmfulScenario],
    adapter: async () => execution,
    configurations: ['full-two-stage'],
    trials: 1,
    benchmarkVersion: 'more-evidence-direction-change-v1',
    environment: testEnvironment,
  });
  const score = scoreReport(report);

  assert.equal(report.runs[0].status, 'failed');
  assert.equal(score.results[0].process.more_evidence_blocks_direction_change, false);
  assert.equal(score.results[0].process.pass, false);
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
        event(1, 'stage_one_started'),
        event(2, 'stage_one_completed'),
        event(3, 'stage_two_started'),
        event(4, 'subagent_spawned', { agent_id: 'reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true }),
        event(5, 'subagent_prompt', { phase: 'reconstruct', candidate_disclosed: false, agent_id: 'reader-1' }),
        event(6, 'source_retrieved', { source_id: 'acceptance-copy', actor: 'subagent', agent_id: 'reader-1' }),
        reconstruction(7, 'reader-1', ['acceptance-copy']),
        event(8, 'subagent_prompt', { phase: 'candidate', candidate_disclosed: true, agent_id: 'reader-1' }),
        verdict(9, 'reader-1', ['acceptance-copy'], 'fix-typo'),
        event(10, 'agent_action', { action_id: 'fix-typo', direction_changing: false }),
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
