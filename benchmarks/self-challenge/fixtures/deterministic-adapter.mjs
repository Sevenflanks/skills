import { ADAPTER_EXECUTION_SCHEMA_VERSION, validateAdapterRequest } from '../lib/contracts.mjs';
import { runStageTwoProtocol } from '../adapters/stage-two-protocol.mjs';

const BEHAVIOR_BY_SCENARIO = {
  'train-framing-baseline': {
    action: 'preserve-per-record-results',
    candidate: 'Aggregate each record into one summary result.',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-framing-pivot': {
    action: 'preserve-per-record-results',
    candidate: 'Aggregate each record into one summary result.',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-harmful-fixture-ownership': {
    action: 'keep-private-fixture-location',
    candidate: 'Move private fixture outputs into a shared directory.',
    stageOne: true,
    stageTwo: true,
    verdict: 'KEEP_COURSE',
  },
  'train-necessary-user-correction': {
    action: 'request-plan-revision',
    candidate: 'Keep implementing the original delivery scope.',
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
    let promptCount = 0;
    await runStageTwoProtocol({
      candidate: behavior.candidate,
      authoritative_sources: request.scenario.authoritative_sources,
      evidence_reveal_order: request.scenario.evidence_reveal_order,
      candidate_former_agent_id: 'main-agent',
      problem_evidence: 'A direction-relevant conflict requires source-first reconstruction.',
      constraints: ['Use the authoritative sources as the current baseline.'],
      non_goals: ['Do not edit files or revise the plan.'],
      emit: (type, fields) => add(events, type, fields),
      openChallenger: async () => ({
        agent_id: 'fixture-reader-1',
        read_only_assurance: 'observed-no-write',
        ask: async () => {
          promptCount += 1;
          if (promptCount === 1) {
            return {
              source_ids: request.scenario.evidence_reveal_order,
              baseline: 'The authoritative sources remain the baseline.',
              invariants: ['Confirmed intent remains authoritative.'],
              source_conflicts: [],
              source_precedence: 'resolved',
              alternative_hypotheses: ['Repair the implementation within the baseline.'],
              falsification_conditions: ['A newer explicit user decision changes the baseline.'],
            };
          }
          return {
            evidence_source_ids: request.scenario.evidence_reveal_order,
            evidence_sufficient: true,
            source_precedence: 'resolved',
            value: behavior.verdict,
            baseline_steelman: 'The authoritative sources define the current commitment.',
            candidate_steelman: 'The proposed direction could address the observed problem.',
            main_agent_error_risk: 'A local failure may be mistaken for invalidated intent.',
            protected_or_invalidated_invariant: 'Confirmed intent remains authoritative.',
            change_condition: 'New decision-relevant evidence invalidates the baseline.',
            reason: 'The reconstructed sources support the reported disposition.',
            allowed_next_action: behavior.action,
          };
        },
      }),
    });
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
