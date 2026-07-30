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
    emit: () => {},
    openChallenger: async () => {
      onOpen?.();
      return {
        agent_id,
        read_only_assurance: 'observed-no-write',
        ask: async () => (promptCount++ === 0 ? reconstruction : verdict),
      };
    },
  });
}

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
      verdict: { ...validVerdict(), evidence_sufficient: false, source_precedence: 'unresolved', value: 'MORE_EVIDENCE' },
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
