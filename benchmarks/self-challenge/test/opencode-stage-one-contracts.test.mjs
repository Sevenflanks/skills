import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { buildStageOnePrompt, createOpenCodeStageOneAdapter, executionFromStageOneEvidence } from '../adapters/opencode-stage-one.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..', '..');
const candidatePath = path.join(repositoryRoot, 'skills', 'self-challenge', 'SKILL.md');
const request = {
  schema_version: 'self-challenge-adapter-request.v1',
  configuration: 'stage-one-only',
  trial: 1,
  scenario: {
    id: 'train-routine-typo',
    prompt: 'Correct one spelling mistake.',
    authoritative_sources: [{ id: 'copy', content: 'One label has a spelling error.' }],
    evidence_reveal_order: ['copy'],
  },
};

test('Given the unpublished candidate, when its content is injected into a stage-one prompt, then the attached brief includes the unique candidate instruction and no publication artifacts exist', async () => {
  const candidateContent = await readFile(candidatePath, 'utf8');
  const prompt = buildStageOnePrompt(request, `${candidateContent}\nCANDIDATE_SENTINEL: 71d7e`);
  const [catalogContent, marketplaceContent, rootReadme, candidateFiles] = await Promise.all([
    readFile(path.join(repositoryRoot, 'skills.json'), 'utf8'),
    readFile(path.join(repositoryRoot, '.claude-plugin', 'marketplace.json'), 'utf8'),
    readFile(path.join(repositoryRoot, 'README.md'), 'utf8'),
    readdir(path.dirname(candidatePath)),
  ]);

  assert.match(candidateContent, /^---\r?\nname: self-challenge\r?\ndescription: .+\r?\nlicense: MIT\r?\nmetadata:\r?\n  author: sevenflankse\r?\n  version: 0\.1\.0\r?\n---/);
  assert.equal(prompt.includes('CANDIDATE_SENTINEL: 71d7e'), true);
  assert.deepEqual(candidateFiles, ['SKILL.md']);
  assert.equal(JSON.parse(catalogContent).skills.some((skill) => skill.name === 'self-challenge'), false);
  assert.equal(JSON.parse(marketplaceContent).skills.some((skill) => skill.name === 'self-challenge'), false);
  assert.equal(rootReadme.includes('skills/self-challenge'), false);
});

test('Given failing evidence that would replace an implementation mechanism or semantic boundary, when the candidate distinguishes it from ordinary debugging, then it requires stage one before quiet continuation', async () => {
  const candidateContent = await readFile(candidatePath, 'utf8');

  assert.match(candidateContent, /ordinary within-intent debugging.*Continue these cases quietly\./s);
  assert.match(candidateContent, /routine typo correction.*Continue these cases quietly\./s);
  assert.match(candidateContent, /failing evidence.*replacing an implementation mechanism or semantic boundary.*stage one before continuing quietly within intent/i);
});

test('Given normalized stage-one evidence, when it becomes an execution, then completed reflection precedes interruption and action while a skipped routine stays quiet', () => {
  const usage = { elapsed_ms: null, input_tokens: 1, output_tokens: 1, runtime_reported_cost: null, tool_calls: 0, tool_names: [], turns: 1 };
  const completed = executionFromStageOneEvidence(
    { ...request, scenario: { ...request.scenario, id: 'train-harmful-fixture-ownership' } },
    { decision: 'OPTION_A', sessionId: 'session-complete', stageOne: 'COMPLETED', userInterruption: 'YES', usage },
  );
  const skipped = executionFromStageOneEvidence(
    request,
    { decision: 'OPTION_B', sessionId: 'session-skip', stageOne: 'SKIPPED', userInterruption: 'NO', usage },
  );

  assert.deepEqual(completed.events.map((event) => event.type), ['stage_one_started', 'stage_one_completed', 'user_interruption', 'agent_action']);
  assert.equal(completed.events.at(-1).action_id, 'keep-private-fixture-location');
  assert.equal(completed.events.some((event) => event.type === 'stage_two_started'), false);
  assert.deepEqual(skipped.events.map((event) => event.type), ['agent_action']);
  assert.equal(skipped.events[0].action_id, 'fix-typo');
});

