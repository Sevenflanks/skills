# Daily Work Log Collection Generalization Design

**日期**: 2026-07-01
**目標 skill**: `daily-work-log`
**目標 repo**: `C:\develop\projects\@sevenflanks-skills`

## 目標

將 `daily-work-log` 的蒐集流程泛化，避免未來只靠 agent 臨場記憶補救，並維持 skill 不硬編特定使用者或專案規則。

本次修正三個缺口：

1. 蒐集前先嘗試 recall 使用者或專案對工作日誌的既有偏好。
2. `session` 模式遇到聚合目錄時，自動展開底下的 git repo / worktree。
3. 個人日誌預設只納入目前使用者相關 commit / PR，避免混入同 repo 其他人的工作。

## 背景

2026-06-30 蒐集今日工作日誌時，預設 `session` mode 沒有列出 `jasmine-scins-ah-2026` 相關工作。原因是 `C:\develop\projects\jasmine-scins-ah-2026` 是聚合目錄，不是單一 git repo；實際 repo 位於底下，例如 `jasmine-calculate`、`jasmine-scins-ah-ui`、`jasmine-scins-ah` 與 `.worktrees`。

手動補跑以下命令後才取得完整結果：

```powershell
pwsh -NoProfile -File "<skill>\scripts\collect-daily-work-log.ps1" `
  -SourceMode mixed `
  -ScanRoots "C:\develop\projects\jasmine-scins-ah-2026"
```

補掃結果也揭露第二個問題：部分 repo 內同日有其他作者或 bot 的 commit，直接列入會讓「我的工作日誌」混入非本人工作。

## 設計原則

1. **source of truth 留在 collector**：repo discovery 與 author filtering 應在 JSON 蒐集層完成，不只靠最終摘要階段人工篩選。
2. **skill 泛化，不硬編個人資料**：使用者偏好放在 recall / memory；`SKILL.md` 只要求嘗試查詢與套用，不內建專案名稱。
3. **預設符合個人日誌**：沒有額外參數時，輸出應偏向目前使用者自己的工作，而不是同 repo 的所有活動。
4. **快速查找聚合 repo**：遇到非 git session 目錄時，用快速檔案搜尋找 `.git` marker，不在 PowerShell 內自行逐層遍歷整棵目錄樹。
5. **失敗不阻塞**：recall、identity 解析、聚合目錄展開任一項失敗時，collector 仍輸出合法 JSON，並以 warning 說明降級。

## 方案選擇

採用 **collector-first 泛化**。

不採用純文件引導，因為「記得加 `ScanRoots`」和「摘要時排除他人 author」都容易被未來 agent 漏掉，也會讓 helper JSON 不再是乾淨的 source of truth。

不採用預設不變的新參數方案，因為日報的預設語意就是「我的工作日誌」。若每次都要 agent 記得帶參數，問題仍會重現。

## 設計

### A. Pre-collection Recall Workflow

更新 `skills/daily-work-log/SKILL.md`，在「Confirm scope and defaults」之前新增 recall 步驟。

agent 在執行 collector 前應嘗試查詢既有記憶或使用者偏好，查詢詞至少包含：

- `daily-work-log`
- `工作日誌`
- `日誌`
- 目前工作目錄
- 使用者提到的 repo / project name
- `scan root`
- `repo discovery`

行為規則：

1. 有命中時，將偏好轉成 collector 參數或摘要規則。例如補 `-SourceMode mixed -ScanRoots <root>`，或記錄某專案需要額外 scan root。
2. 無命中、memory 工具不可用、或查詢失敗時，不報錯、不阻塞，直接走原本 collector 流程。
3. recall 結果只能作為使用者 / 專案偏好，不應覆蓋 helper 的安全邊界與 JSON source-of-truth 原則。
4. `SKILL.md` 不記錄任何特定專案名稱；實例可放 eval 或測試 prompt，但不成為通用規則。

### B. Bounded Session Directory Expansion

