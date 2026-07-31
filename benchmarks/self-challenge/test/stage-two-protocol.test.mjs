import assert from 'node:assert/strict';
import test from 'node:test';

import { buildReconstructionPrompt, runStageTwoProtocol } from '../adapters/stage-two-protocol.mjs';
import { validateExecution } from '../lib/contracts.mjs';

test('Given source-first inputs, when the reconstruction prompt is built, then candidate and benchmark controls are rejected', () => {
  const context = {
    authoritative_sources: [{ id: 'intent', content: 'Keep results isolated.' }],
    problem_evidence: 'A failing check exposed a possible conflict.',
    constraints: ['Do not change confirmed intent without evidence.'],
    non_goals: ['Do not edit files.'],
    evidence_reveal_order: ['intent'],
  };

  const prompt = buildReconstructionPrompt(context);
  assert.match(prompt, /Source intent: Keep results isolated\./);
  assert.doesNotMatch(prompt, /candidate/i);

  for (const [field, value] of Object.entries({
    candidate: 'move results to a shared directory',
    scenario_id: 'scenario-canary',
    scenario_prompt: 'scenario-prompt-canary',
    action_options: ['action-canary'],
    configuration: 'full-two-stage',
    trial: 7,
    adjudication: 'adjudication-canary',
    oracle: 'oracle-canary',
    canary: 'canary-value',
  })) {
    assert.throws(() => buildReconstructionPrompt({ ...context, [field]: value }), /source-first context/);
  }
});

test('Given an imminent candidate, when the protocol runs, then one observed-no-write challenger reconstructs before receiving it', async () => {
  const events = [];
  const prompts = [];
  let openCalls = 0;
  const result = await runStageTwoProtocol({
    candidate: 'Move fixture outputs into the shared directory.',
    authoritative_sources: [
      { id: 'ownership-contract', content: 'Fixture outputs stay isolated.' },
      { id: 'failing-test', content: 'The shared lookup cannot find isolated output.' },
    ],
    problem_evidence: 'A lookup failed after the fixture location changed.',
    constraints: ['Preserve the ownership contract.'],
    non_goals: ['Do not edit or relocate fixtures.'],
    evidence_reveal_order: ['failing-test', 'ownership-contract'],
    candidate_former_agent_id: 'main-agent',
    emit: (type, fields) => events.push({ type, ...fields }),
    openChallenger: async () => {
      openCalls += 1;
      return {
        agent_id: 'fresh-reader-1',
        read_only_assurance: 'observed-no-write',
        ask: async (prompt) => {
          prompts.push(prompt);
          if (prompts.length === 1) {
            return {
              source_ids: ['ownership-contract', 'failing-test'],
              baseline: 'Fixture outputs remain isolated.',
              invariants: ['Fixture ownership remains private.'],
              source_conflicts: [],
              source_precedence: 'resolved',
              alternative_hypotheses: ['Repair the lookup path.'],
              falsification_conditions: ['A source authorizes relocation.'],
            };
          }
          return {
            evidence_source_ids: ['ownership-contract', 'failing-test'],
            evidence_sufficient: true,
            source_precedence: 'resolved',
            value: 'KEEP_COURSE',
            baseline_steelman: 'Isolation is explicit.',
            candidate_steelman: 'A shared directory would simplify lookup.',
            main_agent_error_risk: 'The lookup defect may be mistaken for a contract change.',
            protected_or_invalidated_invariant: 'Fixture ownership remains private.',
            change_condition: 'An explicit ownership decision permits relocation.',
            reason: 'The sources preserve isolation.',
            allowed_next_action: 'repair-isolated-lookup',
          };
        },
      };
    },
  });

  assert.equal(openCalls, 1);
  assert.equal(prompts.length, 2);
  assert.doesNotMatch(prompts[0], /Move fixture outputs into the shared directory\./);
  assert.match(prompts[1], /Move fixture outputs into the shared directory\./);
  assert.ok(prompts[0].indexOf('Source failing-test:') < prompts[0].indexOf('Source ownership-contract:'));
  assert.deepEqual(events.map((event) => event.type), [
    'stage_two_started',
    'subagent_spawned',
    'subagent_prompt',
    'source_retrieved',
    'source_retrieved',
    'subagent_reconstruction',
    'subagent_prompt',
    'verdict',
  ]);
  assert.equal(events[1].read_only_assurance, 'observed-no-write');
  assert.equal(events[1].fresh, true);
  assert.equal(events[1].candidate_former_agent_id, 'main-agent');
  assert.equal(events[5].agent_id, 'fresh-reader-1');
  assert.deepEqual(events[5].source_ids, ['ownership-contract', 'failing-test']);
  assert.equal(events[7].agent_id, 'fresh-reader-1');
  assert.deepEqual(events[7].evidence_source_ids, ['ownership-contract', 'failing-test']);
  assert.equal(result.verdict.allowed_next_action, 'repair-isolated-lookup');
});

