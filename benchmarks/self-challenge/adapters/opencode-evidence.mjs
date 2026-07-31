export class OpenCodeAdapterError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.name = 'OpenCodeAdapterError';
  }
}

function parseDocuments(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') {
    return [];
  }
  try {
    return [JSON.parse(raw)];
  } catch {
    return raw.split(/\r?\n/).filter(Boolean).map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', 'OpenCode emitted non-JSON evidence');
      }
    });
  }
}

function tokenPair(value) {
  if (!value || typeof value !== 'object') {
    return null;
  }
  const input = value.input ?? value.input_tokens ?? value.inputTokens;
  const output = value.output ?? value.output_tokens ?? value.outputTokens;
  return Number.isInteger(input) && input >= 0 && Number.isInteger(output) && output >= 0
    ? `${input}:${output}`
    : null;
}

function emptyEvidence() {
  return {
    assistantMessageIds: new Set(), costs: new Set(), sessionIds: new Set(), stepIds: new Set(), texts: [], tokenPairs: new Set(), toolNames: new Set(), turns: new Set(),
  };
}

function usageFrom(evidence) {
  const pair = oneValue(evidence.tokenPairs, 'UNSCORABLE_EVIDENCE', 'token');
  const [inputTokens, outputTokens] = pair.split(':').map(Number);
  const runtimeTurns = oneValue(evidence.turns, 'UNSCORABLE_EVIDENCE', 'turn', true);
  const turns = runtimeTurns ?? (evidence.stepIds.size || evidence.assistantMessageIds.size || evidence.texts.length);
  if (!Number.isInteger(turns) || turns < 1) {
    throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', 'turn evidence is missing');
  }
  const toolNames = [...evidence.toolNames].sort();
  return {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    turns,
    tool_calls: toolNames.length,
    elapsed_ms: null,
    runtime_reported_cost: oneValue(evidence.costs, 'UNSCORABLE_EVIDENCE', 'runtime cost', true),
    tool_names: toolNames,
  };
}

