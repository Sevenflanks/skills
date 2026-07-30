# 02 — 執行 no-skill baseline 與成本估算

**What to build:** 使用已固定的 benchmark foundation 執行重複 no-skill trials，產出目前 Agent 對方向轉折的真實基線、錯誤取捨與完整分層實驗的成本估算，供使用者在任何 candidate 調整前決定 release 標準。

**Blocked by:** 01 — 建立可執行的分層 benchmark 基礎

**Status:** needs-info

**Claimed by:** current OpenCode session on `feature/plan-reflection-skill`

- [ ] No-skill baseline 使用固定 scenario、scorer 與 benchmark version 重複執行，不建立或調整 candidate skill。
- [ ] 報告按 scenario family 呈現 harmful-pivot avoidance、necessary-pivot suppression、within-intent correctness、routine-path cost、user interruption、失敗案例與 trial variance。
- [ ] 記錄 model、runtime、完整 skill catalog、sampling settings、tool availability 與 benchmark version，使結果可重現及比較。
- [ ] 估算完整 no-skill、stage-one-only、full two-stage 實驗的 run count、token use、elapsed time、external cost、tool calls 與 stage-two invocation volume。
- [ ] 缺少、矛盾或無法評分的 evidence 以 baseline failure 明確回報，不得為了讓結果好看而修改 scorer 或 scenario truth。
- [ ] 產出可供人類決策的門檻建議區間與 error trade-offs，但不得代替使用者選擇或鎖定 release thresholds。

## Comments

- 首次 30-slot baseline 在模型回覆前全數因 OpenCode `--file` argument ordering 失敗；未重試或覆寫。
- 失敗證據與 unavailable metrics 記錄於 [`../reports/02-no-skill-baseline.md`](../reports/02-no-skill-baseline.md)。
- Adapter ordering 已修正並有回歸測試；需要使用者決定是否授權新 artifact directory 與 fresh sessions 的 clean rerun。
- 使用者已授權 clean rerun，並指定以 `C:\nvm4w\nodejs\opencode.cmd` 執行 OpenCode。
- V2 已以 absolute executable、`--pure` 與 hidden background process 啟動，但第一個 model invocation 約五分鐘仍無 session 或 terminal evidence；process tree 已安全終止，未啟動第三批。
- Ticket 02 目前被此 fixed runtime hang 阻擋；權威結果見 baseline report。
