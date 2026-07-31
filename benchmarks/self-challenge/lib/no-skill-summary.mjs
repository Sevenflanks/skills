import { validateRunReport, validateScore } from './contracts.mjs';

function statistic(values) {
  const availableValues = values.filter((value) => Number.isFinite(value));
  if (availableValues.length === 0) {
    return { total: values.length, available: 0, unavailable: values.length, min: null, max: null, mean: null, standard_deviation: null };
  }
  const mean = availableValues.reduce((sum, value) => sum + value, 0) / availableValues.length;
  const variance = availableValues.reduce((sum, value) => sum + ((value - mean) ** 2), 0) / availableValues.length;
  return {
    total: values.length,
    available: availableValues.length,
    unavailable: values.length - availableValues.length,
    min: Math.min(...availableValues),
    max: Math.max(...availableValues),
    mean,
    standard_deviation: Math.sqrt(variance),
  };
}

function booleanOutcome(entries, key) {
  const completed = entries.filter((entry) => entry.run.status === 'completed');
  if (completed.length === 0) {
    return { total: entries.length, available: 0, unavailable: entries.length, passed: null, failed: null };
  }
  const passed = completed.filter((entry) => entry.result.outcome[key]).length;
  return { total: entries.length, available: completed.length, unavailable: entries.length - completed.length, passed, failed: completed.length - passed };
}

function overallOutcome(entries) {
  const completed = entries.filter((entry) => entry.run.status === 'completed');
  if (completed.length === 0) {
    return { total: entries.length, available: 0, unavailable: entries.length, passed: null, failed: null };
  }
  const passed = completed.filter((entry) => entry.result.overall_pass).length;
  return { total: entries.length, available: completed.length, unavailable: entries.length - completed.length, passed, failed: completed.length - passed };
}

function aggregate(entries) {
  const completed = entries.filter((entry) => entry.run.status === 'completed');
  return {
    total: entries.length,
    completed: completed.length,
    failed: entries.length - completed.length,
    outcome: {
      acceptance_preserved: booleanOutcome(entries, 'acceptance_preserved'),
      harmful_pivot_avoided: booleanOutcome(entries, 'harmful_pivot_avoided'),
      necessary_pivot_suppressed: booleanOutcome(entries, 'necessary_pivot_suppressed'),
      within_intent_adaptation_correct: booleanOutcome(entries, 'within_intent_adaptation_correct'),
      unnecessary_user_interruption: booleanOutcome(entries, 'unnecessary_user_interruption'),
      overall_pass: overallOutcome(entries),
    },
    cost: {
      tokens: statistic(entries.map((entry) => entry.result.cost.measures.tokens)),
      turns: statistic(entries.map((entry) => entry.result.cost.measures.turns)),
      tool_calls: statistic(entries.map((entry) => entry.result.cost.measures.tool_calls)),
      elapsed_ms: statistic(entries.map((entry) => entry.result.cost.measures.elapsed_ms)),
    },
    runtime_reported_cost: statistic(entries.map((entry) => entry.run.status === 'completed' ? entry.run.transcript.usage.runtime_reported_cost ?? null : null)),
    variance: {
      overall_pass: statistic(completed.map((entry) => entry.result.overall_pass ? 1 : 0)),
      acceptance_preserved: statistic(completed.map((entry) => entry.result.outcome.acceptance_preserved ? 1 : 0)),
    },
  };
}

function pairedEntries(report, score) {
  const results = new Map(score.results.map((result) => [result.run_id, result]));
  if (results.size !== report.runs.length) {
    throw new Error('Run report and score must have one result per run');
  }
  return report.runs.map((run) => {
    const result = results.get(run.run_id);
    if (!result) {
      throw new Error(`Score is missing ${run.run_id}`);
    }
    return { run, result };
  });
}

function sessionEvidence(entries) {
  const sessionRuns = new Map();
  const missingSessionRunIds = [];
  const completedRunIds = [];
  for (const entry of entries) {
    if (entry.run.status === 'failed') {
      continue;
    }
    completedRunIds.push(entry.run.run_id);
    const sessionId = entry.run.transcript.usage.session_id;
    if (typeof sessionId !== 'string') {
      missingSessionRunIds.push(entry.run.run_id);
      continue;
    }
    const runIds = sessionRuns.get(sessionId) ?? [];
    runIds.push(entry.run.run_id);
    sessionRuns.set(sessionId, runIds);
  }
  const reusedSessions = [...sessionRuns.entries()]
    .filter(([, runIds]) => runIds.length > 1)
    .map(([session_id, run_ids]) => ({ session_id, run_ids }));
  return {
    pass: completedRunIds.length === entries.length && missingSessionRunIds.length === 0 && reusedSessions.length === 0,
    completed_run_ids: completedRunIds,
    unique_session_ids: [...sessionRuns.keys()].sort(),
    missing_session_run_ids: missingSessionRunIds,
    reused_sessions: reusedSessions,
  };
}

export function summarizeNoSkillBaseline({ report, score }) {
  validateRunReport(report);
  validateScore(score);
  if (report.benchmark_version !== score.benchmark_version) {
    throw new Error('Run report and score benchmark versions must match');
  }
  const entries = pairedEntries(report, score);
  if (entries.some((entry) => entry.run.configuration !== 'no-skill')) {
    throw new Error('No-skill summary accepts only no-skill runs');
  }
  const families = new Map();
  for (const entry of entries) {
    const current = families.get(entry.run.family_id) ?? [];
    current.push(entry);
    families.set(entry.run.family_id, current);
  }
  const failures = entries
    .filter((entry) => entry.run.status === 'failed')
    .map((entry) => ({ run_id: entry.run.run_id, scenario_id: entry.run.scenario_id, failure: entry.run.failure }));
  return {
    schema_version: 'self-challenge-no-skill-summary.v1',
    benchmark_version: report.benchmark_version,
    configuration: 'no-skill',
    total_runs: entries.length,
    failures,
    session_evidence: sessionEvidence(entries),
    aggregate: aggregate(entries),
    families: [...families.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([family_id, familyEntries]) => ({
      family_id,
      category: familyEntries[0].run.category,
      scenario_ids: [...new Set(familyEntries.map((entry) => entry.run.scenario_id))].sort(),
      trial_count: familyEntries.length,
      ...aggregate(familyEntries),
    })),
  };
}
