---
name: daily-work-log
description: 整理每日工作日誌或跨 repo 今日工作時使用。先探測 OpenCode／Codex 可用來源並預告，再合併本機 session、跨 branch Git 與相關 GitHub PR／issue 證據，輸出主題分組日誌。
license: MIT
metadata:
  author: sevenflankse
  version: 0.7.1
---

# Daily Work Log

將本機 OpenCode／Codex 活動、跨 branch Git 與 GitHub PR 證據整理成精簡日誌。同一 PowerShell collector 先輸出 probe JSON，再輸出 collection JSON；來源預告與最終摘要由 agent 在對話提供。開始撰寫對話或摘要前，從 runtime 發現並載入 `i-have-adhd` skill，不依賴固定安裝路徑。

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
   - recall 僅鎖定本次指定日期、使用者點名的 repo，以及會影響本次 collection 的偏好；使用使用者給出的具體詞，不擴成寬泛同義詞搜尋。
   - 輸入仍有效時，沿用同任務有用的 collection 參數、證據與已完成查詢。handoff 本身不使其失效；不重做 collection，也不重問已回答欄位。
   - recall 不可用、失敗或沒有有用結果（含截斷／大型回傳未取得有效偏好）時，停止 recall 搜尋，不擴大範圍，直接使用預設 helper workflow；截斷 recall 不作成果證據。
   - Do not add project-specific rules to this skill; project-specific collection habits belong in memory.

2. **Confirm scope and defaults**
   - If the user does not specify a clear time range, default range is today in the configured timezone.
   - This default is about missing explicit time range, not about auto-triggering on completely blank input.
   - The helper defaults to `Asia/Taipei`; override `From`, `To`, or `Timezone` when the user needs another range or timezone.
   - Allow overrides for `From`, `To`, repo source mode, or scan roots when the user asks.
   - Default repo source mode is `session`; fallback or broader discovery can use `scan` or `mixed`.
    - OpenCode 內部先用 `opencode db --format json`；Codex 先以 state metadata 的 lifespan overlap 定位候選，再以 history item 的實際時間精選，並以候選 session 的 exact JSONL 補證。兩來源可用時一併納入。
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
   - 呼叫正式 collect 時，工具支援等待 timeout 設定就設為 **600000 ms**；這是工具設定，不是 script 參數，也不是效能 SLA。若工具不支援，揭露實際等待限制，不以重跑補足。
   - 逾時或未取得有效 JSON 時停止並回報，不自動重跑；工具 timeout 不改變既有來源 guard 或停止條件。
   - 工具等待 timeout 與資料讀取額度分開；Codex 的預設總額度／單檔額度仍依「Codex 有界涵蓋」辦理。
    - Codex adapter 需要 Python 3.11+；只對本機 Codex state／history 做唯讀 SQL。已核對 runtime contract、精選順序、exact supplement、fallback 與分開計帳規則見「Codex 有界涵蓋」。
   - collector 合併 event／response 鏡像、同 session ID 續行及父子 session 的精確重播，保留 `sessionIds`／`files`／`timestamps`；不推測自然語意主題。
    - OpenCode DB 成功且非空時，依下方「OpenCode repo discovery」補充 structured bash workdir；fallback logs 才使用 `permission=external_directory`／`read`／`read-only` touched path。
   - In `session` mode, if a session path is a safe aggregate directory rather than a git repo, the collector expands nested git repos / worktrees using fast `.git` marker discovery.
   - The default author scope is the current user. Commits and PRs from other authors are excluded unless they are release / deploy bot commits with PR-chain evidence back to current-user work.
   - If a repo has session evidence but no current-user commits, keep it in the final report as one short agent-written session summary when evidence is sufficient; do not invent details.
   - The collector preserves session-derived evidence with source `session-expanded` when a safe aggregate directory contributes nested repo / worktree matches.
   - The PowerShell collector does not generate natural-language summaries. The agent writes any one-line session summary from `sessionEvidence`.

