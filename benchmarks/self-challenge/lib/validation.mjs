export class ContractError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ContractError';
  }
}

export function fail(path, message) {
  throw new ContractError(`${path} ${message}`);
}

export function assertObject(value, path) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(path, 'must be an object');
  }
}

export function assertString(value, path) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(path, 'must be a non-empty string');
  }
}

export function assertBoolean(value, path) {
  if (typeof value !== 'boolean') {
    fail(path, 'must be a boolean');
  }
}

export function assertArray(value, path) {
  if (!Array.isArray(value)) {
    fail(path, 'must be an array');
  }
}

export function assertPositiveInteger(value, path) {
  if (!Number.isInteger(value) || value < 1) {
    fail(path, 'must be a positive integer');
  }
}

export function assertNonNegativeInteger(value, path) {
  if (!Number.isInteger(value) || value < 0) {
    fail(path, 'must be a non-negative integer');
  }
}

export function assertEnum(value, allowed, path) {
  if (!allowed.includes(value)) {
    fail(path, `must be one of: ${allowed.join(', ')}`);
  }
}

export function assertUniqueStrings(values, path) {
  assertArray(values, path);
  if (values.length === 0) {
    fail(path, 'must not be empty');
  }
  const seen = new Set();
  for (const [index, value] of values.entries()) {
    assertString(value, `${path}[${index}]`);
    if (seen.has(value)) {
      fail(path, `must not contain duplicate value ${value}`);
    }
    seen.add(value);
  }
}

export function assertExactKeys(value, keys, path) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail(path, `must contain exactly: ${expected.join(', ')}`);
  }
}
