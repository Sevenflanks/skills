# 定義 long-lived process 的啟動與 ownership 策略階層

Type: grilling
Status: resolved
Blocked by: 01

## Question

Agent 應如何依序選擇 repo 或 framework managed lifecycle、已驗證 external launcher、自管 detached wrapper，或在無法證明 detachment 時回報 blocked？每一層需要哪些 ownership、stdio isolation、readiness、observation、shutdown、cleanup 與 callback 證據？

## Answer

本階層只在本機 process 必須跨越 initiating tool call 時啟用；會等到 exit 才返回的同步 command 不進入此流程。在 officially supported Windows 上，Agent 採第一個符合共同結果底線的 tier，不因 repo 慣例、方便的 launch command、tool timeout 或過去成功經驗直接推定 lifecycle 已受管理。Non-Windows 不進入這個 execution hierarchy；前兩種 owner 僅能分類後 handoff，不執行 lifecycle。

### Strategy hierarchy

1. **Verified repo／framework managed lifecycle**：Windows 上先做一次 bounded discovery。只有現行 mode/config 的 contract 能涵蓋所需 lifecycle outcomes，並取得本次執行的 scoped handle／run binding 時才取得優先權。責任可由 framework 與 Agent 分工，但必須有單一 Agent coordinator，且每項 outcome 都有明確 owner、沒有空白或重複宣稱。Non-Windows 僅分類 owner 並 handoff。
2. **Verified external launcher**：Windows 上第一層不合格時，優先採能提供 detachment、stdio、observe 與 stop contract 的 external launcher。資格需要 stable capability contract 加上本次 command、launcher path/version、current-run binding、stdio disposition 與 readiness 的實際綁定；文件或過去經驗本身不足。Non-Windows 僅分類 owner 並 handoff。
3. **Self-managed detached wrapper**：沒有合格 managed owner 時才使用。Launch 前必須已有可執行的 final disposition：owner-specific shutdown、同一次 finalizer invocation 內可完成 identity-bound validation-to-termination 的 primitive，或已明確接受的 preserve／handoff owner。Agent 必須證明 child 已脫離 initiating call、stdio 已隔離，並持久化跨 one-shot calls 所需的最小 current-run identity；不得假設記憶體中的 process handle 能跨 tool calls 保留。Command 返回或 tool timeout 都不算 detachment 證據。
4. **Blocked／handoff**：任何可執行 tier 都無法證明 detachment 或 ownership 時，停止 Agent 自動啟動，列出缺少的證據，並提供使用者 terminal／IDE 啟動、external handoff 或不需常駐 process 的替代方案。這只阻擋不安全的自動 launch，不宣稱底層 command 永遠不能執行。

Tier 執行失敗時，必須先證明該次 run 已停止、已 preserve／handoff，或明確記為 unresolved，才可 fall through；不得同時 race 多個 tier。

### Proportional outcome contract

七類 outcome 是結果責任，不是七道必須逐項執行的 gate。Tier 可以直接滿足或消除多項 outcome；每項標記為 `owner handled`、`not applicable` 或 `escalated`。正常 managed path 不做額外 OS inspection，高風險或失敗才展開完整證據。

| Outcome | Fast-path evidence | Escalation evidence |
| --- | --- | --- |
| Ownership | Framework／launcher 的 stable contract 加本次 scoped handle／run binding；可靠抽象不必公開底層 PID tree。Self-managed 只持久化 finalizer 所需的最小 current-run identity。 | Binding 模糊、wrapper-chain failure 或 cleanup 不一致時，才補 creation time、image、command line、parent chain 與 targeted process-tree evidence；PID、name、port alone 不足，也不得以掃描結果擴大 termination 範圍。 |
| Stdio isolation | Managed owner 的 bounded capture，能證明不再綁住 initiating call且之後可回讀。 | Self-managed wrapper 預設將 stdout／stderr 寫入已知檔案；只有診斷需要時才持續讀取。 |
| Readiness | Downstream 或 handoff 需要 process 可用時，使用一個最便宜且可靠的 workload-specific signal 與 deadline；優先 owner event/status，其次 endpoint/resource probe。 | 訊號矛盾、deadline 到期或首次使用失敗時增加 probes；spawn、存活、fixed sleep 或 port occupied 都不等於 ready。 |
| Observation | 預設在 readiness、首次依賴使用、shutdown／handoff 與錯誤時做 checkpoint。 | 只有 process 健康本身是 correctness invariant、使用者要求監看或已有 failure signal 時才 continuous observation。 |
| Shutdown | 透過 current owner 的正式 shutdown interface，先 graceful stop 並 bounded wait。 | Graceful timeout 後，只能對 ownership 已證明的 scoped handle／tree bounded escalation；證明不了就保留 evidence 並回報 unresolved。 |
| Cleanup／preserve | Managed owner 依已驗證 contract 回報 stopped 即可 short-circuit；只有 contract 失效跡象，或後續確實需要重用本次 listener／resource 時才做 targeted check。Preserve／handoff 則驗證 binding 仍有效且 later-cleanup owner 已明確。 | Self-managed、owner/binding 不一致或 resource 仍存在時，reconcile tracked entities 與必要的 workload-specific port、window、file lock、watch subscription 或 job state；不做廣泛 OS 掃描。Forced termination 只有具備同一次 finalizer invocation 內的 identity-bound primitive 時可用，否則 handoff。 |
| Callback | Happy path 精簡回報 tier、current-run binding、stdio disposition、readiness result、final disposition／owner。 | Failure、blocked、preserve、handoff、ownership ambiguity 或 cleanup escalation 時，附上完整 identity、logs、resource state、evidence paths 與 unresolved items。所有 outcome 都必須 callback。 |

