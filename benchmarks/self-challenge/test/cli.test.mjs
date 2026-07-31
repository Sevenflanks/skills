import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..', '..');
const runCommand = path.join(repositoryRoot, 'benchmarks', 'self-challenge', 'bin', 'run.mjs');
const scoreCommand = path.join(repositoryRoot, 'benchmarks', 'self-challenge', 'bin', 'score.mjs');
const environmentPath = path.join(repositoryRoot, 'benchmarks', 'self-challenge', 'fixtures', 'deterministic-environment.json');

test('Given deterministic fixtures, when the run and score CLIs execute, then they write valid artifacts', async () => {
  const outputDirectory = await mkdtemp(path.join(os.tmpdir(), 'self-challenge-cli-'));
  const runResult = await execFile(
    process.execPath,
    [runCommand, '--configuration', 'full-two-stage', '--trials', '2', '--environment', environmentPath, '--output', outputDirectory],
    { cwd: repositoryRoot },
  );
  const runOutput = JSON.parse(runResult.stdout);
  const report = JSON.parse(await readFile(runOutput.artifact_path, 'utf8'));
  assert.equal(report.runs.length, 12);
  assert.deepEqual(report.environment, JSON.parse(await readFile(environmentPath, 'utf8')));

  const scoreResult = await execFile(
    process.execPath,
    [scoreCommand, '--input', runOutput.artifact_path, '--output', outputDirectory],
    { cwd: repositoryRoot },
  );
  const scoreOutput = JSON.parse(scoreResult.stdout);
  const score = JSON.parse(await readFile(scoreOutput.artifact_path, 'utf8'));
  assert.equal(score.summary.overall.total, 12);
  assert.equal(score.summary.outcome.passed, 12);
});