5. **Inspect collection gaps before writing the summary**
   - 先檢查 `errors`、`meta.canGenerateLog`、`meta.collectionStatus` 與各 `readStatus`。`no-sources`／`read-failed` 停止；`no-activity` 說明來源可讀但沒有當日證據，不能稱為讀取失敗或產生空白工作日誌。
   - `readStatus` 分別為 `unavailable`、`not-read`（probe）、`empty`、`success`、`partial`、`failed`。`partial`／`failed` 或略過來源要指出缺口；有其他成功來源可繼續，不宣稱資料完整。
    - 檢查 Codex `coverage.complete=false`、日期／停止欄位、`limitHits`／`skipped` 及「Codex 有界涵蓋」診斷；即使 `success`、`empty` 或沒有未訪問日期，也只代表已選資料。有界空結果不能稱為「完整查過今天沒有工作」。
   - `canGenerateLog=false` 時只說明狀態與原因，不能憑記憶或額外掃描補成日誌。
   - Check `meta.ghAvailable` and `meta.ghViewer`.
   - If GitHub CLI is unavailable or not authenticated, stop before writing the daily log. Tell the user to install `gh` or run `gh auth login`, then rerun collection.
   - Continue without GitHub evidence only when the user strongly insists on a degraded report. In that case, state the PR / issue supplement gap explicitly in the final notes.
   - Check repo `warnings` and top-level `warnings` / `errors`.
   - Note repos that are not git repos, repos with session activity but no commits, and repos with commits but no PR/issue supplement.
   - Only include paths that resolve to git repo or worktree roots. Surface skipped or unresolved paths through warnings or final notes.
    - PR 補證須連回該 worktree 當日 commit／branch／hash 或可靠 session 證據；同作者、同 repo、近期更新只作候選，不能全收。collector 沒有 commit 關聯時保留 session-only；必要手動補證也須記錄當日關聯及 Draft／實際交付狀態。
    - 有效 repo／worktree 即使沒有當日本人 commit，仍由 `origin` remote 解析 canonical `githubRepo`。remote 缺失／無法確認時揭露缺口；`name` 只作顯示 fallback，不反推 mapping，也不從已刪 worktree 或父目錄猜 repo。
    - 分類／resolver 優先重用已有可靠當日 branch／PR 證據；可查 remote 就先查，不把可自行確認的 identity 轉問使用者。補報不以目前 checkout 代替當日 branch；無當日 branch 或多義時，只詢問未解的歸屬。
    - resolver 回傳原因未明的 HTTP 400／`http_error` 時，回報「解析失敗，原因未知」並停止同類 branch 嘗試；不稱為 missing mapping、不逐 branch 猜結果，也不因此新增永久 mapping。