function observe(value, evidence) {
  if (Array.isArray(value)) {
    for (const item of value) {
      observe(item, evidence);
    }
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  for (const key of ['sessionID', 'sessionId', 'session_id']) {
    if (typeof value[key] === 'string') {
      evidence.sessionIds.add(value[key]);
    }
  }
  if (value.type === 'text' && typeof value.text === 'string') {
    evidence.texts.push(value.text);
  }
  if (value.role === 'assistant' || value.info?.role === 'assistant') {
    const id = value.id ?? value.info?.id;
    if (typeof id === 'string') {
      evidence.assistantMessageIds.add(id);
    }
  }
  if (value.type === 'step_finish' || value.type === 'step-finish') {
    const id = value.id ?? value.part?.id;
    if (typeof id === 'string') {
      evidence.stepIds.add(id);
    }
  }
  const pair = tokenPair(value.tokens);
  if (pair !== null) {
    evidence.tokenPairs.add(pair);
  }
  if (Number.isInteger(value.turns) && value.turns >= 0) {
    evidence.turns.add(value.turns);
  }
  if (Number.isFinite(value.cost) && value.cost >= 0) {
    evidence.costs.add(value.cost);
  }
  if (typeof value.type === 'string' && (value.type === 'tool' || value.type === 'tool_use' || value.type === 'tool_call')) {
    const name = value.tool ?? value.name;
    if (typeof name === 'string') {
      evidence.toolNames.add(name);
    }
  }
  for (const child of Object.values(value)) {
    observe(child, evidence);
  }
}

function oneValue(values, code, label, allowAbsent = false) {
  if (values.size === 0 && allowAbsent) {
    return null;
  }
  if (values.size !== 1) {
    throw new OpenCodeAdapterError(code, `${label} evidence is ${values.size === 0 ? 'missing' : 'conflicting'}`);
  }
  return [...values][0];
}

export function parseFrozenOption(decisionText) {
  const options = [...decisionText.matchAll(/FIRST_DECISION\s*:\s*(OPTION_[A-Z0-9_]+)/g)].map((match) => match[1]);
  const uniqueOptions = new Set(options);
  if (uniqueOptions.size > 1) {
    throw new OpenCodeAdapterError('AMBIGUOUS_ACTION', 'The first model response contains conflicting action choices');
  }
  if (uniqueOptions.size === 0) {
    throw new OpenCodeAdapterError('UNMAPPABLE_ACTION', 'The first model response does not contain an action choice');
  }
  return [...uniqueOptions][0];
}

function observeDocuments(rawEvidence) {
  const evidence = emptyEvidence();
  for (const raw of Array.isArray(rawEvidence) ? rawEvidence : [rawEvidence]) {
    for (const document of parseDocuments(raw)) {
      observe(document, evidence);
    }
  }
  return evidence;
}

export function parseOpenCodeEvidence(rawEvidence) {
  const evidence = observeDocuments(rawEvidence);
  return {
    decision: parseFrozenOption(evidence.texts.join('\n')),
    sessionId: oneValue(evidence.sessionIds, 'UNSCORABLE_EVIDENCE', 'session ID'),
    usage: usageFrom(evidence),
  };
}

function textParts(value, texts) {
  if (Array.isArray(value)) {
    for (const item of value) {
      textParts(item, texts);
    }
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  if (value.type === 'text' && typeof value.text === 'string') {
    texts.push(value.text);
  }
  for (const child of Object.values(value)) {
    textParts(child, texts);
  }
}

function assistantResponses(rawEvidence) {
  const responses = [];
  function collect(value) {
    if (Array.isArray(value)) {
      value.forEach(collect);
      return;
    }
    if (!value || typeof value !== 'object') {
      return;
    }
    if (value.role === 'assistant' || value.info?.role === 'assistant') {
      const texts = [];
      textParts(value, texts);
      responses.push(texts.join(''));
      return;
    }
    Object.values(value).forEach(collect);
  }
  for (const raw of Array.isArray(rawEvidence) ? rawEvidence : [rawEvidence]) {
    for (const document of parseDocuments(raw)) {
      collect(document);
    }
  }
  return responses;
}

export function parseStageOneEvidence({ runEvidence, exportEvidence }) {
  const runSessionId = sessionFrom(runEvidence);
  const exported = observeDocuments(exportEvidence);
  const exportSessionId = oneValue(exported.sessionIds, 'UNSCORABLE_EVIDENCE', 'export session ID');
  if (runSessionId !== exportSessionId) {
    throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', 'run and export session IDs differ');
  }
  const responses = assistantResponses(exportEvidence);
  if (responses.length !== 1) {
    throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', `exported assistant response count is ${responses.length}`);
  }
  const match = /^STAGE_ONE: (COMPLETED|SKIPPED)\r?\nFIRST_DECISION: (OPTION_A|OPTION_B)\r?\nUSER_INTERRUPTION: (YES|NO)$/.exec(responses[0]);
  if (!match) {
    throw new OpenCodeAdapterError('UNSCORABLE_EVIDENCE', 'exported assistant response does not match the stage-one grammar');
  }
  return {
    decision: match[2],
    sessionId: runSessionId,
    stageOne: match[1],
    userInterruption: match[3],
    usage: usageFrom(exported),
  };
}

export function normalizeOpenCodeRejection(error) {
  return {
    name: error instanceof Error ? error.name : 'UnknownError',
    message: error instanceof Error ? error.message : String(error),
    code: typeof error?.code === 'string' || Number.isInteger(error?.code) ? error.code : null,
    stdout: typeof error?.stdout === 'string' ? error.stdout : '',
    stderr: typeof error?.stderr === 'string' ? error.stderr : '',
    timed_out: typeof error?.timedOut === 'boolean' ? error.timedOut : null,
  };
}

export function sessionFrom(raw) {
  return oneValue(observeDocuments(raw).sessionIds, 'UNSCORABLE_EVIDENCE', 'session ID');
}
