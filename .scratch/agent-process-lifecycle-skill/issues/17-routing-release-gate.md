# 17 — 執行 routing release gate

**What to build:** 建立核准的固定 routing release gate，在相同 pinned conditions 下比較 current 與 candidate descriptions；candidate 未達確認的 thresholds 時阻擋 publication。Gate 保留 raw evidence，並以 bounded worker calibration 協助判讀，不改變 fixed aggregate denominator。

**Blocked by:** 10, 保持候選版本未列出

**Status:** ready-for-agent

- [ ] current 與 candidate 以兩個 variants 在同一 pinned environment 執行，使用相同且有記錄的 worker count、isolated fixtures、raw streams 與 completeness checks。
- [ ] candidate 使用規格確認的 exact model-facing description；本 gate 不得改寫 description、prompt classification、threshold 或 denominator rule 來取得通過結果。
- [ ] fixed base matrix 每個 prompt 恰好執行三次 valid trials，aggregate 是唯一 release denominator；invalid attempts 不計入 trigger rate。
- [ ] positive aggregate 至少 95%；positive 3/3 為 desired，positive 2/3 才可擴大至十次且至少達 9/10，positive 0/3 或 1/3 直接 block。
- [ ] candidate near-miss aggregate 不得高於同 run 的 current comparator；candidate 3/3 false trigger 直接 block，candidate 2/3 才可擴大至十次且不得超過 3/10。
- [ ] targeted ten-run isolation 只用於結果不一致或距 threshold 僅一 trial 的 prompt，追加七次不得改變 fixed aggregate。
- [ ] 每個 false-trigger load 都證明沒有 OS inspection、launch、termination 或 lifecycle shell call，並保留 matrix completeness、parity、raw evidence 與 pinned-environment records。
- [ ] worker calibration 受 bounded 範圍限制，不得取代 failed fixed gate、改寫 denominator 或豁免缺少的 evidence。
