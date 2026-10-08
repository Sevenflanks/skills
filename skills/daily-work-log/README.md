# daily-work-log

`daily-work-log` 整理 OpenCode／Codex 活動、Git 跨 branch commits 與相關 GitHub PR／issue 證據。先以同一 collector 輕量 probe，由 agent 預告來源與略過原因，再正式蒐集並輸出適合貼上的主題分組日誌。

## 解決的問題

當使用者要回顧「今天做了什麼」時，agent 很容易只看目前 branch、漏掉跨 repo 工作、或直接憑 commit message 猜 PR / issue 關聯。這個 skill 用固定 PowerShell helper 先產純 JSON，再由 skill 將資料壓成簡潔日誌，降低蒐集不一致與 shell 噪音。

## 使用時機

當任務需要：

- 依 OpenCode 或 Codex session 與 Git activity 整理指定日期的日誌。
- 優先按 GitHub repo name 分組輸出工作內容，缺少 GitHub repo name 時才 fallback 到 repo 資料夾名稱。
- 補上 PR 編號與 closing issue 關聯。
- 在 Windows / PowerShell / OpenCode 環境中，以一致方式收集工作證據。

不適用於單一 commit、單一 PR、或純文字潤稿需求。

## 主要流程

1. 蒐集前先嘗試 recall `daily-work-log`、`工作日誌`、`日誌`、current cwd、使用者提到的 repo / project、`scan root`、`repo discovery` 等偏好。若沒有可用結果，安靜使用預設流程。
2. 執行 collector `-ProbeOnly`；只檢查已知紀錄入口與 CLI 是否存在，不掃歷史、不執行 CLI、不讀 auth／config。根據 JSON 在對話預告本次來源與略過理由，再移除 `-ProbeOnly` 正式蒐集。兩來源皆可用就合併。
3. 若使用者未提供明確時間範圍，helper 會以 configured timezone 計算「今天」，預設為 `Asia/Taipei`。這裡指的是缺少明確時間範圍，不是任何空白輸入都自動觸發。若使用者需要其他 timezone、日期範圍、或掃描根目錄，應明確覆寫。
4. OpenCode 先查 `opencode db --format json`；若 DB 不可用、查詢失敗、或 JSON 無效，才依序 fallback 到 `storage/directory-readme` 與 OpenCode logs。沒有 CLI 但本機紀錄可讀仍可用。
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

## 多來源與停止條件

Codex 讀取 `-CodexRoot`（否則 `CODEX_HOME`，再否則 `~/.codex`）中的 `sessions` 與 `archived_sessions`。按事件 `timestamp` 比對指定範圍，包含跨日續行；不能按檔名或 mtime 篩掉舊檔。collector 合併精確 event／response 鏡像、父子重播與相同 session ID 續行，保留來源 session IDs、檔案與時間證據。跨來源的同 repo／工作主題由 agent 合併成一條日誌，不刪來源證據、不自造 NLP。

JSON `meta.sources` 分別回報 OpenCode／Codex 的可用性、CLI 存在、入口原因與 `readStatus`：

| 狀態 | 意義 |
| --- | --- |
| `unavailable` | 無可用入口；說明略過理由。 |
| `not-read` | probe 尚未正式讀取，不能推論當日活動。 |
| `empty` | 正式讀取成功，但範圍內無活動。 |
| `success` | 讀取成功且有範圍內證據。 |
| `partial` | 部分紀錄失敗，使用已讀證據並揭露缺口。 |
| `failed` | 正式讀取失敗，不能當成無活動。 |

`meta.collectionStatus=no-sources` 或 `read-failed` 時停止，不掃 Git／GitHub、不產生日誌；直接呼叫 collector 同樣受 guard 保護。`no-activity` 只說明沒有當日證據。正式 collection 的 `meta.canGenerateLog=false` 或 `errors` 也不得憑記憶補日誌。部分來源成功可繼續，但指出讀取／略過缺口。

`scan`／`mixed` 保留原有跨 branch Git、worktree、current-author 與相關 PR 補證；也須先通過來源 guard。Codex 只有 CLI、沒有本機紀錄時略過。這個 skill 不自動安裝／登入 CLI、不修改來源資料、不新增其他 agent 來源。

## 執行與驗證

```powershell
pwsh -NoProfile -File "<skill>\scripts\collect-daily-work-log.ps1" -ProbeOnly
# agent 在對話預告，再將 probe meta.from/to 固定傳入正式 collection。
pwsh -NoProfile -File "<skill>\scripts\collect-daily-work-log.ps1" -From "<probe-from>" -To "<probe-to>"
```

`-OpenCodeLogRoot`、`-OpenCodeStorageRoot`、`-CodexRoot` 可覆寫紀錄入口；collector／formatter stdout 均為純 JSON。formatter 保留新增 metadata 與全部 `sessionEvidence`，只對 shown commits 做上限 compaction。

合成測試隔離全部入口與 CLI，不讀真實 transcripts。新增多來源 tests 使用 Git／GitHub 公開邊界 stub；既有 Pester 回歸使用合成 Git repo 與 OpenCode／GitHub CLI stub，驗證 `--all`、作者過濾與 PR 關聯。

```powershell
pwsh -NoProfile -File skills/daily-work-log/tests/multi-source.tests.ps1 -Case all
Invoke-Pester -Script skills/daily-work-log/tests/collect-daily-work-log.tests.ps1
npm run validate
```

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`scripts/collect-daily-work-log.ps1`](scripts/collect-daily-work-log.ps1)：資料蒐集 helper，輸出純 JSON。
- [`evals/evals.json`](evals/evals.json)：評估案例。
- [`tests/multi-source.tests.ps1`](tests/multi-source.tests.ps1)：來源組合、停止條件、Codex 跨日／archive／去重與 formatter 合成測試。
- [`tests/collect-daily-work-log.tests.ps1`](tests/collect-daily-work-log.tests.ps1)：既有 OpenCode、Git／PR 與 formatter 回歸。