test('Given a candidate skill path, when a stage-one adapter runs, then it reads the candidate content into the prompt before invoking the model seam', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-candidate-path-'));
  const injectedCandidatePath = path.join(directory, 'candidate.md');
  const rawEvidenceDirectory = path.join(directory, 'raw');
  await writeFile(injectedCandidatePath, 'CANDIDATE_PATH_SENTINEL: 8c11', 'utf8');
  const adapter = createOpenCodeStageOneAdapter({
    candidateSkillPath: injectedCandidatePath,
    rawEvidenceDirectory,
    executor: async (args) => {
      if (args[0] === 'export') {
        return {
          exitCode: 0,
          stderr: '',
          stdout: [
            JSON.stringify({ type: 'session.created', sessionID: args[2] }),
            JSON.stringify({ type: 'message', role: 'assistant', parts: [{ type: 'text', text: 'STAGE_ONE: SKIPPED\nFIRST_DECISION: OPTION_B\nUSER_INTERRUPTION: NO' }], tokens: { input: 1, output: 1 } }),
          ].join('\n'),
          timedOut: false,
        };
      }
      const prompt = await readFile(args.at(-1), 'utf8');
      assert.equal(prompt.includes('CANDIDATE_PATH_SENTINEL: 8c11'), true);
      return { exitCode: 0, stderr: '', stdout: JSON.stringify({ type: 'session.created', sessionID: 'candidate-path-session' }), timedOut: false };
    },
  });

  const execution = await adapter(request);

  assert.deepEqual(execution.events.map((event) => event.type), ['agent_action']);
});

test('Given run or export failure evidence, when the adapter stops without retrying, then it preserves every raw artifact and exposes the correct failure code', async () => {
  const normalRun = { exitCode: 0, stderr: '', stdout: JSON.stringify({ type: 'session.created', sessionID: 'failure-session' }), timedOut: false };
  const cases = [
    { code: 'OPENCODE_TIMEOUT', results: [{ ...normalRun, timedOut: true }], files: 2 },
    { code: 'OPENCODE_EXIT_FAILURE', results: [{ ...normalRun, exitCode: 9 }], files: 2 },
    { code: 'OPENCODE_TIMEOUT', results: [normalRun, { ...normalRun, timedOut: true }], files: 3 },
    { code: 'OPENCODE_EXPORT_FAILURE', results: [normalRun, { ...normalRun, exitCode: 9 }], files: 3 },
  ];

  for (const testCase of cases) {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-stage-one-failure-'));
    let invocation = 0;
    const adapter = createOpenCodeStageOneAdapter({
      candidateSkillContent: 'candidate test content',
      rawEvidenceDirectory: directory,
      executor: async () => testCase.results[invocation++],
    });
    await assert.rejects(() => adapter(request), (error) => error.code === testCase.code);
    assert.equal(invocation, testCase.results.length);
    assert.equal((await readdir(directory)).length, testCase.files);
  }
});

test('Given the held-out manifest, when stage-one controller corpus isolation is checked, then it validates only opaque metadata and does not load private scenarios', async () => {
  const [manifestContent, controllerSource] = await Promise.all([
    readFile(path.join(repositoryRoot, 'benchmarks', 'self-challenge', 'scenarios', 'true-held-out-manifest.json'), 'utf8'),
    readFile(path.join(repositoryRoot, 'benchmarks', 'self-challenge', 'bin', 'run-stage-one-training.mjs'), 'utf8'),
  ]);
  const manifest = JSON.parse(manifestContent);

  assert.equal(manifest.entries.every((entry) => Object.keys(entry).sort().join(',') === 'category,family_id,id,sha256'), true);
  assert.equal(controllerSource.includes('validateBenchmarkCorpus'), true);
  assert.equal(controllerSource.includes('loadPrivateHeldOutScenarios'), false);
  assert.equal(controllerSource.includes('true-held-out-manifest.json'), true);
});
