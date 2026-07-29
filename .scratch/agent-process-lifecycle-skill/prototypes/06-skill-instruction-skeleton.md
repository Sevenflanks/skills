# PROTOTYPE / NON-PRODUCTION

## HITL review target

這份文件只把 `agent-process-lifecycle` 的 instruction hierarchy 具體化，供 ticket 06 review。它不是可發布的 `SKILL.md`，不包含完整 Windows 或 failure contract。

## Candidate metadata description

Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, or a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation. On Windows, classify owner, select the first viable execution tier, and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify only to hand off or block before launch; do not perform lifecycle execution. Do not use for synchronous commands or when merely observing or using an external or runtime-managed resource whose owner and lifecycle contract are already clear.

Routing 刻意聚焦 lifecycle decision，而不是廣泛 process。這可保留 positive recall，同時降低 near-miss 誤觸發與每個 command 的 context 成本。單一 skill 直接 replacement，不設 parent、child、alias 或 deprecated stub。

## Proposed production `SKILL.md` execution order

Follow this order: decide applicability, apply the platform gate, select a Windows execution tier, load the selected branch reference at its decision site, establish Stop／Preserve before launch, execute, Finalize, handle failure／handoff, then review contrastive examples and the final reference index.

### 1. Purpose and boundary

**Purpose:** 說明 lifecycle owner 是誰，以及 process 何時跨越 initiating tool call。

**Boundary:** 納入 Agent-owned local process、detached finite job、current-run preserve 與事後殘留 reconciliation。External、framework 或 runtime-managed resource 仍在 owner／lifecycle responsibility 必須判斷時納入 ownership classification 與責任導向 handoff，但不由本 skill 直接 OS-managed；只有 owner 已明確且完整、task 僅觀察或使用該 resource 時才不觸發／退出。Browser QA 與 downstream result 由 caller 負責。

### 2. Reasoning-only entry check

**Check once:** 在首次 candidate long-lived launch 前，只以 reasoning 判斷是否存在 lifecycle decision，確認 owner、跨 call 可能性與 downstream 是否需要 readiness。不要做 per-command audit、PID／port probe、廣泛 OS scan 或 continuous polling。

**Task-local reuse:** 在 HEAD、repo/worktree/working directory、relevant working-tree/launch config、environment、launcher/wrapper/execution tool/argument mode/launch behavior、owner identity/contract/state、requested lifecycle decision、actual observation、previous failure 與 freshness 均未變動且非 unknown/stale 時重用 fact bundle。bundle 至少記錄 tier、contract evidence、current-run binding、stdio、readiness、disposition owner。

**Event invalidation:** 下列事件立即使判斷失效，下一個相關決策前重做 entry check：HEAD、repo/worktree/working directory、relevant working-tree/launch config、environment、launcher/wrapper/execution tool/argument mode/launch behavior、owner identity/contract/state、requested lifecycle decision 改變；actual observation contradicts the decision、previous failure 改變，或 freshness 變為 unknown/stale；新增 start、reuse、preserve、terminate、handoff、cleanup 或 reconciliation 決策；exit、crash、timeout、session interruption。

**Platform gate:** `1.0.0` 官方只支援 Windows。Non-Windows 不進入下列 minimum outcomes 或 tier execution；只做不含 OS inspection／lifecycle shell call 的 bounded owner classification，辨識到 managed／external owner 時 handoff，否則在 launch 前 blocked。本版不補寫 platform mechanics 或 dedicated reference。

### 3. Minimum outcomes before tier selection

每個可執行 tier 都必須能直接滿足或明確交付這些最小 outcomes；詳細 evidence 延後到 references：ownership binding；stdio 不再持有 initiating call；需要時具 bounded readiness；可觀察 state；Stop／Preserve disposition；cleanup／handoff；lifecycle callback。

**Immediate safety rule:** Launch 前必須能驗證 owner contract／能產生 fresh current-run scoped handle／binding 的 strategy 與可執行 final disposition；不要求 live binding 已存在。Termination 則必須有 live ownership proof。

