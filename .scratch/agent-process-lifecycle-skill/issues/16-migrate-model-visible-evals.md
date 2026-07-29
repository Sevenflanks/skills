# 16 — 完成 model-visible instructions 與 eval migration

**What to build:** 完成尚未發布候選版本的 lifecycle-only model-visible instructions、selected-branch progressive disclosure 與 failure／handoff reference，並將每個既有 eval 轉為 lifecycle-only assertion 或明確退休。完成後，候選版本可透過同一 model-visible seam 交付 tier selection、ownership decision、責任邊界、Stop／Preserve、failure／handoff／unresolved 與 callback separation。此 ticket 不驗證 metadata selection，不重新執行或重算 routing benchmark、Windows runtime acceptance，也不測試 private implementation structure。

**Blocked by:** 15, Preserve、later Stop 與完整 helper acceptance

**Status:** ready-for-agent

- [ ] Main instructions 依 applicability、platform gate、Windows tier、selected-branch reference、launch 前 Stop／Preserve、execution、Finalize、failure／handoff、contrastive examples 與 reference index 執行，且只有選中 Windows self-managed branch 或 escalation path 才載入對應 reference。
- [ ] Managed path 接受 owner-scoped opaque binding，不要求 PID tree，並維持 zero additional OS inspection 與 lifecycle shell call；non-Windows 維持 bounded classification、handoff／blocked 與 zero-call behavior。
- [ ] Failure／handoff reference 完整定義 targeted evidence、reconciliation、safe unresolved terminal outcome、machine-readable callback facts，以及 non-Windows complete handoff payload。
- [ ] Main instructions 與 references 完整移除 Browser QA responsibility；browser／downstream resource 與 task result 仍由 caller 負責。
- [ ] 每個既有 eval 都轉為 lifecycle-only assertion 或明確標記 retired，且不保留 Browser QA responsibility。
- [ ] eval coverage 包含 generic GUI、watcher、detached finite job natural completion、managed owner、runtime handoff、Windows self-managed behavior、Preserve、reconciliation 與 downstream-result separation。
- [ ] detached finite job eval 區分自然 exit、result 與無 residue，以及 cancellation、timeout 或失去控制後才需要 termination 的情況。
- [ ] model-visible cases 驗證 task-level reasoning-only entry check、event-driven invalidation、first viable tier、launch 前 Stop 或 Preserve、reconciliation 後才可進入下一 tier、minimum outcomes，以及 failure、handoff、unresolved 與 callback payload。
- [ ] 恰好兩個 non-Windows prompt-level cases 驗證無 owner 時 launch 前 blocked 與已辨識 owner 時 handoff，並確認 zero OS inspection、lifecycle shell call、launch、termination 與完整 handoff payload。
- [ ] eval 只引用既有 routing 與 runtime evidence，不重新計算 benchmark 或 acceptance，也不宣稱 non-Windows runtime support、generic process manager 或 private helper decomposition。
