const RECONSTRUCTION_CONTEXT_KEYS = new Set([
  'authoritative_sources',
  'problem_evidence',
  'constraints',
  'non_goals',
  'evidence_reveal_order',
]);
const READ_ONLY_ASSURANCES = new Set(['runtime-enforced', 'observed-no-write']);
const SOURCE_PRECEDENCE = new Set(['resolved', 'unresolved']);
const DISPOSITIONS = new Set([
  'KEEP_COURSE',
  'ADAPT_WITHIN_INTENT',
  'REPLAN_REQUIRED',
  'MORE_EVIDENCE',
]);

function requireString(value, name) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new TypeError(`${name} must be a non-empty string`);
  }
  return value;
}

function requireStringList(value, name) {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string' || entry.trim() === '')) {
    throw new TypeError(`${name} must be an array of non-empty strings`);
  }
  return value;
}

function requireNonEmptyStringList(value, name) {
  const entries = requireStringList(value, name);
  if (entries.length === 0) {
    throw new TypeError(`${name} must not be empty`);
  }
  return entries;
}

function requireUniqueStringList(value, name, duplicateLabel) {
  const entries = requireNonEmptyStringList(value, name);
  if (new Set(entries).size !== entries.length) {
    throw new TypeError(`${name} must not contain duplicate ${duplicateLabel}`);
  }
  return entries;
}

function requireEnum(value, values, name) {
  if (!values.has(value)) {
    throw new TypeError(`${name} must be supported`);
  }
  return value;
}

function requireObject(value, name) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value;
}

function requireSources(value) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new TypeError('authoritative_sources must be a non-empty array');
  }
  const sources = value.map((source, index) => ({
    id: requireString(source?.id, `authoritative_sources[${index}].id`),
    content: requireString(source?.content, `authoritative_sources[${index}].content`),
  }));
  if (new Set(sources.map((source) => source.id)).size !== sources.length) {
    throw new TypeError('authoritative_sources must not contain duplicate source IDs');
  }
  return sources;
}

function orderSources(sources, value) {
  const sourceIds = new Set(sources.map((source) => source.id));
  const order = requireUniqueStringList(value, 'evidence_reveal_order', 'source IDs');
  if (order.length !== sources.length || order.some((sourceId) => !sourceIds.has(sourceId))) {
    throw new TypeError('evidence_reveal_order must contain every authoritative source ID exactly once');
  }
  const sourcesById = new Map(sources.map((source) => [source.id, source]));
  return order.map((sourceId) => sourcesById.get(sourceId));
}

function assertCandidateWithheld(candidate, problemEvidence, constraints, nonGoals) {
  const normalizedCandidate = candidate.trim().toLowerCase();
  const escapedCandidate = normalizedCandidate.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const candidatePattern = new RegExp(`(^|[^A-Za-z0-9])${escapedCandidate}(?=$|[^A-Za-z0-9])`);
  const fields = [problemEvidence, ...constraints, ...nonGoals];
  if (fields.some((field) => candidatePattern.test(field.trim().toLowerCase()))) {
    throw new TypeError('candidate must not appear in a caller-controlled round-one field');
  }
}

export function buildReconstructionPrompt(context) {
  if (context === null || typeof context !== 'object' || Array.isArray(context)) {
    throw new TypeError('source-first context must be an object');
  }
  if (Object.keys(context).some((key) => !RECONSTRUCTION_CONTEXT_KEYS.has(key))) {
    throw new TypeError('source-first context contains unsupported input');
  }
  const sources = requireSources(context.authoritative_sources);
  const orderedSources = orderSources(sources, context.evidence_reveal_order);
  const problemEvidence = requireString(context.problem_evidence, 'problem_evidence');
  const constraints = requireStringList(context.constraints, 'constraints');
  const nonGoals = requireStringList(context.non_goals, 'non_goals');
  return [
    'Act as a fresh read-only challenger.',
    'Reconstruct the baseline from the authoritative sources before evaluating any proposed direction.',
    'Do not edit files, revise plans, authorize scope changes, or invoke self-challenge.',
    'Authoritative sources:',
    ...orderedSources.map((source) => `Source ${source.id}: ${source.content}`),
    `Problem evidence: ${problemEvidence}`,
    'Constraints:',
    ...constraints.map((constraint) => `- ${constraint}`),
    'Non-goals:',
    ...nonGoals.map((nonGoal) => `- ${nonGoal}`),
    'Use this rule: recency and clarity resolve intent only when they form one unique evidence-backed ordering; otherwise mark source precedence unresolved.',
    'Return source IDs, baseline, invariants, source conflicts and precedence, alternative hypotheses, and falsification conditions.',
  ].join('\n');
}

