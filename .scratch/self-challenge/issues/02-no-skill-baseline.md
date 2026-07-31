# 02 — 執行 no-skill baseline 與成本估算

**What to build:** 使用已固定的 benchmark foundation 執行重複 no-skill trials，產出目前 Agent 對方向轉折的真實基線、錯誤取捨與完整分層實驗的成本估算，供使用者在任何 candidate 調整前決定 release 標準。

**Blocked by:** 01 — 建立可執行的分層 benchmark 基礎

**Status:** resolved

**Claimed by:** current OpenCode session on `feature/plan-reflection-skill`

- [x] No-skill baseline 使用固定 scenario、scorer 與 benchmark version 重複執行，不建立或調整 candidate skill。
- [x] 報告按 scenario family 呈現 harmful-pivot avoidance、necessary-pivot suppression、within-intent correctness、routine-path cost、user interruption、失敗案例與 trial variance。
- [x] 記錄 model、runtime、完整 skill catalog、sampling settings、tool availability 與 benchmark version，使結果可重現及比較。
- [x] 估算完整 no-skill、stage-one-only、full two-stage 實驗的 run count、token use、elapsed time、external cost、tool calls 與 stage-two invocation volume。
- [x] 缺少、矛盾或無法評分的 evidence 以 baseline failure 明確回報，不得為了讓結果好看而修改 scorer 或 scenario truth。
- [x] 產出可供人類決策的門檻建議區間與 error trade-offs，但不得代替使用者選擇或鎖定 release thresholds。

## Comments

- 首次 30-slot baseline 在模型回覆前全數因 OpenCode `--file` argument ordering 失敗；未重試或覆寫。
- 失敗證據與 unavailable metrics 記錄於 [`../reports/02-no-skill-baseline.md`](../reports/02-no-skill-baseline.md)。
- Adapter ordering 已修正並有回歸測試；需要使用者決定是否授權新 artifact directory 與 fresh sessions 的 clean rerun。
- 使用者已授權 clean rerun，並指定以 `C:\nvm4w\nodejs\opencode.cmd` 執行 OpenCode。
- V2 已以 absolute executable、`--pure` 與 hidden background process 啟動，但第一個 model invocation 約五分鐘仍無 session 或 terminal evidence；process tree 已安全終止，未啟動第三批。
- Ticket 02 當時被此 fixed runtime hang 阻擋；權威結果見 baseline report。
- Runtime diagnosis confirmed that Node `execFile` keeps child stdin open; the user authorized replacing it with hidden `spawn(..., { stdio: ['ignore', 'pipe', 'pipe'] })` and then resuming Ticket 02.
- V3 completed all 30 run/export pairs with 30 unique sessions, but the official controller classified every slot as `UNMAPPABLE_ACTION`.
- Coordinator review found a deterministic double-normalization defect: `parseOpenCodeEvidence()` returns `OPTION_A/B`, then `mapFrozenDecision()` incorrectly calls `parseFrozenOption()` on that token again. A new clean batch requires a separate authorization after this gate failure.
- 使用者最新 continuation 明確授權新的 immutable V4 artifact directory；未重試、覆寫或改寫 V1/V2/V3 evidence。
- V4 固定 30 slots：26 個 unique-session scorable completions 全數 behaviorally correct，4 個 `OPENCODE_TIMEOUT` 固定 baseline failures；權威 metrics 與非 binding Ticket 03 options 已寫入 `../reports/02-no-skill-baseline.md`。
- Ticket 02 的 evidence/report 工作已 resolved。Ticket 03 保持 `ready-for-human`，由使用者選擇 release thresholds、timeout treatment 與後續授權。
