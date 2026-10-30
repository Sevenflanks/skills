# daily-work-log

`daily-work-log` 整理 OpenCode／Codex 活動、Git 跨 branch commits 與相關 GitHub PR／issue 證據。先以同一 collector 輕量 probe，由 agent 預告來源與略過原因，再正式蒐集並輸出適合貼上的主題分組日誌。Codex 使用 metadata 候選、SQLite history 精選及 exact JSONL 補證；`0.164.0-alpha.11.1` 是已核對的 reference contract，不是 runtime version gate。必要資料能力與 query safety 決定 adapter 可否讀取，所有涵蓋缺口均如實揭露。

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

1. 蒐集前只針對指定日期、使用者點名的 repo 與會影響本次 collection 的偏好 recall；沒有有用結果就停止搜尋並使用預設流程。沿用同任務仍有效的參數與查詢結果；handoff 本身不使它們失效。
2. 執行 collector `-ProbeOnly`；只檢查已知紀錄入口與 CLI 是否存在，不掃歷史、不執行 CLI、不讀 auth／config。根據 JSON 在對話預告本次來源與略過理由，再移除 `-ProbeOnly` 正式蒐集。兩來源皆可用就合併。
3. 若使用者未提供明確時間範圍，helper 會以 configured timezone 計算「今天」，預設為 `Asia/Taipei`。這裡指的是缺少明確時間範圍，不是任何空白輸入都自動觸發。若使用者需要其他 timezone、日期範圍、或掃描根目錄，應明確覆寫。
4. OpenCode 先查 `opencode db --format json`；若 DB 不可用、查詢失敗、或 JSON 無效，才依序 fallback 到 `storage/directory-readme` 與 OpenCode logs。沒有 CLI 但本機紀錄可讀仍可用。
5. 若 DB 查詢成功且回傳空陣列 `[]`，代表沒有 session repo 證據，這個結果具權威性，不再 fallback 到檔案來源。
6. 若 DB 失敗且 `storage/directory-readme` 沒有找到任何可解析 git repo / worktree root 的路徑，繼續 fallback 到 OpenCode logs；log fallback 會納入可解析成 git repo / worktree root 的 `permission=external_directory`、`permission=read`、`permission=read-only` touched path 證據。
7. `session` discovery 可將安全的彙總目錄展開成巢狀 git repo / worktree。
8. 預設 `authorScope` 是 `current`；若無法解析 identity，helper 會提出 warning 並 fallback 到 all authors。
9. 目前使用者過濾採用寬鬆 identity matching；`release` / `deploy` bot commit 只有在 PR-chain 證據連回目前使用者工作時才保留。
10. 有 session evidence 但沒有目前使用者 commit 的 repo，仍由有效 `origin` remote 解析 canonical `githubRepo`，保留 `sessionEvidence` 與無 commit 缺口。缺失／無法確認 remote 時不猜 mapping，資料夾名稱只作顯示 fallback。
11. 讓 helper 只輸出純 JSON，不混入說明文字。PowerShell collector 不產生自然語言摘要；agent 只能從 `sessionEvidence` 寫一條短摘要。
12. 由 skill 檢查 JSON 內的 warning / error / `ghAvailable` / `ghViewer` 狀態；若 `gh` 不可用或未登入，預設先停止並建議安裝 GitHub CLI 或執行 `gh auth login`。
13. 只納入可解析成 git repo 或 worktree root 的路徑，其他缺口要透過 warning 或最終註記說清楚。
14. 依 `githubRepo` 的 GitHub repo name 分組，若缺少 `githubRepo` 才 fallback 到 repo 資料夾名稱，並將內容壓成簡短工作日誌條列。
15. 只有使用者強烈堅持在沒有可用或已登入 `gh` 的環境繼續時，才產生降級日報並在最終輸出保留 PR / issue 補證缺口；repo 非 git、或今日有 session 但無 commit，也要保留資料缺口說明。
16. 選定主題後、preview 前，對實際引用且影響成果／待辦的 issue，以可靠 canonical repo＋精確編號查當前 state。同 repo＋編號去重，跨 repo 同號分開查；PR closing reference／`issuesClosed` 只證明關聯。查詢失敗或無法判讀就保留 unknown 與缺口，不擴搜。補報要區分查詢時狀態與報告日成果，不能倒推歷史，也不能以狀態補查取代當日工作證據。

