# 建立 generic 與 near-miss trigger 基準

Type: task
Status: resolved
Blocked by: 01

## Question

應建立並執行哪些可重現的 generic positive-trigger 與 near-miss negative-trigger prompts，才能比較現況 description、原地泛化候選與 skill name 語義偏見，並為「決定泛化後的 skill 架構」提供觸發率與誤觸發證據？

## Answer

已建立 [OpenCode Trigger Baseline](../benchmarks/02-trigger-baseline/README.md)，以 16 個不含候選 skill name 的真實任務 prompts 固定八個 positive lifecycle cases 與八個 near-miss negatives，並比較三個只改變 metadata 的 variant：

- `current`：published `playwright-server-lifecycle` name 與 description。
- `generalized-current-name`：保留 `playwright-server-lifecycle` name，換成 ticket「定義 lifecycle skill 的適用邊界」所界定的 generic description。
- `generalized-neutral-name`：使用完全相同的 generic description，只把 name 改為 `agent-process-lifecycle`。

完整 inputs 見 [trigger-evals.json](../benchmarks/02-trigger-baseline/trigger-evals.json) 與 [variants.json](../benchmarks/02-trigger-baseline/variants.json)。Runner 以 OpenCode `1.18.5`、Python `3.12.0`、`openai/gpt-5.6-sol`、seed `20260728` 執行每個 prompt/variant 三次；每次在 deny-by-default temporary fixture 中只允許 `skill` tool，並只把精確選取該 candidate 的 completed `skill` event 算成 trigger。

### 實測結果

| Variant | Positive trigger | Near-miss false trigger |
| --- | ---: | ---: |
| `current` | 24/24（100.0%） | 13/24（54.2%） |
| `generalized-current-name` | 23/24（95.8%） | 20/24（83.3%） |
| `generalized-neutral-name` | 24/24（100.0%） | 21/24（87.5%） |

Pairwise delta 皆為 right minus left：

- `current` → `generalized-current-name`：positive `-4.2pp`，false trigger `+29.2pp`。在這組 prompts 中，原地泛化未增加 recall，反而顯著擴大誤觸發。
- `generalized-current-name` → `generalized-neutral-name`：positive `+4.2pp`，false trigger `+4.2pp`。name 語義偏見只造成各一筆 trial 的差距；此樣本不足以單獨支持 rename。
- `current` → `generalized-neutral-name`：positive `0.0pp`，false trigger `+33.3pp`；這是 description 與 name 的合併效果，不可作因果拆分。

Positive prompts 中，`current` 與 `generalized-neutral-name` 皆為八種情境各 3/3；`generalized-current-name` 只有 timeout residual process 為 2/3，其餘皆 3/3。Near-miss 分布如下，數字為三次中觸發次數：

| Near-miss | `current` | generalized/current name | generalized/neutral name |
| --- | ---: | ---: | ---: |
| synchronous long command | 3 | 3 | 3 |
| observe external service | 2 | 2 | 3 |
| framework complete ownership | 3 | 3 | 3 |
| Docker runtime | 1 | 3 | 3 |
| Kubernetes runtime | 0 | 1 | 0 |
| Windows Service runtime | 1 | 3 | 3 |
| remote CI | 0 | 2 | 3 |
| IDE-owned service | 3 | 3 | 3 |

完整 machine-readable evidence 位於 [aggregate.json](../benchmarks/02-trigger-baseline/results/full-gpt56sol-run-1/aggregate.json)，摘要見 [aggregate.md](../benchmarks/02-trigger-baseline/results/full-gpt56sol-run-1/aggregate.md)，環境、controls、completeness 與 SHA-256 見 [manifest.json](../benchmarks/02-trigger-baseline/results/full-gpt56sol-run-1/manifest.json)，所有 attempts 與 raw stream pointers 見 [trials.ndjson](../benchmarks/02-trigger-baseline/results/full-gpt56sol-run-1/trials.ndjson)。Matrix 完成 `144/144` valid trials；另有一次 `generalized-neutral-name` / remote CI attempt timeout，經 bounded retry 補齊且未計為未觸發。

### 下游解讀限制

- 這是 trigger metadata baseline，只量測 routing，不驗證 skill body 的 lifecycle 行為或安全性。
- 每個 prompt 只有三次，且只涵蓋單一 OpenCode/model/runtime；`4.2pp` 等於一筆 trial，應視為弱訊號。
- 泛化 description 明列 external、framework、IDE 與 runtime-managed handoff，可能使模型即使在 owner 已明確時仍載入 skill；高 near-miss rate 是後續「決定泛化後的 skill 架構」必須處理的 precision 成本，不是本 ticket 的架構結論。
- 現況 description 在這組 positive prompts 已達 100%，因此本 baseline 沒有觀察到可由泛化取得的 recall headroom；後續若需改寫 description，應以降低已明確 owner／同步 command 的誤觸發為主要 eval 壓力。
