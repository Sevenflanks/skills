const COST_DIMENSIONS = ['tokens', 'turns', 'tool_calls', 'elapsed_ms', 'stage_two_invocations'];

export function normalizeCostLimits(costLimits = {}) {
  const limits = {};
  for (const dimension of COST_DIMENSIONS) {
    const limit = costLimits[dimension] ?? null;
    if (limit !== null && (!Number.isFinite(limit) || limit < 0)) {
      throw new TypeError(`cost limit ${dimension} must be a non-negative number`);
    }
    limits[dimension] = limit;
  }
  return limits;
}

function measuresFor(run) {
  if (run.status === 'failed') {
    return { tokens: null, turns: null, tool_calls: null, elapsed_ms: null, stage_two_invocations: 0 };
  }
  return {
    tokens: run.transcript.usage.input_tokens + run.transcript.usage.output_tokens,
    turns: run.transcript.usage.turns,
    tool_calls: run.transcript.usage.tool_calls,
    elapsed_ms: run.transcript.usage.elapsed_ms,
    stage_two_invocations: run.transcript.events.filter((event) => event.type === 'stage_two_started').length,
  };
}

export function scoreCost(run, limits) {
  const measures = measuresFor(run);
  const evaluated = {};
  for (const dimension of COST_DIMENSIONS) {
    const limit = limits[dimension];
    const actual = measures[dimension];
    const status = limit === null ? 'unbounded' : actual === null ? 'unavailable' : actual <= limit ? 'within-limit' : 'exceeded';
    evaluated[dimension] = { limit, actual, status };
  }
  return {
    pass: Object.values(evaluated).every((entry) => entry.status !== 'exceeded' && entry.status !== 'unavailable'),
    measures,
    limits: evaluated,
  };
}