test('Given a missing candidate, when the protocol is asked to run, then it does not open a challenger', async () => {
  let openCalls = 0;
  await assert.rejects(
    () => runStageTwoProtocol({
      candidate: ' ',
      authoritative_sources: [{ id: 'intent', content: 'Keep the baseline.' }],
      problem_evidence: 'A possible conflict exists.',
      constraints: [],
      non_goals: [],
      evidence_reveal_order: ['intent'],
      candidate_former_agent_id: 'main-agent',
      openChallenger: async () => {
        openCalls += 1;
      },
    }),
    /candidate must be a non-empty string/,
  );
  assert.equal(openCalls, 0);
});

test('Given a source-first transcript, when execution validation runs, then it requires reconstruction and evidence-first verdict fields', () => {
  const execution = {
    schema_version: 'self-challenge-adapter-execution.v1',
    events: [
      { id: 'event-1', sequence: 1, type: 'stage_one_started' },
      { id: 'event-2', sequence: 2, type: 'stage_one_completed' },
      { id: 'event-3', sequence: 3, type: 'stage_two_started' },
      { id: 'event-4', sequence: 4, type: 'subagent_spawned', agent_id: 'fresh-reader-1', candidate_former_agent_id: 'main-agent', read_only_assurance: 'observed-no-write', fresh: true },
      { id: 'event-5', sequence: 5, type: 'subagent_prompt', phase: 'reconstruct', candidate_disclosed: false, agent_id: 'fresh-reader-1' },
      { id: 'event-6', sequence: 6, type: 'source_retrieved', source_id: 'intent', actor: 'subagent', agent_id: 'fresh-reader-1' },
      {
        id: 'event-7',
        sequence: 7,
        type: 'subagent_reconstruction',
        agent_id: 'fresh-reader-1',
        source_ids: ['intent'],
        baseline: 'Keep the baseline.',
        invariants: ['The contract remains stable.'],
        source_conflicts: [],
        source_precedence: 'resolved',
        alternative_hypotheses: ['Repair the implementation.'],
        falsification_conditions: ['A later decision supersedes the baseline.'],
      },
      { id: 'event-8', sequence: 8, type: 'subagent_prompt', phase: 'candidate', candidate_disclosed: true, agent_id: 'fresh-reader-1' },
      {
        id: 'event-9',
        sequence: 9,
        type: 'verdict',
        agent_id: 'fresh-reader-1',
        evidence_source_ids: ['intent'],
        evidence_sufficient: true,
        source_precedence: 'resolved',
        value: 'KEEP_COURSE',
        baseline_steelman: 'The source is explicit.',
        candidate_steelman: 'The change could simplify the implementation.',
        main_agent_error_risk: 'A local defect could be mistaken for a direction change.',
        protected_or_invalidated_invariant: 'The contract remains stable.',
        change_condition: 'A later explicit decision changes the contract.',
        reason: 'The source supports the baseline.',
        allowed_next_action: 'repair-implementation',
      },
      { id: 'event-10', sequence: 10, type: 'agent_action', action_id: 'repair-implementation', direction_changing: false },
    ],
    usage: { input_tokens: 1, output_tokens: 1, turns: 3, tool_calls: 1, elapsed_ms: 1 },
  };

  assert.doesNotThrow(() => validateExecution(execution));
  const insufficientEvidence = structuredClone(execution);
  insufficientEvidence.events[8].evidence_sufficient = false;
  assert.throws(() => validateExecution(insufficientEvidence), /MORE_EVIDENCE/);
  const unresolvedPrecedence = structuredClone(execution);
  unresolvedPrecedence.events[8].source_precedence = 'unresolved';
  assert.throws(() => validateExecution(unresolvedPrecedence), /MORE_EVIDENCE/);
});

