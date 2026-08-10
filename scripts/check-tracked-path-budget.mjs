import { execFileSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const TRACKED_PATH_BUDGET = 185;

export function parseGitLsFilesOutput(output) {
  return String(output)
    .split('\0')
    .filter((repositoryPath) => repositoryPath.length > 0);
}

export function acquireTrackedPaths(runCommand = execFileSync) {
  return parseGitLsFilesOutput(runCommand('git', ['ls-files', '-z'], { encoding: 'utf8' }));
}

function comparePaths(left, right) {
  if (left < right) {
    return -1;
  }
  if (left > right) {
    return 1;
  }
  return 0;
}

export function assessTrackedPathBudget(paths) {
  let maxLength = 0;
  let maxPath = null;
  const offenders = [];

  for (const repositoryPath of paths) {
    const length = repositoryPath.length;
    if (length > maxLength || (length === maxLength && (maxPath === null || comparePaths(repositoryPath, maxPath) < 0))) {
      maxLength = length;
      maxPath = repositoryPath;
    }
    if (length > TRACKED_PATH_BUDGET) {
      offenders.push({ length, path: repositoryPath });
    }
  }

  offenders.sort((left, right) => right.length - left.length || comparePaths(left.path, right.path));

  return { maxLength, maxPath, offenders };
}

export function formatTrackedPathBudgetFailure(result) {
  const pathLabel = result.offenders.length === 1 ? 'path exceeds' : 'paths exceed';
  const lines = [
    `Tracked path budget failed: ${result.offenders.length} ${pathLabel} ${TRACKED_PATH_BUDGET} characters.`,
  ];

  for (const offender of result.offenders) {
    lines.push(`- ${offender.length} characters: ${JSON.stringify(offender.path)}`);
  }

  return lines.join('\n');
}

export function formatTrackedPathBudgetSuccess(result) {
  if (result.maxPath === null) {
    return 'Tracked path budget passed: no tracked paths found.';
  }

  return `Tracked path budget passed: maximum observed length is ${result.maxLength}/${TRACKED_PATH_BUDGET} characters: ${JSON.stringify(result.maxPath)}.`;
}

export function main(runCommand = execFileSync, logger = console) {
  const result = assessTrackedPathBudget(acquireTrackedPaths(runCommand));
  if (result.offenders.length > 0) {
    logger.error(formatTrackedPathBudgetFailure(result));
    return 1;
  }

  logger.log(formatTrackedPathBudgetSuccess(result));
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}
