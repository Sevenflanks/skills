---
name: daily-work-log
description: 整理每日工作日誌或跨 repo 今日工作時使用。先探測 OpenCode／Codex 可用來源並預告，再合併本機 session、跨 branch Git 與相關 GitHub PR／issue 證據，輸出主題分組日誌。
license: MIT
metadata:
  author: sevenflankse
  version: 0.4.0
---

# Daily Work Log

將本機 OpenCode／Codex 活動、跨 branch Git 與 GitHub PR 證據整理成精簡日誌。同一 PowerShell collector 先輸出 probe JSON，再輸出 collection JSON；來源預告與最終摘要由 agent 在對話提供。

## When to use

Use this skill when:

- The user asks for a daily work log, work journal, standup summary, or asks what was done today.
- 使用者希望從 OpenCode 或 Codex sessions、git commits、PRs 或 issues 整理工作。
- The user needs repo-grouped bullets such as `owner/repo`, `repo-a`, or similar repository sections.
- The environment is Windows / PowerShell / OpenCode and repeatable local evidence collection matters.

Do not use this skill when:

- The user wants a changelog for only one known commit or one PR.
- The user already provides the exact final text and only wants wording edits.
- The user asks to write the report to a file by default. This skill returns the report in-chat first; file output is optional only when explicitly requested.

## Core rule

以 collector JSON 作為證據，先 probe → 向使用者預告來源與略過原因 → 正式 collect。OpenCode 與 Codex 都可用時兩者合併，沒有來源優先順序。來源皆不可用或正式讀取皆失敗時停止，說明原因；不掃 Git／GitHub 湊日誌，也不輸出工作日誌。若 GitHub CLI 不可用或未認證，沿用既有預設停止規則；使用者強烈要求降級時才繼續並說明補證缺口。CLI 安裝或登入只能建議，不自動執行。

## Workflow

1. **Recall collection preferences before collecting**
   - Before running the helper, try to recall user or project-specific daily-log collection preferences.
   - Search terms should include `daily-work-log`, `工作日誌`, `日誌`, the current working directory, user-mentioned repo / project names, `scan root`, and `repo discovery`.
   - If useful context is found, translate it into helper parameters or final-summary rules.
   - If recall is unavailable, fails, or returns no useful result, stay silent and continue with the default helper workflow.
   - Do not add project-specific rules to this skill; project-specific collection habits belong in memory.

2. **Confirm scope and defaults**
   - If the user does not specify a clear time range, default range is today in the configured timezone.
   - This default is about missing explicit time range, not about auto-triggering on completely blank input.
   - The helper defaults to `Asia/Taipei`; override `From`, `To`, or `Timezone` when the user needs another range or timezone.
   - Allow overrides for `From`, `To`, repo source mode, or scan roots when the user asks.
   - Default repo source mode is `session`; fallback or broader discovery can use `scan` or `mixed`.
   - OpenCode 內部先用 `opencode db --format json`；Codex 另從本機日期分區有界蒐集，兩者可用時一併納入。
   - If the DB command is unavailable, fails, or returns invalid JSON, fallback order is DB, then `storage/directory-readme`, then OpenCode logs.
   - If the DB query succeeds and returns empty `[]`, treat that as authoritative for session discovery and do not fallback to file-based sources.
   - Default `authorScope` is `current`; broad identity matching uses current-user git config and GitHub viewer evidence when available.
   - If the current identity cannot be resolved, the helper warns and falls back to all authors instead of silently pretending current-user filtering happened.

3. **先 probe 並預告來源**
   - 使用 `scripts/collect-daily-work-log.ps1 -ProbeOnly`，傳入本次相同 `From`／`To`／`Timezone`、來源入口覆寫與 repo mode。
   - 讀取 `meta.sources.opencode`／`codex` 的 `available`、`cliAvailable`、`reason`、`entries`，在對話先預告本次使用的來源與每個略過理由，例如：「本次合併 OpenCode 與 Codex；Codex CLI 不存在，但本機紀錄可讀。」
   - probe 只檢查已知紀錄入口與 command 存在；不掃完整歷史、不啟動 CLI、不讀 auth、config 或 secrets。入口可讀不代表有當日活動，也不保證正式讀取成功。
   - 任一來源有可讀本機紀錄，即使沒有 CLI 也可使用。OpenCode CLI 可供非互動式 DB 查詢；Codex 只有 CLI、沒有可讀紀錄時略過。
   - 若兩者 `available=false`，說明各來源原因後結束。即使使用者要求 `scan`／`mixed` 也遵守此停止條件。