本輪查詢與先前準備只在輸入仍有效時沿用；新證據或失效時只刷新受影響項。補證不擴大工作主題，也不代替當日工作證據。

## Consuming-agent smoke

#47 的六案 bounded consuming-agent smoke 中，daily-work-log 的 36、37-r2、38、39、40-r2 通過：36 對 shared#18／tools#18 各 lookup 1 次，分別辨識 OPEN／CLOSED；37 首輪因 fixture 缺 closing reference 為 partial，修正後 r2 精確查詢 1 次，以 404 保留 unknown／工作；38 分開現在 CLOSED 與歷史 OPEN；39 recall、probe、collect 各 1 次，來源預告在 probe 與 collect 間；40 首輪因額外工具呼叫失敗，co-location 修正後 r2 沿用既有 OPEN、無額外工具呼叫。這是各案獨立 Task context 的有限 smoke（host 仍注入 deja 歷史），不是完整盲測或普遍可靠性保證；ERP 53 範圍見 [`erp-daily-work-log evals`](../erp-daily-work-log/evals/README.md)。

## 多來源與停止條件

### OpenCode 的 repo 歸屬

`0.5.1` 修正相對 session path 依 collector CWD 誤歸 repo，並以當日 structured bash workdir 補回 home-started session 的外部工作 repo。完整來源、時間、2,048 + sentinel、4,096 長度、partial 與 missing worktree 契約見 [`SKILL.md` 的 OpenCode repo discovery](SKILL.md#opencode-repo-discovery)。只讀必要結構化 metadata；不解析 command／文字／output、不新增 cache 或 DB schema。Cap 是候選列數限制，不是 DB I/O 或 latency 保證。

例如 synthetic home-started parent 可保留 `pathSource=bash-workdir`、`tool=bash`、`timestamp` 歸到 `C:\synthetic\repo`；相同 session／path 只列一次。已刪 worktree 不猜 canonical repo，只揭露 aggregate warning。DB 成功空結果、失敗 fallback 順序與 probe 契約維持。

Codex 從 `-CodexRoot`（否則 `CODEX_HOME`，再否則 `~/.codex`）唯讀 state／history SQLite，以 state lifespan overlap 找候選、history item 的實際時間與 turn/item 關聯精選，再對候選 exact JSONL 補證。metadata 日期只代表候選，不代表實際工作日期；封存候選可納入。必要 schema、時間、內容與 indexed query capability 才是 SQL gate；實際 plan 必須為 indexed `SEARCH`，拒絕 `SCAN`，不建立 index 或進行全表查詢。版本不同、unknown 或 missing 只作診斷，不單獨 reject／降級／產草稿。Python 3.11+ 必要，child JSON pipe 固定 UTF-8。單筆壞 item 隔離，不取消其他有效 evidence；canonical `item_completed` 與 SQL mirror 依實際 item identity 合併並保留 provenance。能力缺口走既有有界 fallback 並可能產生本機 adapter capability 草稿；missing、permission、valid-empty 不產草稿。Exact EOF 不代表來源完整。完整欄位、fallback 與安全 contract 見 [`references/evidence-views.md`](references/evidence-views.md#adapter-contract-與-diagnostics)。

History DB 缺檔時，若所有已選 exact 候選的 session identity 相符、無損讀至 EOF，且沒有未知時間、SQL 限額或相容性／權限缺口，無範圍內活動可回報 `empty/no-activity`；仍保留 history `missing` 診斷與 `coverage.complete=false`。缺檔本身不授予成功，損壞或無法確認 lineage 仍依失敗／部分讀取契約處理。

Exact 父子／續行重播在所有 session 的 SQL／JSONL reconciliation 之後合併：實際 session metadata 須核對成功且構成可信祖先鏈，cwd、turn、時間、role、全文及原始事件 identity 均相同；完整原始事件的 SHA-256 存於 exact provenance 的 `eventIdentity`。保留 `sessionIds`、`files`、`timestamps`、所有 provenance 與 mirror details；不同工作、call、turn、cwd 或只有 state parent 提示不合併。逐 session reconciliation 計數保留合併前的結果。

Legacy 日期分區 fallback 的 cap、日期與停止策略見 [`SKILL.md` 的「Codex 有界涵蓋」](SKILL.md#codex-有界涵蓋)：32 日期、2,048 entries、128 候選，預設 64 MiB total／8 MiB file／64 KiB line，固定路徑最多 64 ancestor components。指定時區的實際日期升序優先，再補 UTC 額外日期；filesystem 訪問 lazy 達限即停，不排序歷史檔案。首次、重跑與錯誤都不全掃，也不先全列再 filter。

SQL 與 JSONL 資源分開計帳：SQL 預設最多 10,000 rows、16 MiB serialized UTF-8 returned-row payload；15 秒 deadline 共用於 SQLite 與 exact JSONL 讀取／解析。Payload 不代表實體 I/O、token 或成本。候選 exact JSONL 預設單行上限 1 MiB，可調 64 KiB–8 MiB；讀取 bytes 仍使用原 total/file 額度 64／8 MiB。Legacy 日期分區仍用 64 KiB line cap。細節及未讀範圍診斷見上方 SKILL.md。

`coverage.complete` 固定為 `false`。新增日期與停止欄位的解讀見下方；`success`／`empty` 只描述已選資料，不能說完整查過沒有工作。Legacy 日期 fallback 使用 4 KiB chunks 與 64 KiB line buffer；exact JSONL 使用可調 line cap（預設 1 MiB），同樣以 4 KiB chunks 讀取。超長行丟棄至 newline 後續讀，實讀及丟棄 bytes 仍計額度。行長以 LF 前原始 bytes 計算，含 CR／BOM；完整行才解碼與解析。Byte 截斷尾行不當作損壞 JSON；完整壞 UTF8／JSON 保留警告與前後 evidence，仍遵守 failed／partial 契約。Probe 的 `probeWork` 分開記錄入口檢查與單 entry 訪問，不開 transcript。

### Coverage 欄位怎麼讀

| 欄位 | 意義 |
| --- | --- |
| `candidateDays` | 完整、有序的候選日期聯集；指定時區日期在前，UTC 額外候選在後。 |
| `visitedDays` | 已開始 partition path 檢查，包含不存在或被拒絕的路徑。與既有 `selectedDays` 相同，數量為 `daysConsidered`；不是全日列舉完成。 |
| `unvisitedDays` | 因全域 cap 尚未開始 path 檢查的候選。空陣列也不能宣稱完整。 |
| `stopReason` | 全域停止原因：`totalBytes`、`entries`、`files`、`days` 或 `candidate-days-exhausted`；同時達限依此前四項的順序呈現。最後一項只表示候選 traversal 結束。 |
| `oversizedLines` | 已讀到超過 64 KiB 的行數，每行只計一次，包含丟棄中到 EOF／byte cap 的行；不是 JSON parse failure 數。 |
| `fileCapStops` | 尚有未讀 bytes 且因單檔 cap 停止的檔數；真正 EOF 恰好達限不計，global／file 同時截斷仍計一次。 |
| `readBytesDistribution` | 成功 open 的實讀量分布：count、totalBytes、minBytes、maxBytes 與固定五桶；空檔與中途失敗計入，open 失敗除外。無樣本極值為 null。 |
| `oversizedDiscardBytes` | 已確認超長行的實讀丟棄 bytes，含 buffered prefix 與已讀 newline；是 readBytes 子集，不再加算預算。 |
| `filesWithRangeEvents` | 去重前有保留範圍內事件的檔數，逐檔一次；不是 session 數或最終證據列數，後段失敗仍保留計數。 |

詳細計帳、桶界、錯誤與去重定義以 [`SKILL.md` 的 aggregate 契約](SKILL.md#aggregate-診斷的計帳契約) 為準。Probe／不可用來源沒有 collection coverage；可用空來源則有零 counters、空分布。新增統計只使用固定大小 aggregate state，不保存新的逐檔路徑／內容。

例如讀了 8 檔、64 MiB、8 次單檔停止、48 MiB 超長行丟棄，只有 2 檔產出範圍內事件，表示實讀量有 75% 用於已判定的超長行；不是「只有 2 個 session」，也無法推算漏了多少事件。要同時揭露 total cap、未訪問候選、archive／分區外續行；達限不能單獨證明額度不足或最佳值。

`limitHits` 保留所有達限訊號，包括局部 `fileBytes`／`lineBytes`／`pathComponents`。局部達限仍可續讀其他候選，所以 `stopReason=candidate-days-exhausted` 可以同時有局部缺口；列舉失敗另看 `enumerationFailures`。Archive／範圍外續行、未讀完檔案或同日未列舉 entries 都可能漏收。恰好達 entries／files／totalBytes cap 保守回報，不額外讀取來證明完整；單檔在真正 EOF 恰好到 file cap 則不記 `fileBytes`。

JSON `meta.sources` 分別回報 OpenCode／Codex 的可用性、CLI 存在、入口原因與 `readStatus`：

| 狀態 | 意義 |
| --- | --- |
| `unavailable` | 無可用入口；說明略過理由。 |
| `not-read` | probe 尚未正式讀取，不能推論當日活動。 |
| `empty` | 已選資料無範圍內活動，仍可能漏收。 |
| `success` | 已選資料讀取成功且有範圍內證據，仍可能漏收。 |
| `partial` | 部分紀錄失敗或有活動但達限，使用已讀證據並揭露缺口。 |
| `failed` | 正式讀取失敗，不能當成無活動。 |

`meta.collectionStatus=no-sources` 或 `read-failed` 時停止，不掃 Git／GitHub、不產生日誌；直接呼叫 collector 同樣受 guard 保護。`no-activity` 只說明沒有當日證據。正式 collection 的 `meta.canGenerateLog=false` 或 `errors` 也不得憑記憶補日誌。部分來源成功可繼續，但指出讀取／略過缺口。

`scan`／`mixed` 保留原有跨 branch Git、worktree、current-author 與相關 PR 補證；也須先通過來源 guard。Codex 只有 CLI、沒有本機紀錄時略過。這個 skill 不自動安裝／登入 CLI、不修改來源資料、不新增其他 agent 來源。

## 執行與驗證

### 摘要的交付狀態

按 [`SKILL.md` Workflow 第 6 步](SKILL.md#workflow) 先對照交付證據，再合併同 repo／跨來源相同主題；不同實質工作仍分開，優先保留成果與待辦。例如：

- 「登入修正已合併 #31；續作待合併 #33（Draft）」：前者需 MERGED，後者 OPEN 且已知 Draft；同主題不重複照抄 OpenCode／Codex 標題。
- 「處理匯出截斷問題（session-only；尚無 commit／PR 證據）」：僅標題可支持處理主題，不宣稱驗收通過、部署成功或已合併。
- 「取消舊方案 #34（已關閉、未合併）」：CLOSED 不等於已交付；commit 或 bot release 也不能替代 merge／實際部署證據。

Formatter 保留 PR state，`[OPEN]` 包含 Draft 可能性；未保留 `isDraft` 時只寫待合併，不猜 ready。Session 標題本身即使寫「驗收通過」也須結果補證，才能用成果用語。

```powershell
pwsh -NoProfile -File "<skill>\scripts\collect-daily-work-log.ps1" -ProbeOnly
# agent 在對話預告，再將 probe meta.from/to 固定傳入正式 collection。
pwsh -NoProfile -File "<skill>\scripts\collect-daily-work-log.ps1" -From "<probe-from>" -To "<probe-to>"
```

`-OpenCodeLogRoot`、`-OpenCodeStorageRoot`、`-CodexRoot` 可覆寫紀錄入口；collector／formatter stdout 均為純 JSON。formatter 保留新增 metadata 與全部 `sessionEvidence`，只對 shown commits 做上限 compaction。

### 證據視圖與私有落檔

大型原始 JSON 直接落入當次私有暫存，依 [`references/evidence-views.md`](references/evidence-views.md) 的完整流程，用 formatter `-InputPath $rawPath -View index` 讀 bounded status／counts／limits／raw pointers，再按需讀取 ERP `$evidence` 的 repo／session。Index 的 count 或 pointer 不是完整 evidence，也不是 draft delivery。若有 compatibility draft，另以 `-View compatibility` 讀取完整脫敏 title／body／destination，先在對話展示全文、目的地並註明未發布；render 不代表交付，完成實際交付後才清理。ERP 視圖保留全部 commits／refs／branchHints、PR head／Draft／closing issues／交付狀態、來源／續行、meta／coverage／warnings／errors，只移除 repo path 與排版空白，不任意截斷。證據檔仍是私有資料。

Windows PowerShell 5.1 的預設 redirect 會產生 UTF-16LE；上述 recipe 在 pwsh 7 child 內明確 capture UTF-8，支援 PS5.1 → pwsh 7 與 pwsh 7 直接呼叫。JSON 參數及多行 Python 存在當次暫存檔，跨 process 只傳路徑；先看缺口／repo 索引，再選 repo／session，不將大型 raw 或無效 recall 灌入上下文。無效 recall 停止搜尋且不作成果證據。沿用 probe → 公告 → collect、停止條件與任務結束清理。

同次 collection 重用 viewer 與 canonical repo 的 PR 查詢，worktree 關聯仍獨立判斷。同作者的當日 PR commit 若無該 worktree hash／branch 關聯也不收；session-only 不自造完成成果。Resolver 原因未明的 HTTP 400 只回報解析失敗，不逐 branch 猜、不當作 missing mapping。

### 調整 Codex 讀取額度

PowerShell 7+ 使用 `-CodexTotalBytes`／`-CodexFileBytes` 指定**正整數 bytes**，預設為 64／8 MiB。以下例子明確使用 128／16 MiB，probe 與 collection 共用範圍及額度：

```powershell
$parameters = @{
  From = '2026-05-29T00:00:00+08:00'
  To = '2026-05-29T23:59:59+08:00'
  Timezone = 'Asia/Taipei'
  CodexTotalBytes = 128MB  # PowerShell 的 MB 為 1,048,576 bytes，即 MiB。
  CodexFileBytes = 16MB
}
& '<skill>\scripts\collect-daily-work-log.ps1' @parameters -ProbeOnly
# agent 依 probe JSON 預告來源後，正式蒐集同一範圍。
& '<skill>\scripts\collect-daily-work-log.ps1' @parameters
```

有效範圍為 1 至 9,223,372,036,854,775,807 的整數 bytes；0、負數、小數、NaN、Infinity、`unlimited` 與超出範圍的值均拒絕。單檔實際讀取上限是單檔額度與全域剩餘額度的較小值，允許 file 設定大於 total。Legacy 64 KiB line cap 與其餘訪問上限不隨參數增加。達限只揭露缺口，不自動加碼或重跑；提高額度也不保證完整。

另有 SQL 與 exact 單行參數：`-CodexSqlRows` 預設 10,000（1–100,000）、`-CodexSqlPayloadBytes` 預設 16 MiB（1 KiB–64 MiB）、`-CodexQuerySeconds` 預設 15 秒（0.01–120 秒，共用 SQLite／exact adapter deadline）；`-CodexExactLineBytes` 預設 1 MiB（64 KiB–8 MiB）。SQL deadline／row／payload 耗額會揭露未讀範圍，不以新預算重新啟動 legacy reader。SQL payload 只計回傳 row 的 serialized UTF-8 大小，不是實體 I/O、token、成本或整體記憶體界限。

合成測試隔離全部入口與 CLI，不讀真實 transcripts。新增多來源 tests 使用 Git／GitHub 公開邊界 stub；既有 Pester 回歸使用合成 Git repo 與 OpenCode／GitHub CLI stub，驗證 `--all`、作者過濾與 PR 關聯。

```powershell
pwsh -NoProfile -File skills/daily-work-log/tests/bounded-collection.tests.ps1 -Case all -EvidenceRoot "<existing-external-temp-directory>"
pwsh -NoProfile -File skills/daily-work-log/tests/multi-source.tests.ps1 -Case all
Invoke-Pester -Script skills/daily-work-log/tests/collect-daily-work-log.tests.ps1
pwsh -NoProfile -File skills/daily-work-log/tests/diagnostics.tests.ps1 -EvidenceRoot "<existing-external-temp-directory>"
pwsh -NoProfile -File skills/daily-work-log/tests/repo-discovery.tests.ps1 -Case all -EvidenceRoot "<existing-external-temp-directory>"
pwsh -NoProfile -File skills/daily-work-log/tests/evidence-view.tests.ps1 -Case all -EvidenceRoot "<existing-external-temp-directory>"
pwsh -NoProfile -File skills/daily-work-log/tests/windows-capture.tests.ps1 -EvidenceRoot "<existing-external-temp-directory>"
npm run validate
```

## 有界驗證與量測

`windows-capture.tests.ps1` 在 PS5.1 → pwsh 7 與 pwsh 7 → pwsh 7 實際執行 evidence-view recipe；只替換 collector 為合成輸出，formatter 使用既有 CLI。驗證中文／多行／引號／大型 JSON 往返、參數檔、Python 選讀與跨 worktree 續行；`-Mutation utf16` 應在 UTF-8 斷言失敗。測試 child 的 execution policy 旗標只影響該 process；當次 runtime 暫存自動清理，指定 EvidenceRoot 才保留合成 JSON。

`evidence-view.tests.ps1` 以合成雙 worktree／OpenCode＋Codex 續行、git／gh 公開邊界替身驗證 canonical、查詢次數、worktree PR 隔離、錯誤缺口、ERP 欄位與 default 相容。`-Case reuse -BaselineRevision 9ff9580 -MeasureOnly -EvidenceRoot '<external-temp>'` 可對同一 fixture 量測基線，移除 baseline／MeasureOnly 即測目前版。保留 sanitized `collection.json`、`query-counts.json`；`-Case formatter` 保留合成 input／ERP view／UTF-8 bytes。界限與 mutation 對應見 [`tests/evidence/README.md`](tests/evidence/README.md)；沒有真實 GitHub、個人歷史或 latency 結論。

`bounded-collection.tests.ps1` 只建立並清除本次合成來源，隔離 OpenCode、Git／gh；驗證額度 binding、日期飢餓、多日／負時區、巨大日期跨度、entries／files／bytes、ancestor／junction、UTC／時區含頭尾、選中父子／續行去重與狀態。串流案例涵蓋 UTF8 跨 chunk、BOM／CRLF、64 KiB exact／超限、超長行 EOF／丟棄期間達 cap、完整壞 UTF8／JSON、真正 EOF 與 capped tail。增加 2,000 範圍外壞檔，選中 4 檔的訪問與 bytes 保持不變。

`-Case long-session` 將三筆事件放在 2／8／16 MiB 後，16／2、64／8、128／16 MiB profiles 各收到 0／1／2 筆；新預設改善涵蓋，但仍有缺口。`-Case date-priority` 在前日資料超出總額度時仍收到指定日期四筆，`-Case line` 保留 3 MB 超長行前後兩筆。各案例可用 `-EvidenceRoot` 保留 sanitized JSON、耗時與 process high-water memory，供 PR reader 摘錄；run artifacts 留在外部 TEMP，不提交 repo。

`-Case benchmark -EvidenceRoot "<existing-external-temp-directory>"` 以 64 選中檔與 100→10,000 範圍外舊檔，分別記錄 probe／collection／隔離 synthetic enumerate-read-parse reference 的冷暖耗時、實際 entries／opened files／read bytes、process high-water memory 與原始 JSON UTF-8 size。產物為 `benchmark-measurements.json`、`benchmark-scope.json` 與替換絕對 fixture 路徑的代表性 JSON，可供 PR 引用。Reference 只在合成測試內使用，沒有 production fallback。

冷是同一測試 process 在 fixture 增量後首次呼叫，暖是重跑；不控制 OS filesystem cache。Collection 計時包含 collector 的 probe、合成 Git／gh 邊界呼叫與 JSON 序列化，排除 fixture 建立及外部測試啟動。Memory 為整個測試 process 累積 `PeakWorkingSet64`，包含 fixture 建立與 reference，不代表 collector-only、child processes 或每次配置量。Entries 是 application-level MoveNext，bytes 是 FileStream.Read 回傳量，排除 OS metadata／prefetch。Reference 不執行 Git／gh 或完整 collector，耗時不能當作同等流程的速度提升比例；其 output size 不適用。日期候選陣列隨要求日期範圍成長；4 KiB／64 KiB 只限 reader buffers，不是事件清單或整個 process 的 hard memory cap。64／8 MiB 是已確認預設，不是最佳門檻或性能 SLA；本回歸未確認真實 workload。

## 版本變更

`0.8.0` 新增 formatter bounded index／compatibility views、source discovery 計帳索引與 canonical Codex evidence contract。版本白名單不再作 runtime gate；必要能力仍受 indexed query、安全時間／內容與有界 fallback 約束。新增先交付草稿再清理的 consumer flow。

`0.7.1` 修正 NOT NULL 欄位的不可達日期分支及 covering index 誤拒，補上脫敏 query-plan 診斷；保留真實 SCAN／排序拒絕、唯讀 DB 與既有 fallback 額度。補強 Windows 呼叫端的 UTF-8 capture、參數檔及大型證據按需選讀範例。

`0.7.0` 新增 Codex state metadata 候選、SQLite history item 精選與 exact JSONL 補證；核對 Python 3.11+ 與 Codex `0.164.0-alpha.11.1` contract，加入 SQL rows／payload／deadline 診斷及脫敏相容性草稿流程。維持有界讀取與既有 JSONL 額度；草稿僅於當次明確同意後才可發布，不宣稱完整 recall 或成本倍率。

`0.5.1` 修正 CWD-dependent OpenCode 相對 path，新增單一有界當日 structured bash workdir 補證、session/path 去重、missing worktree 防誤歸與 partial 揭露。新增實際 SQLite SQL discovery boundary 與 collection/formatter 回歸；Git／gh、Codex 64／8 MiB 及其他既有 caps 維持。Boundary tests 需本機 Python 3 的標準庫 `sqlite3`，production collector 沒有 Python dependency。

`0.5.0` 新增 aggregate 單檔停止／實讀分布／超長行丟棄 bytes／有範圍事件檔數，補足失敗與去重計帳、formatter 保留回歸及交付狀態摘要 evals。維持 64／8 MiB、既有排序／其他 caps、事件與 readStatus 契約；合成 fixture／stream faults／CLI stubs 並未驗證真實 workload 或實際摘要模型執行品質。

`0.4.0` 新增可調 byte 額度，預設提高至 64／8 MiB；指定時區日期優先、超長行後串流續讀，新增 additive 日期／停止／超長行 coverage。既有 `readStatus` 與 formatter 相容；仍可漏收，沒有無上限或達限自動重跑。

`0.3.0` 將 Codex 完整歷史涵蓋改為有界、可漏收；新增 coverage 與 probe counters，archive 正式略過。呼叫參數不變，摘要必須明講涵蓋缺口。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`scripts/collect-daily-work-log.ps1`](scripts/collect-daily-work-log.ps1)：資料蒐集 helper，輸出純 JSON。
- [`evals/evals.json`](evals/evals.json)：評估案例。
- [`tests/bounded-collection.tests.ps1`](tests/bounded-collection.tests.ps1)：搜尋／I/O 上限、舊歷史增量與 synthetic benchmark。
- [`tests/multi-source.tests.ps1`](tests/multi-source.tests.ps1)：來源組合、停止條件、Codex 選中跨日／去重、archive 略過與 formatter 合成測試。
- [`tests/collect-daily-work-log.tests.ps1`](tests/collect-daily-work-log.tests.ps1)：既有 OpenCode、Git／PR 與 formatter 回歸。
- [`tests/diagnostics.tests.ps1`](tests/diagnostics.tests.ps1)：僅載入 production functions，注入合成 Stream 的 Read／Dispose 失敗，驗證 catch／finally 計帳；不執行真實來源 probe。
- [`tests/repo-discovery.tests.ps1`](tests/repo-discovery.tests.ps1)：production discovery functions、synthetic SQLite SQL、CWD invariance、時間／cap／partial／missing worktree／fallback 與 formatter；[`tests/discovery-db-fixture.py`](tests/discovery-db-fixture.py) 只建立 in-memory synthetic DB。
