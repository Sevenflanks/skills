# daily-work-log

`daily-work-log` 是一個用來整理每日工作日誌的 skill。它先從本機 OpenCode 活動、git 跨 branch commit 與 GitHub PR / issue 關聯蒐集證據，再輸出適合直接貼上的分組日誌。

## 解決的問題

當使用者要回顧「今天做了什麼」時，agent 很容易只看目前 branch、漏掉跨 repo 工作、或直接憑 commit message 猜 PR / issue 關聯。這個 skill 用固定 PowerShell helper 先產純 JSON，再由 skill 將資料壓成簡潔日誌，降低蒐集不一致與 shell 噪音。

## 使用時機

當任務需要：

- 依 OpenCode session 與 git activity 整理今日日誌。
- 按 repo / 資料夾名稱分組輸出工作內容。
- 補上 PR 編號與 closing issue 關聯。
- 在 Windows / PowerShell / OpenCode 環境中，以一致方式收集工作證據。

不適用於單一 commit、單一 PR、或純文字潤稿需求。

## 主要流程

1. 以 PowerShell helper 收集指定時間範圍內的 session-derived repo、git `--all` history、PR / issue 補充資料。
2. 讓 helper 只輸出純 JSON，不混入說明文字。
3. 由 skill 檢查 JSON 內的 warning / error / `ghAvailable` 狀態。
4. 依 repo 資料夾名稱分組，將內容壓成簡短工作日誌條列。
5. 若 `gh` 不可用、repo 非 git、或今日有 session 但無 commit，要在最終輸出保留資料缺口說明。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`scripts/collect-daily-work-log.ps1`](scripts/collect-daily-work-log.ps1)：本機資料蒐集 helper，輸出純 JSON。
- [`evals/evals.json`](evals/evals.json)：評估案例。
