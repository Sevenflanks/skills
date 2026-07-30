import { ENVIRONMENT_SCHEMA_VERSION } from './constants.mjs';
import {
  assertArray,
  assertBoolean,
  assertExactKeys,
  assertNonNegativeInteger,
  assertObject,
  assertString,
  fail,
} from './validation.mjs';

function assertFiniteNumber(value, path, minimum, maximum = Number.POSITIVE_INFINITY) {
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    fail(path, `must be a number between ${minimum} and ${maximum}`);
  }
}

function validateCatalog(catalog) {
  assertArray(catalog, 'benchmark environment.skill_catalog');
  if (catalog.length === 0) {
    fail('benchmark environment.skill_catalog', 'must not be empty');
  }
  const names = new Set();
  for (const [index, entry] of catalog.entries()) {
    const path = `benchmark environment.skill_catalog[${index}]`;
    assertObject(entry, path);
    assertExactKeys(entry, ['name', 'version'], path);
    assertString(entry.name, `${path}.name`);
    assertString(entry.version, `${path}.version`);
    if (names.has(entry.name)) {
      fail('benchmark environment.skill_catalog', `must not repeat ${entry.name}`);
    }
    names.add(entry.name);
  }
}

function validateTools(tools) {
  assertArray(tools, 'benchmark environment.tool_availability');
  if (tools.length === 0) {
    fail('benchmark environment.tool_availability', 'must not be empty');
  }
  const names = new Set();
  for (const [index, tool] of tools.entries()) {
    const path = `benchmark environment.tool_availability[${index}]`;
    assertObject(tool, path);
    assertExactKeys(tool, ['available', 'name'], path);
    assertString(tool.name, `${path}.name`);
    assertBoolean(tool.available, `${path}.available`);
    if (names.has(tool.name)) {
      fail('benchmark environment.tool_availability', `must not repeat ${tool.name}`);
    }
    names.add(tool.name);
  }
}

export function validateEnvironment(environment) {
  assertObject(environment, 'benchmark environment');
  assertExactKeys(
    environment,
    ['model', 'runtime', 'sampling_settings', 'schema_version', 'skill_catalog', 'tool_availability'],
    'benchmark environment',
  );
  if (environment.schema_version !== ENVIRONMENT_SCHEMA_VERSION) {
    fail('benchmark environment.schema_version', `must equal ${ENVIRONMENT_SCHEMA_VERSION}`);
  }
  assertString(environment.model, 'benchmark environment.model');
  assertObject(environment.runtime, 'benchmark environment.runtime');
  assertExactKeys(environment.runtime, ['name', 'version'], 'benchmark environment.runtime');
  assertString(environment.runtime.name, 'benchmark environment.runtime.name');
  assertString(environment.runtime.version, 'benchmark environment.runtime.version');
  validateCatalog(environment.skill_catalog);
  assertObject(environment.sampling_settings, 'benchmark environment.sampling_settings');
  assertExactKeys(environment.sampling_settings, ['seed', 'temperature', 'top_p'], 'benchmark environment.sampling_settings');
  assertNonNegativeInteger(environment.sampling_settings.seed, 'benchmark environment.sampling_settings.seed');
  assertFiniteNumber(environment.sampling_settings.temperature, 'benchmark environment.sampling_settings.temperature', 0);
  assertFiniteNumber(environment.sampling_settings.top_p, 'benchmark environment.sampling_settings.top_p', 0, 1);
  validateTools(environment.tool_availability);
  return environment;
}