function normalizeReconstruction(value) {
  const reconstruction = requireObject(value, 'reconstruction');
  return {
    source_ids: requireUniqueStringList(reconstruction.source_ids, 'reconstruction.source_ids', 'source IDs'),
    baseline: requireString(reconstruction.baseline, 'reconstruction.baseline'),
    invariants: requireNonEmptyStringList(reconstruction.invariants, 'reconstruction.invariants'),
    source_conflicts: requireStringList(reconstruction.source_conflicts, 'reconstruction.source_conflicts'),
    source_precedence: requireEnum(reconstruction.source_precedence, SOURCE_PRECEDENCE, 'reconstruction.source_precedence'),
    alternative_hypotheses: requireNonEmptyStringList(reconstruction.alternative_hypotheses, 'reconstruction.alternative_hypotheses'),
    falsification_conditions: requireNonEmptyStringList(reconstruction.falsification_conditions, 'reconstruction.falsification_conditions'),
  };
}

export function buildCandidatePrompt({ candidate, reconstruction }) {
  const candidateAction = requireString(candidate, 'candidate');
  const prior = normalizeReconstruction(reconstruction);
  return [
    'Use the completed source-first reconstruction as the baseline for an adversarial verdict.',
    `Baseline: ${prior.baseline}`,
    `Source precedence: ${prior.source_precedence}`,
    'Invariants:',
    ...prior.invariants.map((invariant) => `- ${invariant}`),
    `Proposed direction: ${candidateAction}`,
    'Steelman both preserving the baseline and changing direction.',
    'State the main agent error risk, the protected or invalidated invariant, evidence source IDs, the condition that would change the conclusion, a reason, one verdict, and one allowed next action.',
    'Apply evidence-first precedence: insufficient evidence or unresolved source precedence returns MORE_EVIDENCE; otherwise return KEEP_COURSE, ADAPT_WITHIN_INTENT, or REPLAN_REQUIRED.',
    'Do not edit files, revise plans, authorize scope changes, or invoke self-challenge.',
  ].join('\n');
}

function normalizeVerdict(value) {
  const verdict = requireObject(value, 'verdict');
  const normalized = {
    evidence_source_ids: requireUniqueStringList(verdict.evidence_source_ids, 'verdict.evidence_source_ids', 'evidence source IDs'),
    evidence_sufficient: verdict.evidence_sufficient,
    source_precedence: requireEnum(verdict.source_precedence, SOURCE_PRECEDENCE, 'verdict.source_precedence'),
    value: requireEnum(verdict.value, DISPOSITIONS, 'verdict.value'),
    baseline_steelman: requireString(verdict.baseline_steelman, 'verdict.baseline_steelman'),
    candidate_steelman: requireString(verdict.candidate_steelman, 'verdict.candidate_steelman'),
    main_agent_error_risk: requireString(verdict.main_agent_error_risk, 'verdict.main_agent_error_risk'),
    protected_or_invalidated_invariant: requireString(verdict.protected_or_invalidated_invariant, 'verdict.protected_or_invalidated_invariant'),
    change_condition: requireString(verdict.change_condition, 'verdict.change_condition'),
    reason: requireString(verdict.reason, 'verdict.reason'),
    allowed_next_action: requireString(verdict.allowed_next_action, 'verdict.allowed_next_action'),
  };
  if (typeof normalized.evidence_sufficient !== 'boolean') {
    throw new TypeError('verdict.evidence_sufficient must be a boolean');
  }
  const evidenceGap = !normalized.evidence_sufficient || normalized.source_precedence === 'unresolved';
  if (evidenceGap && normalized.value !== 'MORE_EVIDENCE') {
    throw new TypeError('evidence-first precedence requires MORE_EVIDENCE');
  }
  if (!evidenceGap && normalized.value === 'MORE_EVIDENCE') {
    throw new TypeError('MORE_EVIDENCE requires an evidence gap');
  }
  return normalized;
}