4. **Run the bundled collector**
   - Use `skills/daily-work-log/scripts/collect-daily-work-log.ps1`.
   - Keep the script output pure JSON on `stdout`.
   - Do not append human text, markdown, or logging noise to `stdout`.
   - 使用與 probe 相同參數，移除 `-ProbeOnly`；若原先省略時間，將 probe 的 `meta.from`／`to` 明確傳入，固定本次日界線。兩來源皆可用時全數蒐集，正式 collector 自身會重新檢查來源並阻擋無來源／讀取全失敗的呼叫。
   - Codex 入口為 `-CodexRoot`（否則 `CODEX_HOME`，再否則 `~/.codex`）；只直接定位 `sessions/yyyy/MM/dd` 日期分區，`archived_sessions` 僅 probe 可用性，正式蒐集略過並揭露缺口。具體界限與停止策略見下方「Codex 有界涵蓋」。
   - 對選中並已讀取的 JSONL 事件，以 `timestamp` 比對含頭尾的指定範圍；預設今天依 `Timezone` 計算。選中檔的舊檔名或 mtime 不取代事件時間；日期分區之外的跨日續行可漏收，不宣稱完整涵蓋。
   - collector 合併 event／response 鏡像、同 session ID 續行及父子 session 的精確重播，保留 `sessionIds`／`files`／`timestamps`；不推測自然語意主題。
   - In `session` mode, treat session-derived repo discovery as including both session-start directories and touched external repo evidence that can be resolved to git repo or worktree roots from `permission=external_directory` or `permission=read` log entries.
   - In `session` mode, if a session path is a safe aggregate directory rather than a git repo, the collector expands nested git repos / worktrees using fast `.git` marker discovery.
   - The default author scope is the current user. Commits and PRs from other authors are excluded unless they are release / deploy bot commits with PR-chain evidence back to current-user work.
   - If a repo has session evidence but no current-user commits, keep it in the final report as one short agent-written session summary when evidence is sufficient; do not invent details.
   - The collector preserves session-derived evidence with source `session-expanded` when a safe aggregate directory contributes nested repo / worktree matches.
   - The PowerShell collector does not generate natural-language summaries. The agent writes any one-line session summary from `sessionEvidence`.

5. **Inspect collection gaps before writing the summary**
   - 先檢查 `errors`、`meta.canGenerateLog`、`meta.collectionStatus` 與各 `readStatus`。`no-sources`／`read-failed` 停止；`no-activity` 說明來源可讀但沒有當日證據，不能稱為讀取失敗或產生空白工作日誌。
   - `readStatus` 分別為 `unavailable`、`not-read`（probe）、`empty`、`success`、`partial`、`failed`。`partial`／`failed` 或略過來源要指出缺口；有其他成功來源可繼續，不宣稱資料完整。
    - 檢查 Codex `coverage.complete=false`、`candidateDays`／`visitedDays`／`unvisitedDays`、`stopReason`、`oversizedLines`、`limitHits`、`skipped` 與實際訪問／讀取 counters；即使 `success`、`empty` 或沒有未訪問日期，也只代表已選資料。有界空結果不能稱為「完整查過今天沒有工作」。
   - `canGenerateLog=false` 時只說明狀態與原因，不能憑記憶或額外掃描補成日誌。
   - Check `meta.ghAvailable` and `meta.ghViewer`.
   - If GitHub CLI is unavailable or not authenticated, stop before writing the daily log. Tell the user to install `gh` or run `gh auth login`, then rerun collection.
   - Continue without GitHub evidence only when the user strongly insists on a degraded report. In that case, state the PR / issue supplement gap explicitly in the final notes.
   - Check repo `warnings` and top-level `warnings` / `errors`.
   - Note repos that are not git repos, repos with session activity but no commits, and repos with commits but no PR/issue supplement.
   - Only include paths that resolve to git repo or worktree roots. Surface skipped or unresolved paths through warnings or final notes.
   - Treat PR supplement as relevant only when it can be tied back to the day's commit / branch / hash evidence; do not attach every updated PR from the same repo.

