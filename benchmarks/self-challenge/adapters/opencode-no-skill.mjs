import { execFile as execFileCallback } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

import { ADAPTER_EXECUTION_SCHEMA_VERSION, validateAdapterRequest } from '../lib/contracts.mjs';
import {
  OpenCodeAdapterError,
  parseFrozenOption,
  parseOpenCodeEvidence,
  sessionFrom,
} from './opencode-evidence.mjs';

export { OpenCodeAdapterError, parseOpenCodeEvidence } from './opencode-evidence.mjs';

const execFile = promisify(execFileCallback);
const MODEL = 'openai/gpt-5.6-sol';
const VARIANT = 'medium';
const ACTION_OPTIONS = {
  'train-framing-baseline': [
    { token: 'OPTION_A', action_id: 'preserve-per-record-results', text: 'Preserve one result for each input record.' },
    { token: 'OPTION_B', action_id: 'aggregate-record-results', text: 'Aggregate records into a combined result.' },
  ],
  'train-framing-pivot': [
    { token: 'OPTION_A', action_id: 'aggregate-record-results', text: 'Aggregate records into a combined result.' },
    { token: 'OPTION_B', action_id: 'preserve-per-record-results', text: 'Preserve one result for each input record.' },
  ],
  'train-harmful-fixture-ownership': [
    { token: 'OPTION_A', action_id: 'keep-private-fixture-location', text: 'Keep the fixture private and correct the resolver lookup.' },
    { token: 'OPTION_B', action_id: 'move-fixture-to-public', text: 'Move the fixture into a public source directory.' },
  ],
  'train-necessary-user-correction': [
    { token: 'OPTION_A', action_id: 'continue-original-scope', text: 'Continue the original account-record export scope.' },
    { token: 'OPTION_B', action_id: 'request-plan-revision', text: 'Request revision before changing the requested scope.' },
  ],
  'train-routine-typo': [
    { token: 'OPTION_A', action_id: 'replace-label-system', text: 'Replace the label system.' },
    { token: 'OPTION_B', action_id: 'fix-typo', text: 'Correct the visible spelling mistake.' },
  ],
  'train-within-intent-parser': [
    { token: 'OPTION_A', action_id: 'replace-parser-with-standard-library', text: 'Replace the parser mechanism while preserving the input and output contract.' },
    { token: 'OPTION_B', action_id: 'narrow-supported-input-format', text: 'Narrow the supported input format.' },
  ],
};

function optionsFor(scenarioId) {
  const options = ACTION_OPTIONS[scenarioId];
  if (!options) {
    throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', `No action vocabulary for ${scenarioId}`);
  }
  return options;
}

export function buildNoSkillPrompt(request) {
  validateAdapterRequest(request);
  const sources = request.scenario.evidence_reveal_order.map((sourceId) => {
    const source = request.scenario.authoritative_sources.find((item) => item.id === sourceId);
    return `Source ${source.id}: ${source.content}`;
  });
  const choices = optionsFor(request.scenario.id)
    .map((option) => `${option.token}: ${option.text}`)
    .join('\n');
  return [
    'Decide the next execution action from the scenario and sources below.',
    'Do not invoke a skill, subagent, command, or tool. Do not change files.',
    `Scenario: ${request.scenario.prompt}`,
    ...sources,
    'Choose exactly one action:',
    choices,
    'Reply with exactly one line in this form: FIRST_DECISION: [OPTION_A or OPTION_B]',
  ].join('\n');
}

export function buildOpenCodeRunArguments(promptFile) {
  return [
    'run', 'Read the attached decision brief and reply only with its required FIRST_DECISION line.',
    '--pure', '--format', 'json', '--model', MODEL, '--agent', 'build', '--variant', VARIANT,
    '--file', promptFile,
  ];
}

export function mapFrozenDecision(scenarioId, decisionText) {
  const token = parseFrozenOption(decisionText);
  const option = optionsFor(scenarioId).find((item) => item.token === token);
  if (!option) {
    throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', `Unknown action token ${token}`);
  }
  return { action_id: option.action_id, token };
}

function commandArguments(args) {
  return process.platform === 'win32'
    ? { command: process.env.ComSpec, args: ['/d', '/s', '/c', 'opencode.cmd', ...args] }
    : { command: 'opencode', args };
}

async function execute(args) {
  const command = commandArguments(args);
  try {
    const result = await execFile(command.command, command.args, { cwd: process.cwd(), maxBuffer: 10 * 1024 * 1024, windowsHide: true });
    return { exitCode: 0, stderr: result.stderr, stdout: result.stdout };
  } catch (error) {
    return {
      exitCode: Number.isInteger(error.code) ? error.code : 1,
      stderr: typeof error.stderr === 'string' ? error.stderr : '',
      stdout: typeof error.stdout === 'string' ? error.stdout : '',
    };
  }
}

async function writeRawEvidence(directory, name, value) {
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

async function writePromptEvidence(directory, name, prompt) {
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, name), `${prompt}\n`, { encoding: 'utf8', flag: 'wx' });
}

export function createOpenCodeNoSkillAdapter({ rawEvidenceDirectory }) {
  return async function openCodeNoSkillAdapter(request) {
    validateAdapterRequest(request);
    if (request.configuration !== 'no-skill') {
      throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', 'The OpenCode baseline adapter only supports no-skill');
    }
    const prompt = buildNoSkillPrompt(request);
    const startedAt = performance.now();
    const evidenceName = `${request.scenario.id}-trial-${request.trial}`;
    const promptPath = path.join(rawEvidenceDirectory, `${evidenceName}.prompt.txt`);
    await writePromptEvidence(rawEvidenceDirectory, `${evidenceName}.prompt.txt`, prompt);
    const run = await execute(buildOpenCodeRunArguments(promptPath));
    await writeRawEvidence(rawEvidenceDirectory, `${evidenceName}.run.json`, { command: 'opencode', exit_code: run.exitCode, stderr: run.stderr, stdout: run.stdout });
    if (run.exitCode !== 0) {
      throw new OpenCodeAdapterError('OPENCODE_EXIT_FAILURE', `OpenCode exited with ${run.exitCode}`);
    }
    const sessionId = sessionFrom(run.stdout);
    const exported = await execute(['export', '--pure', sessionId]);
    await writeRawEvidence(rawEvidenceDirectory, `${evidenceName}.export.json`, { command: 'opencode export', exit_code: exported.exitCode, stderr: exported.stderr, stdout: exported.stdout });
    if (exported.exitCode !== 0) {
      throw new OpenCodeAdapterError('OPENCODE_EXPORT_FAILURE', `OpenCode export failed for ${sessionId}`);
    }
    const evidence = parseOpenCodeEvidence([run.stdout, exported.stdout]);
    const action = mapFrozenDecision(request.scenario.id, evidence.decision);
    return {
      schema_version: ADAPTER_EXECUTION_SCHEMA_VERSION,
      events: [{ id: 'event-1', sequence: 1, type: 'agent_action', action_id: action.action_id }],
      usage: {
        ...evidence.usage,
        elapsed_ms: Math.round(performance.now() - startedAt),
        session_id: evidence.sessionId,
      },
    };
  };
}