function normalizeChallenger(value) {
  const challenger = requireObject(value, 'challenger');
  const agentId = requireString(challenger.agent_id, 'challenger.agent_id');
  const readOnlyAssurance = requireEnum(challenger.read_only_assurance, READ_ONLY_ASSURANCES, 'challenger.read_only_assurance');
  if (typeof challenger.ask !== 'function') {
    throw new TypeError('challenger.ask must be a function');
  }
  if (readOnlyAssurance === 'runtime-enforced') {
    requireString(challenger.capability_evidence, 'challenger.capability_evidence');
  }
  return { agent_id: agentId, read_only_assurance: readOnlyAssurance, capability_evidence: challenger.capability_evidence, ask: challenger.ask };
}

function assertKnownSourceIds(sourceIds, knownSourceIds, name) {
  if (sourceIds.some((sourceId) => !knownSourceIds.has(sourceId))) {
    throw new TypeError(`${name} must only reference authoritative sources`);
  }
}

function assertVerdictFollowsReconstruction(reconstruction, verdict) {
  if (verdict.source_precedence !== reconstruction.source_precedence) {
    throw new TypeError('verdict.source_precedence must match reconstruction source precedence');
  }
  const reconstructionSourceIds = new Set(reconstruction.source_ids);
  if (verdict.evidence_source_ids.some((sourceId) => !reconstructionSourceIds.has(sourceId))) {
    throw new TypeError('verdict.evidence_source_ids must be a subset of reconstruction.source_ids');
  }
}

export async function runStageTwoProtocol({
  candidate,
  authoritative_sources,
  problem_evidence,
  constraints,
  non_goals,
  evidence_reveal_order,
  candidate_former_agent_id,
  openChallenger,
  emit,
}) {
  const candidateAction = requireString(candidate, 'candidate');
  const candidateFormerAgentId = requireString(candidate_former_agent_id, 'candidate_former_agent_id');
  if (typeof openChallenger !== 'function') {
    throw new TypeError('openChallenger must be a function');
  }
  if (typeof emit !== 'function') {
    throw new TypeError('emit must be a function');
  }
  const sources = requireSources(authoritative_sources);
  const orderedSources = orderSources(sources, evidence_reveal_order);
  const problemEvidence = requireString(problem_evidence, 'problem_evidence');
  const roundOneConstraints = requireStringList(constraints, 'constraints');
  const roundOneNonGoals = requireStringList(non_goals, 'non_goals');
  assertCandidateWithheld(candidateAction, problemEvidence, roundOneConstraints, roundOneNonGoals);
  const reconstructionPrompt = buildReconstructionPrompt({
    authoritative_sources: sources,
    problem_evidence: problemEvidence,
    constraints: roundOneConstraints,
    non_goals: roundOneNonGoals,
    evidence_reveal_order: orderedSources.map((source) => source.id),
  });
  const sourceIds = new Set(sources.map((source) => source.id));

  emit('stage_two_started');
  const challenger = normalizeChallenger(await openChallenger());
  if (challenger.agent_id === candidateFormerAgentId) {
    throw new TypeError('challenger.agent_id must differ from candidate_former_agent_id');
  }
  const spawn = {
    agent_id: challenger.agent_id,
    candidate_former_agent_id: candidateFormerAgentId,
    read_only_assurance: challenger.read_only_assurance,
    fresh: true,
  };
  if (challenger.read_only_assurance === 'runtime-enforced') {
    spawn.capability_evidence = challenger.capability_evidence;
  }
  emit('subagent_spawned', spawn);
  emit('subagent_prompt', { phase: 'reconstruct', candidate_disclosed: false, agent_id: challenger.agent_id });
  const reconstruction = normalizeReconstruction(await challenger.ask(reconstructionPrompt));
  assertKnownSourceIds(reconstruction.source_ids, sourceIds, 'reconstruction.source_ids');
  for (const sourceId of reconstruction.source_ids) {
    emit('source_retrieved', { source_id: sourceId, actor: 'subagent', agent_id: challenger.agent_id });
  }
  emit('subagent_reconstruction', { agent_id: challenger.agent_id, ...reconstruction });

  const candidatePrompt = buildCandidatePrompt({ candidate: candidateAction, reconstruction });
  emit('subagent_prompt', { phase: 'candidate', candidate_disclosed: true, agent_id: challenger.agent_id });
  const verdict = normalizeVerdict(await challenger.ask(candidatePrompt));
  assertVerdictFollowsReconstruction(reconstruction, verdict);
  emit('verdict', { agent_id: challenger.agent_id, ...verdict });
  return { agent_id: challenger.agent_id, read_only_assurance: challenger.read_only_assurance, reconstruction, verdict };
}