function validReconstruction() {
  return {
    source_ids: ['intent'],
    baseline: 'Keep the baseline.',
    invariants: ['The contract remains stable.'],
    source_conflicts: [],
    source_precedence: 'resolved',
    alternative_hypotheses: ['Repair the implementation.'],
    falsification_conditions: ['A later decision changes the contract.'],
  };
}

function validVerdict() {
  return {
    evidence_source_ids: ['intent'],
    evidence_sufficient: true,
    source_precedence: 'resolved',
    value: 'KEEP_COURSE',
    baseline_steelman: 'The source is explicit.',
    candidate_steelman: 'The change could simplify the implementation.',
    main_agent_error_risk: 'A local defect could be mistaken for a direction change.',
    protected_or_invalidated_invariant: 'The contract remains stable.',
    change_condition: 'A later explicit decision changes the contract.',
    reason: 'The source supports the baseline.',
    allowed_next_action: 'repair-implementation',
  };
}

function validMoreEvidenceVerdict() {
  return {
    ...validVerdict(),
    evidence_sufficient: false,
    value: 'MORE_EVIDENCE',
    more_evidence: {
      decision_relevant_question: 'Does the source explicitly permit the candidate direction?',
      minimal_read_only_investigation: 'Read the current ownership decision only.',
      completion_signal: 'The ownership decision states whether the direction is permitted.',
      non_expansion_scope: 'Do not edit files, revise plans, or inspect unrelated sources.',
    },
  };
}

function runProtocolWith({
  reconstruction = validReconstruction(),
  verdict = validVerdict(),
  authoritative_sources = [{ id: 'intent', content: 'Keep the baseline.' }],
  evidence_reveal_order = authoritative_sources.map((source) => source.id),
  candidate = 'Repair the implementation.',
  candidate_former_agent_id = 'main-agent',
  problem_evidence = 'A local failure needs review.',
  constraints = [],
  non_goals = [],
  agent_id = 'fresh-reader-1',
  onOpen,
  openChallenger,
  emit = () => {},
  ...protocolOptions
} = {}) {
  let promptCount = 0;
  return runStageTwoProtocol({
    candidate,
    authoritative_sources,
    problem_evidence,
    constraints,
    non_goals,
    evidence_reveal_order,
    candidate_former_agent_id,
    emit,
    openChallenger: openChallenger ?? (async () => {
      onOpen?.();
      return {
        agent_id,
        read_only_assurance: 'observed-no-write',
        ask: async () => (promptCount++ === 0 ? reconstruction : verdict),
      };
    }),
    ...protocolOptions,
  });
}

function guardedExecution(events) {
  const completeEvents = [
    { type: 'stage_one_started' },
    { type: 'stage_one_completed' },
    ...events,
  ];
  return {
    schema_version: 'self-challenge-adapter-execution.v1',
    events: completeEvents.map((event, index) => ({ id: `event-${index + 1}`, sequence: index + 1, ...event })),
    usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: 0 },
  };
}

test('Given an evidence gap, when a MORE_EVIDENCE verdict omits its bounded investigation payload, then the protocol rejects it', async () => {
  await assert.rejects(
    () => runProtocolWith({
      verdict: {
        ...validMoreEvidenceVerdict(),
        more_evidence: undefined,
      },
    }),
    /more_evidence/,
  );
});

