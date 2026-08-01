# agent-process-lifecycle

版本 `1.0.0`，Windows-only execution。這是處理 Agent 所造成之本機 OS process lifecycle decision 的 skill，不是 generic process manager，也不判定 downstream workload 是否成功。

## 解決的問題

當 Agent 啟動的 local process 可能跨越 initiating tool call，或需要處理 ownership、readiness、Stop、Preserve、handoff 與 reconciliation 時，本 skill 提供一致的責任判定。它避免把同步命令、外部 owner 或不具足夠 identity evidence 的資源誤當成可安全管理的 current-run resource。

## 使用時機

當 foreground local command 可能 hang 或超出 initiating tool call，或 Agent-started process 需要 cleanup、reconciliation、保留或責任轉移時使用。Windows 先選第一個 viable tier：verified managed lifecycle、verified external launcher、Windows self-managed helper，最後才是 blocked 或 handoff。

## 不適用情境

同步等到正常 exit 才返回的 command 不適用。若 prompt 已明確指出 framework、IDE、Kubernetes、Docker、Windows Service、CI 或其他 external／runtime owner，且完整 lifecycle contract 已知，也不由本 skill 接管。本 skill 不負責 Browser QA、page、screenshot、console、network 與 downstream success policy，這些由 caller 負責。

## 平台與 execution tier

`1.0.0` 只支援 Windows execution。non-Windows 只做分類與 bounded owner classification：可辨識 owner 時交付 handoff，否則在 launch 前 blocked；不做 OS inspection、lifecycle shell call、launch 或 termination。

Tier 不競速。上一 tier 必須先完成 Stop、Preserve、handoff 或 unresolved reconciliation，才可考慮下一 tier。Caller 必須提供 workload-specific readiness signal 與 deadline，不能以 spawn、process alive、fixed sleep 或 port occupied 代替 readiness。

## Stop、Preserve 與 handoff

Launch 前先決定 `Stop` 或 `Preserve`。`Stop` 必須有 identity-bound final disposition 與 live ownership proof。`Preserve` 必須指定 later-cleanup owner 與 handoff contract，交付 fresh binding、record、stdio、readiness 與日後 Stop 方法。兩者都無法成立時，結果是 blocked、handoff 或 unresolved。

## Windows self-managed helper

Self-managed helper 是前兩個 tier 不可用時的 Windows fallback。它隱藏 Job、ACL、atomic record、PID identity 與 retained handle 的複雜度，且只有兩個 public helper actions：`Launch` 與 `Finalize`。`Stop` 與 `Preserve` 是 `Finalize` 的 dispositions，不是額外 action。Caller 仍擁有 workload-specific readiness 語意與 deadline。

## 檔案

- [README.md](README.md)
- [SKILL.md](SKILL.md)
- [evals/evals.json](evals/evals.json)
- [references/failure-and-handoff.md](references/failure-and-handoff.md)
- [references/windows-self-managed.md](references/windows-self-managed.md)
- [scripts/Invoke-AgentProcessLifecycle.ps1](scripts/Invoke-AgentProcessLifecycle.ps1)
- [scripts/JobHandleHolder.ps1](scripts/JobHandleHolder.ps1)

## 驗證證據與限制

Ticket 16 的 model-visible evidence、Ticket 17 的 routing release gate 與 Windows helper acceptance evidence 均重用，publication preflight 不重跑或重算。`npm run validate` 只做 structural consistency validation，不能取代 routing、runtime safety 或 responsibility boundary gates。

本 inventory 不保證 Windows self-managed `Launch` 完成 recoverable record atomic publication 前發生的 abrupt host crash 能自動恢復或判定所有狀態，也不保證能抵抗 same-user malicious tamper。這些是明確 non-guarantees；這不是對 Ticket 18 inventory publication runtime 的保證。