6. **核對引用 issue 狀態後，依 GitHub repo 名稱彙整**
   - 選定工作日誌主題後、preview 或寫入前，核對每個會改變成果或 todo 的明確引用 issue 當前狀態。核對先使用同任務、同一 `(canonical repo, issue number)` 且仍有效的成功查詢；只有缺少證據、查詢失效或新證據影響該 issue 時，才以可靠 canonical `githubRepo` 對精確 issue 編號查詢。不因進入摘要或 handoff 重查。僅對相同 `(canonical repo, issue number)` 去重，不同 repo 的同號 issue 分開查。
   - `closingIssuesReferences` 與 collector 衍生的 `issuesClosed` 只描述 PR 關聯，不代表 issue 當前狀態。依精確 repo 與編號查詢 issue 本身；不據該關聯推定 `CLOSED`，也不搜尋無關 issue 或 repo。
   - 將查得狀態標明為查詢時狀態。補報舊日期時，區分目前 issue 狀態與報告日當時已知／已完成事項；不把之後的狀態變更回溯到報告日，也不以今日 issue state 取代當日工作證據。
   - 若無可靠 canonical repo，或精確查詢失敗、回 404、結果無法判讀，保留 issue 狀態為 unknown，並說明 identity／verification gap；不以 repo folder 名稱代替 repo identity、不猜狀態，也不擴大成全 repo 搜尋。
   - Group by GitHub repo name from `repos[].githubRepo` first, such as `owner/repo`.
   - If `githubRepo` is unavailable for a repo, fall back to `repos[].name` repo folder name.
   - Never use absolute paths as final group headings.
   - 每條以「類別（有助定位時）＋具體變更／成果」表達，結果先行，句尾保留支撐該主題的全部相關 PR 編號。完整意思優先於 30 個中文字或名詞串；同主題跨 repo 時加可辨識的 repo 前綴。
   - 同一範圍內所有列出的 PR 都是 `MERGED` 時，可共用一次「均已合併」狀態；狀態混合時分別標明各成果／續作的 `MERGED`、`OPEN`、`Draft`、`CLOSED` 或 session-only 狀態。
   - 保留所有支撐實際列出工作主題的 PR 編號，不把無關或低訊號 PR 塞入摘要；合併狀態不代表部署，也不據此宣稱未查證的效率或效益。
   - Default to 2-5 bullets per repo; if there are more material changes, merge nearby commits into independently understandable theme-level bullets.
   - Each bullet should be understandable on its own. A reader should understand what changed without needing the previous bullet as context.
   - If a bullet only makes sense together with neighboring bullets, merge them into one clearer sentence or drop the weaker fragment.
   - Keep separate bullets when two changes are materially different.
    - 同 repo／worktree 的相同工作主題跨 OpenCode、Codex、父子或續行只寫一條，將對應 `sessionEvidence`、commit 與 PR 一起作為證據；不同實質工作仍分開。語意合併由 agent 判斷，不要求 collector 做 NLP。
    - 先依證據辨識交付狀態，再壓縮文字：`MERGED` 才寫「已合併」；`OPEN` 寫「待合併」，已知 `isDraft=true` 再標「Draft」。`CLOSED` 且無 merge 證據只寫「已關閉、未合併」；狀態不明明講待確認。Commit 本身不證明 PR 已合併。
    - 同主題分開表達已交付成果與待完成部分；不可用其中一個 merged PR 把整個主題或另一個 PR 宣稱完成。Formatter 的 `[OPEN]` 不證明 ready，未保留 Draft 資訊時維持「待合併」。
    - 只有 session 標題或未補 Git／PR 證據時，標示「session-only／僅 session 證據」，用「討論／處理／驗證中」等符合證據的用語。標題即使寫「驗收通過／部署成功」，也不是實際驗收、部署或合併證據；這些成果須有對應結果補證才可宣稱。保留有意義的待辦，不把標題當已完成清單。
   - 不公開完整私人對話、內部路徑或 secrets；只用必要的工作主題與可公開 PR／issue 編號。

7. **State data gaps honestly**
   - 對話先報目前狀態與待決事項；缺口已說明後，後續只補充變更，最終摘要仍保留相關缺口。
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

## OpenCode repo discovery

- Session `directory`／`path` 與 fallback injected／log path 只接受明確 fully-qualified absolute 值；沒有來源 base 契約的 relative、drive-relative、root-relative 值略過並以既有 aggregate warning 揭露。不可依 collector CWD 或 session title 猜 repo。合法 drive／UNC absolute 沿用既有 resolver／安全 aggregate expansion 契約。
- DB metadata 成功且非空時，只追加一次 `part JOIN session` query：沿用 session interval overlap，part `time_created` 另以 inclusive From／To 篩選。以 `json_valid` 保護個別壞 data，只投影 session ID／title／既有 session 時間、tool／workdir／part timestamp；不返回完整 `data`、commands、output 或對話。
- 只確定 `type=tool`、`tool=bash` 的 `state.input.workdir` 語意：值須 text、長度最多 4,096、明確 fully-qualified absolute。其他 tool 欄位與文字不猜。依 part time／id 固定排序，最多處理 **2,048 候選 rows**，SQL `LIMIT 2049` 的額外一列只作截斷 sentinel。Cap 限制候選回傳／處理列數，不是 SQLite 掃描量、DB I/O、query latency 或整個 process 記憶體 SLA；不新增 cache、index 或 schema。
- Structured workdir 必須仍存在且可解析 Git repo／worktree；已刪／missing worktree 只回 aggregate unresolved warning，不靠不存在路徑的 Git 父目錄或名稱推 canonical mapping。Home-started parent 可由其自己的範圍內 bash workdir 歸 repo。相同 session／正規化 path 去重，保留 `discoverySource=session`、`pathSource=bash-workdir`、`tool`、`timestamp`；formatter 完整保留。
- DB 成功 `[]` 不補查 parts、也不 fallback。Metadata query 失敗維持 DB → directory-readme → logs。Supplement query failed／非 JSON／row shape 錯誤／cap／unresolved workdir 保留已成功 metadata／有效 rows，以 OpenCode `readStatus=partial`、overall `collectionStatus=partial` 與 warning 揭露缺口，不重試或擴大來源。Relative 值的略過 warning 本身不算 metadata 讀取失敗。
- Probe 維持純 JSON、零 DB query、零 data 讀取。`success` 只代表已選來源讀取成功，不保證所有 repo 都有 structured 證據。

