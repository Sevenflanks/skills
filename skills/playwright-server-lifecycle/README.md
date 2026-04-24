# playwright-server-lifecycle

`playwright-server-lifecycle` 是一個 browser / Playwright 驗證輔助 skill，用來避免 agent 為了看 UI 而以前景模式啟動 dev server，導致 session 卡住或留下殘留 process。

## 解決的問題

在 Windows、PowerShell、OpenCode shell 或類似環境中，直接執行 `pnpm dev`、`npm run dev`、`nuxt dev`、`vite`、Tomcat 等長時間 server，常會阻塞 agent session。即使用 timeout 中斷，也可能留下不清楚的 port / process 狀態。

此 skill 會要求 agent 將 server 視為需要 lifecycle 管理的資源：啟動前檢查、背景啟動、記錄 PID/port/log、用 Playwright 驗證、結束後停止並確認 port 釋放。

## 使用時機

當任務需要：

- 使用 Playwright 或 browser automation 驗證 UI。
- 啟動本機 dev server 才能截圖、檢查登入頁或做 smoke test。
- 在 Windows／PowerShell／OpenCode shell 中操作長時間前景命令。
- 管理 server 的 stdout/stderr log、PID、port 與 cleanup。

不適用於有限時間會自行結束的命令，例如 `pnpm build`、`pnpm test`、`mvn test`。

## 主要流程

1. 啟動前先確認目標 port 是否已被占用。
2. 若需啟動 server，使用背景／detached process，不要直接以前景執行 dev server。
3. 將 stdout/stderr 導到 log 檔，並記錄 launcher PID 與 listener PID/port。
4. 以 port 或 HTTP endpoint 輪詢 ready 狀態，不用固定 sleep 猜測。
5. 用 Playwright 驗證 URL、標題、可見文字、console/network 狀態或截圖。
6. 關閉 browser/page。
7. 停止本次啟動的 server，確認 port 已釋放。
8. 清理暫存 screenshot、MCP output 或測試 log，除非使用者要求保留。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`evals/evals.json`](evals/evals.json)：評估案例。