test('Given a session guard, when an unchanged tuple re-enters, then it is blocked while changed material receives a later attempt', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({
    baseline_material: {
      confirmed_sources: ['Keep fixture outputs isolated.'],
      constraints: ['Preserve fixture ownership.'],
      non_goals: ['Do not relocate fixtures.'],
    },
  });
  const events = [];
  let openCalls = 0;
  const run = (overrides = {}) => runProtocolWith({
    candidate: 'Repair the isolated lookup.',
    problem_evidence: 'The lookup fails after a path update.',
    emit: (type, fields = {}) => events.push({ type, ...fields }),
    onOpen: () => { openCalls += 1; },
    session_guard: guard,
    baseline_material: {
      confirmed_sources: ['Keep fixture outputs isolated.'],
      constraints: ['Preserve fixture ownership.'],
      non_goals: ['Do not relocate fixtures.'],
    },
    candidate_material: 'Repair\r\n  the isolated   lookup.',
    evidence_material: 'The lookup\r\n fails after a   path update.',
    ...overrides,
  });

  const first = await run();
  const duplicate = await run({
    candidate_material: 'Repair\n the isolated lookup.',
    evidence_material: 'The lookup fails after a path update.',
  });
  const changedEvidence = await run({ evidence_material: 'A fresh read proves the isolated path is missing.' });
  const changedCandidate = await run({
    candidate: 'Repair the isolated lookup without moving fixtures.',
    candidate_material: 'Repair the isolated lookup without moving fixtures.',
    evidence_material: 'A fresh read proves the isolated path is missing again.',
  });
  const changedBaseline = await run({
    baseline_material: {
      confirmed_sources: ['Move fixture outputs into the shared directory.'],
      constraints: ['Preserve fixture ownership.'],
      non_goals: ['Do not relocate fixtures.'],
    },
    evidence_material: 'A fresh read proves the isolated path is missing once more.',
  });

  assert.equal(first.attempt_id, 'stage-two-1');
  assert.equal(duplicate.failure.code, 'DUPLICATE_TUPLE');
  assert.equal(duplicate.failure.baseline_preserved, true);
  assert.equal(changedEvidence.attempt_id, 'stage-two-3');
  assert.equal(changedCandidate.attempt_id, 'stage-two-4');
  assert.equal(changedBaseline.failure.code, 'BASELINE_CHANGED');
  assert.equal(changedBaseline.failure.handoff, 'USER_OWNED');
  assert.equal(openCalls, 3);
  assert.equal(events.filter((event) => event.type === 'subagent_spawned').length, 3);
  assert.equal(events.filter((event) => event.type === 'failure').length, 2);
});

test('Given guarded challenger failures, when the same tuple retries, then each typed failure preserves the baseline and consumes that tuple', async () => {
  const { createStageTwoSessionGuard, StageTwoProtocolError } = await import('../adapters/stage-two-protocol.mjs');
  const cases = [
    ['CHALLENGER_TIMEOUT', async () => { throw new StageTwoProtocolError('CHALLENGER_TIMEOUT'); }],
    ['SOURCE_RETRIEVAL_FAILURE', async () => ({ agent_id: 'reader', read_only_assurance: 'observed-no-write', ask: async () => { throw new Error('network'); } })],
    ['MALFORMED_RECONSTRUCTION', async () => ({ agent_id: 'reader', read_only_assurance: 'observed-no-write', ask: async () => ({}) })],
    ['MALFORMED_VERDICT', async () => ({ agent_id: 'reader', read_only_assurance: 'observed-no-write', ask: async () => validReconstruction() })],
    ['MISSING_VERDICT', async () => {
      let calls = 0;
      return { agent_id: 'reader', read_only_assurance: 'observed-no-write', ask: async () => (calls++ === 0 ? validReconstruction() : undefined) };
    }],
    ['READ_ONLY_ASSURANCE_FAILURE', async () => ({ agent_id: 'reader', ask: async () => validReconstruction() })],
    ['OBSERVED_WRITE', async () => ({ agent_id: 'reader', observed_write: true, read_only_assurance: 'observed-no-write', ask: async () => validReconstruction() })],
    ['RECURSIVE_INVOCATION', async () => ({ agent_id: 'reader', recursive_self_challenge: true, read_only_assurance: 'observed-no-write', ask: async () => validReconstruction() })],
  ];

  for (const [expectedCode, openChallenger] of cases) {
    const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
    const options = {
      session_guard: guard,
      baseline_material: 'Keep fixture outputs isolated.',
      candidate_material: 'Repair the isolated lookup.',
      evidence_material: 'The isolated lookup failed.',
      openChallenger,
    };
    const first = await runProtocolWith(options);
    const retry = await runProtocolWith(options);
    assert.equal(first.failure.code, expectedCode);
    assert.equal(first.failure.baseline_preserved, true);
    assert.deepEqual(first.failure.safe_fallback, { kind: 'PRESERVE_BASELINE' });
    assert.equal(retry.failure.code, 'DUPLICATE_TUPLE');
  }
});

