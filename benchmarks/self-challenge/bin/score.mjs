#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { scoreReport, writeScoreArtifact } from '../lib/scorer.mjs';

const COST_DIMENSIONS = new Set(['tokens', 'turns', 'tool_calls', 'elapsed_ms', 'stage_two_invocations']);

function usage() {
  return `Usage: node benchmarks/self-challenge/bin/score.mjs --input <run-report.json> [options]

Options:
  --input <file>                  Run report to score
  --output <directory>            Artifact directory (default: input directory)
  --cost-limit <dimension=value>  Repeatable optional limits; absent dimensions are unbounded
  --help                          Show this help
`;
}

function nextValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function parseCostLimit(value) {
  const [dimension, rawLimit, extra] = value.split('=');
  const limit = Number(rawLimit);
  if (extra !== undefined || !COST_DIMENSIONS.has(dimension) || !Number.isFinite(limit) || limit < 0) {
    throw new Error('--cost-limit must be a non-negative dimension=value pair');
  }
  return [dimension, limit];
}

function parseArguments(argv) {
  const options = { input: null, output: null, costLimits: {} };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--help') {
      return { help: true };
    }
    if (option === '--input') {
      options.input = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--output') {
      options.output = path.resolve(process.cwd(), nextValue(argv, index, option));
      index += 1;
    } else if (option === '--cost-limit') {
      const [dimension, limit] = parseCostLimit(nextValue(argv, index, option));
      options.costLimits[dimension] = limit;
      index += 1;
    } else {
      throw new Error(`Unknown option ${option}`);
    }
  }
  if (!options.input) {
    throw new Error('--input is required');
  }
  options.output ??= path.dirname(options.input);
  return options;
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const report = JSON.parse(await readFile(options.input, 'utf8'));
  const score = scoreReport(report, { costLimits: options.costLimits });
  const artifactPath = await writeScoreArtifact(score, options.output);
  process.stdout.write(`${JSON.stringify({ artifact_path: artifactPath, overall: score.summary.overall })}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