## Codex 有界涵蓋

**允許漏收，但所有首次、重跑與錯誤路徑都禁止全歷史列舉／讀取／解析，包括先全列再 filter。** 不快取候選；metadata 日期分支先通過既有 index／query plan gate，再逐 exact rollout 補證；SQL 無法使用時，只對有界日期分區 fallback。錯誤只回報缺口，不擴大搜尋或另開預算。

- Python adapter 僅支援 Python 3.11+；正式回報實際 Python／SQLite runtime 與已核對 Codex contract `0.164.0-alpha.11.1`。JSON pipe 雙向固定 UTF-8，僅在 child process 設定 IO encoding，不改全域環境。缺 Python、missing／permission、valid-empty 與 compatibility error 分開呈現；缺 Python、metadata 缺失／無權限／不相容或 valid-empty 無 exact ID 時，使用既有有界日期分區 fallback。保留 valid-empty 診斷，不產相容性草稿；補證後仍無活動才報 empty／no-activity。query 耗額或 adapter/process 失敗不以新預算重啟日期讀取。
- Metadata 只對已知 `threads` 做必要唯讀 schema／index 核對。依欄位 NULLability 省略不可能的 NULL／秒 fallback 分支；其餘 created／updated 秒／毫秒查詢欄位須有 leading-column、非 partial 的既有 index。每個必要 updated range 與 unknown/null 分支的 `EXPLAIN QUERY PLAN` 都須是 indexed `SEARCH`（含 covering index），沒有 `SCAN`／temporary sort，才開始候選讀取。毫秒優先，缺值才用秒；nullable 的未知時間候選保留，unknown 不推定。缺 index 或不安全 plan 明示 compatibility gap 與固定分支／正規化計畫診斷，改走有界日期 fallback；不建 index。`LIMIT` 與 deadline 另限回傳／執行資源，不能取代此 gate。
- SQL 資源預設 **10,000 rows、16 MiB serialized UTF-8 returned-row payload**；`-CodexQuerySeconds` 預設 15 秒，是涵蓋 SQLite 與 exact JSONL 讀取／解析的共用 adapter deadline。row cap 透過額外 sentinel row 偵測；payload 同時限制必要投影與 SQLite 單列長度。耗額時記錄 adapter、範圍及未讀區間。payload 是回傳列序列化大小，不是 SQLite 實體 I/O、token 數、延遲 SLA 或整個 process 記憶體上限。
- State metadata 只用 lifespan overlap 篩候選，不以建立日篩除早建 session；history SQL 先以實際 `EXPLAIN QUERY PLAN` 確認既有 index／PK 對 `thread_id` 作 `SEARCH`，拒絕任何 `SCAN`，不限制 index 名稱；可保留單一候選 thread 內的 ordinal 排序。缺安全計畫時產生缺必要 index 的 compatibility 草稿，跳過該 SQL 並繼續有界 exact 補證。Item 依實際 `created_at_ms`、type 與 turn/item 關聯取材，unknown/null 時間不推定。封存候選不因封存而排除。保留可辨識的 user／assistant 內容、tool evidence／output 及其 turn/call lineage；對每個候選仍讀取 exact JSONL 補證，projection EOF 不宣稱 interop 完整。
- SQL 的 repo cwd 是候選值；exact JSONL 的 session lineage 相符且同 turn 有明確絕對 cwd 時，校正該 turn 的鏡像及 SQL-only 證據歸屬，並以 `repoContext` 保留 thread／turn／file／line／byteOffset 來源。原始 detail／mirrorDetails／provenance 保留；不同 thread／turn 的 context 不互用，不同 call 的工具證據仍分開。
- SQL 精選本身不適用原 JSONL byte cap；exact rollout 及 legacy 日期分區的實讀 bytes 共用既有 `-CodexTotalBytes`／`-CodexFileBytes`，預設 **64／8 MiB**。Exact JSONL 單行上限 `-CodexExactLineBytes` 預設 **1 MiB**、可設 **64 KiB–8 MiB**；超長行丟棄至 newline 再續讀，buffered prefix、丟棄資料及後續讀取均只按實讀 bytes 計入原額度。Legacy 日期分區仍使用 **64 KiB** 行界限。