### 4. Tier selection

依序選第一個能正向證明共同 lifecycle outcomes 的 tier，不先證明較低 tier 不存在，也不並行 race：

1. Verified managed lifecycle，須有可驗證的 owner／launcher contract，且能為選定 operation 產生 fresh current-run scoped handle／binding；live binding 不必在 launch 前存在。
2. Verified external launcher，須有可驗證且能為選定 operation 產生 fresh current-run scoped binding 的 stable capability contract，並能在 execution 取得本次 command、version、stdio、readiness 的實際關聯；live binding 不必在 launch 前存在。
3. Self-managed detached wrapper，只在前兩層不合格且已有 final disposition、detachment、stdio isolation 與最小 identity 可證明時使用。
4. 若沒有可執行 tier，launch 前 blocked／handoff，列出缺少的證據。

**Immediate safety rule:** Tier failure 不得在 reconciliation 前 fall through。先完成該 run 的 Stop、Preserve／handoff，或明確記為 unresolved，再考慮下一 tier。

### 5. Branch references and pre-launch Stop / Preserve disposition

選定 Windows self-managed branch 後，立即載入 `[Future production reference: Windows helper]`，再驗證 pre-launch disposition，並執行 `Launch`／`Finalize`。若出現 ownership ambiguity、readiness failure、owner conflict、unexpected exit、wrapper ambiguity、shutdown timeout、identity mismatch、resource residual 或 Preserve／handoff 等 escalation trigger，立即載入 `[Future production reference: failure evidence]`，再進行 diagnostic、reconciliation 或 handoff。

在 launch 前先決定 current-run 的 disposition 與 owner：

- `Stop`：必須已有可執行的 identity-bound final disposition；Windows self-managed 的 launch contract 可在 runtime 建立並驗證 retained Job forced authority，graceful stop 只是 caller 可提供的 optional action，不可先 launch 再補責任。
- `Preserve`：launch 前必須已有 later-cleanup owner 與交付契約；successful Launch 後再交付 fresh live binding、record、stdio、readiness 與日後 Stop 方法，不要求 launch 前已有 live binding。
- 兩者都無法成立：blocked／handoff。

Managed path 不增加 lifecycle shell call 或 OS inspection。Self-managed Windows happy path 僅允許 `Launch` 與 `Finalize`，其中 `Finalize` 接受 `Stop` 或 `Preserve`。

### 6. Selected lifecycle execution

執行已選 tier，先取得新的 current-run scoped handle／binding，不跨 launch 重用 PID、port、handle 或 run ID；未取得 fresh binding 前不得宣稱 launch／reuse 成功。只記錄 caller 提供的 workload-specific readiness signal 與 deadline。spawn、存活、fixed sleep 或 port occupied 不等於 readiness。

觀察採 event-based checkpoints，限於 readiness、首次依賴使用、shutdown／handoff 與錯誤。managed owner 依正式 interface 執行；self-managed Windows `Launch` 合併 detached launch、stdio redirect、minimal record 與 bounded readiness。不要加入 status、poll、retry、kill 或第三 lifecycle action。

### 7. Finalize Stop / Preserve

`Stop` 在 Windows self-managed path 可直接使用由 launch contract 在 runtime 建立並驗證的 retained Job forced authority，或先執行 caller 提供的 optional graceful action、bounded wait，再以同一 retained authority forced escalation。`Preserve` 仍須 Finalize，重驗 owner，更新 later-cleanup owner，不終止 process；Preserve 不等於 external owner，也不等於 cleanup 完成。

不能證明 ownership、binding、membership 或清理結果時，禁止 PID／name／port-only termination，改記錄 unresolved 並 handoff。不要在 tier reconciliation 完成前 fall through。

Lifecycle result 與 downstream result 分開。Caller 自行處理 browser 或其他 downstream resource；即使 caller／downstream finalization 失敗，lifecycle cleanup 仍須繼續；lifecycle callback 不覆寫 downstream result。