### Fast path

1. 確認 process 確實需要跨越 initiating tool call。
2. Bounded 選取第一個可正向辨識且符合 contract 的 tier，取得新的 current-run binding；不再證明較低 tier 不存在。
3. 確認 stdio isolation；若下游需要可用狀態，以單一 bounded signal 等待 readiness。Self-managed path 將 detached launch、最小 record、stdio redirect 與 readiness 合併在同一次 tool call。
4. 不做常態 polling，只在依賴操作與 lifecycle checkpoints 驗證狀態。
5. 結束時透過 owner interface shutdown；self-managed path 使用一次 finalizer call。符合 managed cleanup 條件即 short-circuit。
6. 送出一行精簡 callback；只有 escalation trigger 才展開完整 evidence path。一般同步或 verified-managed path 不增加 lifecycle shell call，self-managed happy path 最多使用 launch/readiness 與 finalizer 兩次 lifecycle shell call。

### Efficiency and evidence reuse

- 同一 task 內，repo/worktree、HEAD、相關 working-tree config 與 launcher path/version 未變時，可重用已驗證的 contract evidence，不重查文件或試探 invocation。HEAD/config/environment 改變、先前失敗或 freshness 不明即失效。
- Contract evidence 可以重用，但每次 launch 必須取得新的 run ID／handle／owner binding；不得跨 launch 重用 PID、port、handle 或 run ID。
- Parent 與 subagent 共用一份 task-local lifecycle fact bundle：`tier`、contract evidence、current binding、stdio、readiness、disposition owner。只能有一個 coordinator，其他 actor 不重做 discovery 或重複 launch。
- 互不相依的 read-only discovery probes 可 batch／parallel；owner classification 與 launch 有依賴，不可並行。
- Readiness 使用 owner event/status 時不另做檢查；self-managed launch 在同一次 invocation 內採單一 bounded wait 或有 deadline 的有限 backoff，不用 fixed sleep，也不讓多個 agent 或 tool calls 輪流 polling。

### Escalation triggers

只有下列情境進入完整證據流程：ownership binding 不明、readiness failure、既有 resource owner conflict、unexpected exit、wrapper/child 關係不清、graceful shutdown timeout、cleanup identity mismatch、cleanup 後資源仍存在，或 preserve/handoff 需要轉移責任。Self-managed 本身只要求最小 record 與兩次 call budget，不自動觸發完整 dossier。無 escalation trigger 時，不重建 process tree、不持續 polling，也不輸出冗長的七段報告。

### Acceptance probes

- Framework 只有 start command、沒有 failure cleanup 或 shutdown coverage：第一層不合格。
- External launcher 只有 PID、沒有 stable contract 與本次 binding：第二層不合格。
- Wrapper 只因 tool timeout 而看似仍在執行：第三層不合格，回報 blocked／handoff。
- Self-managed launch 前沒有 owner-specific stop、可用的 same-invocation identity-bound finalizer，或明確 preserve owner：第三層不合格，不得先啟動再補責任。
- Managed owner 的 scoped handle 可觀察、可 shutdown，且沒有 contract 失效跡象：不要求額外 resource check 或重建底層 PID tree。
- Managed owner 回報 stopped 但本次建立的 resource 仍存在：不得 short-circuit，升級 reconciliation。
- 上一 tier readiness 失敗但 run 尚未完成 cleanup／handoff：不得啟動下一 tier。
