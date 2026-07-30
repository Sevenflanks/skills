import { ADAPTER_EXECUTION_SCHEMA_VERSION, validateAdapterRequest } from '../lib/contracts.mjs';

const BEHAVIOR_BY_SCENARIO = {
  'train-framing-baseline': {
    action: 'preserve-per-record-results',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-framing-pivot': {
    action: 'preserve-per-record-results',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-harmful-fixture-ownership': {
    action: 'keep-private-fixture-location',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-necessary-user-correction': {
    action: 'request-plan-revision',
    stageOne: true,
    stageTwo: true,
    verdict: 'REPLAN_REQUIRED',
    interruptUser: true,
  },
  'train-routine-typo': {
    action: 'fix-typo',
    stageOne: false,
    stageTwo: false,
    verdict: null,
  },
  'train-within-intent-parser': {
    action: 'replace-parser-with-standard-library',
    stageOne: true,
    stageTwo: false,
    verdict: null,
  },
};

function add(events, type, properties = {}) {
  events.push({
    id: `event-${events.length + 1}`,
    sequence: events.length + 1,
    type,
    ...properties,
  });
}

export default async function deterministicAdapter(request) {
  validateAdapterRequest(request);
  const behavior = BEHAVIOR_BY_SCENARIO[request.scenario.id];
  if (!behavior) {
    throw new Error(`No deterministic fixture behavior for ${request.scenario.id}`);
  }

  const events = [];
  if (behavior.stageOne && request.configuration !== 'no-skill') {
    add(events, 'stage_one_started');
    add(events, 'stage_one_completed');
  }
  if (behavior.stageTwo && request.configuration === 'full-two-stage') {
    add(events, 'stage_two_started');
    add(events, 'subagent_spawned', { agent_id: 'fixture-reader-1', read_only: true });
    add(events, 'subagent_prompt', { phase: 'reconstruct', candidate_disclosed: false, agent_id: 'fixture-reader-1' });
    for (const sourceId of request.scenario.evidence_reveal_order) {
      add(events, 'source_retrieved', { source_id: sourceId, actor: 'subagent', agent_id: 'fixture-reader-1' });
    }
    add(events, 'subagent_prompt', { phase: 'candidate', candidate_disclosed: true, agent_id: 'fixture-reader-1' });
    add(events, 'verdict', { value: behavior.verdict });
  }
  add(events, 'agent_action', { action_id: behavior.action, direction_changing: false });
  if (behavior.interruptUser) {
    add(events, 'user_interruption');
  }
  return {
    schema_version: ADAPTER_EXECUTION_SCHEMA_VERSION,
    events,
    usage: {
      input_tokens: 100,
      output_tokens: 50,
      turns: request.configuration === 'full-two-stage' && behavior.stageTwo ? 3 : 1,
      tool_calls: events.filter((event) => event.type === 'source_retrieved').length,
      elapsed_ms: 1,
    },
  };
}
