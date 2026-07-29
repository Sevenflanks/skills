# 15 — Preserve、later Stop 與完整 helper acceptance

**What to build:** 在前述 Launch、valid-authority Stop 與 authority rejection slices 之上，加入 Preserve 與 later Stop handoff，並彙整完整的 production Windows helper acceptance。Acceptance report 必須分開記錄 production checks、prototype facts、abrupt host crash non-guarantee 與 same-user tamper non-guarantee。

**Blocked by:** 14, 拒絕無法驗證的 Finalize authority

**Status:** ready-for-agent

- [ ] Preserve 重新驗證 ownership、不終止 process，並交付 fresh live binding、record、stdio、readiness、later owner 與日後 Stop 方法。
- [ ] later Stop 在新的 invocation 中可依 handoff contract 完成 valid ownership validation、graceful 或 forced Stop，並回報 resource result。
- [ ] production acceptance 覆蓋 fresh invocation、nested assignment、stdio isolation、bounded readiness、readiness failure cleanup、graceful Stop、forced Stop、scoped tree termination、unrelated process preservation、fresh exclusive record、atomic update、ACL、redirection rejection 與 Preserve later Stop。
- [ ] production acceptance 覆蓋 malformed、stale、mismatched、PID reuse、missing authority、membership、inaccessible authority、same session、same security context、workload handle 與 early root exit；不得以 prototype evidence 代替。
- [ ] 每個 Stop 與 failure-cleanup case 證明 fixture process、named ownership object 與 temporary artifact 清空；Preserve case 改為證明 live binding 與 later owner 仍有效。
- [ ] acceptance 確認沒有 close-triggered termination、PID/name/port-only kill、broad scan、routine polling、record 內 graceful-stop command 或第三 lifecycle action。
- [ ] report 分開列出 production checks 與 prototype feasibility facts，並明確揭露 atomic record publication 前 abrupt host crash 及同一 user security context 的惡意 record 或 named-object tampering 兩項 non-guarantees。
- [ ] Accepted production helper 與其 model-facing Windows helper reference 使用相同的 `Launch`／`Finalize` public contract、輸入、結果欄位、安全限制與 non-guarantees；reference 不暴露 private Job／record implementation choreography 給 caller。