test('Given an active guarded challenger, when it recursively invokes stage two, then only the parent emits one recursive terminal', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let nestedResult;
  const common = {
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate: 'Repair the isolated lookup.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    problem_evidence: 'The isolated lookup failed.',
  };
  const result = await runProtocolWith({
    ...common,
    emit: (type, fields = {}) => events.push({ type, ...fields }),
    openChallenger: async () => ({
      agent_id: 'reader',
      read_only_assurance: 'observed-no-write',
      ask: async () => {
        nestedResult = await runProtocolWith({ ...common, emit: () => {} });
        return validReconstruction();
      },
    }),
  });
  const execution = {
    schema_version: 'self-challenge-adapter-execution.v1',
    events: [
      { id: 'event-1', sequence: 1, type: 'stage_one_started' },
      { id: 'event-2', sequence: 2, type: 'stage_one_completed' },
      ...events.map((event, index) => ({ id: `event-${index + 3}`, sequence: index + 3, ...event })),
    ],
    usage: { input_tokens: 0, output_tokens: 0, turns: 0, tool_calls: 0, elapsed_ms: 0 },
  };

  assert.equal(nestedResult.recursive, true);
  assert.equal(result.failure.code, 'RECURSIVE_INVOCATION');
  assert.deepEqual(events.map((event) => event.type), [
    'stage_two_started', 'subagent_spawned', 'subagent_prompt',
    'recursive_self_challenge_invoked', 'failure',
  ]);
  assert.doesNotThrow(() => validateExecution(execution));
});

