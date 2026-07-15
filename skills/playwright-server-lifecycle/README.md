# playwright-server-lifecycle

`playwright-server-lifecycle` 是一個 browser / Playwright 驗證輔助 skill，管理本機 listener 的分類、process ownership tree、browser 結果與失敗安全的 cleanup，避免 agent session 卡住或留下殘留 process。

## 解決的問題

在 Windows、PowerShell、OpenCode shell 或類似環境中，任何本機 listener 都可能阻塞 agent session 或留下不清楚的 process 狀態，包含 temporary HTTP server、static viewer、dev server 與 preview server。以前景方式執行或以 timeout 假裝背景執行，都不能視為安全的啟動方式。

此 skill 以三個閘門管理本次執行的資源：先分類 listener，再分開回報 browser 是否完成與是否通過，最後在 `finally` 中回收可證明屬於本次的 ownership tree 並確認 port 已釋放。

## 使用時機

當任務需要：

- 使用 Playwright 或 browser automation 驗證 UI。
- 啟動本機 listener、temporary HTTP server、static viewer、dev server 或 preview server 才能截圖、檢查登入頁或做 smoke test。
- 在 Windows／PowerShell／OpenCode shell 中操作長時間前景命令。
- 管理 launcher、wrapper、listener 的 PID、port、stdout / stderr log、process ownership 與 cleanup recovery。

不適用於有限時間會自行結束的命令，例如 `pnpm build`、`pnpm test`、`mvn test`。

## 三個閘門

### 1. 建立 listener 前先分類

先判斷目標是否真的需要 listener。self-contained static HTML 優先用 `file://` 直接開啟。需要 listener 時，先檢查目標 port 與既有 owner，只有符合使用者意圖時才重用外部 process，絕不納入 cleanup。以 detached 方式啟動本次 listener，並記錄命令、launcher、wrapper、listener、port 與 log，建立本次的 ownership tree。

### 2. 分開回報 browser 結果

browser 操作完成不代表驗證通過。報告必須分開列出 `completed` 與 `passed`，並將 console、page 與 network errors 分為 blocking 和 non-blocking。阻斷成功條件的錯誤會使 `passed=false`，即使導覽、互動或截圖已完成。

### 3. 在 `finally` 中清理並回呼

無論 readiness、browser 驗證或 cleanup 是否失敗，都先關閉 browser，再只回收可由記錄證明屬於本次的 launcher、wrapper 與 listener。確認 port 已釋放，保留無法證明 ownership 或未釋放 port 的命令、PID、owner 與 log 證據。最後回呼時必須包含 browser 結果、錯誤分類、process 最終狀態、port release 與未解決項目。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`evals/evals.json`](evals/evals.json)：評估案例。
