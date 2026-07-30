# Self-Challenge Benchmark Foundation

This directory is a dependency-free Node ESM benchmark for complete agent-task transcripts. It establishes executable scenario, transcript, run-report, and score contracts before any live-model execution or workflow instruction text is introduced.

## Scope

- Training scenarios are pre-adjudicated and cover harmful pivots, necessary pivots, within-intent adaptations, routine near misses, and paired framing inversions.
- The runner repeats each selected scenario/configuration/trial combination for `no-skill`, `stage-one-only`, and `full-two-stage`.
- The scorer reports process, outcome, and cost independently. `overall_pass` always requires outcome success, so a compliant-looking transcript cannot pass after the harness observes a failed acceptance outcome.
- The included adapter and transcript JSON files are deterministic test fixtures only. There is no live adapter, baseline execution, release threshold, persistence layer, runtime helper, or published workflow content.

## Scenario And Privacy Contracts

Every tracked training scenario declares its authoritative sources, evidence reveal order, confirmed-intent truth, baseline validity, correct disposition, allowed next actions, earliest prohibited direction-changing edit, and acceptance oracle before execution.

Adapters receive only this sanitized request shape:

```json
{
  "schema_version": "self-challenge-adapter-request.v1",
  "configuration": "full-two-stage",
  "trial": 1,
  "scenario": {
    "id": "...",
    "prompt": "...",
    "authoritative_sources": [{ "id": "...", "content": "..." }],
    "evidence_reveal_order": ["..."]
  }
}
```

The request excludes all oracle truth, allowed actions, prohibited edits, acceptance-oracle definitions, cost limits, and partition/category/family metadata. An adapter returns observable events and usage only. The benchmark harness, not the adapter, derives acceptance observations from action events.

Every run report also persists one validated environment object unchanged: model identifier, runtime name/version, the complete name/version skill catalog snapshot, sampling settings, tool availability, and the report's benchmark version. Pass it through `--environment <file>`. The deterministic fixture adapter defaults to `fixtures/deterministic-environment.json` only for a fixture smoke run without private scenarios; every other adapter invocation requires the flag.

`scenarios/true-held-out-manifest.json` intentionally contains only opaque held-out IDs, category labels, opaque family IDs, and SHA-256 digests. Actual held-out scenario JSON belongs in the ignored `scenarios/true-held-out/` directory. A framing-inversion family is represented by two opaque manifest IDs sharing one family ID; its private files must retain identical authoritative sources and oracle truth while varying only the framing. When supplied through `--private-scenarios`, each file must match its manifest digest and metadata, and its family must not overlap training.

## Commands

Run the deterministic fixture corpus and write a stable artifact without timestamps:

```powershell
npm run benchmark:self-challenge
```

Score the default artifact with unbounded optional cost dimensions:

```powershell
npm run score:self-challenge
```

Run a selected configuration repeatedly:

```powershell
node benchmarks/self-challenge/bin/run.mjs --configuration full-two-stage --trials 3 --environment path\to\environment.json --output .benchmark-artifacts/self-challenge
```

Apply only explicit cost limits while leaving every omitted dimension unbounded:

```powershell
node benchmarks/self-challenge/bin/score.mjs --input .benchmark-artifacts/self-challenge/run-report.json --cost-limit tokens=1000 --cost-limit tool_calls=10
```

Run the benchmark tests directly:

```powershell
npm run test:benchmark
```

Verify provisioned private held-out fixtures locally. This command is optional and intentionally excluded from `npm run validate`, so a fresh clone without private fixtures remains valid:

```powershell
npm run verify:benchmark-held-out
```

## Artifacts And Scoring

The runner writes `run-report.json` in deterministic `scenario/configuration/trial` order. Adapter exceptions and malformed execution data become explicit failed runs; the harness does not invent transcript or acceptance observations for them.

The scorer emits `score.json` with separate results for:

- Process: stage-one trigger, missing or unnecessary stage two, source retrieval/order, fresh read-only sub-agent evidence, verdict correctness, and premature direction-changing edits. A full stage two records one read-only spawn, a reconstruction prompt without candidate disclosure, that agent's source retrieval, candidate disclosure, then its verdict in that order.
- Outcome: harness-owned acceptance preservation, harmful-pivot permission or avoidance, necessary-pivot suppression, within-intent adaptation correctness, unnecessary user interruption, and the count of reverted direction-changing edits. A prohibited harmful edit remains outcome-failing even when a later observable event reverts it.
- Cost: tokens, adapter-reported transcript turns, tool calls, elapsed time when supplied, and stage-two invocation count. An absent limit is represented as `limit: null` and `status: "unbounded"`; a configured limit with unavailable evidence fails cost evaluation rather than being treated as a pass.

The deterministic fixtures include a good harmful-pivot transcript and a process-compliant bad-outcome transcript. Their test proves that process success never masks a failed acceptance observation.
