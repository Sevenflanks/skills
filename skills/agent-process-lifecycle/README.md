# agent-process-lifecycle

版本 `1.1.1`，Windows-only execution。這是處理 Agent 所造成之本機 OS process lifecycle decision 的 skill，不是 generic process manager，也不判定 downstream workload 是否成功。

## 解決的問題

當 Agent 啟動的 local process 可能跨越 initiating tool call，或需要處理 ownership、readiness、Stop、Preserve、handoff 與 reconciliation 時，本 skill 提供一致的責任判定。它避免把同步命令、外部 owner 或不具足夠 identity evidence 的資源誤當成可安全管理的 current-run resource。

## 使用時機

當 foreground local command 可能 hang 或超出 initiating tool call，或 Agent-started process 需要 cleanup、reconciliation、保留或責任轉移時使用。Windows 先選第一個 viable tier：verified managed lifecycle、verified external launcher、Windows self-managed helper，最後才是 blocked 或 handoff。

## 不適用情境

只有所有工作都正常結束、沒有需管理 descendant 的同步 command 不適用。短命 CLI exit 0 或 HTTP 202 不證明 child exit；若 launcher 退出後仍有 child，需選可覆蓋 child 的 owner binding。若 prompt 已明確指出 framework、IDE、Kubernetes、Docker、Windows Service、CI 或其他 external／runtime owner，且完整 lifecycle contract 已知，也不由本 skill 接管。本 skill 不負責 Browser QA、page、screenshot、console、network 與 downstream success policy，這些由 caller 負責。

## 平台與 execution tier

`1.1.1` 只支援 Windows execution。non-Windows 只做分類與 bounded owner classification：可辨識 owner 時交付 handoff，否則在 launch 前 blocked；不做 OS inspection、lifecycle shell call、launch 或 termination。

Tier 不競速。上一 tier 必須先完成 Stop、Preserve、handoff 或 unresolved reconciliation，才可考慮下一 tier。Caller 必須提供 workload-specific readiness signal 與 deadline，不能以 spawn、process alive、fixed sleep 或 port occupied 代替 readiness。

## Stop、Preserve 與 handoff

Launch 前先決定 `Stop` 或 `Preserve`。`Stop` 必須有 identity-bound final disposition 與 live ownership proof。`Preserve` 必須指定 later-cleanup owner 與 handoff contract，交付 fresh binding、record、stdio、readiness 與日後 Stop 方法。兩者都無法成立時，結果是 blocked、handoff 或 unresolved。

短命 launcher 的暫時 Stop 路由在同一 tool 的 `finally` 依已驗證 binding 清理，readiness 失敗、cancel、interrupt 仍需 reconciliation；測試另有不依賴 shell timeout 或 `finally` 的 bounded fixture lifetime。Preserve 還需 caller 已觀察到此 route 的 host tool 在 child 活著時返回；shell-end 不是 host completion，缺此證據時 launch 前 block/handoff，不改成 Stop。單次 probe 失敗不表示 OS exit，lifecycle/downstream 結果各自回報。

## Windows self-managed helper

Self-managed helper 是前兩個 tier 不可用時的 Windows fallback。它隱藏 Job、ACL、atomic record、PID identity 與 retained handle 的複雜度，且只有兩個 public helper actions：`Launch` 與 `Finalize`。`Stop` 與 `Preserve` 是 `Finalize` 的 dispositions，不是額外 action。Caller 仍擁有 workload-specific readiness 語意與 deadline。

`1.1.1` 允許 record 與 stdio 使用 caller 已獲授權的專案內 artifact 目錄，不要求 home-scoped 初始化或完整 ancestor ACL audit，也不修改既有 ACL。Launch 會同時等待 workload-specific readiness 與本次保留的 root handle；candidate early exit 與可辨識的 bind error 會在 deadline 前帶回 bounded stderr evidence，並只清理本次 owned resource。短命 launcher 已退出時不能靠 helper 的 root binding 推測 child ownership。

## 檔案

- [README.md](README.md)
- [SKILL.md](SKILL.md)
- [evals/evals.json](evals/evals.json)
- [references/failure-and-handoff.md](references/failure-and-handoff.md)
- [references/windows-self-managed.md](references/windows-self-managed.md)
- [scripts/Invoke-AgentProcessLifecycle.ps1](scripts/Invoke-AgentProcessLifecycle.ps1)
- [scripts/JobHandleHolder.ps1](scripts/JobHandleHolder.ps1)
- [tests/project-lifecycle.integration.test.ps1](tests/project-lifecycle.integration.test.ps1)
- [tests/project-lifecycle-failures.integration.test.ps1](tests/project-lifecycle-failures.integration.test.ps1)
- [tests/short-cli-descendant.regression.test.ps1](tests/short-cli-descendant.regression.test.ps1)
- [tests/fixtures/short-cli-descendant.cjs](tests/fixtures/short-cli-descendant.cjs)

## 短命 CLI 的可重現診斷

`pwsh -NoProfile -File skills/agent-process-lifecycle/tests/short-cli-descendant.regression.test.ps1` 會執行全同步 baseline、短命 CLI 留下真實 loopback child、同 tool `finally` 的 Stop，及模擬 cancel/readiness failure 的 reconciliation。它會驗證錯誤 owner token 不可停止 child、`child-exit-intent.json` 出現時不可宣稱 OS exit、持續開啟的 socket 不妨礙 child 到期退出。同 tool 保留已核對的 Process handle，有限 `WaitForExit` 確認實際退出後才清理本次目錄；沒有確認則保留證據。fixture token 僅是受控測試的 cooperative owner method，不代表產品環境的 ownership authority。child 的 `FixtureLifetimeMilliseconds` 預設 8000，只是測試中斷時的獨立上限，非產品程序壽命。

若需診斷**目前 host** 的 Preserve 可行性，另在欲驗證的 host/tool route 執行 `pwsh -NoProfile -File skills/agent-process-lifecycle/tests/short-cli-descendant.regression.test.ps1 -Scenario HostDiagnostic -FixtureLifetimeMilliseconds 8000`。紀錄 caller 收到**整個 tool result** 的時間，於 tool 返回時核對輸出目錄中 `process-identity.json` 的 PID 與 OS 上的 process start time、確認 child 尚活著；`shell-end.json` 或 `child-exit-intent.json` 都不證明 host completion／OS exit。即使某次 tool 在 child 活著時返回，也需先確認 later owner 和 Stop 才能規劃 Preserve；若直到 child 的 bounded exit 才返回，該 route 應在 launch 前 block/handoff。diagnostic 的 child 自行屆期，待 `child-exit-intent.json` 出現後，以命令輸出的 `-Scenario CleanupDiagnostic -DiagnosticRoot '<exact root>'` 核對原 process OS 已退出並清理；原 PID 若被重用、creation time 不符或無法核對，保守保留證據。本診斷不推論所有 host 的行為，也不使用 shell timeout 當 detach 或 cleanup。

## 驗證證據與限制

Ticket 16 的 model-visible evidence、Ticket 17 的 routing release gate 與 Windows helper acceptance evidence 均重用，publication preflight 不重跑或重算。`npm run validate` 只做 structural consistency validation，不能取代 routing、runtime safety 或 responsibility boundary gates。

本 inventory 不保證 Windows self-managed `Launch` 完成 recoverable record atomic publication 前發生的 abrupt host crash 能自動恢復或判定所有狀態，也不保證能抵抗 same-user malicious tamper。這些是明確 non-guarantees；這不是對 Ticket 18 inventory publication runtime 的保證。