test('Given an active guarded challenger, when nested stage two changes the baseline, then recursion still terminates only the parent attempt', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let nestedResult;
  const common = {
    session_guard: guard,
    candidate: 'Repair the isolated lookup.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    problem_evidence: 'The isolated lookup failed.',
  };
  const result = await runProtocolWith({
    ...common,
    baseline_material: 'Keep fixture outputs isolated.',
    emit: (type, fields = {}) => events.push({ type, ...fields }),
    openChallenger: async () => ({
      agent_id: 'reader',
      read_only_assurance: 'observed-no-write',
      ask: async () => {
        nestedResult = await runProtocolWith({
          ...common,
          baseline_material: 'Move fixture outputs into the shared directory.',
          emit: () => {},
        });
        return validReconstruction();
      },
    }),
  });

  assert.deepEqual(nestedResult, { recursive: true });
  assert.equal(result.failure.code, 'RECURSIVE_INVOCATION');
  assert.equal(new Set(events.map((event) => event.attempt_id)).size, 1);
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given MORE_EVIDENCE, when only the candidate changes, then it cannot reclassify until evidence materially changes', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let openCalls = 0;
  const common = {
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    problem_evidence: 'The isolated lookup failed.',
    evidence_material: 'The isolated lookup failed.',
    onOpen: () => { openCalls += 1; },
    emit: (type, fields = {}) => events.push({ type, ...fields }),
  };
  const first = await runProtocolWith({
    ...common,
    candidate: 'Repair the isolated lookup.',
    candidate_material: 'Repair the isolated lookup.',
    verdict: validMoreEvidenceVerdict(),
  });
  const candidateOnly = await runProtocolWith({
    ...common,
    candidate: 'Repair the isolated lookup without moving fixtures.',
    candidate_material: 'Repair the isolated lookup without moving fixtures.',
  });
  const candidateOnlyRetry = await runProtocolWith({
    ...common,
    candidate: 'Repair the isolated lookup without moving fixtures.',
    candidate_material: 'Repair the isolated lookup without moving fixtures.',
  });
  const secondCandidateOnly = await runProtocolWith({
    ...common,
    candidate: 'Repair the isolated lookup with a local cache.',
    candidate_material: 'Repair the isolated lookup with a local cache.',
  });
  const changedEvidence = await runProtocolWith({
    ...common,
    candidate: 'Repair the isolated lookup without moving fixtures.',
    candidate_material: 'Repair the isolated lookup without moving fixtures.',
    evidence_material: 'A new source proves the isolated lookup remains required.',
  });

  assert.equal(first.verdict.value, 'MORE_EVIDENCE');
  assert.equal(candidateOnly.failure.code, 'EVIDENCE_NOT_MATERIALLY_CHANGED');
  assert.equal(candidateOnlyRetry.failure.code, 'DUPLICATE_TUPLE');
  assert.equal(secondCandidateOnly.failure.code, 'EVIDENCE_NOT_MATERIALLY_CHANGED');
  assert.equal(openCalls, 2);
  assert.equal(changedEvidence.verdict.value, 'KEEP_COURSE');
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given a preflight failure whose original terminal emit fails once, when the fallback terminal emits, then the guarded transcript has exactly one terminal', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let failOnce = true;
  const result = await runProtocolWith({
    session_guard: guard,
    baseline_material: 'Changed baseline.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    emit: (type, fields = {}) => {
      if (type === 'failure' && failOnce) { failOnce = false; throw new Error('once'); }
      events.push({ type, ...fields });
    },
  });
  assert.equal(result.failure.code, 'EMIT_FAILURE');
  assert.equal(events.filter((event) => event.type === 'failure').length, 1);
  assert.equal(events.at(-1).code, 'EMIT_FAILURE');
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given a USER_OWNED handoff emitter failure, when the guarded attempt terminates, then only EMIT_FAILURE is observable', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let failInterruption = true;
  const options = {
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate_material: 'Repair the isolated lookup.',
    problem_evidence: 'The isolated lookup failed.',
    verdict: validMoreEvidenceVerdict(),
    emit: (type, fields = {}) => {
      if (type === 'user_interruption' && failInterruption) {
        failInterruption = false;
        throw new Error('handoff emitter unavailable');
      }
      events.push({ type, ...fields });
    },
  };

  await runProtocolWith({ ...options, evidence_material: 'The isolated lookup failed.' });
  const result = await runProtocolWith({ ...options, evidence_material: 'A new source remains unresolved.' });

  assert.equal(result.failure.code, 'EMIT_FAILURE');
  assert.equal(events.filter((event) => event.attempt_id === 'stage-two-2' && (event.type === 'verdict' || event.type === 'failure')).length, 1);
  assert.equal(events.at(-1).type, 'failure');
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given a recursive marker emitter failure, when actual guarded recursion is detected, then EMIT_FAILURE remains the sole terminal', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let failMarker = true;
  let nestedResult;
  const common = {
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate: 'Repair the isolated lookup.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    problem_evidence: 'The isolated lookup failed.',
  };
  const result = await runProtocolWith({
    ...common,
    emit: (type, fields = {}) => {
      if (type === 'recursive_self_challenge_invoked' && failMarker) {
        failMarker = false;
        throw new Error('marker emitter unavailable');
      }
      events.push({ type, ...fields });
    },
    openChallenger: async () => ({
      agent_id: 'reader',
      read_only_assurance: 'observed-no-write',
      ask: async () => {
        nestedResult = await runProtocolWith({ ...common, emit: () => {} });
        return validReconstruction();
      },
    }),
  });

  assert.equal(nestedResult.recursive, true);
  assert.equal(result.failure.code, 'EMIT_FAILURE');
  assert.equal(events.filter((event) => event.type === 'verdict' || event.type === 'failure').length, 1);
  assert.equal(events.at(-1).type, 'failure');
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given a write marker emitter failure, when an observed write is reported, then EMIT_FAILURE remains the sole terminal', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let failMarker = true;
  const result = await runProtocolWith({
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    emit: (type, fields = {}) => {
      if (type === 'subagent_write_observed' && failMarker) {
        failMarker = false;
        throw new Error('marker emitter unavailable');
      }
      events.push({ type, ...fields });
    },
    openChallenger: async () => ({
      agent_id: 'reader',
      observed_write: true,
      read_only_assurance: 'observed-no-write',
      ask: async () => validReconstruction(),
    }),
  });

  assert.equal(result.failure.code, 'EMIT_FAILURE');
  assert.equal(events.filter((event) => event.type === 'verdict' || event.type === 'failure').length, 1);
  assert.equal(events.at(-1).type, 'failure');
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given a second materially changed evidence gap, when it remains MORE_EVIDENCE, then the guard emits USER_OWNED handoff and blocks a third challenger', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let openCalls = 0;
  const run = (evidence_material) => runProtocolWith({
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material,
    problem_evidence: 'The isolated lookup failed.',
    verdict: validMoreEvidenceVerdict(),
    onOpen: () => { openCalls += 1; },
    emit: (type, fields = {}) => events.push({ type, ...fields }),
  });
  await run('The isolated lookup failed.');
  await run('A new source still leaves the ownership decision unresolved.');
  const third = await run('A third source remains unresolved.');

  assert.equal(openCalls, 2);
  assert.deepEqual(third, { handoff: 'USER_OWNED' });
  assert.deepEqual(events.filter((event) => event.type === 'user_interruption'), [{ type: 'user_interruption', handoff: 'USER_OWNED', attempt_id: 'stage-two-2' }]);
});

