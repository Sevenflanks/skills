# 決定 Windows self-managed lifecycle helper 的最小契約

Type: prototype
Status: resolved
Blocked by: 03, 05

## Question

在 OpenCode one-shot PowerShell 無法跨 tool calls 保留 live process handle 的限制下，`agent-process-lifecycle` 是否應提供最小 deterministic Windows helper，讓 self-managed tier 能以 bounded launch/readiness 與 same-invocation identity-bound finalization 安全運作？若提供，最小 command surface、ownership record、stdio、readiness、graceful／forced shutdown、evidence 與測試契約為何；若不提供，哪些情境必須在 launch 前 blocked／handoff？

## Answer

提供 Windows-only deterministic helper，但只作為 verified repo／framework owner 與 verified external launcher 都不適用時的最後 fallback。它不是通用 process manager，也不吸收 workload-specific readiness、Browser QA 或持續監控責任。

### Empirical basis

[Throwaway prototype](../prototypes/08-windows-self-managed-helper/Harness.ps1) 在 Windows 11、PowerShell 7.6.4 與 OpenCode host 已位於外層 Job 的環境中證明：第一次 fresh PowerShell invocation 可建立唯一 named Job、以 suspended 狀態 assign process、隔離 stdio、等待 readiness 後返回；associated process 能讓 Job 跨 invocation 存活，第二次 fresh invocation 可重開同一 Job，驗證 ownership，並透過 retained Job handle graceful 或 forced shutdown。

實測涵蓋 cross-invocation reopen、stdout／stderr、graceful shutdown、包含 child 的 forced Job termination、unrelated sentinel 不受影響、readiness failure 在 Launch 內 cleanup，以及可觀察到 creation-time mismatch 的 record fail closed。所有情境通過，且 temporary artifacts 與 fixture processes 均完成清理。

Microsoft 的 named Job lifetime、`OpenJobObject`、child inheritance 與 `TerminateJobObject` contract 支持此設計。Prototype 是正常流程的 feasibility evidence，不是 production source：它在 readiness 後才以非 atomic write 發布 record、將 Job handle 繼承給 fixture，且只測一種 record mismatch，因此不證明 abrupt-crash safety、一般 tamper resistance 或 production graceful callback contract。後續實作必須依本契約重新收斂與審查，不得直接搬用 prototype。