更新 `skills/daily-work-log/scripts/collect-daily-work-log.ps1`。

在 `session` / `mixed` 模式中，當 session source 取得的 path 符合以下條件時，視為「可能的聚合目錄」：

1. path 存在。
2. path 是資料夾。
3. path 本身不是 git repo / worktree root。
4. path 通過安全邊界檢查。

通過後，collector 會在該資料夾底下尋找 nested repo / worktree，並將結果加入 repo candidates。source 建議標記為 `session-expanded`，保留與一般 `scan` 來源的區別。

#### 快速查找 `.git` marker

展開聚合目錄時，不應由 PowerShell 自行遞迴遍歷目錄樹。

推薦流程：

1. 優先用 `rg` 查找 `.git` marker，例如概念上等價於：

   ```powershell
   rg --files -uu -g .git <session-directory>
   ```

2. 若 `rg` 不可用，才 fallback 到受限的 PowerShell 掃描。
3. 每個 `.git` marker 取 parent directory。
4. 對 parent directory 呼叫 `git rev-parse --show-toplevel` 驗證 repo / worktree root。
5. 驗證成功才加入候選。

這個設計的目的不是指定唯一命令字串，而是要求實作使用成熟快速搜尋工具作為主要 traversal，避免 PowerShell 腳本自行維護大量遞迴與排除邏輯。

#### 安全邊界

聚合目錄展開必須有以下保護：