test('Given a synchronous emitter failure at a stage-two phase, when the guarded protocol stops, then it returns EMIT_FAILURE and consumes the tuple', async () => {
  for (const failingType of ['stage_two_started', 'subagent_spawned', 'subagent_prompt', 'source_retrieved', 'verdict']) {
    const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
    const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
    const events = [];
    let failed = false;
    const options = {
      session_guard: guard,
      baseline_material: 'Keep fixture outputs isolated.',
      candidate_material: 'Repair the isolated lookup.',
      evidence_material: 'The isolated lookup failed.',
      emit: (type, fields = {}) => {
        if (!failed && type === failingType) {
          failed = true;
          throw new Error('emitter unavailable');
        }
        events.push({ type, ...fields });
      },
    };
    const first = await runProtocolWith(options);
    const retry = await runProtocolWith(options);
    assert.equal(first.failure.code, 'EMIT_FAILURE');
    assert.equal(retry.failure.code, 'DUPLICATE_TUPLE');
    assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
  }
});

test('Given an open-challenger failure whose terminal emit fails once, when fallback emission succeeds, then the transcript remains complete', async () => {
  const { createStageTwoSessionGuard } = await import('../adapters/stage-two-protocol.mjs');
  const guard = createStageTwoSessionGuard({ baseline_material: 'Keep fixture outputs isolated.' });
  const events = [];
  let failTerminal = true;
  const result = await runProtocolWith({
    session_guard: guard,
    baseline_material: 'Keep fixture outputs isolated.',
    candidate_material: 'Repair the isolated lookup.',
    evidence_material: 'The isolated lookup failed.',
    emit: (type, fields = {}) => {
      if (type === 'failure' && failTerminal) {
        failTerminal = false;
        throw new Error('terminal emitter unavailable');
      }
      events.push({ type, ...fields });
    },
    openChallenger: async () => {
      throw new Error('challenger unavailable');
    },
  });

  assert.equal(result.failure.code, 'EMIT_FAILURE');
  assert.equal(events.filter((event) => event.type === 'failure').length, 1);
  assert.doesNotThrow(() => validateExecution(guardedExecution(events)));
});

test('Given bounded MORE_EVIDENCE payload violations, when the protocol normalizes a verdict, then it rejects empty or extra fields and payloads on other verdicts', async () => {
  for (const verdict of [
    { ...validMoreEvidenceVerdict(), more_evidence: { ...validMoreEvidenceVerdict().more_evidence, completion_signal: ' ' } },
    { ...validMoreEvidenceVerdict(), more_evidence: { ...validMoreEvidenceVerdict().more_evidence, extra: 'expands scope' } },
    { ...validVerdict(), more_evidence: validMoreEvidenceVerdict().more_evidence },
  ]) {
    await assert.rejects(() => runProtocolWith({ verdict }), /more_evidence/);
  }
});

test('Given empty or duplicate successful-path evidence, when the protocol normalizes it, then it rejects the transcript', async () => {
  for (const field of ['source_ids', 'invariants', 'alternative_hypotheses', 'falsification_conditions']) {
    await assert.rejects(
      () => runProtocolWith({ reconstruction: { ...validReconstruction(), [field]: [] } }),
      new RegExp(`reconstruction\\.${field}`),
    );
  }
  await assert.rejects(
    () => runProtocolWith({ reconstruction: { ...validReconstruction(), source_ids: ['intent', 'intent'] } }),
    /duplicate source IDs/,
  );
  await assert.rejects(
    () => runProtocolWith({ verdict: { ...validVerdict(), evidence_source_ids: [] } }),
    /verdict\.evidence_source_ids/,
  );
  await assert.rejects(
    () => runProtocolWith({ verdict: { ...validVerdict(), evidence_source_ids: ['intent', 'intent'] } }),
    /duplicate evidence source IDs/,
  );
});

