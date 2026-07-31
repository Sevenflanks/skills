import { readFile } from 'node:fs/promises';

import { ContractError, validateEnvironment } from './contracts.mjs';

export async function loadBenchmarkEnvironment(filePath) {
  let environment;
  try {
    environment = JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    throw new ContractError(`Unable to read benchmark environment ${filePath}: ${error.message}`);
  }
  return validateEnvironment(environment);
}
