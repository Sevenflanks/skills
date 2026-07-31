import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createOpenCodeStageOneAdapter } from '../adapters/opencode-stage-one.mjs';
import { OpenCodeAdapterError, parseStageOneEvidence } from '../adapters/opencode-evidence.mjs';
import { runStageOneTraining } from '../bin/run-stage-one-training.mjs';

const request = {
  schema_version: 'self-challenge-adapter-request.v1',
  configuration: 'stage-one-only',
  trial: 1,
  scenario: {
    id: 'train-routine-typo',
    prompt: 'Correct the visible spelling mistake.',
    authoritative_sources: [{ id: 'copy', content: 'The label has one spelling error.' }],
    evidence_reveal_order: ['copy'],
  },
};
const canonicalResponse = 'STAGE_ONE: SKIPPED\nFIRST_DECISION: OPTION_B\nUSER_INTERRUPTION: NO';

function serialize(events) {
  return events.map((event) => JSON.stringify(event)).join('\n');
}

function runEvidence(sessionId, response = canonicalResponse) {
  return serialize([
    { type: 'session.created', sessionID: sessionId },
    { type: 'message', id: 'run-assistant', role: 'assistant', parts: [{ type: 'text', text: response }] },
  ]);
}

function exportEvidence(sessionId, response = canonicalResponse, assistantCount = 1) {
  const assistants = Array.from({ length: assistantCount }, (_, index) => ({
    type: 'message',
    id: `export-assistant-${index}`,
    role: 'assistant',
    parts: [{ type: 'text', text: response }],
    tokens: { input: 5, output: 3 },
  }));
  return serialize([
    { type: 'session.created', sessionID: sessionId },
    { type: 'message', role: 'user', parts: [{ type: 'text', text: 'STAGE_ONE: [COMPLETED or SKIPPED]\nFIRST_DECISION: [OPTION_A or OPTION_B]\nUSER_INTERRUPTION: [YES or NO]' }] },
    ...assistants,
  ]);
}

function rejectedExecution(message) {
  const error = new Error(message);
  error.code = 'TEST_REJECTION';
  error.stdout = 'partial stdout';
  error.stderr = 'partial stderr';
  error.timedOut = false;
  return error;
}

test('Given a realistic exported transcript, when the canonical assistant response is parsed, then user marker templates and duplicate run text do not affect one exact response', () => {
  const evidence = parseStageOneEvidence({
    runEvidence: runEvidence('canonical-session', `${canonicalResponse}\nFIRST_DECISION: OPTION_A`),
    exportEvidence: exportEvidence('canonical-session'),
  });

  assert.deepEqual(evidence, {
    decision: 'OPTION_B',
    sessionId: 'canonical-session',
    stageOne: 'SKIPPED',
    userInterruption: 'NO',
    usage: {
      elapsed_ms: null,
      input_tokens: 5,
      output_tokens: 3,
      runtime_reported_cost: null,
      tool_calls: 0,
      tool_names: [],
      turns: 1,
    },
  });

  for (const broken of [
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('different-session') },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', `${canonicalResponse}\nextra`) },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', 'FIRST_DECISION: OPTION_B\nSTAGE_ONE: SKIPPED\nUSER_INTERRUPTION: NO') },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', 'STAGE_ONE: UNKNOWN\nFIRST_DECISION: OPTION_B\nUSER_INTERRUPTION: NO') },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', 'STAGE_ONE: SKIPPED\nFIRST_DECISION: OPTION_B') },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', `${canonicalResponse}\nSTAGE_ONE: SKIPPED`) },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', `${canonicalResponse}\nFIRST_DECISION: OPTION_B`) },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', `${canonicalResponse}\nUSER_INTERRUPTION: NO`) },
    { runEvidence: runEvidence('canonical-session'), exportEvidence: exportEvidence('canonical-session', canonicalResponse, 2) },
  ]) {
    assert.throws(() => parseStageOneEvidence(broken), (error) => error instanceof OpenCodeAdapterError);
  }
});

test('Given rejected run or export commands, when the adapter stops, then it writes one normalized raw rejection artifact and does not retry', async () => {
  for (const testCase of [{ phase: 'run', calls: 1, files: 2 }, { phase: 'export', calls: 2, files: 3 }]) {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-rejection-'));
    let calls = 0;
    const adapter = createOpenCodeStageOneAdapter({
      candidateSkillContent: 'candidate test content',
      rawEvidenceDirectory: directory,
      executor: async () => {
        calls += 1;
        if (testCase.phase === 'run' || calls === 2) {
          throw rejectedExecution(`${testCase.phase} rejected`);
        }
        return { exitCode: 0, stderr: '', stdout: runEvidence('rejection-session'), timedOut: false };
      },
    });

    await assert.rejects(() => adapter(request), (error) => error instanceof OpenCodeAdapterError);
    const files = await readdir(directory);
    const evidenceName = `train-routine-typo-trial-1.${testCase.phase}.json`;
    const artifact = JSON.parse(await readFile(path.join(directory, evidenceName), 'utf8'));
    assert.equal(calls, testCase.calls);
    assert.equal(files.length, testCase.files);
    assert.deepEqual(artifact.error, { code: 'TEST_REJECTION', message: `${testCase.phase} rejected`, name: 'Error', stderr: 'partial stderr', stdout: 'partial stdout', timed_out: false });
  }
});

test('Given rejected or false-positive preflight output, when stage-one training starts, then it persists rejection evidence and requires the exact native build line', async () => {
  const rejectionOutput = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-preflight-rejection-'));
  let rejectionCalls = 0;
  await assert.rejects(
    () => runStageOneTraining({
      outputDirectory: rejectionOutput,
      command: async () => {
        rejectionCalls += 1;
        throw rejectedExecution('version rejected');
      },
      executor: async () => assert.fail('executor must not run after version rejection'),
    }),
    /version command rejected/,
  );
  const rejectionArtifact = JSON.parse(await readFile(path.join(rejectionOutput, 'opencode-version.json'), 'utf8'));
  assert.equal(rejectionCalls, 1);
  assert.deepEqual(rejectionArtifact.error, { code: 'TEST_REJECTION', message: 'version rejected', name: 'Error', stderr: 'partial stderr', stdout: 'partial stdout', timed_out: false });

  const falsePositiveOutput = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-preflight-agent-'));
  const preflightCalls = [];
  await assert.rejects(
    () => runStageOneTraining({
      outputDirectory: falsePositiveOutput,
      command: async (args) => {
        preflightCalls.push(args);
        return args[0] === '--pure'
          ? { exitCode: 0, stderr: '', stdout: '1.18.9\n', timedOut: false }
          : { exitCode: 0, stderr: '', stdout: 'build-tools\n', timedOut: false };
      },
      executor: async () => assert.fail('executor must not run after false-positive agent output'),
    }),
    /native build agent/,
  );
  assert.deepEqual(preflightCalls, [['--pure', '--version'], ['agent', 'list', '--pure']]);
});
