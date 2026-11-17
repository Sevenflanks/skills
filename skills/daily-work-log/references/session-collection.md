# Session 既有蒐集契約

本文件只適用 `EvidenceSource=session` 及 combined 的 Session 分支。所有原參數、adapters、限制與回歸保留；以下 `SourceMode` 是 repo 探索，不是來源選擇。GitHub 主來源的規則見 [sources.md](sources.md)。呼叫公開入口時明填 EvidenceSource=session；combined 由 collector 內部協調，不另跑第二次 collect。

2. **Confirm scope and defaults**
   - If the user does not specify a clear time range, default range is today in the configured timezone.
   - This default is about missing explicit time range, not about auto-triggering on completely blank input.
   - The helper defaults to `Asia/Taipei`; override `From`, `To`, or `Timezone` when the user needs another range or timezone.
   - Allow overrides for `From`, `To`, repo source mode, or scan roots when the user asks.
   - Default repo discovery mode is `session`; fallback or broader discovery can use `scan` or `mixed`.
    - OpenCode 內部先用 `opencode db --format json`；Codex 先以 state metadata 的 lifespan overlap 定位候選，再以 history item 的實際時間精選，並以候選 session 的 exact JSONL 補證。兩來源可用時一併納入。
   - If the DB command is unavailable, fails, or returns invalid JSON, fallback order is DB, then `storage/directory-readme`, then OpenCode logs.
   - If the DB query succeeds and returns empty `[]`, treat that as authoritative for session discovery and do not fallback to file-based sources.
   - Default `authorScope` is `current`; broad identity matching uses current-user git config and GitHub viewer evidence when available.
   - If the current identity cannot be resolved, the helper warns and falls back to all authors instead of silently pretending current-user filtering happened.

3. **先 probe 並預告來源**
   - 依下方 invocation 使用 `scripts/capture-daily-work-log.ps1 -Mode probe`，將本次 `From`／`To`／`Timezone`、來源入口覆寫與 repo mode 寫入 UTF-8 JSON 參數檔。
   - 讀取 `meta.sources.opencode`／`codex` 的 `available`、`cliAvailable`、`reason`、`entries`，在對話先預告本次使用的來源與每個略過理由，例如：「本次合併 OpenCode 與 Codex；Codex CLI 不存在，但本機紀錄可讀。」
   - probe 只檢查已知紀錄入口與 command 存在；不掃完整歷史、不啟動 CLI、不讀 auth、config 或 secrets。入口可讀不代表有當日活動，也不保證正式讀取成功。
   - 任一來源有可讀本機紀錄，即使沒有 CLI 也可使用。OpenCode CLI 可供非互動式 DB 查詢；Codex 只有 CLI、沒有可讀紀錄時略過。
   - 若兩者 `available=false`，說明各來源原因後結束。即使使用者要求 `scan`／`mixed` 也遵守此停止條件。

4. **Run the bundled collector**
   - 使用 bundled capture `-Mode collect -ProbePath <同次-probe.json>`，參數檔沿用 probe。Helper 要求 `meta.probeOnly=true`、`errors=[]`、至少一來源 available 與 `from`／`to`／`timezone`，自動固定 probe 日界線並拒絕明傳不一致範圍。先完成對話公告才呼叫 collect。
   - Collector stdout 維持純 JSON；capture 直接寫私有 UTF-8 檔，成功時不印 raw stdout。兩來源皆可用時全數蒐集，collector 自身會重新檢查來源並阻擋無來源／讀取全失敗的呼叫。
   - 呼叫正式 collect 時，工具支援等待 timeout 設定就設為 **600000 ms**；這是工具設定，不是 script 參數，也不是效能 SLA。若工具不支援，揭露實際等待限制，不以重跑補足。
   - 逾時或未取得有效 JSON 時停止並回報，不自動重跑；工具 timeout 不改變既有來源 guard 或停止條件。
   - 工具等待 timeout 與資料讀取額度分開；Codex 的預設總額度／單檔額度仍依「Codex 有界涵蓋」辦理。
    - Codex adapter 需要 Python 3.11+；只對本機 Codex state／history 做唯讀 SQL。完整 runtime、capability 與 fallback 契約見 [`references/evidence-views.md`](references/evidence-views.md#codex-能力與-canonical-evidence)。
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
    - 檢查 Codex `coverage.complete=false`、日期／停止欄位、`limitHits`／`skipped` 及「Codex 有界涵蓋」診斷；即使 `success`、`empty` 或沒有未訪問日期，也只代表已選資料。有界空結果不能稱為「完整查過今天沒有工作」。若有 compatibility draft，依 Evidence views 先讀取並交付完整脫敏草稿，再進行任務結束清理。
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