6. **Summarize by GitHub repo name**
   - Group by GitHub repo name from `repos[].githubRepo` first, such as `owner/repo`.
   - If `githubRepo` is unavailable for a repo, fall back to `repos[].name` repo folder name.
   - Never use absolute paths as final group headings.
   - Prefer short bullets, ideally within 30 Chinese characters.
   - Default to 2-5 bullets per repo. If a repo would exceed that, merge nearby commits into theme-level bullets instead of listing every commit-shaped fragment.
   - Prefer bullets that preserve issue / PR numbers such as `PR #219` or `#217`.
   - Each bullet should be understandable on its own. A reader should understand what changed without needing the previous bullet as context.
   - If a bullet only makes sense together with neighboring bullets, merge them into one clearer sentence or drop the weaker fragment.
   - Keep separate bullets when two changes are materially different.
   - 同 repo／worktree 的相同工作主題跨 OpenCode、Codex、父子或續行只寫一條，將對應 `sessionEvidence`、commit 與 PR 一起作為證據；不同實質工作仍分開。語意合併由 agent 判斷，不要求 collector 做 NLP。
   - 不公開完整私人對話、內部路徑或 secrets；只用必要的工作主題與可公開 PR／issue 編號。

7. **State data gaps honestly**
   - If the user strongly insisted on continuing without available/authenticated `gh`, explicitly say PR / issue links were not supplemented.
   - If a repo had session activity but no commits, say so.
   - If a directory is not a git repo, say so instead of dropping it silently.

## PowerShell helper invocation

Use PowerShell 7+ and pass an explicit script path. Examples:

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1" -ProbeOnly
# 向使用者預告 JSON 中的來源與略過原因後，再使用同一範圍正式蒐集。
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1"
```

Override time range and source mode:

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1" `
  -From "2026-05-29T00:00:00+08:00" `
  -To "2026-05-29T23:59:59+08:00" `
  -SourceMode mixed `
  -ScanRoots "<scan-root>"
```

## Collector JSON shape

Treat collector JSON as source of truth:

- `meta`: `generatedAt`, `timezone`, `from`, `to`, `sourceMode`, `scanRoots`, `probeOnly`, `sources`, `canGenerateLog`；正式 collection 另有 `collectionStatus`，進入 Git／GitHub 補證時保留 `ghAvailable`、`ghViewer`、`authorScope`、`currentIdentity`。
- `warnings` / `errors`: global evidence gaps or failures.
- `repos[]`: `name`, `path`, `source`, `isGitRepo`, optional `githubRepo`, optional `sessionEvidence`, `commits[]`, `prs[]`, `warnings[]`.
- `commits[]`: commit evidence from `git log --all`, including `authorEmail`; ignore stash noise before summarizing.
- `prs[]`: PR evidence tied to commit / branch / hash relevance; preserve PR and issue numbers when useful.
- `sessionEvidence[]`：`agent` 區分 `opencode`／`codex`；OpenCode 保留 DB／fallback session 欄位；Codex 保留有限長度 `title`、`role`、`sessionId`、`sessionIds[]`、`files[]`、`timestamps[]`。repo 去重不刪不同 session 證據。

## Codex 有界涵蓋

**允許漏收，但所有首次、重跑與錯誤路徑都禁止全歷史列舉／讀取／解析，包括先全列再 filter。** 採無 cache 的直接日期定位；錯誤只回報缺口，不擴大搜尋。

