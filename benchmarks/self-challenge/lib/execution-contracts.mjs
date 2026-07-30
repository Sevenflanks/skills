import { ADAPTER_EXECUTION_SCHEMA_VERSION, DISPOSITIONS, EVENT_TYPES } from './constants.mjs';
import {
  assertArray,
  assertBoolean,
  assertEnum,
  assertExactKeys,
  assertNonNegativeInteger,
  assertObject,
  assertPositiveInteger,
  assertString,
  fail,
} from './validation.mjs';

function validateEvent(event, index) {
  const path = `execution.events[${index}]`;
  assertObject(event, path);
  assertString(event.id, `${path}.id`);
  assertPositiveInteger(event.sequence, `${path}.sequence`);
  assertString(event.type, `${path}.type`);
  if (!EVENT_TYPES.has(event.type)) {
    fail(`${path}.type`, `must be a supported observable event, not ${event.type}`);
  }
  if (event.type === 'agent_action') {
    assertString(event.action_id, `${path}.action_id`);
    assertBoolean(event.direction_changing, `${path}.direction_changing`);
  }
  if (event.type === 'action_reverted') {
    assertString(event.action_event_id, `${path}.action_event_id`);
  }
  if (event.type === 'source_retrieved') {
    assertString(event.source_id, `${path}.source_id`);
    assertEnum(event.actor, ['main-agent', 'subagent'], `${path}.actor`);
    if (event.actor === 'subagent') {
      assertString(event.agent_id, `${path}.agent_id`);
    } else if (event.agent_id !== undefined) {
      fail(`${path}.agent_id`, 'must be absent for a main-agent source read');
    }
  }
  if (event.type === 'subagent_spawned') {
    assertString(event.agent_id, `${path}.agent_id`);
    assertBoolean(event.read_only, `${path}.read_only`);
  }
  if (event.type === 'subagent_prompt') {
    assertEnum(event.phase, ['reconstruct', 'candidate'], `${path}.phase`);
    assertBoolean(event.candidate_disclosed, `${path}.candidate_disclosed`);
    assertString(event.agent_id, `${path}.agent_id`);
  }
  if (event.type === 'verdict') {
    assertEnum(event.value, DISPOSITIONS, `${path}.value`);
  }
}

function indexes(events, type) {
  return events.map((event, index) => ({ event, index })).filter((entry) => entry.event.type === type);
}

function validateStageOneOrder(events) {
  const starts = indexes(events, 'stage_one_started');
  const completions = indexes(events, 'stage_one_completed');
  if (starts.length === 0 && completions.length === 0) {
    return;
  }
  if (starts.length !== 1 || completions.length !== 1 || starts[0].index >= completions[0].index) {
    fail('execution.events', 'stage_one_completed must follow exactly one stage_one_started');
  }
}

function validateStageTwoOrder(events) {
  const starts = indexes(events, 'stage_two_started');
  const spawns = indexes(events, 'subagent_spawned');
  const prompts = indexes(events, 'subagent_prompt');
  const sources = indexes(events, 'source_retrieved');
  const verdicts = indexes(events, 'verdict');
  const observableCount = starts.length + spawns.length + prompts.length + verdicts.length;
  if (observableCount === 0) {
    return;
  }
  if (starts.length !== 1 || spawns.length !== 1 || prompts.length !== 2 || verdicts.length !== 1) {
    fail('execution.events', 'stage two must contain one start, one spawn, two prompts, source retrieval, and one verdict');
  }
  const reconstruction = prompts.find((entry) => entry.event.phase === 'reconstruct' && entry.event.candidate_disclosed === false);
  const candidate = prompts.find((entry) => entry.event.phase === 'candidate' && entry.event.candidate_disclosed === true);
  if (!reconstruction || !candidate) {
    fail('execution.events', 'stage two must include reconstruction and candidate prompts with the required disclosure flags');
  }
  const [start, spawn, verdict] = [starts[0], spawns[0], verdicts[0]];
  const challengerSources = sources.filter((entry) => entry.event.actor === 'subagent' && entry.event.agent_id === spawn.event.agent_id);
  if (!spawn.event.read_only || !(start.index < spawn.index && spawn.index < reconstruction.index)) {
    fail('execution.events', 'stage two reconstruction prompt must follow one fresh read-only spawn');
  }
  if (reconstruction.event.agent_id !== spawn.event.agent_id || candidate.event.agent_id !== spawn.event.agent_id || challengerSources.length === 0 || !challengerSources.every((entry) => reconstruction.index < entry.index && entry.index < candidate.index)) {
    fail('execution.events', 'stage two prompts and source retrieval must use the spawned agent after reconstruction and before candidate disclosure');
  }
  if (candidate.index >= verdict.index) {
    fail('execution.events', 'stage two verdict must follow the candidate prompt');
  }
}

export function validateExecution(execution) {
  assertObject(execution, 'execution');
  assertExactKeys(execution, ['events', 'schema_version', 'usage'], 'execution');
  if (execution.schema_version !== ADAPTER_EXECUTION_SCHEMA_VERSION) {
    fail('execution.schema_version', `must equal ${ADAPTER_EXECUTION_SCHEMA_VERSION}`);
  }
  assertArray(execution.events, 'execution.events');
  const ids = new Set();
  for (const [index, event] of execution.events.entries()) {
    validateEvent(event, index);
    if (event.sequence !== index + 1 || ids.has(event.id)) {
      fail('execution.events', 'must have unique IDs and contiguous sequence numbers starting at one');
    }
    ids.add(event.id);
  }
  validateStageOneOrder(execution.events);
  validateStageTwoOrder(execution.events);
  const agentActions = new Map();
  const revertedActionIds = new Set();
  for (const [index, event] of execution.events.entries()) {
    if (event.type === 'agent_action') {
      agentActions.set(event.id, event);
    }
    if (event.type === 'action_reverted') {
      if (!agentActions.has(event.action_event_id)) {
        fail(`execution.events[${index}].action_event_id`, 'must reference an earlier agent_action');
      }
      if (revertedActionIds.has(event.action_event_id)) {
        fail(`execution.events[${index}].action_event_id`, 'must not revert the same action twice');
      }
      revertedActionIds.add(event.action_event_id);
    }
  }
  assertObject(execution.usage, 'execution.usage');
  assertExactKeys(execution.usage, ['elapsed_ms', 'input_tokens', 'output_tokens', 'tool_calls', 'turns'], 'execution.usage');
  for (const key of ['input_tokens', 'output_tokens', 'tool_calls', 'turns']) {
    assertNonNegativeInteger(execution.usage[key], `execution.usage.${key}`);
  }
  if (execution.usage.elapsed_ms !== null) {
    assertNonNegativeInteger(execution.usage.elapsed_ms, 'execution.usage.elapsed_ms');
  }
  return execution;
}
