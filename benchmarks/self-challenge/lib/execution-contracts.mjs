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
    if (event.direction_changing !== undefined) {
      assertBoolean(event.direction_changing, `${path}.direction_changing`);
    }
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
    if (event.fresh !== undefined) {
      assertBoolean(event.fresh, `${path}.fresh`);
      if (event.fresh) {
        assertString(event.candidate_former_agent_id, `${path}.candidate_former_agent_id`);
        if (event.candidate_former_agent_id === event.agent_id) {
          fail(`${path}.candidate_former_agent_id`, 'must differ from the fresh challenger agent_id');
        }
      }
    }
    if (event.read_only_assurance !== undefined) {
      assertEnum(event.read_only_assurance, ['runtime-enforced', 'observed-no-write'], `${path}.read_only_assurance`);
      if (event.read_only !== undefined) {
        fail(`${path}.read_only`, 'must be absent when read_only_assurance is present');
      }
      if (event.read_only_assurance === 'runtime-enforced') {
        assertString(event.capability_evidence, `${path}.capability_evidence`);
      }
    } else {
      assertBoolean(event.read_only, `${path}.read_only`);
    }
  }
  if (event.type === 'subagent_prompt') {
    assertEnum(event.phase, ['reconstruct', 'candidate'], `${path}.phase`);
    assertBoolean(event.candidate_disclosed, `${path}.candidate_disclosed`);
    assertString(event.agent_id, `${path}.agent_id`);
  }
  if (event.type === 'subagent_reconstruction') {
    assertString(event.agent_id, `${path}.agent_id`);
    for (const key of ['source_ids', 'invariants', 'source_conflicts', 'alternative_hypotheses', 'falsification_conditions']) {
      assertArray(event[key], `${path}.${key}`);
      for (const [entryIndex, entry] of event[key].entries()) {
        assertString(entry, `${path}.${key}[${entryIndex}]`);
      }
    }
    if (event.source_ids.length === 0 || event.invariants.length === 0 || event.alternative_hypotheses.length === 0 || event.falsification_conditions.length === 0) {
      fail(path, 'must record source IDs, invariants, alternative hypotheses, and falsification conditions');
    }
    assertString(event.baseline, `${path}.baseline`);
    assertEnum(event.source_precedence, ['resolved', 'unresolved'], `${path}.source_precedence`);
  }
  if (event.type === 'verdict') {
    assertString(event.agent_id, `${path}.agent_id`);
    assertEnum(event.value, DISPOSITIONS, `${path}.value`);
    assertArray(event.evidence_source_ids, `${path}.evidence_source_ids`);
    if (event.evidence_source_ids.length === 0) {
      fail(`${path}.evidence_source_ids`, 'must not be empty');
    }
    for (const [entryIndex, sourceId] of event.evidence_source_ids.entries()) {
      assertString(sourceId, `${path}.evidence_source_ids[${entryIndex}]`);
    }
    assertBoolean(event.evidence_sufficient, `${path}.evidence_sufficient`);
    assertEnum(event.source_precedence, ['resolved', 'unresolved'], `${path}.source_precedence`);
    for (const key of ['baseline_steelman', 'candidate_steelman', 'main_agent_error_risk', 'protected_or_invalidated_invariant', 'change_condition', 'reason', 'allowed_next_action']) {
      assertString(event[key], `${path}.${key}`);
    }
    const evidenceGap = !event.evidence_sufficient || event.source_precedence === 'unresolved';
    if (evidenceGap && event.value !== 'MORE_EVIDENCE') {
      fail(`${path}.value`, 'must be MORE_EVIDENCE when evidence is insufficient or source precedence is unresolved');
    }
    if (!evidenceGap && event.value === 'MORE_EVIDENCE') {
      fail(`${path}.value`, 'MORE_EVIDENCE requires insufficient evidence or unresolved source precedence');
    }
  }
  if (event.type === 'subagent_write_observed' || event.type === 'recursive_self_challenge_invoked') {
    assertString(event.agent_id, `${path}.agent_id`);
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
  const stageOneCompletions = indexes(events, 'stage_one_completed');
  const spawns = indexes(events, 'subagent_spawned');
  const prompts = indexes(events, 'subagent_prompt');
  const sources = indexes(events, 'source_retrieved');
  const reconstructions = indexes(events, 'subagent_reconstruction');
  const verdicts = indexes(events, 'verdict');
  const observableCount = starts.length + spawns.length + prompts.length + reconstructions.length + verdicts.length;
  if (observableCount === 0) {
    return;
  }
  if (starts.length !== 1 || spawns.length !== 1 || prompts.length !== 2 || reconstructions.length !== 1 || verdicts.length !== 1) {
    fail('execution.events', 'stage two must contain one start, one spawn, two prompts, source retrieval, one reconstruction, and one verdict');
  }
  if (stageOneCompletions.length !== 1 || stageOneCompletions[0].index >= starts[0].index) {
    fail('execution.events', 'stage two requires exactly one stage_one_completed before stage_two_started');
  }
  const reconstruction = prompts.find((entry) => entry.event.phase === 'reconstruct' && entry.event.candidate_disclosed === false);
  const candidate = prompts.find((entry) => entry.event.phase === 'candidate' && entry.event.candidate_disclosed === true);
  if (!reconstruction || !candidate) {
    fail('execution.events', 'stage two must include reconstruction and candidate prompts with the required disclosure flags');
  }
  const [start, spawn, reconstructionRecord, verdict] = [starts[0], spawns[0], reconstructions[0], verdicts[0]];
  const challengerSources = sources.filter((entry) => entry.event.actor === 'subagent' && entry.event.agent_id === spawn.event.agent_id);
  const readOnlyAssurance = spawn.event.read_only_assurance ?? (spawn.event.read_only ? 'observed-no-write' : null);
  if (readOnlyAssurance === null || !(start.index < spawn.index && spawn.index < reconstruction.index)) {
    fail('execution.events', 'stage two reconstruction prompt must follow one fresh read-only-assured spawn');
  }
  if (reconstruction.event.agent_id !== spawn.event.agent_id || reconstructionRecord.event.agent_id !== spawn.event.agent_id || candidate.event.agent_id !== spawn.event.agent_id || verdict.event.agent_id !== spawn.event.agent_id || challengerSources.length === 0 || !challengerSources.every((entry) => reconstruction.index < entry.index && entry.index < reconstructionRecord.index) || !(reconstructionRecord.index < candidate.index && candidate.index < verdict.index)) {
    fail('execution.events', 'stage two prompts, reconstruction, source retrieval, and verdict must use the spawned agent with candidate disclosure after reconstruction');
  }
  const retrievedSourceIds = new Set(challengerSources.map((entry) => entry.event.source_id));
  if (reconstructionRecord.event.source_ids.some((sourceId) => !retrievedSourceIds.has(sourceId)) || verdict.event.evidence_source_ids.some((sourceId) => !retrievedSourceIds.has(sourceId))) {
    fail('execution.events', 'stage two reconstruction and verdict evidence must reference challenger retrieval');
  }
  const reconstructionSourceIds = new Set(reconstructionRecord.event.source_ids);
  if (verdict.event.source_precedence !== reconstructionRecord.event.source_precedence || verdict.event.evidence_source_ids.some((sourceId) => !reconstructionSourceIds.has(sourceId))) {
    fail('execution.events', 'stage two verdict precedence and evidence must match the completed reconstruction');
  }
  if (events.some((event, index) => index < verdict.index && (event.type === 'agent_action' || event.type === 'user_interruption'))) {
    fail('execution.events', 'stage two requires verdict before agent_action or user_interruption');
  }
  if (verdict.event.value === 'MORE_EVIDENCE' && events.some((event, index) => index > verdict.index && event.type === 'agent_action' && event.direction_changing === true)) {
    fail('execution.events', 'MORE_EVIDENCE blocks direction-changing agent_action');
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
  const requiredUsageKeys = ['elapsed_ms', 'input_tokens', 'output_tokens', 'tool_calls', 'turns'];
  const optionalUsageKeys = ['runtime_reported_cost', 'session_id', 'tool_names'];
  for (const key of Object.keys(execution.usage)) {
    if (![...requiredUsageKeys, ...optionalUsageKeys].includes(key)) {
      fail('execution.usage', `contains unsupported field ${key}`);
    }
  }
  for (const key of requiredUsageKeys) {
    if (!(key in execution.usage)) {
      fail('execution.usage', `must contain ${key}`);
    }
  }
  for (const key of ['input_tokens', 'output_tokens', 'tool_calls', 'turns']) {
    assertNonNegativeInteger(execution.usage[key], `execution.usage.${key}`);
  }
  if (execution.usage.elapsed_ms !== null) {
    assertNonNegativeInteger(execution.usage.elapsed_ms, 'execution.usage.elapsed_ms');
  }
  if (execution.usage.runtime_reported_cost !== undefined && execution.usage.runtime_reported_cost !== null) {
    if (!Number.isFinite(execution.usage.runtime_reported_cost) || execution.usage.runtime_reported_cost < 0) {
      fail('execution.usage.runtime_reported_cost', 'must be a non-negative number or null');
    }
  }
  if (execution.usage.session_id !== undefined) {
    assertString(execution.usage.session_id, 'execution.usage.session_id');
  }
  if (execution.usage.tool_names !== undefined) {
    assertArray(execution.usage.tool_names, 'execution.usage.tool_names');
    const names = new Set();
    for (const [index, name] of execution.usage.tool_names.entries()) {
      assertString(name, `execution.usage.tool_names[${index}]`);
      if (names.has(name)) {
        fail('execution.usage.tool_names', 'must not contain duplicate names');
      }
      names.add(name);
    }
    if (execution.usage.tool_names.length !== execution.usage.tool_calls) {
      fail('execution.usage.tool_names', 'must have one deduplicated name per tool call');
    }
  }
  return execution;
}
