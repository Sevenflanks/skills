# 定義 lifecycle skill 的適用邊界

Type: grilling
Status: resolved
Blocked by: none

## Question

哪些由 Agent 啟動、預期跨越 initiating tool call 的本機 process 應由 lifecycle skill 管理？listener、GUI、watcher、有限時間 command，以及由 IDE、Playwright、Docker 或外部使用者完整管理的 service，應如何用可觀察條件劃分包含與排除邊界？

## Answer

適用邊界以 lifecycle ownership 為主，不以 process 類型、是否開 port 或預估執行時間為主。`initiating tool call` 是促成 process 啟動的 Agent tool invocation；若該 invocation 返回、逾時或中止後 process 仍可能存活，就視為跨越該 call。後續 ticket「定義 non-Windows self-managed guidance 深度」將 `1.0.0` 官方 compatibility 收斂為 Windows-only：以下直接管理規則只在 Windows 執行；non-Windows 只做不含 OS inspection 或 lifecycle shell call 的 bounded owner classification，之後 handoff 或在 launch 前 blocked。

### Windows 納入直接管理

- Agent 促成本機 OS process 啟動，預期它會跨越 initiating tool call，且沒有其他具可驗證完整 lifecycle contract 的 owner。
- Agent 刻意背景化或 detach 的有限時間 job；自然完成時驗證 exit、結果與無殘留，只有取消、逾時或失去控制時才 termination。
- Agent-owned listener、GUI、watcher 與 background worker；它們共用 ownership 邊界，但各自使用 port/HTTP、window/process tree、首次成功編譯或 job state 等合適的 readiness 與 completion evidence。
- 使用者要求 keep-running 的 current-run process；它仍是 Agent-owned，必須 preserve 並交付 live identity、evidence 與 later-cleanup owner，直到明確 handoff 才改變 ownership。
- 原本應結束卻意外留下的 process、listener、wrapper、GUI、zombie，或造成 session 卡住、ownership 不明的 process；這是事後調查與 reconciliation 入口。

### 分類後 handoff

- Agent 準備啟動重複 service、reuse 既有 service、處理 port 衝突、preserve 或考慮 termination 時，先做 ownership 分類。
- 由使用者、IDE 或其他外部 owner 啟動的既有 process，一旦證明為 external，就不得納入 current-run cleanup 或 termination。
- Playwright runner 或其他 framework 只有在這次實際 mode/config 能證明涵蓋 start、readiness、failure cleanup 與 shutdown 時，才取得完整 ownership；若 contract 不完整，或結束後仍留下 process，ownership 回到 Agent。
- Docker container、Kubernetes workload、WSL service、Windows Service、systemd unit 等 runtime-managed resource 不使用本 skill 的 PID-based 直接管理；本 skill 只辨認 ownership 並 handoff 給對應 runtime 或專用 skill。在 Windows 上，本機 launcher CLI 若本身意外殘留，仍可按本機 OS process 處理；non-Windows 則只分類並 handoff。

### 排除

- 預期在 initiating tool call 內完成、且 call 直到 exit 才返回的同步 command；執行很久本身不構成納入理由。
- Agent 只是連線、測試或觀察已由外部 owner 完整管理的 service，且不涉及 start、reuse、port collision、preserve 或 termination 決策。
- 具可驗證完整 lifecycle contract 的 framework-owned process，以及已 handoff 的 orchestrated resource。

Tool timeout 不等於 detachment，也不證明 process 已退出。任何事後 reconciliation 都必須以可驗證 ownership 為 termination 前提；PID、port 或 process name 單獨不足以證明 ownership，無法證明時應保留 evidence 並回報 unresolved。
