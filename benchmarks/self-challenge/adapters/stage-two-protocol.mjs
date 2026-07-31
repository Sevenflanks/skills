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
const MORE_EVIDENCE_FIELDS = [
  'decision_relevant_question',
  'minimal_read_only_investigation',
  'completion_signal',
  'non_expansion_scope',
];
const STAGE_TWO_FAILURE_CODES = new Set([
  'BASELINE_CHANGED',
  'DUPLICATE_TUPLE',
  'RECURSIVE_INVOCATION',
  'CHALLENGER_TIMEOUT',
  'EVIDENCE_NOT_MATERIALLY_CHANGED',
  'OPEN_CHALLENGER_FAILURE',
  'SOURCE_RETRIEVAL_FAILURE',
  'MALFORMED_RECONSTRUCTION',
  'MALFORMED_VERDICT',
  'MISSING_VERDICT',
  'READ_ONLY_ASSURANCE_FAILURE',
  'OBSERVED_WRITE',
  'EMIT_FAILURE',
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

function canonicalizeText(value, name) {
  return requireString(value, name)
    .normalize('NFC')
    .replace(/\r\n?|\n/g, '\n')
    .trim()
    .replace(/\s+/gu, ' ');
}

function canonicalizeMaterial(value, name) {
  if (typeof value === 'string') {
    return JSON.stringify(canonicalizeText(value, name));
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry, index) => canonicalizeMaterial(entry, `${name}[${index}]`)).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).map((key) => `${JSON.stringify(key)}:${canonicalizeMaterial(value[key], `${name}.${key}`)}`).join(',')}}`;
  }
  throw new TypeError(`${name} must be a string, array, or object of strings`);
}

function resolveIdentity({ identity, material, name }) {
  if ((identity === undefined) === (material === undefined)) {
    throw new TypeError(`${name} requires exactly one identity or material`);
  }
  return identity === undefined
    ? canonicalizeMaterial(material, `${name}_material`)
    : canonicalizeText(identity, `${name}_identity`);
}

function safeFailure({ attempt_id, code, phase, handoff = 'NONE' }) {
  if (!STAGE_TWO_FAILURE_CODES.has(code)) {
    throw new TypeError('failure code must be recognized');
  }
  return {
    attempt_id,
    stage: 'stage_two',
    scope: 'stage_two_protocol',
    phase,
    code,
    baseline_preserved: true,
    safe_fallback: { kind: 'PRESERVE_BASELINE' },
    handoff,
  };
}

export class StageTwoProtocolError extends Error {
  constructor(code) {
    if (!STAGE_TWO_FAILURE_CODES.has(code)) {
      throw new TypeError('stage-two failure code must be recognized');
    }
    super(code);
    this.code = code;
  }
}

function classifiedFailureCode(error, fallback) {
  return error instanceof StageTwoProtocolError ? error.code : fallback;
}

export function createStageTwoSessionGuard({ baseline_material }) {
  const baselineIdentity = canonicalizeMaterial(baseline_material, 'baseline_material');
  const consumedTuples = new Set();
  let activeTuple = null;
  let activeEvidence = null;
  let recursiveInvocation = false;
  let pendingEvidence = null;
  let userHandoffRequired = false;
  let nextAttempt = 1;

  return Object.freeze({
    prepare({ baseline_material: baselineMaterial, candidate_identity, candidate_material, evidence_identity, evidence_material }) {
      if (activeTuple !== null) {
        recursiveInvocation = true;
        return { recursive: true };
      }
      const baseline = canonicalizeMaterial(baselineMaterial, 'baseline_material');
      const candidate = resolveIdentity({ identity: candidate_identity, material: candidate_material, name: 'candidate' });
      const evidence = resolveIdentity({ identity: evidence_identity, material: evidence_material, name: 'evidence' });
      if (baseline !== baselineIdentity) {
        const attempt_id = `stage-two-${nextAttempt++}`;
        return { attempt_id, failure: safeFailure({ attempt_id, code: 'BASELINE_CHANGED', phase: 'preflight', handoff: 'USER_OWNED' }) };
      }
      if (userHandoffRequired) {
        return { handoff: 'USER_OWNED' };
      }
      const tuple = JSON.stringify([baseline, candidate, evidence]);
      if (consumedTuples.has(tuple)) {
        const attempt_id = `stage-two-${nextAttempt++}`;
        return { attempt_id, failure: safeFailure({ attempt_id, code: 'DUPLICATE_TUPLE', phase: 'preflight' }) };
      }
      if (pendingEvidence === evidence) {
        const attempt_id = `stage-two-${nextAttempt++}`;
        consumedTuples.add(tuple);
        return { attempt_id, failure: safeFailure({ attempt_id, code: 'EVIDENCE_NOT_MATERIALLY_CHANGED', phase: 'preflight' }) };
      }
      const attempt_id = `stage-two-${nextAttempt++}`;
      consumedTuples.add(tuple);
      activeTuple = tuple;
      activeEvidence = evidence;
      return {
        attempt_id,
        tuple,
        requires_more_evidence: pendingEvidence === evidence,
        requires_user_handoff: pendingEvidence !== null && pendingEvidence !== evidence,
      };
    },
    finish(tuple, verdict, userHandoff) {
      if (activeTuple === tuple) {
        if (verdict?.value === 'MORE_EVIDENCE') {
          pendingEvidence = activeEvidence;
        } else if (verdict !== undefined && pendingEvidence !== null && activeEvidence !== pendingEvidence) {
          pendingEvidence = null;
        }
        userHandoffRequired = userHandoff === true;
        activeTuple = null;
        activeEvidence = null;
        recursiveInvocation = false;
      }
    },
    activeFailure(tuple) {
      return activeTuple === tuple && recursiveInvocation ? 'RECURSIVE_INVOCATION' : null;
    },
  });
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
    'A MORE_EVIDENCE verdict must include a more_evidence object with exactly these non-empty fields: decision_relevant_question, minimal_read_only_investigation, completion_signal, and non_expansion_scope. The investigation must be read-only and must not expand beyond its stated scope.',
    'Do not edit files, revise plans, authorize scope changes, or invoke self-challenge.',
  ].join('\n');
}

function normalizeMoreEvidence(value) {
  const moreEvidence = requireObject(value, 'verdict.more_evidence');
  const keys = Object.keys(moreEvidence);
  if (keys.length !== MORE_EVIDENCE_FIELDS.length || keys.some((key) => !MORE_EVIDENCE_FIELDS.includes(key))) {
    throw new TypeError('verdict.more_evidence must contain exactly the bounded investigation fields');
  }
  return Object.fromEntries(
    MORE_EVIDENCE_FIELDS.map((field) => [field, requireString(moreEvidence[field], `verdict.more_evidence.${field}`)]),
  );
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
  if (normalized.value === 'MORE_EVIDENCE') {
    normalized.more_evidence = normalizeMoreEvidence(verdict.more_evidence);
  } else if ('more_evidence' in verdict) {
    throw new TypeError('verdict.more_evidence is only allowed for MORE_EVIDENCE');
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
  session_guard,
  baseline_material,
  candidate_identity,
  candidate_material,
  evidence_identity,
  evidence_material,
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
  let sessionAttempt = null;
  if (session_guard !== undefined) {
    if (session_guard === null || typeof session_guard.prepare !== 'function' || typeof session_guard.finish !== 'function') {
      throw new TypeError('session_guard must be created by createStageTwoSessionGuard');
    }
    sessionAttempt = session_guard.prepare({
      baseline_material,
      candidate_identity,
      candidate_material,
      evidence_identity,
      evidence_material,
    });
  }
  const emitStageTwo = (type, fields = {}) => {
    try {
      emit(type, sessionAttempt === null ? fields : { ...fields, attempt_id: sessionAttempt.attempt_id });
    } catch {
      throw new StageTwoProtocolError('EMIT_FAILURE');
    }
  };
  if (sessionAttempt?.recursive) {
    return { recursive: true };
  }
  if (sessionAttempt?.handoff) {
    return { handoff: sessionAttempt.handoff };
  }
  if (sessionAttempt?.failure) {
    let failure = sessionAttempt.failure;
    try {
      emitStageTwo('stage_two_started');
    } catch {
      failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code: 'EMIT_FAILURE', phase: 'preflight' });
      try {
        emitStageTwo('stage_two_started');
      } catch {
        return { attempt_id: sessionAttempt.attempt_id, failure };
      }
    }
    try {
      emitStageTwo('failure', failure);
    } catch {
      failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code: 'EMIT_FAILURE', phase: 'preflight' });
      try {
        emitStageTwo('failure', failure);
      } catch {
        // The emitter is the observable boundary; no terminal can be fabricated after it rejects twice.
      }
    }
    return { attempt_id: sessionAttempt.attempt_id, failure };
  }

  let phase = 'start';
  let challengerAgentId;
  let completedVerdict;
  let completedUserHandoff = false;
  const normalizeForGuard = (normalizer, code) => {
    try {
      return normalizer();
    } catch (error) {
      if (sessionAttempt === null) {
        throw error;
      }
      throw new StageTwoProtocolError(code);
    }
  };
  const assertNoObservedViolation = (response) => {
    if (response?.observed_write === true) {
      throw new StageTwoProtocolError('OBSERVED_WRITE');
    }
    if (response?.recursive_self_challenge === true) {
      throw new StageTwoProtocolError('RECURSIVE_INVOCATION');
    }
    if (sessionAttempt !== null && session_guard.activeFailure(sessionAttempt.tuple) !== null) {
      throw new StageTwoProtocolError('RECURSIVE_INVOCATION');
    }
  };
  try {
    phase = 'start';
    emitStageTwo('stage_two_started');
    phase = 'open_challenger';
    const openedChallenger = await openChallenger();
    assertNoObservedViolation(openedChallenger);
    phase = 'read_only_assurance';
    const challenger = normalizeForGuard(() => normalizeChallenger(openedChallenger), 'READ_ONLY_ASSURANCE_FAILURE');
    challengerAgentId = challenger.agent_id;
    if (challenger.agent_id === candidateFormerAgentId) {
      if (sessionAttempt === null) {
        throw new TypeError('challenger.agent_id must differ from candidate_former_agent_id');
      }
      throw new StageTwoProtocolError('OPEN_CHALLENGER_FAILURE');
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
    emitStageTwo('subagent_spawned', spawn);
    emitStageTwo('subagent_prompt', { phase: 'reconstruct', candidate_disclosed: false, agent_id: challenger.agent_id });
    phase = 'source_retrieval';
    const reconstructionResponse = await challenger.ask(reconstructionPrompt);
    assertNoObservedViolation(reconstructionResponse);
    phase = 'reconstruction';
    const reconstruction = normalizeForGuard(
      () => normalizeReconstruction(reconstructionResponse),
      'MALFORMED_RECONSTRUCTION',
    );
    normalizeForGuard(
      () => assertKnownSourceIds(reconstruction.source_ids, sourceIds, 'reconstruction.source_ids'),
      'MALFORMED_RECONSTRUCTION',
    );
    for (const sourceId of reconstruction.source_ids) {
      emitStageTwo('source_retrieved', { source_id: sourceId, actor: 'subagent', agent_id: challenger.agent_id });
    }
    emitStageTwo('subagent_reconstruction', { agent_id: challenger.agent_id, ...reconstruction });

    const candidatePrompt = buildCandidatePrompt({ candidate: candidateAction, reconstruction });
    emitStageTwo('subagent_prompt', { phase: 'candidate', candidate_disclosed: true, agent_id: challenger.agent_id });
    phase = 'verdict';
    const verdictResponse = await challenger.ask(candidatePrompt);
    assertNoObservedViolation(verdictResponse);
    if (verdictResponse === undefined || verdictResponse === null) {
      throw new StageTwoProtocolError('MISSING_VERDICT');
    }
    const verdict = normalizeForGuard(() => normalizeVerdict(verdictResponse), 'MALFORMED_VERDICT');
    normalizeForGuard(
      () => assertVerdictFollowsReconstruction(reconstruction, verdict),
      'MALFORMED_VERDICT',
    );
    if (sessionAttempt?.requires_more_evidence && verdict.value !== 'MORE_EVIDENCE') {
      throw new StageTwoProtocolError('EVIDENCE_NOT_MATERIALLY_CHANGED');
    }
    if (sessionAttempt?.requires_user_handoff && verdict.value === 'MORE_EVIDENCE') {
      emitStageTwo('user_interruption', { handoff: 'USER_OWNED' });
      completedUserHandoff = true;
    }
    emitStageTwo('verdict', { agent_id: challenger.agent_id, ...verdict });
    completedVerdict = verdict;
    return {
      ...(sessionAttempt === null ? {} : { attempt_id: sessionAttempt.attempt_id }),
      agent_id: challenger.agent_id,
      read_only_assurance: challenger.read_only_assurance,
      reconstruction,
      verdict,
    };
  } catch (error) {
    if (sessionAttempt === null) {
      throw error;
    }
    const fallback = phase === 'open_challenger'
      ? 'OPEN_CHALLENGER_FAILURE'
      : phase === 'source_retrieval'
        ? 'SOURCE_RETRIEVAL_FAILURE'
        : phase === 'read_only_assurance'
          ? 'READ_ONLY_ASSURANCE_FAILURE'
          : phase === 'start'
            ? 'EMIT_FAILURE'
            : 'MALFORMED_VERDICT';
    let code = classifiedFailureCode(error, fallback);
    let failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code, phase });
    if (phase === 'start' && code === 'EMIT_FAILURE') {
      try {
        emitStageTwo('stage_two_started');
      } catch {
        return { attempt_id: sessionAttempt.attempt_id, failure };
      }
    }
    try {
      if (code === 'OBSERVED_WRITE') {
        try {
          emitStageTwo('subagent_write_observed', { agent_id: challengerAgentId ?? 'unknown-challenger' });
        } catch {
          code = 'EMIT_FAILURE';
          failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code, phase });
        }
      }
      if (code === 'RECURSIVE_INVOCATION') {
        try {
          emitStageTwo('recursive_self_challenge_invoked', { agent_id: challengerAgentId ?? 'unknown-challenger' });
        } catch {
          code = 'EMIT_FAILURE';
          failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code, phase });
        }
      }
      emitStageTwo('failure', failure);
    } catch {
      failure = safeFailure({ attempt_id: sessionAttempt.attempt_id, code: 'EMIT_FAILURE', phase: 'failure' });
      try {
        emitStageTwo('failure', failure);
      } catch {
        // The emitter is the observable boundary; no terminal can be fabricated after it rejects twice.
      }
    }
    return { attempt_id: sessionAttempt.attempt_id, failure };
  } finally {
    if (sessionAttempt !== null) {
      session_guard.finish(sessionAttempt.tuple, completedVerdict, completedUserHandoff);
    }
  }
}