test('Given a completed reconstruction, when round two changes its precedence or cites omitted evidence, then the protocol rejects it', async () => {
  await assert.rejects(
    () => runProtocolWith({
      reconstruction: { ...validReconstruction(), source_precedence: 'unresolved' },
      verdict: { ...validVerdict(), source_precedence: 'resolved', value: 'KEEP_COURSE' },
    }),
    /must match reconstruction source precedence/,
  );
  await assert.rejects(
    () => runProtocolWith({
      verdict: { ...validMoreEvidenceVerdict(), source_precedence: 'unresolved' },
    }),
    /must match reconstruction source precedence/,
  );
  await assert.rejects(
    () => runProtocolWith({
      authoritative_sources: [
        { id: 'intent', content: 'Keep the baseline.' },
        { id: 'additional-source', content: 'This source is not reconstructed.' },
      ],
      verdict: { ...validVerdict(), evidence_source_ids: ['intent', 'additional-source'] },
    }),
    /must be a subset of reconstruction.source_ids/,
  );
});

test('Given a candidate phrase in caller-controlled round-one fields, when the protocol starts, then it rejects before opening a challenger', async () => {
  for (const fields of [
    { problem_evidence: 'Evidence says REPAIR THE IMPLEMENTATION. now.' },
    { constraints: ['First repair the implementation. before continuing.'] },
    { non_goals: ['Do not repair the implementation. in this path.'] },
  ]) {
    let openCalls = 0;
    await assert.rejects(
      () => runProtocolWith({ candidate: ' Repair the implementation. ', onOpen: () => { openCalls += 1; }, ...fields }),
      /round-one field/,
    );
    assert.equal(openCalls, 0);
  }
});

test('Given ASCII token and phrase boundaries, when round-one fields are checked, then only standalone candidates are withheld', async () => {
  for (const fields of [
    { problem_evidence: 'The fixture has a prefix and suffix.' },
    { constraints: ['Keep the fixture prefix and suffix unchanged.'] },
    { non_goals: ['Do not alter the fixture prefix or suffix.'] },
  ]) {
    await assert.doesNotReject(() => runProtocolWith({ candidate: 'fix', ...fields }));
  }

  let openCalls = 0;
  await assert.rejects(
    () => runProtocolWith({
      candidate: 'fix',
      problem_evidence: 'Apply the FIX before continuing.',
      onOpen: () => { openCalls += 1; },
    }),
    /round-one field/,
  );
  assert.equal(openCalls, 0);
});

test('Given the candidate phrase only in authoritative source content, when the protocol starts, then it preserves the evidence and opens the challenger', async () => {
  let openCalls = 0;
  await assert.doesNotReject(() => runProtocolWith({
    candidate: 'Repair the implementation.',
    authoritative_sources: [{ id: 'intent', content: 'The user previously said: Repair the implementation.' }],
    onOpen: () => { openCalls += 1; },
  }));
  assert.equal(openCalls, 1);
});

test('Given evidence reveal order, when round one is built, then it orders every source and rejects invalid orders', () => {
  const context = {
    authoritative_sources: [
      { id: 'first', content: 'First source.' },
      { id: 'second', content: 'Second source.' },
    ],
    problem_evidence: 'A local failure needs review.',
    constraints: [],
    non_goals: [],
    evidence_reveal_order: ['second', 'first'],
  };
  const prompt = buildReconstructionPrompt(context);
  assert.ok(prompt.indexOf('Source second:') < prompt.indexOf('Source first:'));
  assert.match(prompt, /recency and clarity resolve intent only when they form one unique evidence-backed ordering/);

  for (const order of [['first'], ['first', 'first'], ['first', 'unknown']]) {
    assert.throws(() => buildReconstructionPrompt({ ...context, evidence_reveal_order: order }), /evidence_reveal_order/);
  }
});

test('Given the candidate former identity equals the challenger, when the protocol starts, then it rejects before either prompt', async () => {
  let openCalls = 0;
  await assert.rejects(
    () => runProtocolWith({
      candidate_former_agent_id: 'same-agent',
      agent_id: 'same-agent',
      onOpen: () => { openCalls += 1; },
    }),
    /must differ from candidate_former_agent_id/,
  );
  assert.equal(openCalls, 1);
});