本契約接受一項明確限制：不得使用 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`，因此 Launch host 若在 recoverable record 發布前 abrupt crash，可能留下沒有完整 ownership record 的 suspended process。Helper 只保證可觀察並由自身處理的 launch/readiness failure 會 cleanup，不得宣稱 host-crash-safe；callback 與 instruction 必須揭露此限制。

### Command surface

Helper 只有兩個 lifecycle action：

1. `Launch`：合併 detached launch、ownership binding、stdio redirect、bounded readiness 與 run-record write。
2. `Finalize`：接受 `Stop` 或 `Preserve` disposition，合併 ownership revalidation、handoff 或一次 owner-specific graceful stop、bounded wait、必要的 forced Job termination 與 final result。

不提供 `status`、`poll`、`retry`、`kill`、`cleanup` 或 process-discovery action。Callback 不增加第三次 shell call；失敗診斷由 action result 與 evidence paths 表達。

### Launch contract

Caller 提供 executable、argument array、working directory、stdout／stderr paths，以及一個 workload-specific readiness check 與 deadline。Helper 不內建 HTTP、port、window、compiler 或其他 workload 規則；它只 bounded 執行 caller 已選定的 check，且不得把 spawn、process alive、fixed sleep 或 port occupied 當成 ready。

Helper 先以 fresh、exclusive、受目前 Windows user ACL 保護的 record path 建立 preparing record，再產生 cryptographically random run ID 與唯一 `Local\` named Job。它以 suspended 狀態建立 root process，完成 stdio isolation、Job assignment 與 recoverable ownership binding 的 atomic update 後才能 resume；readiness 完成後再 atomic update record。Production 不把 Job handle 繼承或交付給 workload。

若 nested Job assignment、stdio handle allowlist、readiness 或 record write 無法安全完成，Launch 必須在同一次 invocation 內透過仍 retained 的 process／Job handle fail closed 並 cleanup；cleanup 未完成則回報 unresolved，不得留下看似成功的 record。由於已接受 abrupt-crash gap，host 在 atomic publish 前消失不屬於此保證。

### Ownership record

每次 Launch 建立一份 human-readable JSON record。它是 authority-bearing local capability，只保存跨 invocation finalization 必需的資料：

- schema version、run ID、Job name 與 record state。
- normalized executable、arguments 與 working directory digest／identity。
- root PID、creation time 與 image identity，僅供 membership 與 instance validation，不作 termination authority。
- stdout／stderr paths。
- readiness check identity、deadline、result 與 timestamp；不保存可供日後任意執行的 script body。
- record state、requested final disposition，以及 Preserve 完成後的 handoff owner；未發生時為空。

Record 不保存 executable graceful-stop command。Path 必須 fresh、exclusive、不可重導，所有 create／replace 都 atomic，並由 Windows ACL 限制為目前使用者；既有 record path、symlink／reparse redirection 或 concurrent Launch 一律拒絕。Schema、derived Job name、run binding、record state 或 root identity 不符時，Finalize fail closed。

此 integrity contract 防 accidental misuse、stale record 與可觀察 mismatch，不以 MAC／signature 防禦同一 Windows user security context 下可一致改寫 record 與建立同名 objects 的惡意程式；該 threat model 超出最小 helper 範圍。

### Finalize contract

Finalize 接受 `Disposition=Stop|Preserve`。`Stop` 可由 caller 在當下提供 owner-specific graceful-stop command descriptor／callback 與 grace deadline；action 不從 run record 還原，最多執行一次，且本身必須可 bounded 中止。未提供 graceful action、action 失敗或逾時時，一律允許進入 forced-only path，但 graceful action 不得以 PID／name／port 作為 termination authority。

Launch 與 Finalize 必須位於可看到同一 `Local\` object namespace 的 Windows session，並使用相容 security context。Finalize 依 record 重開 named Job 一次；Job name 只作 locator，不作 termination authority。

Finalize 以同一 live root process handle 核對 recorded PID instance 的 creation time、image identity 與 Job membership，並至少保留到 ownership decision 完成。Recorded root 必須仍是該 Job 的 member；會 daemonize、wrapper-exit 或 transfer ownership 的 command 不適用此 fallback，改用 verified owner 或 unresolved／handoff。驗證完成後必須保留同一 Job handle 直到 query、graceful wait、必要的 `TerminateJobObject` 與 empty-job wait 全部結束；不得驗證後關閉，再依 PID、name 或 port 重新取得 termination target。

Graceful stop 未提供、執行失敗或逾時時，可透過同一 retained Job handle forced terminate 該 Job tree。Record mismatch、Job 不存在、root instance 不符、membership 無法證明、Job reopen／query 失敗或 forced wait 無法確認清空時，不得 fallback 到 PID／name／port kill；結果為 unresolved／handoff。一旦 Job handle 已成功 open 並保留，之後發生同名 Job reuse 也不會改變該 handle 指向的 object。

### Preserve and callback

需要 keep-running 時仍執行第二次 `Finalize -Disposition Preserve`。它完成相同 ownership revalidation，但不執行 graceful／forced termination；它 atomic 更新 handoff owner，並交付 record、live binding、stdio paths、readiness result 與日後使用同一 helper `Finalize -Disposition Stop` 的方式。日後 Stop 屬於接手 owner 的新 cleanup task，不計入原 task 的兩次-call budget。Preserve 不等於 external owner，也不得宣稱 cleanup 完成。

兩個 action 都回傳 machine-readable result。Happy path 至少包含 action、run ID、tier、binding、stdio、readiness、final disposition 與 evidence paths；failure／blocked／preserve／handoff 額外包含 failure kind、cleanup attempt/result、unresolved reason 與 later owner。Lifecycle result 與 downstream task result 分開呈現。

### Acceptance contract

正式 helper 至少驗證：

- OpenCode host 已位於外層 Job 時，nested suspended assignment 仍能成功；失敗時 child 不會裸奔。
- Launch 與 Finalize 由兩個 fresh PowerShell invocations 執行，Job 可重開且 process 在兩者之間存活。
- stdout／stderr 不綁住 initiating call，readiness 有期限且 failure 在 Launch 內 cleanup。
- Graceful path 不使用 forced termination。
- Forced path 會清除 root 與 inherited children，但相同 command 的 unrelated sentinel 保持存活。
- Malformed／stale／mismatch record、PID reuse、missing Job、membership mismatch 與 inaccessible Job 一律 fail closed，且不嘗試 termination；另驗證 fresh exclusive path、atomic create／replace、ACL 與 redirection rejection。
- Production workload 不繼承 Job handle；Launch／Finalize 必須在相同 Windows session／相容 security context 重開 `Local\` Job。
- Root 提前退出但 child 仍留在 Job 時不做 ownership transfer，結果為 unresolved／handoff。
- `Finalize -Disposition Preserve` 不終止 process，會可信更新 later owner；之後仍可用同一 action 的 `Stop` disposition 收尾。
- 不存在 `KILL_ON_JOB_CLOSE`、PID／name／port-only kill、broad process／port scan、常態 polling 或第三個 lifecycle action。
- 每個 Stop／failure-cleanup 情境完成後沒有 fixture process、named Job 或 temporary artifact 殘留；Preserve 情境改驗證 handoff owner 與 live binding 仍有效。

Acceptance report 必須分開列出 prototype 已觀察的 facts、production contract checks 與未保證的 abrupt-host-crash／same-user malicious tamper。不得以目前四個 prototype scenarios 宣稱後兩者已通過。

若目標 Windows host 不支援上述 assignment／reopen contract，或 caller 在 Launch 前無法提供 bounded readiness、可保護的 record location 與可接受的 final disposition，self-managed tier 不合格，必須在 launch 前 blocked／handoff。
