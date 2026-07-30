# Ticket 02: No-Skill Baseline Decision Report

**Decision status:** No release threshold can be selected. Ticket 02 has no completed, scorable no-skill model trial. The separately authorized v2 batch reached the fixed absolute executable and pure-mode preflight, then hung during its first model invocation without producing a run result, session ID, usage, or failure record. Per the no-retry and no-third-batch rules, execution stopped.

## Fixed Experiment Contract

- Benchmark version: `self-challenge-foundation-v1`.
- Intended corpus: 6 tracked training scenarios x 5 sequential fresh-session trials = 30 no-skill slots.
- Configuration: `no-skill` only. No stage-one-only, full-two-stage, private held-out scenario, continuation, resume, retry, `--auto`, or candidate `self-challenge` skill was used.
- Runtime request: OpenCode `1.18.9`, native `build` agent, `openai/gpt-5.6-sol`, variant `medium`.
- Every v2 OpenCode command is specified with `--pure` and the exact executable `C:\nvm4w\nodejs\opencode.cmd`: version, agent list, run, and export. The v2 command shapes are persisted in `experiment.json`.
- Repository skill catalog snapshot: `code-intent-comments@0.1.0`, `daily-work-log@0.1.4`, `gh-body-file@0.1.1`, and `playwright-server-lifecycle@0.1.1`. The controller rejects a catalog or `skills/self-challenge` directory containing the candidate skill.
- Sampling settings are unavailable from this runtime and are explicitly recorded as `seed: null`, `temperature: null`, and `top_p: null`.

## V2 Evidence And Runtime Blocker

- V2 artifact root: `.benchmark-artifacts/self-challenge-no-skill-baseline-v2/`.
- Preflight completed and recorded `environment.json`, `experiment.json`, and `opencode-agent-list.txt`.
- One raw prompt was atomically written for `train-framing-baseline` trial 1. No raw run or export record exists.
- The hidden background controller and its absolute-path `opencode.exe` child remained active for about five minutes without completing the first invocation. CPU was nonzero, but the artifact directory did not advance beyond that one prompt.
- The process tree was terminated to prevent an indefinite hidden runtime. No v2 slot completed, no slot is eligible for resume, and no v2 `run-report.json`, `score.json`, or summary exists.

This is a fixed runtime hang, not a behavioral observation and not an `OPENCODE_EXIT_FAILURE` record. It cannot safely resume because the active invocation was terminated without a session ID or terminal evidence; restarting it would duplicate an unknown in-flight slot. The user instruction forbids a third batch.

## Family Outcomes, Variance, And Cost

| Family | Intended slots | Completed evidence | Outcome / variance / cost |
| --- | ---: | ---: | --- |
| Framing inversion / aggregation contract | 10 | 0 | unavailable |
| Harmful pivot / fixture ownership | 5 | 0 | unavailable |
| Necessary pivot / user scope correction | 5 | 0 | unavailable |
| Routine near miss / typo | 5 | 0 | unavailable |
| Within-intent adaptation / parser | 5 | 0 | unavailable |
| **Total** | **30** | **0** | **unavailable** |

There are no session IDs, decisions, mapped actions, transcripts, tokens, turns, deduplicated tool calls, elapsed-time measurements, runtime-reported cost, user interruptions, or acceptance observations. Do not infer zero rates, zero variance, zero cost, or fresh-session success from their absence.

## Concise V1 History

The earlier v1 artifact remains preserved and untouched at `.benchmark-artifacts/self-challenge-no-skill-baseline-v1-complete/`. It recorded 30 launcher failures before any model answer because a positional message was parsed as an additional `--file` path. The adapter now places the positional message before `--file`; v2 independently confirmed absolute executable and `--pure` preflight, but exposed the separate first-invocation hang above. Neither v1 sentinel scores nor v2 missing output are behavioral baseline results.

## Non-Binding Threshold Discussion

No evidence-backed numeric floor, range, or trade-off can be proposed. Harmful-pivot avoidance, necessary-pivot suppression, within-intent correctness, routine overhead, user interruption, and tail variance are all unknown.

When a valid baseline is available, the human decision should explicitly balance:

1. Harmful-pivot avoidance against necessary-pivot suppression.
2. Within-intent correctness against routine-path token, time, tool, and interruption cost.
3. Tail variance against a mean-only pass rate.
4. Necessary user interruption against unnecessary friction on routine or clearly within-intent changes.

Ticket 03 remains the only place to select and lock those limits. This report selects none.

## Future 180-Run Structural Estimate

- 12 scenarios x 5 trials x 3 configurations = **180** benchmark runs.
- `no-skill`: 60 runs; `stage-one-only`: 60 runs; `full-two-stage`: 60 runs.
- Stage two is structurally capped at **60 invocations**, with at most one fresh read-only challenger per full-two-stage run.

No completed no-skill trial exists from which to project token, elapsed-time, tool-call, or monetary floors/ranges. Incremental stage-one, incremental stage-two, and full monetary costs are unavailable. Any future authorization must separate 180 main runs from the conditional 60 stage-two invocations and first resolve the v2 runtime hang without overwriting or retrying this batch.

## Coordinator Decision Required

1. Record Ticket 02 as blocked by the first-v2-slot runtime hang, not as a behavioral baseline.
2. Preserve both v1 and v2 artifacts unchanged; do not reclassify missing evidence as a failed decision outcome.
3. Do not proceed to Ticket 03 threshold selection from these unavailable metrics.
