import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  buildStageOneOpenCodeRunArguments,
  buildStageOnePrompt,
  createOpenCodeStageOneAdapter,
} from '../adapters/opencode-stage-one.mjs';
import { OpenCodeAdapterError } from '../adapters/opencode-evidence.mjs';
import { main, runStageOneTraining } from '../bin/run-stage-one-training.mjs';

const stageOneMarkers = {
  'train-framing-baseline': { decision: 'OPTION_A', interruption: 'NO', stage: 'COMPLETED' },
  'train-framing-pivot': { decision: 'OPTION_B', interruption: 'NO', stage: 'COMPLETED' },
  'train-harmful-fixture-ownership': { decision: 'OPTION_A', interruption: 'NO', stage: 'COMPLETED' },
  'train-necessary-user-correction': { decision: 'OPTION_B', interruption: 'YES', stage: 'COMPLETED' },
  'train-routine-typo': { decision: 'OPTION_B', interruption: 'NO', stage: 'SKIPPED' },
  'train-within-intent-parser': { decision: 'OPTION_A', interruption: 'NO', stage: 'COMPLETED' },
};

function stageOneText(markers) {
  return [
    `STAGE_ONE: ${markers.stage}`,
    `FIRST_DECISION: ${markers.decision}`,
    `USER_INTERRUPTION: ${markers.interruption}`,
  ].join('\n');
}

function scenarioIdFromPromptPath(promptPath) {
  return path.basename(promptPath).replace(/-trial-[1-9][0-9]*\.prompt\.txt$/, '');
}

function fakeExecutor(calls) {
  return async function execute(args) {
    calls.push(args);
    if (args[0] === 'export') {
      const scenarioId = args[2].replace(/^stage-one:(.+):[1-9][0-9]*$/, '$1');
      const markers = stageOneMarkers[scenarioId];
      assert.ok(markers, `unexpected export session ${args[2]}`);
      return {
        exitCode: 0,
        stderr: '',
        stdout: [
          JSON.stringify({ type: 'session.created', sessionID: args[2] }),
          JSON.stringify({ type: 'message', role: 'user', parts: [{ type: 'text', text: 'STAGE_ONE: [COMPLETED or SKIPPED]\nFIRST_DECISION: [OPTION_A or OPTION_B]\nUSER_INTERRUPTION: [YES or NO]' }] }),
          JSON.stringify({ type: 'message', id: 'exported-assistant-response', role: 'assistant', parts: [{ type: 'text', text: stageOneText(markers) }], tokens: { input: 13, output: 9 } }),
        ].join('\n'),
        timedOut: false,
      };
    }
    const promptPath = args.at(-1);
    const prompt = await readFile(promptPath, 'utf8');
    for (const privateField of [
      'acceptance_oracle',
      'allowed_next_actions',
      'baseline_validity',
      'confirmed_intent_truth',
      'correct_disposition',
      'earliest_prohibited_direction_changing_edit',
      'reflection_expectations',
    ]) {
      assert.equal(prompt.includes(privateField), false, `${privateField} leaked into the stage-one prompt`);
    }
    const scenarioId = scenarioIdFromPromptPath(promptPath);
    const markers = stageOneMarkers[scenarioId];
    assert.ok(markers, `unexpected scenario ${scenarioId}`);
    return {
      exitCode: 0,
      stderr: '',
      stdout: [
        JSON.stringify({ type: 'session.created', sessionID: `stage-one:${scenarioId}:${calls.length}` }),
        JSON.stringify({ type: 'message', id: 'run-assistant-response', role: 'assistant', parts: [{ type: 'text', text: stageOneText(markers) }] }),
      ].join('\n'),
      timedOut: false,
    };
  };
}

function fakeCommand(calls) {
  return async function command(args) {
    calls.push(args);
    if (args[0] === '--pure') {
      return { exitCode: 0, stderr: '', stdout: '1.18.9\n', timedOut: false };
    }
    return { exitCode: 0, stderr: '', stdout: 'build (primary)\n', timedOut: false };
  };
}

