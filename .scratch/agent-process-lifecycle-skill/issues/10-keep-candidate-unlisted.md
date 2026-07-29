# 10 — 保持候選版本未列出

**What to build:** 讓新的 lifecycle 候選版本可由維護者手動載入並供測試使用，但在核准的 implementation、acceptance evidence 與 publication inventory 完成前，不讓 model invocation 或 production 使用它。候選版本必須先完成確認的快速 routing 與 platform gate；若執行需要 helper 而 production helper 尚不存在，必須在 launch 前阻擋，且候選版本不得出現在任何發布 inventory。

**Blocked by:** None — can start immediately

**Status:** ready-for-agent

- [ ] 測試可手動載入候選版本並呼叫其測試入口；候選版本不會因手動載入而被加入 model-facing 或 published inventory。
- [ ] 候選版本使用規格確認的 exact model-facing description，不以實作方便為由改寫 trigger 或 near-miss exclusion。
- [ ] 已確認的快速 routing 與 platform gate 能在執行前判斷適用性與平台限制，並對不適用情境不建立 lifecycle fact bundle。
- [ ] 在 production helper 尚不存在時，helper-required execution 於 launch 前回傳 blocked，且不執行 launch、termination 或 lifecycle shell call。
- [ ] blocked 結果指出缺少 production acceptance 的原因，不提供 alias、stub 或替代發布路徑。
- [ ] 候選版本的 prototype code、prototype facts 與 feasibility evidence 不會被宣稱為 production implementation 或 acceptance。
- [ ] repository validation 維持綠燈，且候選版本仍不出現在 catalog 或 marketplace publication inventory。
