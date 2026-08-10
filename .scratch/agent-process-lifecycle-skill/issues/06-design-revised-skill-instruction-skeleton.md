# 設計修訂後的 skill instruction 骨架

Type: prototype
Status: resolved
Blocked by: 04, 05, 08

## Question

根據已決定的 skill 架構與責任分界，修訂後的 description、章節順序、decision hierarchy、案例、failure handling 與 cross-skill handoff 應採用什麼骨架，才能保持精簡、提高觸及率，並讓後續 Agent 可直接實作？

## Answer

採用 [修訂後的 skill instruction skeleton](../prototypes/06-skill-instruction-skeleton.md) 作為決策完整的規格骨架，原型僅是 review evidence，不是 production source。具體決定如下：

### Model-facing description

```text
Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, or a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation. On Windows, classify owner, select the first viable execution tier, and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify only to hand off or block before launch; do not perform lifecycle execution. Do not use for synchronous commands or when merely observing or using an external or runtime-managed resource whose owner and lifecycle contract are already clear.
```

這個 description 以 lifecycle decision 與可觀察症狀觸發，不枚舉 process types；near-miss 明確排除 synchronous command，以及 owner 與 lifecycle contract 已清楚且 task 僅觀察或使用該 external／runtime-managed resource 的情境。需要 non-Windows owner classification／handoff 時仍會觸發 platform gate。

### Instruction hierarchy

- Main `SKILL.md` 採 execution-ordered flow：applicability、platform gate、Windows tier selection、selected-branch reference loading、launch 前 Stop／Preserve disposition、execution、Finalize、failure／handoff、contrastive examples、final reference index；Windows helper reference 必須在選定 Windows self-managed branch 後、pre-launch validation 與 `Launch`／`Finalize` 前載入，failure reference 必須在 escalation trigger 出現後、diagnostic／reconciliation／handoff 前載入。
- Applicability boundary：external、framework 或 runtime-managed resource 在 owner／lifecycle responsibility 必須判斷時仍須分類並以責任導向 handoff，但不由本 skill 直接 OS-managed；只有 owner 已明確且完整、task 僅觀察或使用該 resource 時才不觸發／退出。Metadata description 維持原文的 near-miss exclusion。
- Main `SKILL.md` inline 列出 tier 的 minimum outcomes：ownership binding、stdio 不再持有 initiating call、需要時具 bounded readiness、可觀察 state、Stop／Preserve disposition、cleanup／handoff、lifecycle callback；詳細 evidence 不在 happy path 展開。
- Safety guards inline：launch 前須先能驗證 owner contract、可產生 fresh current-run scoped handle／binding 的 strategy 與可執行 final disposition，但不要求 launch 前已有 live binding；execution 必須取得 fresh binding，未取得前不得宣稱 launch／reuse 成功；termination 則必須有 live ownership proof。Tier failure 在 reconciliation 前不得 fall through，downstream finalization failure 後 lifecycle cleanup 仍須繼續，兩者結果分離。
- Windows 上 Tier 依序選 first viable tier：verified managed lifecycle、verified external launcher、Windows self-managed detached wrapper；前兩者的 eligibility 都要求可驗證 owner／launcher contract 能為選定 operation 產生 fresh current-run scoped handle／binding，但不要求 launch 前已有 live binding；若無可執行 tier，launch 前 blocked／handoff。Non-Windows 不進入 execution tier，只能 bounded owner classification 與 handoff。Managed path 不增加額外 lifecycle shell call 或 OS inspection；Windows self-managed happy path 只允許 `Launch` 與 `Finalize`。
- Launch 前先決定 `Stop` 或 `Preserve`。`Stop` 必須有可執行的 identity-bound final disposition；`Preserve` 必須先指定 later-cleanup owner 與交付契約，successful Launch 後再交付 fresh live binding、record、stdio、readiness 與日後 Stop 方法，不要求 launch 前已有 live binding。兩者都無法成立就 blocked／handoff。Windows self-managed 的 retained Job authority 可在 runtime 建立並驗證，graceful stop 只是 optional action。
- Windows self-managed path 由 `Launch` 與 `Finalize` 承擔 detached launch、stdio redirect、minimal record、bounded readiness，以及 `Stop` 或 `Preserve`；不新增 status、poll、retry、kill 或第三個 lifecycle action。`1.0.0` 官方 compatibility 只支援 Windows；non-Windows 不執行 lifecycle，僅在 inline platform gate 後 bounded 分類與 handoff，不補寫其 mechanics。
- Lifecycle result 與 downstream result 分離，browser 或其他 downstream resource 由 caller 負責；handoff 以能承擔後續 ownership 的責任方為中心，不依賴 named skill。主檔使用 compact contrastive examples。Production 將 Windows helper contract 放在 `references/windows-self-managed.md`，將 failure evidence、reconciliation 與 handoff payload 放在 `references/failure-and-handoff.md`；依前述 branch-local timing 載入，而非等到 execution／finalization 後才載入。
- Task-local reuse 與 invalidation 必須保留全部已決定條件：HEAD、repo/worktree/working directory、relevant working-tree/launch config、environment、launcher/wrapper/execution tool/argument mode/launch behavior、owner identity/contract/state、requested lifecycle decision、actual contradicting observation、previous failure，以及 unknown/stale freshness；任一改變或出現即在下一個相關決策前重做 entry check。

本 ticket 只完成 instruction skeleton 決策，不指定 acceptance thresholds、version、publishing gates、migration execution 或 production implementation。