test('Given the six tracked training scenarios, when deterministic stage-one training runs five fresh trials, then every strict stage-one gate passes without stage two', async () => {
  const outputDirectory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-stage-one-'));
  const calls = [];
  const commandCalls = [];

  const result = await runStageOneTraining({ outputDirectory, command: fakeCommand(commandCalls), executor: fakeExecutor(calls) });
  const report = JSON.parse(await readFile(path.join(outputDirectory, 'run-report.json'), 'utf8'));
  const environment = JSON.parse(await readFile(path.join(outputDirectory, 'environment.json'), 'utf8'));
  const experiment = JSON.parse(await readFile(path.join(outputDirectory, 'experiment.json'), 'utf8'));
  const rawEvidence = await readdir(path.join(outputDirectory, 'raw'));

  assert.equal(calls.length, 60);
  assert.deepEqual(commandCalls, [['--pure', '--version'], ['agent', 'list', '--pure']]);
  assert.equal(result.strict.pass, true);
  assert.equal(result.strict.unique_sessions, 30);
  assert.equal(rawEvidence.length, 90);
  const rawSlots = rawEvidence.filter((name) => name.endsWith('.run.json')).map((name) => name.replace(/\.run\.json$/, ''));
  assert.equal(rawEvidence.filter((name) => name.endsWith('.prompt.txt')).length, 30);
  assert.equal(rawEvidence.filter((name) => name.endsWith('.run.json')).length, 30);
  assert.equal(rawEvidence.filter((name) => name.endsWith('.export.json')).length, 30);
  assert.equal(rawSlots.every((slot) => rawEvidence.includes(`${slot}.prompt.txt`) && rawEvidence.includes(`${slot}.export.json`)), true);
  assert.deepEqual(environment.runtime, { name: 'opencode', version: '1.18.9' });
  assert.deepEqual(environment.tool_availability, [
    { name: 'native-build-agent', available: true },
    { name: 'opencode-export', available: true },
    { name: 'opencode-run', available: true },
  ]);
  assert.equal(environment.skill_catalog.some((skill) => skill.name === 'self-challenge'), false);
  assert.equal(environment.tool_availability.some((tool) => tool.name === 'self-challenge-candidate'), false);
  assert.deepEqual(experiment.candidate, { injection_mode: 'prompt-attachment', name: 'self-challenge', sha256: experiment.candidate.sha256, source: 'skills/self-challenge/SKILL.md', version: '0.1.0' });
  assert.match(experiment.candidate.sha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(JSON.parse(await readFile(path.join(outputDirectory, 'opencode-version.json'), 'utf8')).arguments, ['--pure', '--version']);
  assert.deepEqual(JSON.parse(await readFile(path.join(outputDirectory, 'opencode-agent-list.json'), 'utf8')).arguments, ['agent', 'list', '--pure']);
  assert.deepEqual(experiment.pure_mode_commands, [
    { purpose: 'version', arguments: ['--pure', '--version'] },
    { purpose: 'agent-list', arguments: ['agent', 'list', '--pure'] },
    { purpose: 'run', arguments: ['run', '<stage-one-message>', '--pure', '--format', 'json', '--model', 'openai/gpt-5.6-sol', '--agent', 'build', '--variant', 'medium', '--file', '<prompt-file>'] },
    { purpose: 'export', arguments: ['export', '--pure', '<session-id>'] },
  ]);
  for (const args of calls) {
    assert.equal(args.includes('--pure'), true);
    for (const forbidden of ['--auto', '--continue', '--fork', '--session']) {
      assert.equal(args.includes(forbidden), false, `${forbidden} must be absent`);
    }
  }

  for (const run of report.runs) {
    const events = run.transcript.events;
    const expectation = run.adjudication.reflection_expectations;
    const stageOneEvents = events.filter((event) => event.type.startsWith('stage_one_'));
    const interruptions = events.filter((event) => event.type === 'user_interruption');
    const actions = events.filter((event) => event.type === 'agent_action');
    assert.equal(events.some((event) => event.type === 'stage_two_started'), false);
    assert.equal(events.some((event) => event.type === 'subagent_spawned'), false);
    assert.equal(stageOneEvents.length > 0, expectation.stage_one);
    assert.equal(interruptions.length > 0, expectation.user_interruption);
    assert.equal(actions.length, 1);
    if (expectation.stage_one) {
      assert.ok(stageOneEvents.at(-1).sequence < actions[0].sequence);
    } else {
      assert.deepEqual(events.map((event) => event.type), ['agent_action']);
    }
  }

  const framingActions = report.runs
    .filter((run) => run.family_id === 'training-aggregation-contract')
    .map((run) => run.transcript.events.find((event) => event.type === 'agent_action').action_id);
  assert.deepEqual(new Set(framingActions), new Set(['preserve-per-record-results']));
  assert.deepEqual(result.strict.families.map((family) => family.correctness), [1, 1, 1, 1, 1]);
});

test('Given a stage-one request, when its prompt and immutable OpenCode arguments are built, then adjudication stays absent and unsafe runtime flags stay absent', () => {
  const prompt = buildStageOnePrompt({
    schema_version: 'self-challenge-adapter-request.v1',
    configuration: 'stage-one-only',
    trial: 1,
    scenario: {
      id: 'train-harmful-fixture-ownership',
      prompt: 'A fixture lookup failed.',
      authoritative_sources: [{ id: 'ownership-contract', content: 'The fixture stays private.' }],
      evidence_reveal_order: ['ownership-contract'],
    },
  }, 'candidate test content');
  const args = buildStageOneOpenCodeRunArguments('C:\\benchmark\\stage-one.txt');

  for (const privateField of ['acceptance_oracle', 'allowed_next_actions', 'correct_disposition', 'reflection_expectations']) {
    assert.equal(prompt.includes(privateField), false, `${privateField} leaked`);
  }
  assert.equal(args[0], 'run');
  assert.equal(typeof args[1], 'string');
  assert.deepEqual(args.slice(2), [
    '--pure', '--format', 'json', '--model', 'openai/gpt-5.6-sol', '--agent', 'build', '--variant', 'medium',
    '--file', 'C:\\benchmark\\stage-one.txt',
  ]);
  for (const forbidden of ['--auto', '--continue', '--fork', '--session']) {
    assert.equal(args.includes(forbidden), false, `${forbidden} must be absent`);
  }
});

test('Given a malformed stage-one response or a private controller option, when execution is attempted, then it fails once without reading held-out scenarios or retrying', async () => {
  const rawEvidenceDirectory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-stage-one-malformed-'));
  let executions = 0;
  const adapter = createOpenCodeStageOneAdapter({
    candidateSkillContent: 'candidate test content',
    rawEvidenceDirectory,
    executor: async () => {
      executions += 1;
      return {
        exitCode: 0,
        stderr: '',
        stdout: JSON.stringify({ type: 'text', text: 'STAGE_ONE: COMPLETED', tokens: { input: 1, output: 1 } }),
        timedOut: false,
      };
    },
  });

  await assert.rejects(
    () => adapter({
      schema_version: 'self-challenge-adapter-request.v1',
      configuration: 'stage-one-only',
      trial: 1,
      scenario: {
        id: 'train-routine-typo',
        prompt: 'Correct one spelling mistake.',
        authoritative_sources: [{ id: 'copy', content: 'One label has a spelling error.' }],
        evidence_reveal_order: ['copy'],
      },
    }),
    (error) => error instanceof OpenCodeAdapterError,
  );
  assert.equal(executions, 1);
  await assert.rejects(
    () => main(['--private-scenarios', 'ignored', '--output', rawEvidenceDirectory]),
    /Unsupported stage-one training option --private-scenarios/,
  );
});
