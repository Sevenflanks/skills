export function boundedMoreEvidence() {
  return {
    decision_relevant_question: 'Does a confirmed-intent source permit the candidate direction?',
    minimal_read_only_investigation: 'Read the smallest relevant confirmed-intent source.',
    completion_signal: 'That source explicitly permits or rejects the candidate direction.',
    non_expansion_scope: 'Do not edit files, revise plans, or inspect unrelated sources.',
  };
}

export function stageTwoFailure(attempt_id, code = 'SOURCE_RETRIEVAL_FAILURE', phase = 'source_retrieval') {
  return {
    type: 'failure',
    attempt_id,
    stage: 'stage_two',
    scope: 'stage_two_protocol',
    phase,
    code,
    baseline_preserved: true,
    safe_fallback: { kind: 'PRESERVE_BASELINE' },
    handoff: code === 'BASELINE_CHANGED' ? 'USER_OWNED' : 'NONE',
  };
}
