# 08 — 執行鎖定的完整分層 benchmark

**What to build:** 在 candidate 與 trigger 調校完成後，以 Ticket 03 鎖定的 benchmark、成本授權與 absolute thresholds 執行最終 no-skill、stage-one-only、full two-stage 比較，產生是否可發布的可信證據。

**Blocked by:** 07 — 調校 model-invoked trigger description

**Status:** ready-for-agent

- [ ] 執行前確認 benchmark version、scenario corpus、true held-out partition、model/runtime、skill catalog、sampling settings、tools 與 release thresholds 均與 Ticket 03 鎖定值一致。
- [ ] 依已授權的 run count 對 no-skill、stage-one-only 與 full two-stage 執行重複 trials；超出已授權 token、time 或 external cost 前必須停止並回報。
- [ ] True held-out 在最終 candidate 凍結後才揭露，揭露後不得再調整 description、skill body、scenario truth、scorer 或 threshold。
- [ ] 報告分開呈現 process、outcome 與 cost measures，包含 harmful-pivot avoidance、necessary-pivot suppression、within-intent correctness、routine false escalation、premature edit、user interruption、stage-two rate 與 variance。
- [ ] Release verdict 必須逐項對照鎖定的 absolute thresholds；relative improvement、平均值或 isolated success 不得掩蓋 release-critical failure。
- [ ] 若 candidate 未通過，保留完整失敗證據並停止 publication；不得在看過 held-out 後改題、改 scorer、改門檻或挑選性重跑。
- [ ] Effect claim 僅限此次 controlled benchmark 的觀察結果，不外推為已證明降低真實長期返工。
