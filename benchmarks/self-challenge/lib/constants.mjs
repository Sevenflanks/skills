export const SCENARIO_SCHEMA_VERSION = 'self-challenge-scenario.v1';
export const HELD_OUT_MANIFEST_SCHEMA_VERSION = 'self-challenge-held-out-manifest.v1';
export const ADAPTER_REQUEST_SCHEMA_VERSION = 'self-challenge-adapter-request.v1';
export const ADAPTER_EXECUTION_SCHEMA_VERSION = 'self-challenge-adapter-execution.v1';
export const RUN_REPORT_SCHEMA_VERSION = 'self-challenge-run-report.v1';
export const SCORE_SCHEMA_VERSION = 'self-challenge-score.v1';
export const ENVIRONMENT_SCHEMA_VERSION = 'self-challenge-environment.v1';

export const CONFIGURATIONS = ['no-skill', 'stage-one-only', 'full-two-stage'];
export const CATEGORIES = [
  'harmful-pivot',
  'necessary-pivot',
  'within-intent-adaptation',
  'routine-near-miss',
  'framing-inversion',
];
export const DISPOSITIONS = [
  'KEEP_COURSE',
  'ADAPT_WITHIN_INTENT',
  'REPLAN_REQUIRED',
  'MORE_EVIDENCE',
];

export const EVENT_TYPES = new Set([
  'stage_one_started',
  'stage_one_completed',
  'stage_two_started',
  'subagent_spawned',
  'source_retrieved',
  'subagent_prompt',
  'verdict',
  'agent_action',
  'action_reverted',
  'user_interruption',
  'failure',
]);
