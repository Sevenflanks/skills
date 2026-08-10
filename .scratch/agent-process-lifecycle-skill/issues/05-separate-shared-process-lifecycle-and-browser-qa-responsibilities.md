# 劃分共用 process lifecycle 與 browser QA 責任

Type: grilling
Status: resolved
Blocked by: 01, 03

## Question

根據適用邊界與啟動策略，ownership、stdio isolation、readiness、cleanup 與 callback 哪些應是共用 process lifecycle 核心？`completed`/`passed`、blocking errors、Playwright `webServer` 與 janitor 等哪些只屬於 browser QA guidance？

## Answer

`agent-process-lifecycle` 只管理 process resource lifecycle，不管理 Browser QA。責任以 resource outcome 與 downstream work outcome 分界，不以是否使用 browser 分界。

### Lifecycle core responsibility

Core 負責 ownership classification、strategy tier、stdio isolation、bounded readiness 流程、event-based observation、shutdown、cleanup／preserve／handoff、reconciliation 與 lifecycle callback。七類 outcome 是結果責任，不是每次逐項執行的 gates；verified owner 可一次滿足多項 outcome，只有 self-managed 與 failure path需要 OS-level work。

- Caller 提供 workload-specific readiness signal，例如 URL、window、首次成功編譯或 job state；core 負責 signal 有 deadline、結果被記錄，且 spawn／存活不被誤當 ready。
- Cleanup／reconciliation 必須有明確 owner，但不要求存在名為 janitor 的 helper。Deterministic helper 是否值得提供，改由獨立 ticket 決定。
- Caller 自行關閉 browser、page 或其他 downstream resource；無論 caller finalization 成功或失敗，都必須繼續 lifecycle cleanup。Core 不執行 `browser_close`。
- Lifecycle callback 只回報 tier、current-run binding、stdio、readiness、final disposition、cleanup／preserve／handoff 與 unresolved items。Caller 保留自己的 task／QA 結果，最終回報並列兩者；lifecycle 不覆寫 downstream result，但 unresolved lifecycle 不得被宣稱為整體 clean completion。

### Browser QA removed

從 revised skill 完整移除 success criteria、`completed`／`passed`、blocking／non-blocking browser errors、URL／screen／accessibility evidence sufficiency、screenshot、console／page／network QA verdict 與 browser close sequencing。本 map 不把這些規則搬到另一個 skill，也不建立新的 Browser QA owner；未來若有實證需求，另開 effort。

這些規則並非完全重複官方 Playwright MCP：官方提供 [assertions](https://playwright.dev/mcp/tools/assertions)、[screenshots](https://playwright.dev/mcp/tools/screenshots)、[console](https://playwright.dev/mcp/tools/console) 與 [network](https://playwright.dev/mcp/tools/network-mocking) 等操作和蒐證能力，但不定義 `completed`／`passed`、blocking severity、evidence sufficiency 或通用 final QA verdict。移除的理由是責任位置不屬於 lifecycle，而不是它們毫無用途；本次接受暫時不再由通用 skill 保證該 reporting policy。

### Playwright webServer boundary

`Playwright webServer` 只保留為 verified framework owner 的具體例子，不作為 Browser QA guidance。Core 要求依 current mode/config 確認 start、readiness、failure cleanup 與 shutdown contract；Playwright 本次啟動的 server 可標記 `owner handled`，`reuseExistingServer` 找到的既有 server 則屬 external owner，不得納入 current-run cleanup。Generic skill 不教 Playwright config、browser 操作或 QA verdict。

### Execution budget

- 同步 command 或 verified repo／framework owner：不增加 lifecycle shell call或 OS inspection。
- Verified launcher：使用其正式 lifecycle interface，不建立底層 PID dossier。
- Self-managed happy path：最多兩次 lifecycle shell call；第一次合併 detached launch、最小 identity record、stdio redirect 與 bounded readiness，第二次執行 shutdown／finalize。
- Callback 不增加 shell call。只有 readiness failure、owner conflict、unexpected exit、wrapper ambiguity、shutdown timeout 或 cleanup mismatch 才增加一次 targeted diagnostic／reconciliation；不做 per-command audit、常態 polling、廣泛 port scan 或 process-tree scan。
- One-shot PowerShell 無法跨 tool calls 保留 live process handle。Forced termination 只有在同一次 finalizer invocation 內能以經驗證 primitive 維持 identity-bound validation-to-termination 時可用；否則 preserve evidence 並 handoff，不得退化成 PID／name／port-only kill。

此 budget 服務本 skill 的主要目的：避免 long-lived foreground process 卡住 Agent，同時讓 managed happy path 幾乎沒有額外成本，將較高證據成本限制在真正危險的 self-managed 或 failure path。
