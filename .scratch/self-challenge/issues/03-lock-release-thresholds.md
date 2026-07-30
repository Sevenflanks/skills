# 03 — 鎖定人工 release thresholds 與 benchmark 成本授權

**What to build:** 根據 no-skill baseline 的變異、錯誤取捨與完整成本估算，由使用者明確選擇可接受的 release thresholds 並決定是否授權後續完整分層實驗。

**Blocked by:** 02 — 執行 no-skill baseline 與成本估算

**Status:** ready-for-human

- [ ] 向使用者呈現 baseline 的 harmful pivot、necessary-pivot suppression、within-intent correctness、routine cost、unnecessary interruption 與 variance，不以單一平均值隱藏 trade-off。
- [ ] 使用者明確選擇 release-critical metrics 的絕對通過界線、aggregation rules 與 variance treatment；relative improvement 不得取代絕對可接受行為。
- [ ] 使用者明確接受或拒絕完整 benchmark 的 run count、token、time 與 external-cost 估算。
- [ ] 鎖定 benchmark version、scenario families、true held-out partition、model/runtime 支援面與門檻，並記錄為後續 tickets 的不可變輸入。
- [ ] 在本 ticket 完成前，不得開始 candidate body、trigger description 或任何調參工作。
- [ ] 本 ticket 的決策由使用者完成；Agent 只能整理證據與忠實記錄，不得自行挑選產品風險或成本界線。