- 候選日期聯集維持起迄時間的 UTC 日期與 `Timezone` 日期之最小至最大值；先訪問指定時區的實際日期升序，再補 UTC 額外候選升序，最多開始 **32 日**的 partition path 檢查。日期只定位目錄，已選事件仍以 timestamp 判範圍。
- 每日只 lazy 列舉該分區第一層，跨日期共最多 **2,048 entries／128 JSONL 候選檔**。非 JSONL 與子目錄也計 entry；不排序、不展開子目錄，達限即 Dispose，不再呼叫 MoveNext。
- `-CodexTotalBytes`／`-CodexFileBytes` 預設為每次 **64 MiB**／每檔 **8 MiB**；只接受 **1 至 9,223,372,036,854,775,807 的整數 bytes**，可明確指定 **128 MiB／16 MiB**。單檔有效額度仍取單檔與全域剩餘額度的較小值。Probe 與 collection 使用相同額度；達限回報缺口，不自動加碼或重跑，也沒有無上限模式。參數例子見 [`README.md`](README.md#調整-codex-讀取額度)。
- FileStream.Read 每次最多 **4 KiB**且不超過剩餘額度，單行 buffer 為 **64 KiB**（LF 前的原始 bytes，含 BOM／CR）。超長行只計一次 `oversizedLines`，丟棄至 newline 或 EOF，再續讀正常行；所有實讀／丟棄 bytes 都計額度。完整行才 strict UTF8 解碼與解析，支援跨 chunk、首行 BOM、CRLF 與真正 EOF 的無 newline 尾行。達 cap 的未完整尾行略過，不當成損壞資料；完整壞 UTF8／JSON 略過該行並保留警告及前後有效 evidence。達總 byte cap 停止後續候選搜尋。
- 固定日期路徑最多檢查 **64 個 ancestor components**，拒絕 junction／reparse points；分區內巢狀目錄與 archive 都略過。檔案順序沿用 filesystem，不保證取到最新檔；恰好達 entries／files／totalBytes cap 也保守揭露限制。
- `meta.sources.codex.coverage` 保留 `limits`、`daysConsidered`、`selectedDays`、`visitedEntries`、`candidateFiles`、`openedFiles`、`readBytes`、`enumerationFailures`、`limitHits`、`skipped`；新增 `candidateDays`（完整有序日期候選）、`visitedDays`（開始 path 檢查，與 `selectedDays` 相同，含不存在／被拒絕路徑）、`unvisitedDays`（達全域 cap 尚未開始檢查的候選）、`oversizedLines`（已讀到超過單行上限的行數）。Visited 不表示全日列舉完畢；未訪問集合為空也不表示完整。
- `stopReason` 只描述全域 traversal 終點：同時達限依 `totalBytes` → `entries` → `files` 優先，再為尚有未訪問候選的 `days`，否則 `candidate-days-exhausted`。局部 `fileBytes`／`lineBytes`／`pathComponents` 只在 `limitHits`；缺失目錄／列舉失敗看 `visitedDays`／`enumerationFailures`。固定 `complete=false`／`strategy=date-partitions-no-cache`／`archive=skipped`。Counters 是 application-level MoveNext 與實際 FileStream.Read bytes，不代表 OS metadata／prefetch I/O。
- `probeWork` 分開記已知入口檢查數與成功 MoveNext 數；最多檢查兩入口、各消耗一 entry，`openedFiles=0`／`readBytes=0`。probe 沒有 collection coverage，不能推論當日活動。
- 有事件且達限時為 `partial`；無事件且無損壞時保留 `empty`／`no-activity`；選中事件全失敗保留 `failed`／`read-failed`。Archive 被略過本身不算解析失敗，所有結果仍須說明不完整。

這組上限限制 filesystem 訪問與 transcript 讀取；日期候選陣列仍隨要求範圍成長，reader buffers 不隨 byte 額度成長，但不限制事件清單或整個 PowerShell process 記憶體。64／8 MiB 是已確認預設，不是最佳門檻或 latency SLA；合成量測界線見 [`README.md`](README.md#有界驗證與量測)。

## Optional evidence compaction

For high-volume evidence, pipe collector JSON through `scripts/format-daily-work-log-evidence.ps1`. It reads collector JSON from stdin, emits pure JSON, preserves `meta`, `warnings`, `errors`, and returns compact repo evidence: `name`, `githubRepo`, `commitCount`, `shownCommits`, `prs`, `lowSignalPrRefs`, `sessionEvidence`, `warnings`.

formatter 只限制 shown commits；完整保留 session 證據，避免截斷掉第二來源或續行。管線前仍必須完成 probe 與來源預告。

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1" |
  pwsh -NoProfile -File "<path-to-skill>\scripts\format-daily-work-log-evidence.ps1" -MaxCommitsPerRepo 8
```

## High-commit repos

When a repo has many commits, summarize themes instead of dumping commits. Use compacted `shownCommits` as evidence, keep `shownCommits.Count <= 8` by default, and turn low-signal PR titles such as `noop` into `lowSignalPrRefs` like `PR #238 [MERGED]` instead of user-facing bullets like `PR #238: noop [MERGED]`.

## Required checks

- Helper script output is valid JSON only.
- 正式蒐集前已完成 probe 與對話來源預告；無來源或讀取全失敗時停止，不產生日誌。
- CLI 不存在但紀錄可讀仍可用；所有可用來源一併蒐集，partial coverage 明講缺口。
- Codex 使用有界日期分區，已選事件依 timestamp；archive／範圍外續行明確略過。已選父子／續行去重保留證據；跨來源相同主題由 agent 合併。
- When the user does not provide a clear time range, the helper resolves the range to today in the configured timezone.
- Git history collection uses `git log --all`; do not limit to current branch.
- `scan` / `mixed` repo discovery must cover git worktrees as well as normal repos.
- `session` repo discovery must query `opencode db --format json` first.
- DB fallback order is DB, then `storage/directory-readme`, then OpenCode logs, but DB success with empty `[]` is authoritative and does not fallback.
- If `storage/directory-readme` finds no resolvable repo/worktree roots after a DB failure, continue to OpenCode log fallback.
- OpenCode log fallback includes session-start directories plus touched external repo evidence from `permission=external_directory`, `permission=read`, and `permission=read-only` paths when they resolve to git repo or worktree roots.
- Only paths resolvable to git repo or worktree roots are included in repo results.
- Repo discovery gaps, skipped paths, and partial evidence are reported through warnings and final notes.
- Stash noise such as `refs/stash`, `index on ...`, or `untracked files on ...` is excluded from summary-worthy commits.
- GitHub supplement is required by default. If `gh` is unavailable or unauthenticated, stop and recommend installing GitHub CLI or running `gh auth login` unless the user strongly insists on continuing without GitHub evidence.
- GitHub supplement is filtered by commit / branch / hash relevance; do not attach unrelated updated PRs from the same repo.
- Release / deploy bot commits are only included when PR-chain evidence ties them back to current-user work.
- Missing GitHub supplement is reported as a warning, not silently ignored.
- If no current-user identity can be resolved, warn that `authorScope` fell back to `all` and summarize all authors from the collected evidence.
- Repos with session evidence but no current-user commits remain eligible for one short agent-written session summary when the evidence is sufficient.
- Final output is grouped by `repos[].githubRepo` GitHub repo name first, with `repos[].name` folder name as fallback only when GitHub repo name is unavailable.
- Final output never uses absolute paths as group headings.
- Each repo defaults to 2-5 bullets unless there is a strong reason to exceed that.
- Final bullets stay concise and preserve PR / issue identifiers when available.
- Final bullets are independently understandable; avoid fragments that only make sense when read together.

## Final output format

Use grouped bullets like this:

```text
- **sevenflanks/repo-a**
  - 修首建參數遺失，PR #49
  - 新增 skills 功能

- **repo-b**
  - 修付款按鈕條件邏輯
  - 合併 PR #219，解 #217
```

If there is a global gap, append a short note after the grouped list, for example:

```text
註：依你的要求先在未登入 GitHub CLI 的狀態下產生日報，PR / issue 關聯未補證。
```

## Examples

```text
Input: 幫我整理今天的工作日誌，最好帶 PR 跟 issue。
Output: Run the PowerShell helper for today's range, inspect JSON warnings, then return grouped bullets by GitHub repo name from `githubRepo`, falling back to repo folder name only when needed.
```

```text
Input: 我想補昨天的日報，範圍改成昨天 00:00 到 23:59，另外掃我的專案根目錄底下 repo 補強。
Output: Run the helper with explicit From/To plus `-SourceMode mixed -ScanRoots "<scan-root>"`, then summarize the resulting JSON into grouped bullets.
```

## Common mistakes

| Mistake | Correct behavior |
| --- | --- |
| 只看目前 branch 的 commit | 一律使用 `git log --all`。 |
| 直接從 commit message 猜 PR / issue 關聯 | 先收 git，再用 `gh` 補 PR 與 closing issues。 |
| helper 腳本同時輸出 JSON 與說明文字 | `stdout` 保持 pure JSON；人類摘要由 skill 產生。 |
| DB 回傳空陣列時繼續讀 log 湊 repo | DB 成功且回傳 `[]` 代表 session discovery 沒有 repo，不 fallback。 |
| DB 查詢失敗就停止 session discovery | 依序 fallback 到 `storage/directory-readme`，再讀 OpenCode logs，並保留 warning。 |
| 看見非 git repo 就忽略 | 明講「今日有 session，非 git repo」。 |
| `gh` 失敗時假裝沒有 PR | 預設停止並建議安裝或登入 `gh`；若使用者強烈堅持才保留 warning 並在最終輸出說明未補證。 |
| `gh` 不存在或未登入時直接降級產生日報 | 先停止並建議安裝 `gh` 或執行 `gh auth login`；只有使用者強烈堅持才降級繼續。 |
| 一律用資料夾名稱當分組標題 | 優先使用 `githubRepo` 的 GitHub repo name，缺失時才 fallback 到 repo folder name。 |
| 把相鄰 commit 片段拆成多條半句 | 合併成一條能單獨理解的日誌句；若無法說清楚就不要列。 |
| 把同一 repo 的 commit 幾乎逐條照抄 | 先歸納成 2-5 條主題句，再保留最重要的 PR / issue。 |
