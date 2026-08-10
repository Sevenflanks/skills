# OpenCode Trigger Baseline

此目錄是 scratch-only、可重現的 trigger benchmark，不是新 skill，也不修改 published skill。它比較三個唯一差異為 name / description metadata 的候選 fixture：

1. `current`: published frontmatter 的現行 name 與 description。
2. `generalized-current-name`: ticket 01 ownership boundary 的泛化 description，保留現行 name。
3. `generalized-neutral-name`: 相同泛化 description，改為中性的 `agent-process-lifecycle` name。

`variants.json` 在每次執行讀取 published `SKILL.md` 的 frontmatter，若 frozen current metadata 漂移即停止，不會產生混雜的比較結果。

## Protocol

- `trigger-evals.json` 固定 16 個真實 end-user task prompts：八個需要跨 tool-call 管理本機工作程序的 positive cases，以及八個有明確既有 owner 或同步完成的 near-miss negatives。prompt 不提候選 skill name；fixture permissions 使任何 action request 都無法執行。
- 每個 attempt 都建立一個 temporary project，且只放一個 `.opencode/skills/<candidate>/SKILL.md`。`opencode.json` 採 `{"*":"deny","skill":"allow"}`，使 executable 與 mutating tools 不可用，只有 `skill` 可用。
- 每個 variant trial 前先在其獨立 fixture 以 `opencode debug skill --pure` 做 discovery preflight。`--pure` 仍可列出 built-in/global skills，因此 gate 只要求 fixture skill path 下恰有一個 candidate，且其 name、description、location 與 variant 完全相符；preflight command、hash 與結果會寫入 manifest。
- 呼叫固定為 `opencode run --pure --format json --model openai/gpt-5.6-sol --agent build --dir <fixture> <prompt>`。
- 僅當 JSONL 事件為 `type=tool_use`、`part.type=tool`、`part.tool=skill`、`state.status=completed` 且 `state.input.name` 精確等於候選名稱時，才算 trigger。
- 非 trigger 需要正常 exit 加上 `step_finish` 終端事件。timeout、nonzero process exit、malformed JSONL、缺少終端 completion 都是 invalid attempts，不計為 false negative；每個 logical run 可依 `--retries` bounded retry。
- 每個選取的 `variant × prompt × logical run` 都必須在 bounded retries 後恰有一筆 valid trial。若缺漏或有多筆 valid trial，runner 記錄所有 attempts 與 `incomplete.json`，以 exit code `2` 結束，且不建立 aggregate evidence。


基準環境為 OpenCode `1.18.5`、Python `3.12.0` 與預設 model `openai/gpt-5.6-sol`。先執行 focused tests：

```powershell
py -3.12 -m unittest discover -s .scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline/tests -p test_trigger_benchmark.py
```

一格 smoke，不執行完整 144 valid-trial matrix：

```powershell
py -3.12 .scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline/run_trigger_baseline.py --variant current --prompt listener-local-server --runs-per-query 1 --workers 1 --retries 0 --output-dir results/smoke-current-listener-v2
```

完整 benchmark 的預設是 `16 prompts x 3 variants x 3 valid runs = 144` valid trials，不要在一般驗證時執行：

```powershell
py -3.12 .scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline/run_trigger_baseline.py --output-dir results/full-<timestamp>
```

可調整 `--runs-per-query`、`--workers`、`--timeout-seconds`、`--retries`、`--seed`、`--output-dir`、`--variant` 與 `--prompt`。輸出目錄必須位於本 benchmark scratch directory。

## Evidence And Metrics

每次執行輸出：

- `manifest.json`: requirements、觀測到的 environment、選取範圍、seed、permission policy、每 variant preflight evidence、所有 benchmark Python source / JSON input / published skill 的 collision-safe SHA-256，以及完成後的 evidence artifact hashes。
- `trials.ndjson`: 每一個 attempt 的狀態、exit、duration、command、stream hashes 與 log path。
- `logs/`: 原始 stdout JSONL 與 stderr，供事件判定稽核。
- `aggregate.json` 與 `aggregate.md`: 僅在 matrix completeness gate 通過時產生，包含每 variant 與 per-prompt 的 valid denominator、invalid attempts、positive trigger rate、negative false-trigger rate，及三組 pairwise right-minus-left rate deltas。

positive trigger rate 是 valid positive attempts 中精確選取候選 skill 的比例。negative false-trigger rate 是 valid negative attempts 中錯誤選取候選 skill 的比例。這些 rates 是 metadata routing 的實驗證據，不是 skill architecture 或 publishing 方案的建議。

## Limitations

結果受 model、OpenCode build、provider routing、當時 runtime 與小樣本隨機性影響。fixture 只量測選取，不測量 published body 的正確性、安全性或 lifecycle implementation；外部、framework、IDE 與 runtime-managed cases 是 deliberate near-miss controls。
