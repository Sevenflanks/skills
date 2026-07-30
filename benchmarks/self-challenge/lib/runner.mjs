import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

import {
  ADAPTER_REQUEST_SCHEMA_VERSION,
  CONFIGURATIONS,
  ContractError,
  RUN_REPORT_SCHEMA_VERSION,
  validateAdapterRequest,
  validateCorpus,
  validateExecution,
  validateEnvironment,
  validateHeldOutManifest,
  validateHeldOutScenarioCorpus,
  validateRunReport,
  validateScenario,
} from './contracts.mjs';

async function readJson(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    throw new ContractError(`Unable to read JSON ${filePath}: ${error.message}`);
  }
}

function actionEvents(events) {
  return events.filter((event) => event.type === 'agent_action');
}

function buildAcceptance(scenario, execution) {
  const actions = actionEvents(execution.events);
  const observations = [];
  for (const actionId of scenario.acceptance_oracle.required_action_ids) {
    const evidence = actions.filter((event) => event.action_id === actionId).map((event) => event.id);
    observations.push({
      id: `required-action:${actionId}`,
      passed: evidence.length > 0,
      evidence_event_ids: evidence,
    });
  }
  for (const actionId of scenario.acceptance_oracle.forbidden_action_ids) {
    const evidence = actions.filter((event) => event.action_id === actionId).map((event) => event.id);
    observations.push({
      id: `forbidden-action:${actionId}`,
      passed: evidence.length === 0,
      evidence_event_ids: evidence,
    });
  }
  return {
    owner: 'benchmark-harness',
    passed: observations.every((observation) => observation.passed),
    observations,
  };
}

function runId({ benchmarkVersion, configuration, scenario, trial }) {
  return `${benchmarkVersion}:${configuration}:${scenario.id}:${trial}`;
}

function adjudicationFor(scenario) {
  return {
    allowed_next_actions: [...scenario.allowed_next_actions],
    baseline_validity: scenario.baseline_validity,
    correct_disposition: scenario.correct_disposition,
    earliest_prohibited_direction_changing_edit: scenario.earliest_prohibited_direction_changing_edit,
    reflection_expectations: { ...scenario.reflection_expectations },
    source_ids: scenario.authoritative_sources.map((source) => source.id),
  };
}

function failedRun({ benchmarkVersion, configuration, scenario, trial, error }) {
  const failureCode = error instanceof ContractError
    ? 'ADAPTER_CONTRACT_VIOLATION'
    : ['AMBIGUOUS_ACTION', 'UNMAPPABLE_ACTION', 'UNKNOWN_ACTION', 'OPENCODE_EXIT_FAILURE', 'OPENCODE_EXPORT_FAILURE', 'UNSCORABLE_EVIDENCE'].includes(error?.code)
      ? error.code
      : 'ADAPTER_FAILURE';
  return {
    run_id: runId({ benchmarkVersion, configuration, scenario, trial }),
    scenario_id: scenario.id,
    category: scenario.category,
    family_id: scenario.family_id,
    adjudication: adjudicationFor(scenario),
    configuration,
    trial,
    status: 'failed',
    transcript: null,
    harness_acceptance: null,
    failure: {
      code: failureCode,
      message: error instanceof Error ? error.message : String(error),
    },
  };
}

function deriveDirectionChangingActions(scenario, execution) {
  const knownActions = new Set([...scenario.allowed_next_actions, scenario.earliest_prohibited_direction_changing_edit]);
  return {
    ...execution,
    events: execution.events.map((event) => {
      if (event.type !== 'agent_action') {
        return { ...event };
      }
      if (!knownActions.has(event.action_id)) {
        const error = new Error(`Unknown action ${event.action_id} for scenario ${scenario.id}`);
        error.code = 'UNKNOWN_ACTION';
        throw error;
      }
      return {
        ...event,
        direction_changing: event.action_id === scenario.earliest_prohibited_direction_changing_edit,
      };
    }),
  };
}

export async function loadTrainingScenarios(directory) {
  let fileNames;
  try {
    fileNames = await readdir(directory);
  } catch (error) {
    throw new ContractError(`Unable to read training scenarios from ${directory}: ${error.message}`);
  }
  const jsonFiles = fileNames.filter((fileName) => fileName.endsWith('.json')).sort();
  if (jsonFiles.length === 0) {
    throw new ContractError(`No training scenario JSON files found in ${directory}`);
  }
  const scenarios = await Promise.all(jsonFiles.map((fileName) => readJson(path.join(directory, fileName))));
  for (const scenario of scenarios) {
    validateScenario(scenario);
    if (scenario.partition !== 'training') {
      throw new ContractError(`Training scenario ${scenario.id} must use the training partition`);
    }
  }
  return scenarios.sort((left, right) => left.id.localeCompare(right.id));
}