- 不掃磁碟根，例如 `C:\`。
- 不掃使用者 home root，例如 `C:\Users\<user>`。
- 不掃明顯過大的通用工作根，除非使用者明確提供 `-ScanRoots`。
- 限制最大結果數，例如超過上限就停止並 warning。
- 排除高噪音目錄：`node_modules`、`.output`、`dist`、`build`、`target`、`.gradle`、`.mvn`、`.nuxt`、`.next`。
- 對不可解析或被安全邊界拒絕的 session path 聚合 warning，不逐一路徑噴大量訊息。

#### 與既有 scan 的關係

`scan` / `mixed` 既有 `Get-ScanRepositories` 可保留，但應共用 repo root 驗證與去重邏輯。

若可行，可抽出共用函式：

- `Find-GitMarkersFast`
- `Resolve-GitRepoRoot`
- `Test-SafeExpansionRoot`
- `Get-NestedGitRepositories`

### C. Current Identity Author Filtering

更新 collector，讓個人日誌預設只保留目前使用者相關 evidence。

#### Identity 解析

collector 應建立目前使用者 identity set，來源包含：

1. `gh api user --jq .login`
2. `gh api user --jq .name`，若可用
3. `git config user.name`
4. `git config user.email`

輸出 metadata 建議新增：

```json
{
  "meta": {
    "authorScope": "current",
    "currentIdentity": {
      "ghLogin": "...",
      "gitName": "...",
      "gitEmail": "..."
    }
  }
}
```

若 identity 完全無法解析，collector 應保留舊行為並 warning：`Current author identity could not be resolved; author filtering was not applied.`

#### Commit filtering

`Get-CommitData` 應把 git log format 從 author name 擴充為 author name + author email：

```text
%H%x1f%h%x1f%aI%x1f%an%x1f%ae%x1f%s%x1f%D%x1e
```

預設只保留符合目前 identity 的 commit：

- author email 等於 `git config user.email`
- author name 等於 `git config user.name`
- author name、author email 或其他可取得欄位等於目前 GitHub login

以上任一條件命中即視為目前使用者。這個規則刻意偏寬，優先避免漏收同一使用者在不同機器、不同 git 設定或 GitHub merge 情境下產生的 commit。

bot commit 預設不保留，例如 release commit 或 `github-actions[bot]`。

例外是 release / deploy 類 bot commit 能透過 PR-chain 關聯回目前使用者的 filtered evidence：例如 bot commit 對應的 merge commit、PR number、release PR 或 deploy PR 能追到目前使用者的 PR / commit。這類 bot commit 可作為補充事件列入；僅有「同 repo 同日有本人工作」不足以列入 bot commit。

#### PR filtering

目前 `Get-GhContext` 使用 `involves:@me` 搜尋 PR。新設計下，PR 預設仍需與 filtered commits / branch / hash evidence 有關，不能因同 repo 有今日更新就列入。

PR 保留條件：

1. PR commit hash 命中 filtered commits；或
2. PR number 出現在 filtered commit subject，例如 `(#87)` 或 `Merge pull request #87`；或
3. PR head branch 命中 filtered commit refs / branch hints；或
4. PR author 是目前 `ghLogin` 且 PR 的 commit details 與日期範圍相關。

未來若要團隊日誌，可新增參數，例如：

- `-AuthorScope current|all`
- 或 `-IncludeAllAuthors`

本次預設先採 `current`。

### D. JSON 與 Formatter

collector JSON 需要保留足夠資訊讓 formatter 與 agent 正確摘要：

- `commits[].author`
- `commits[].authorEmail`
- `meta.authorScope`
- `meta.currentIdentity`
- `repos[].source` 可能包含 `session-expanded`
- 無 commit repo 的 session evidence，例如 session title、session path、source 與可用的 touched path 摘要

`format-daily-work-log-evidence.ps1` 應保留 `author` 與 `authorEmail`，並在 compact warning 中保留 author filtering 相關 warning。

套用 current identity author filtering 後，如果某個 repo 有當日 session evidence，但沒有符合目前使用者的 commit，collector 不應直接丟棄該 repo，也不應由 PowerShell 產生自然語言摘要。collector 應輸出足夠 session evidence，讓 agent 在最終日誌主體中為該 repo 產生一條簡短工作紀錄。

例如最終摘要可呈現為：

```text
- 檢視 / 分析 XXX 模組，當日無本人 commit
```

實際文字由 agent 根據 session title、repo name、touched path 或可用 session evidence 生成；若 evidence 不足，才退回註記，不臆測具體工作內容。

### E. 文件與 Evals

更新 `SKILL.md`：

- 新增 pre-collection recall workflow。
- 說明預設 `authorScope=current`。
- 說明 session path 若是安全的聚合目錄，collector 會自動展開 nested repos。
- Common mistakes 補：未先 recall 偏好、只用 session root 不展開聚合目錄、把同 repo 他人 commit 混入個人日誌。

更新 `README.md`：

- 補 helper 新 metadata 欄位。
- 補 session-expanded discovery 與 author filtering 行為。

更新 `evals/evals.json`：

1. 使用者提到「工作日誌 / 日誌」時，agent 應先嘗試 recall 既有偏好。
2. recall 無結果時，agent 不應報錯或停止。
3. session path 是聚合目錄時，collector 應自動展開 nested repos，不需要使用者指定專案名規則。
4. 預設日報只列目前使用者相關 commit / PR。
5. repo 有 session evidence 但沒有本人 commit 時，最終日誌仍以一條 agent-generated session 摘要呈現，不只放註記。

## 測試設計

更新 `skills/daily-work-log/tests/collect-daily-work-log.tests.ps1`。

### 1. 聚合 session 目錄自動展開

建立一個非 git root 的資料夾，底下包含：

- `repo-a/.git`
- `repo-b/.git`
- `.worktrees/repo-c/.git`，其中 `.git` 是 worktree file

mock OpenCode DB 回傳聚合資料夾作為 session directory。

預期：

- collector 在 `session` mode 就納入三個 repo。
- repo source 包含 `session-expanded`。
- 不需要顯式傳 `-ScanRoots`。

### 2. unsafe root 不展開

mock OpenCode DB 回傳 `C:\` 或測試環境的 home root。

預期：

- 不做 nested scan。
- 輸出 warning。
- 不因巨大 root 造成測試卡住。

### 3. 使用快速 `.git` marker 查找

測試 fake `rg` 被呼叫，並回傳 `.git` marker paths。

預期：

- collector 優先使用 `rg`。
- 若 fake `rg` 不存在或失敗，才進受限 fallback。
- 測試不要求硬編唯一命令字串，但要能驗證主要路徑不是 PowerShell 無界遞迴。

### 4. author filtering

同一 repo 建立兩組 commit：

- `test-user <test@example.com>`
- `other-user <other@example.com>`

mock `gh api user --jq .login` 回 `test-user`，`git config` 回 `test-user` / `test@example.com`。

預期：

- 只保留 `test-user` commit。
- metadata 顯示 `authorScope=current`。

### 5. identity 無法解析時降級

讓 `gh api user` 與 `git config` 都失敗。

預期：

- collector 不丟例外。
- 保留舊 commit collection 行為。
- warning 說明 author filtering 未套用。

### 6. PR 只跟 filtered commits 關聯

mock `gh pr list` 回兩個 PR：

- PR #1 author 是目前使用者，commits 命中 filtered commit。
- PR #2 author 是他人，updated today，但 commits 不命中 filtered commit。

預期：

- 只保留 PR #1。
- PR #2 不出現在 compact evidence。

### 7. 無 commit repo 仍保留 session evidence

mock OpenCode DB 回傳某 repo 有當日 session activity，但該 repo 在 author filtering 後沒有任何 commit。

預期：

- repo 不被 collector 丟棄。
- JSON / compact evidence 保留 session title / source 等可供 agent 摘要的資訊。
- collector 不產生自然語言工作紀錄。

## 錯誤處理

- recall 失敗：不報錯、不阻塞，照原流程。
- `rg` 不存在：fallback 到受限 PowerShell scan，並可加低噪音 warning。
- `rg` 失敗：同上，不中斷 collector。
- 聚合目錄展開超過上限：停止加入更多 repo，warning 說明結果可能不完整。
- identity 部分解析：用可用 identity 進行 filtering。
- identity 完全不可解析：降級不過濾，warning。
- PR details 查詢失敗：沿用現況，該 PR 不列入，warning。

## 不做事項

本次不處理：

- 把 `jasmine-scins-ah-2026` 或任何特定專案名稱寫進 `SKILL.md`。
- 改變最終日誌文案風格。
- 產出團隊日誌模式的完整設計；只保留未來 `AuthorScope=all` 的擴充點。
- 引入非 PowerShell collector。
- 讓 recall 成為硬依賴。

## 驗收條件

以下條件全部成立才算完成：

1. `daily-work-log` skill 觸發後，文件要求先嘗試 recall 工作日誌 / 日誌蒐集偏好；無結果時靜默 fallback。
2. `session` mode 遇到安全的非 git 聚合目錄時，可自動展開 nested git repo / worktree。
3. 聚合目錄展開優先用快速 `.git` marker 查找命令，不做無界 PowerShell 遞迴。
4. collector 預設只保留目前使用者相關 commit / PR。
5. 有 session evidence 但無本人 commit 的 repo，最終日誌仍能由 agent 產生一條簡短 session 工作紀錄。
6. identity 無法解析時，collector 保留舊行為並 warning，不產生空報告。
7. Pester tests 覆蓋 session-expanded、unsafe root、rg fast path、author filtering、identity fallback、PR filtering、無 commit repo session evidence。
8. `SKILL.md`、`README.md`、`evals/evals.json` 與 helper JSON 欄位說明一致。

## 實作建議順序

1. 先補 Pester failing tests：session aggregate expansion、unsafe root、author filtering、PR filtering。
2. 實作 identity resolver 與 commit author filtering。
3. 實作 fast `.git` marker discovery 與 session-expanded source。
4. 更新 formatter 保留新增欄位。
5. 更新 `SKILL.md` / `README.md` / `evals/evals.json`。
6. 跑 Pester 與 skill repo 驗證。