### 8. Failure and handoff

Failure path 只在 ownership ambiguity、readiness failure、owner conflict、unexpected exit、wrapper ambiguity、shutdown timeout、identity mismatch、resource 殘留或 Preserve／handoff 時展開 targeted evidence。通用 failure 回報 failure kind、cleanup attempt／result、evidence path、unresolved reason、later owner 與 current binding。Non-Windows blocked／handoff 至少回報 platform、requested lifecycle need、identified owner and/or contract gap、explicit no launch／termination statement、missing safety evidence、至少一個不含 platform command 的可行替代方案、next owner 與 unresolved items。

Managed path 可由 verified stopped short-circuit；self-managed、mismatch 或殘留才做必要 reconciliation。無法安全自管時，停止自動 launch，交付證據給能承擔後續 ownership 的責任方，或回報 unresolved／handoff，而不是假裝 clean completion。

### 9. Contrastive examples

| 情境 | 應走的路徑 | 不應做的事 |
| --- | --- | --- |
| `npm test` 等到 exit 才返回 | 不觸發 lifecycle skill | 因為執行很久就做 lifecycle audit |
| framework mode 有 start、readiness、failure cleanup、shutdown 與本次 binding | managed tier，零額外 OS work | 重建 PID tree 或 routine port scan |
| reuse 已由 IDE 管理的 server | 分類為 external，handoff | 把它納入 current-run Stop |
| Windows 無 managed owner，但 launch 前已有 Stop 或 Preserve contract | self-managed，`Launch` 後 `Finalize` | 用 timeout、PID 或 name 推定 ownership |
| readiness 失敗且上一 tier 尚未 reconcile | unresolved／Stop／handoff 後再決策 | 直接 fall through 啟動下一 tier |
| 非 Windows self-managed 需求 | blocked／handoff | 臆造非 Windows helper mechanics |

### 10. Progressive-disclosure slots

Reference contract 不放進每次 routing context；context pointer 必須留在對應的 branch decision site，依下列時機載入：

- `[Future production reference: Windows helper]`：選定 Windows self-managed branch 後、驗證 pre-launch disposition 或執行 `Launch`／`Finalize` 前載入；依 ticket「決定 Windows self-managed lifecycle helper 的最小契約」補齊 `Launch`、`Finalize`、record、Job binding、abrupt-crash gap 與 acceptance checks。此 prototype 不複製詳細 contract。
- `[Future production reference: failure evidence]`：任一 escalation trigger 出現時、進行 diagnostic、reconciliation 或 handoff 前載入；依 tickets「定義 long-lived process 的啟動與 ownership 策略階層」、「劃分共用 process lifecycle 與 browser QA 責任」及「定義 non-Windows self-managed guidance 深度」補齊 failure-only evidence、reconciliation、non-Windows handoff payload 與 callback 欄位。此 prototype 只保留觸發條件。

## Confirmed HITL design choices

- Metadata 以 lifecycle-decision routing 為主，涵蓋 foreground hang／outlive 與 lingering／zombie／unclear-owner cleanup；near-miss exclusions 保持簡潔，不枚舉 process types。
- Production instruction 依 applicability → platform gate → Windows tier → branch-local reference loading → pre-launch disposition → execution → Finalize → failure／handoff → examples → final reference index 執行；reference contract 在對應 branch 執行前載入。
- Minimum outcomes inline；詳細 evidence progressive disclosure。
- 三條 safety rules inline：Launch 前須有可驗證 owner contract／current-run binding strategy 與 executable disposition，但 termination 須有 live ownership proof；未 reconciliation 不 fall through；downstream finalization failure 後仍繼續 lifecycle cleanup。
- Handoff 以能承擔後續 ownership 的責任方為中心，不綁定 named skill；platform／product names 僅作 contrastive examples。

**Final HITL confirmation target:** 確認這份 execution-ordered skeleton 已完整反映上述設計，且仍保持 prototype、非 production contract。
