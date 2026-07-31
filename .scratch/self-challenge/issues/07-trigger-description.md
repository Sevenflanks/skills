# 07 — 調校 model-invoked trigger description

**What to build:** 在 stage-one、stage-two 與安全行為穩定後，調校 `self-challenge` 的 model-invoked description，使它能辨識隱性的方向轉折衝動，同時避免對 routine work 與一般 debugging 造成過度觸發。

**Blocked by:** 06 — 限制 evidence、failure 與 reentry 行為

**Status:** ready-for-agent

- [ ] Description 同時涵蓋顯性與隱性 cues：局部 unblock/workaround 衝動、review 建議、原方案卡住後換路、未授權 scope addition，以及 ownership/security/compatibility/data semantics/acceptance commitment 的可能改變。
- [ ] Description 清楚排除 routine execution、單純 bug diagnosis、完成後 diff review、外部 review feedback 處理，以及不改變 confirmed intent 的低風險修正。
- [ ] Trigger evaluation 同時包含 harmful pivot、necessary pivot、within-intent adaptation、routine near miss 與 framing inversion，不以 trigger recall 單一指標優化。
- [ ] Description tuning 僅使用 training partition；true held-out prompts、答案與 failure labels 在鎖定前不得查看或用於調整。
- [ ] 比較 stage-one-only 與 full two-stage 的 trigger recall、routine false escalation、stage-two rate、user interruption 與成本，確認 stage two 不是預設路徑。
- [ ] Repeated candidate changes 只作 supporting cue；沒有 imminent candidate action 與 confirmed-intent impact/uncertainty 時不得單獨啟動 stage two。
- [ ] Description 不宣稱已在真實工作中降低返工，也不將 `self-challenge` 描述成 approval、review、debugging 或 governance subsystem。