export async function loadPrivateHeldOutScenarios({ directory, manifest }) {
  validateHeldOutManifest(manifest);
  const manifestById = new Map(manifest.entries.map((entry) => [entry.id, entry]));
  const scenarios = await loadScenarioFiles(directory);
  for (const scenario of scenarios) {
    const entry = manifestById.get(scenario.id);
    if (!entry) {
      throw new ContractError(`Private scenario ${scenario.id} is not listed in the held-out manifest`);
    }
    if (scenario.partition !== 'true-held-out') {
      throw new ContractError(`Private scenario ${scenario.id} must use the true-held-out partition`);
    }
    if (scenario.family_id !== entry.family_id || scenario.category !== entry.category) {
      throw new ContractError(`Private scenario ${scenario.id} does not match its held-out manifest entry`);
    }
    const digest = createHash('sha256').update(JSON.stringify(scenario)).digest('hex');
    if (digest !== entry.sha256) {
      throw new ContractError(`Private scenario ${scenario.id} SHA-256 digest does not match its manifest`);
    }
  }
  if (scenarios.length !== manifest.entries.length) {
    throw new ContractError('Private held-out directory must contain every manifest entry exactly once');
  }
  validateHeldOutScenarioCorpus(scenarios);
  return scenarios;
}

async function loadScenarioFiles(directory) {
  const fileNames = (await readdir(directory)).filter((fileName) => fileName.endsWith('.json')).sort();
  const scenarios = await Promise.all(fileNames.map((fileName) => readJson(path.join(directory, fileName))));
  for (const scenario of scenarios) {
    validateScenario(scenario);
  }
  return scenarios;
}

export function sanitizeAdapterRequest(scenario, configuration, trial) {
  validateScenario(scenario);
  const request = {
    schema_version: ADAPTER_REQUEST_SCHEMA_VERSION,
    configuration,
    trial,
    scenario: {
      id: scenario.id,
      prompt: scenario.prompt,
      authoritative_sources: scenario.authoritative_sources.map((source) => ({ ...source })),
      evidence_reveal_order: [...scenario.evidence_reveal_order],
    },
  };
  validateAdapterRequest(request);
  return request;
}

export function createHarnessRun({ scenario, configuration, trial, benchmarkVersion, execution }) {
  validateScenario(scenario);
  validateExecution(execution);
  const normalizedExecution = deriveDirectionChangingActions(scenario, execution);
  validateExecution(normalizedExecution);
  return {
    run_id: runId({ benchmarkVersion, configuration, scenario, trial }),
    scenario_id: scenario.id,
    category: scenario.category,
    family_id: scenario.family_id,
    adjudication: adjudicationFor(scenario),
    configuration,
    trial,
    status: 'completed',
    transcript: normalizedExecution,
    harness_acceptance: buildAcceptance(scenario, normalizedExecution),
    failure: null,
  };
}

export async function runBenchmark({ scenarios, adapter, configurations = CONFIGURATIONS, trials, benchmarkVersion, environment }) {
  if (!Array.isArray(scenarios) || scenarios.length === 0) {
    throw new ContractError('runBenchmark requires at least one scenario');
  }
  if (typeof adapter !== 'function') {
    throw new ContractError('runBenchmark requires an adapter function');
  }
  if (!Number.isInteger(trials) || trials < 1) {
    throw new ContractError('runBenchmark trials must be a positive integer');
  }
  if (typeof benchmarkVersion !== 'string' || benchmarkVersion.trim() === '') {
    throw new ContractError('runBenchmark benchmarkVersion must be a non-empty string');
  }
  validateEnvironment(environment);
  for (const configuration of configurations) {
    if (!CONFIGURATIONS.includes(configuration)) {
      throw new ContractError(`Unsupported configuration ${configuration}`);
    }
  }

  const runs = [];
  for (const scenario of [...scenarios].sort((left, right) => left.id.localeCompare(right.id))) {
    validateScenario(scenario);
    for (const configuration of [...configurations].sort()) {
      for (let trial = 1; trial <= trials; trial += 1) {
        try {
          const execution = await adapter(sanitizeAdapterRequest(scenario, configuration, trial));
          runs.push(createHarnessRun({ scenario, configuration, trial, benchmarkVersion, execution }));
        } catch (error) {
          runs.push(failedRun({ benchmarkVersion, configuration, scenario, trial, error }));
        }
      }
    }
  }
  const report = {
    schema_version: RUN_REPORT_SCHEMA_VERSION,
    benchmark_version: benchmarkVersion,
    environment,
    runs: runs.sort((left, right) => left.run_id.localeCompare(right.run_id)),
  };
  validateRunReport(report);
  return report;
}

export async function writeRunArtifact(report, outputDirectory) {
  validateRunReport(report);
  await mkdir(outputDirectory, { recursive: true });
  const outputPath = path.join(outputDirectory, 'run-report.json');
  await writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return outputPath;
}

export function validateBenchmarkCorpus({ scenarios, manifest }) {
  return validateCorpus(scenarios, manifest);
}

export { loadBenchmarkEnvironment } from './environment.mjs';
