import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { ADAPTER_EXECUTION_SCHEMA_VERSION, validateAdapterRequest } from '../lib/contracts.mjs';
import { executeOpenCode, OPENCODE_EXECUTABLE } from '../lib/opencode-runtime.mjs';
import { mapTrainingDecision, optionsForTrainingScenario } from './training-action-options.mjs';
import {
  OpenCodeAdapterError,
  parseOpenCodeEvidence,
  sessionFrom,
} from './opencode-evidence.mjs';

export { OpenCodeAdapterError, parseOpenCodeEvidence } from './opencode-evidence.mjs';

const MODEL = 'openai/gpt-5.6-sol';
const VARIANT = 'medium';

export function buildNoSkillPrompt(request) {
  validateAdapterRequest(request);
  const sources = request.scenario.evidence_reveal_order.map((sourceId) => {
    const source = request.scenario.authoritative_sources.find((item) => item.id === sourceId);
    return `Source ${source.id}: ${source.content}`;
  });
  const choices = optionsForTrainingScenario(request.scenario.id)
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

export function mapFrozenDecision(scenarioId, decisionToken) {
  return mapTrainingDecision(scenarioId, decisionToken);
}

async function execute(args) {
  try {
    const result = await executeOpenCode(args);
    return result;
  } catch (error) {
    return {
      exitCode: Number.isInteger(error.code) ? error.code : 1,
      stderr: typeof error.stderr === 'string' ? error.stderr : '',
      stdout: typeof error.stdout === 'string' ? error.stdout : '',
      timedOut: false,
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
    await writeRawEvidence(rawEvidenceDirectory, `${evidenceName}.run.json`, { executable: OPENCODE_EXECUTABLE, arguments: buildOpenCodeRunArguments(promptPath), exit_code: run.exitCode, stderr: run.stderr, stdout: run.stdout, timed_out: run.timedOut });
    if (run.timedOut) {
      throw new OpenCodeAdapterError('OPENCODE_TIMEOUT', 'OpenCode exceeded the benchmark timeout');
    }
    if (run.exitCode !== 0) {
      throw new OpenCodeAdapterError('OPENCODE_EXIT_FAILURE', `OpenCode exited with ${run.exitCode}`);
    }
    const sessionId = sessionFrom(run.stdout);
    const exported = await execute(['export', '--pure', sessionId]);
    await writeRawEvidence(rawEvidenceDirectory, `${evidenceName}.export.json`, { executable: OPENCODE_EXECUTABLE, arguments: ['export', '--pure', sessionId], exit_code: exported.exitCode, stderr: exported.stderr, stdout: exported.stdout, timed_out: exported.timedOut });
    if (exported.timedOut) {
      throw new OpenCodeAdapterError('OPENCODE_TIMEOUT', `OpenCode export timed out for ${sessionId}`);
    }
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