- 候選日期聯集維持起迄時間的 UTC 日期與 `Timezone` 日期之最小至最大值；先訪問指定時區的實際日期升序，再補 UTC 額外候選升序，最多開始 **32 日**的 partition path 檢查。日期只定位目錄，已選事件仍以 timestamp 判範圍。
- 每日只 lazy 列舉該分區第一層，跨日期共最多 **2,048 entries／128 JSONL 候選檔**。非 JSONL 與子目錄也計 entry；不排序、不展開子目錄，達限即 Dispose，不再呼叫 MoveNext。
- `-CodexTotalBytes`／`-CodexFileBytes` 預設為每次 **64 MiB**／每檔 **8 MiB**；只接受 **1 至 9,223,372,036,854,775,807 的整數 bytes**，可明確指定 **128 MiB／16 MiB**。單檔有效額度仍取單檔與全域剩餘額度的較小值。Probe 與 collection 使用相同額度；達限回報缺口，不自動加碼或重跑，也沒有無上限模式。參數例子見 [`README.md`](README.md#調整-codex-讀取額度)。
- Legacy 日期分區 FileStream.Read 每次最多 **4 KiB**且不超過剩餘額度，單行 buffer 為 **64 KiB**（LF 前的原始 bytes，含 BOM／CR）；exact adapter 使用 `-CodexExactLineBytes`（預設 1 MiB，範圍 64 KiB–8 MiB），其餘完整行、strict UTF8、超長行續讀與 byte accounting 規則相同。達 cap 停止後續候選搜尋。
- Legacy 日期 fallback 固定路徑最多檢查 **64 個 ancestor components**，拒絕 junction／reparse points；分區內巢狀目錄與 archive 都略過。檔案順序沿用 filesystem，不保證取到最新檔；恰好達 entries／files／totalBytes cap 也保守揭露限制。SQLite metadata 路徑可納入 archived 候選。
- `meta.sources.codex.coverage` 保留 `limits`、`daysConsidered`、`selectedDays`、`visitedEntries`、`candidateFiles`、`openedFiles`、`readBytes`、`enumerationFailures`、`limitHits`、`skipped`；新增 `candidateDays`（完整有序日期候選）、`visitedDays`（開始 path 檢查，與 `selectedDays` 相同，含不存在／被拒絕路徑）、`unvisitedDays`（達全域 cap 尚未開始檢查的候選）、`oversizedLines`（已讀到超過單行上限的行數）。Visited 不表示全日列舉完畢；未訪問集合為空也不表示完整。
- Legacy 日期 fallback 的 `stopReason` 只描述全域 traversal 終點：同時達限依 `totalBytes` → `entries` → `files` 優先，再為尚有未訪問候選的 `days`，否則 `candidate-days-exhausted`。局部 `fileBytes`／`lineBytes`／`pathComponents` 只在 `limitHits`；缺失目錄／列舉失敗看 `visitedDays`／`enumerationFailures`。Fallback 使用 `complete=false`／`strategy=date-partitions-no-cache`／`archive=skipped`；SQLite adapter 使用 `complete=false`／`strategy=state-history-exact-no-cache`／`archive=exact-candidates`。Counters 是 application-level MoveNext 與實際 FileStream.Read bytes，不代表 OS metadata／prefetch I/O。
- `probeWork` 分開記已知入口檢查數與成功 MoveNext 數；最多檢查兩入口、各消耗一 entry，`openedFiles=0`／`readBytes=0`。probe 沒有 collection coverage，不能推論當日活動。
- SQL adapter 的 `adapters`、`sqliteResources`、`runtime`、`unknownTimeEvents` 與 `compatibilityIssues` 是 additive 診斷，不擴張既有 `readStatus`／`collectionStatus` enum。Compatibility issue 只產生脫敏草稿，列出核對版本、schema/time 差異、影響、合成重現方式與目的地；只顯示草稿和目的地，不自動發布。只有使用者當次明確同意，才可發布。Missing、permission、valid-empty 不當作相容性問題，也不產草稿。
- 有事件且達限時為 `partial`；無事件且無損壞時保留 `empty`／`no-activity`，包含支援的 history DB missing 後 exact 純正常 byte cap；仍保留 missing adapter、limitHits 與 unread coverage。真正 permission／schema／runtime／unknown／已觀察到的損壞不因此改判 empty；選中事件全失敗保留 `failed`／`read-failed`。Legacy fallback 略過 archive 本身不算解析失敗；所有結果仍須說明不完整。

### Aggregate 診斷的計帳契約

以下 additive 欄位只存在於正式、可用 Codex 來源的 `coverage`；probe 及正式 `unavailable` 來源沿用「沒有 collection coverage」契約，而不是虛構已蒐集的零結果。可用但無候選／無事件時仍初始化欄位。全為 aggregate scalar 與固定五個 buckets，不新增逐檔路徑、內容或排序清單；formatter 完整保留 `meta`。

| 欄位 | 統計母體與邊界 |
| --- | --- |
| `fileCapStops` | 選中檔因單檔 byte cap 停止，且當次 `Position < Length` 確認尚有未讀 bytes，逐檔一次。單檔與全域同時達限、仍有尾部時也計一次（兩個 `limitHits`，全域 `stopReason=totalBytes`）；只有全域先達限不計。真正 EOF 恰好到 file cap 不計，即使 total cap 同時到仍保守記 `totalBytes`。讀取／metadata／處理失敗未確認此停止條件時不憑 size 或已讀量推測停止。 |
| `readBytesDistribution` | 成功開啟的每檔實讀量：`count=openedFiles`，`totalBytes=coverage.readBytes`，`minBytes`／`maxBytes` 為極值，無成功 open 時皆為 `null`（count／total／buckets 為 0）。空檔與 open 成功後失敗的檔案仍計，open 失敗不計；所有成功 `Read` 回傳 bytes 在 `finally` 入帳，包含丟棄／截斷／壞行與尚未解析的 chunk。不是檔案大小、session 數或 parsed JSON 行數。 |
| `readBytesDistribution.buckets` | 互斥固定桶：`zero` = 0；`upTo256KiB` = (0, 256 KiB]；`upTo1MiB` = (256 KiB, 1 MiB]；`upTo8MiB` = (1 MiB, 8 MiB]；`over8MiB` = > 8 MiB。桶數總和等於 count，明確提高 file cap 時仍用同一桶界。平均量可由 total／count 算，不累積樣本或 percentile。 |
| `oversizedDiscardBytes` | 已確認超過 line cap 的行中，已讀且經 reader 判定丟棄的原始 bytes，是 `readBytes` 的子集，不加算預算。跨 chunk 首次確認超長時追計 buffer prefix，再計後續已讀 segments；包含 BOM／CR 與已讀 LF。64 KiB prefix 加 LF 是合法邊界、不算超長；64 KiB prefix 加 CRLF 因 CR 超限，全部 65,538 bytes 算丟棄。EOF／cap／Read 失敗中止時只計實際判定的部分，不推估未讀尾部或中斷後未處理的 chunk。尚未讀到超過 64 KiB 的 capped 尾行不算超長。每個超長行的 `oversizedLines` 仍只計一次。 |
| `filesWithRangeEvents` | 每個候選檔保留至少一筆符合既有 parser 的範圍內事件才計一次，發生於鏡像／父子／續行去重之前。須 timestamp 在 inclusive From/To 範圍、可用 cwd 與有效非空文字／tool evidence；metadata-only、telemetry、範圍外事件、無 cwd、壞／丟棄行不計。多筆／重複事件同檔仍一次，不同檔貢獻相同去重事件各計一次；後段讀取／解析失敗不撤銷已保留事件。此 counter 不改 `readStatus` 或來源 guard，也不代表 unique sessions／repo 或最終證據列數。 |

解讀時把單檔停止、讀取量分布、超長行消耗占比與產出事件的檔數一起看，並保留達限、未訪問、archive、範圍外續行及失敗缺口。不能從達限本身判斷額度太小、從桶推算遺漏事件數，或把「成功 JSON 行／證據列／有事件檔／session」互換。既有日期、source 優先、Read 與事件收集策略不因診斷改變。

Legacy 日期分區上限限制 filesystem 訪問與 transcript 讀取；日期候選陣列仍隨要求範圍成長，reader buffers 不隨 byte 額度成長，但不限制事件清單或整個 PowerShell process 記憶體。SQL payload／deadline 也不代表實體 I/O 或 token 成本。64／8 MiB 是 JSONL 已確認預設，不是最佳門檻或 latency SLA；不宣稱真實歷史 100% recall、固定成本比例或性能倍率。

## Evidence views 與私有原始證據

大型 collection 與 ERP 整理先依 [`references/evidence-views.md`](references/evidence-views.md) 的可執行流程：PS5.1／7 呼叫端只傳檔案路徑，pwsh 7 child 明確以 UTF-8 capture，JSON 參數與多行 Python 走檔案。將原始 JSON 直接存入私有 task-local 暫存，再以 formatter `-InputPath` 及 repo／session 選讀必要欄位。不可先把整份原始 JSON 送入主上下文再壓縮。私有檔只供當次任務，完成後清理，不提交或公開。

- 預設 `summary`：`shownCommits` 最多 8、PR 文字引用、全部 `sessionEvidence`、`meta`／warnings／errors。Codex 已知正常的 routine tool 僅顯示 status／exit／source IDs，`detailRef` 的 JSON pointer 指回同次 raw collector JSON（`-InputPath` 時另附檔名）；按需讀取，不重 collect。失敗、驗證、交付／成功 readback、需求與 structuredContent／_meta 保守完整展開，依內容及同 source/session/turn 證據判斷，不按同名工具合併工作。適合一般日報，但不保證 ERP 歸屬證據保真。
- ERP 使用 `-View erp`：不套 commit 上限；以無縮排 JSON 保留每個 repo 的 `githubRepo`、`source`、`isGitRepo`、完整 commits（refs／branchHints）、PR（head／Draft／state／closing issues）、全部 session／續行、warnings 及完整頂層 meta／sources／coverage／errors。省略 repo `path`，缺值維持缺值；這仍是私有證據，不是公開用的去識別輸出。
- 單次 collection 只解析一次 viewer，並共用同 canonical repo 的 PR list／detail 結果；每個 worktree 仍獨立依當日證據過濾。重用只活在此次執行，不跨任務保存。

## High-commit repos

When a repo has many commits, summarize themes instead of dumping commits. Use compacted `shownCommits` as evidence, keep `shownCommits.Count <= 8` by default, and turn low-signal PR titles such as `noop` into `lowSignalPrRefs` like `PR #238 [MERGED]` instead of user-facing bullets like `PR #238: noop [MERGED]`.

## Required checks

- Helper script output is valid JSON only.
- 正式蒐集前已完成 probe 與對話來源預告；無來源或讀取全失敗時停止，不產生日誌。
- CLI 不存在但紀錄可讀仍可用；所有可用來源一併蒐集，partial coverage 明講缺口。
- Codex 優先使用 state metadata → history item → exact JSONL；SQL metadata 可含 archived 候選，fallback 才使用有界日期分區並略過 archive。事件依自身 timestamp，未選日期續行仍可能漏收；跨來源相同主題由 agent 合併。
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

Use grouped bullets like this (illustrative only; not real repo results):

```text
- **sevenflanks/repo-a**
  - 已修正初始化參數遺失並補上回歸保護（均已合併），PR #49、#52
  - 新增 skills 功能（待合併），PR #53

- **repo-b**
  - 修正付款按鈕條件邏輯（已合併），PR #219
  - 完成查詢端修正（已合併），PR #220；續作仍待合併（Draft），PR #221
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
