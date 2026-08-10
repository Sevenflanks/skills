import assert from 'node:assert/strict';
import test from 'node:test';

import {
  TRACKED_PATH_BUDGET,
  acquireTrackedPaths,
  assessTrackedPathBudget,
  formatTrackedPathBudgetFailure,
  formatTrackedPathBudgetSuccess,
  parseGitLsFilesOutput,
} from '../scripts/check-tracked-path-budget.mjs';

test('Given a tracked path at the 185-character boundary, when assessed, then it passes', () => {
  const boundaryPath = 'a'.repeat(185);

  const result = assessTrackedPathBudget([boundaryPath]);

  assert.equal(TRACKED_PATH_BUDGET, 185);
  assert.deepEqual(result, {
    maxLength: 185,
    maxPath: boundaryPath,
    offenders: [],
  });
  assert.equal(
    formatTrackedPathBudgetSuccess(result),
    `Tracked path budget passed: maximum observed length is 185/${TRACKED_PATH_BUDGET} characters: ${JSON.stringify(boundaryPath)}.`,
  );
});

test('Given a tracked path of 186 characters, when assessed, then it is an offender', () => {
  const overBudgetPath = 'b'.repeat(186);

  const result = assessTrackedPathBudget([overBudgetPath]);

  assert.deepEqual(result.offenders, [{ length: 186, path: overBudgetPath }]);
  assert.equal(
    formatTrackedPathBudgetFailure(result),
    `Tracked path budget failed: 1 path exceeds ${TRACKED_PATH_BUDGET} characters.\n- 186 characters: ${JSON.stringify(overBudgetPath)}`,
  );
});

test('Given multiple over-budget paths, when assessed, then the report orders longest paths first and ties by path', () => {
  const shorterLater = 'z'.repeat(186);
  const longest = 'm'.repeat(187);
  const shorterEarlier = 'a'.repeat(186);

  const result = assessTrackedPathBudget([shorterLater, longest, shorterEarlier]);

  assert.deepEqual(result.offenders, [
    { length: 187, path: longest },
    { length: 186, path: shorterEarlier },
    { length: 186, path: shorterLater },
  ]);
  assert.equal(
    formatTrackedPathBudgetFailure(result),
    [
      `Tracked path budget failed: 3 paths exceed ${TRACKED_PATH_BUDGET} characters.`,
      `- 187 characters: ${JSON.stringify(longest)}`,
      `- 186 characters: ${JSON.stringify(shorterEarlier)}`,
      `- 186 characters: ${JSON.stringify(shorterLater)}`,
    ].join('\n'),
  );
});

test('Given NUL-delimited Git output, when paths are acquired, then every repository-relative path is preserved', () => {
  const output = 'plain.txt\0directory/with spaces/file.txt\0nested/file.txt\0';
  const calls = [];

  assert.deepEqual(parseGitLsFilesOutput(output), [
    'plain.txt',
    'directory/with spaces/file.txt',
    'nested/file.txt',
  ]);
  assert.deepEqual(
    acquireTrackedPaths((command, argumentsList, options) => {
      calls.push({ command, argumentsList, options });
      return output;
    }),
    ['plain.txt', 'directory/with spaces/file.txt', 'nested/file.txt'],
  );
  assert.deepEqual(calls, [{
    command: 'git',
    argumentsList: ['ls-files', '-z'],
    options: { encoding: 'utf8' },
  }]);
});
