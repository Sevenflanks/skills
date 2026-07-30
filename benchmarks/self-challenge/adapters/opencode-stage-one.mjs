import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { ADAPTER_EXECUTION_SCHEMA_VERSION, validateAdapterRequest } from '../lib/contracts.mjs';
import { executeOpenCode, OPENCODE_EXECUTABLE } from '../lib/opencode-runtime.mjs';
import { mapTrainingDecision, optionsForTrainingScenario } from './training-action-options.mjs';
import { normalizeOpenCodeRejection, OpenCodeAdapterError, parseStageOneEvidence, sessionFrom } from './opencode-evidence.mjs';

const MODEL = 'openai/gpt-5.6-sol';
const VARIANT = 'medium';

function sourcesFor(request) {
  return request.scenario.evidence_reveal_order.map((sourceId) => {
    const source = request.scenario.authoritative_sources.find((item) => item.id === sourceId);
    return `Source ${source.id}: ${source.content}`;
  });
}

function writeEvent(events, type, fields = {}) {
  events.push({ id: `event-${events.length + 1}`, sequence: events.length + 1, type, ...fields });
}

async function writeNewEvidence(directory, name, value) {
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, name), value, { encoding: 'utf8', flag: 'wx' });
}

function rawResult(argumentsForRun, result) {
  return { executable: OPENCODE_EXECUTABLE, arguments: argumentsForRun, exit_code: result.exitCode, stderr: result.stderr, stdout: result.stdout, timed_out: result.timedOut };
}

function rawRejection(argumentsForRun, error) {
  return { executable: OPENCODE_EXECUTABLE, arguments: argumentsForRun, error: normalizeOpenCodeRejection(error) };
}

export function buildStageOnePrompt(request, candidateSkillContent) {
  validateAdapterRequest(request);
  if (request.configuration !== 'stage-one-only') {
    throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', 'The stage-one adapter only supports stage-one-only');
  }
  const choices = optionsForTrainingScenario(request.scenario.id)
    .map((option) => `${option.token}: ${option.text}`)
    .join('\n');
  return [
    'Perform the self-challenge candidate stage-one check before choosing the next action.',
    'Do not invoke a subagent, command, or tool. Do not change files.',
    'Candidate instructions:',
    candidateSkillContent,
    `Scenario ID: ${request.scenario.id}`,
    `Scenario: ${request.scenario.prompt}`,
    ...sourcesFor(request),
    'Choose exactly one action:',
    choices,
    'Reply with exactly these three lines:',
    'STAGE_ONE: [COMPLETED or SKIPPED]',
    'FIRST_DECISION: [OPTION_A or OPTION_B]',
    'USER_INTERRUPTION: [YES or NO]',
  ].join('\n');
}

export function buildStageOneOpenCodeRunArguments(promptFile) {
  return [
    'run', 'Read the attached stage-one brief and reply only with its required markers.',
    '--pure', '--format', 'json', '--model', MODEL, '--agent', 'build', '--variant', VARIANT,
    '--file', promptFile,
  ];
}

export function executionFromStageOneEvidence(request, evidence) {
  validateAdapterRequest(request);
  const action = mapTrainingDecision(request.scenario.id, evidence.decision);
  const events = [];
  if (evidence.stageOne === 'COMPLETED') {
    writeEvent(events, 'stage_one_started');
    writeEvent(events, 'stage_one_completed');
  }
  if (evidence.userInterruption === 'YES') {
    writeEvent(events, 'user_interruption');
  }
  writeEvent(events, 'agent_action', { action_id: action.action_id });
  return {
    schema_version: ADAPTER_EXECUTION_SCHEMA_VERSION,
    events,
    usage: { ...evidence.usage, session_id: evidence.sessionId },
  };
}

export function createOpenCodeStageOneAdapter({ rawEvidenceDirectory, candidateSkillContent, candidateSkillPath, executor = executeOpenCode }) {
  if (typeof candidateSkillContent !== 'string' && typeof candidateSkillPath !== 'string') {
    throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', 'The stage-one adapter requires candidate skill content or path');
  }
  let loadedCandidateSkillContent = candidateSkillContent;
  return async function openCodeStageOneAdapter(request) {
    validateAdapterRequest(request);
    if (request.configuration !== 'stage-one-only') {
      throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', 'The stage-one adapter only supports stage-one-only');
    }
    loadedCandidateSkillContent ??= await readFile(candidateSkillPath, 'utf8');
    const prompt = buildStageOnePrompt(request, loadedCandidateSkillContent);
    const evidenceName = `${request.scenario.id}-trial-${request.trial}`;
    const promptName = `${evidenceName}.prompt.txt`;
    const promptPath = path.join(rawEvidenceDirectory, promptName);
    await writeNewEvidence(rawEvidenceDirectory, promptName, `${prompt}\n`);
    const argumentsForRun = buildStageOneOpenCodeRunArguments(promptPath);
    const startedAt = performance.now();
    let run;
    try {
      run = await executor(argumentsForRun);
    } catch (error) {
      await writeNewEvidence(rawEvidenceDirectory, `${evidenceName}.run.json`, `${JSON.stringify(rawRejection(argumentsForRun, error), null, 2)}\n`);
      throw new OpenCodeAdapterError('OPENCODE_EXIT_FAILURE', 'OpenCode run command rejected');
    }
    await writeNewEvidence(rawEvidenceDirectory, `${evidenceName}.run.json`, `${JSON.stringify(rawResult(argumentsForRun, run), null, 2)}\n`);
    if (run.timedOut) {
      throw new OpenCodeAdapterError('OPENCODE_TIMEOUT', 'OpenCode exceeded the benchmark timeout');
    }
    if (run.exitCode !== 0) {
      throw new OpenCodeAdapterError('OPENCODE_EXIT_FAILURE', `OpenCode exited with ${run.exitCode}`);
    }
    const sessionId = sessionFrom(run.stdout);
    const exportArguments = ['export', '--pure', sessionId];
    let exported;
    try {
      exported = await executor(exportArguments);
    } catch (error) {
      await writeNewEvidence(rawEvidenceDirectory, `${evidenceName}.export.json`, `${JSON.stringify(rawRejection(exportArguments, error), null, 2)}\n`);
      throw new OpenCodeAdapterError('OPENCODE_EXPORT_FAILURE', 'OpenCode export command rejected');
    }
    await writeNewEvidence(rawEvidenceDirectory, `${evidenceName}.export.json`, `${JSON.stringify(rawResult(exportArguments, exported), null, 2)}\n`);
    if (exported.timedOut) {
      throw new OpenCodeAdapterError('OPENCODE_TIMEOUT', `OpenCode export timed out for ${sessionId}`);
    }
    if (exported.exitCode !== 0) {
      throw new OpenCodeAdapterError('OPENCODE_EXPORT_FAILURE', `OpenCode export failed for ${sessionId}`);
    }
    const execution = executionFromStageOneEvidence(request, parseStageOneEvidence({ runEvidence: run.stdout, exportEvidence: exported.stdout }));
    return {
      ...execution,
      usage: {
        ...execution.usage,
        elapsed_ms: Math.round(performance.now() - startedAt),
      },
    };
  };
}
