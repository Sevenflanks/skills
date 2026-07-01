# daily-work-log

`daily-work-log` 是一個用來整理每日工作日誌的 skill。它先回想使用者或專案的蒐集偏好，再從 OpenCode 活動、git 跨 branch commit 與 GitHub PR / issue 關聯蒐集證據，最後輸出適合直接貼上的分組日誌。預設 `session` 模式會先用 `opencode db --format json` 找 session repo 證據。

## 解決的問題

當使用者要回顧「今天做了什麼」時，agent 很容易只看目前 branch、漏掉跨 repo 工作、或直接憑 commit message 猜 PR / issue 關聯。這個 skill 用固定 PowerShell helper 先產純 JSON，再由 skill 將資料壓成簡潔日誌，降低蒐集不一致與 shell 噪音。

## 使用時機

當任務需要：

- 依 OpenCode session 與 git activity 整理今日日誌。
- 優先按 GitHub repo name 分組輸出工作內容，缺少 GitHub repo name 時才 fallback 到 repo 資料夾名稱。
- 補上 PR 編號與 closing issue 關聯。
- 在 Windows / PowerShell / OpenCode 環境中，以一致方式收集工作證據。

不適用於單一 commit、單一 PR、或純文字潤稿需求。

## 主要流程

1. 蒐集前先嘗試 recall `daily-work-log`、`工作日誌`、`日誌`、current cwd、使用者提到的 repo / project、`scan root`、`repo discovery` 等偏好。若沒有可用結果，安靜使用預設流程。
2. 以 PowerShell helper 收集指定時間範圍內的 session-derived repo、git `--all` history、PR / issue 補充資料。
3. 若使用者未提供明確時間範圍，helper 會以 configured timezone 計算「今天」，預設為 `Asia/Taipei`。這裡指的是缺少明確時間範圍，不是任何空白輸入都自動觸發。若使用者需要其他 timezone、日期範圍、或掃描根目錄，應明確覆寫。
4. 在 `session` 模式，repo discovery 先查 `opencode db --format json`；若 DB 不可用、查詢失敗、或 JSON 無效，才依序 fallback 到 `storage/directory-readme` 與 OpenCode logs。
5. 若 DB 查詢成功且回傳空陣列 `[]`，代表沒有 session repo 證據，這個結果具權威性，不再 fallback 到檔案來源。
6. 若 DB 失敗且 `storage/directory-readme` 沒有找到任何可解析 git repo / worktree root 的路徑，繼續 fallback 到 OpenCode logs；log fallback 會納入可解析成 git repo / worktree root 的 `permission=external_directory`、`permission=read`、`permission=read-only` touched path 證據。
7. `session` discovery 可將安全的彙總目錄展開成巢狀 git repo / worktree。
8. 預設 `authorScope` 是 `current`；若無法解析 identity，helper 會提出 warning 並 fallback 到 all authors。
9. 目前使用者過濾採用寬鬆 identity matching；`release` / `deploy` bot commit 只有在 PR-chain 證據連回目前使用者工作時才保留。
10. 有 session evidence 但沒有目前使用者 commit 的 repo，仍會透過 `sessionEvidence` 保留在 JSON，供 agent 產生一條摘要。
11. 讓 helper 只輸出純 JSON，不混入說明文字。PowerShell collector 不產生自然語言摘要；agent 只能從 `sessionEvidence` 寫一條短摘要。
12. 由 skill 檢查 JSON 內的 warning / error / `ghAvailable` / `ghViewer` 狀態；若 `gh` 不可用或未登入，預設先停止並建議安裝 GitHub CLI 或執行 `gh auth login`。
13. 只納入可解析成 git repo 或 worktree root 的路徑，其他缺口要透過 warning 或最終註記說清楚。
14. 依 `githubRepo` 的 GitHub repo name 分組，若缺少 `githubRepo` 才 fallback 到 repo 資料夾名稱，並將內容壓成簡短工作日誌條列。
15. 只有使用者強烈堅持在沒有可用或已登入 `gh` 的環境繼續時，才產生降級日報並在最終輸出保留 PR / issue 補證缺口；repo 非 git、或今日有 session 但無 commit，也要保留資料缺口說明。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`scripts/collect-daily-work-log.ps1`](scripts/collect-daily-work-log.ps1)：資料蒐集 helper，輸出純 JSON。
- [`evals/evals.json`](evals/evals.json)：評估案例。
