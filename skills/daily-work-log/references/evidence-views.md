# 私有證據落檔與 ERP 結構視圖

先完成 probe → 對話來源預告，再正式 collect；工具 collect timeout 沿用 600000 ms。來源 guard、無活動停止、Codex 有界額度與無自動重跑規則照常適用。以下支援 Windows PowerShell 5.1 或 PowerShell 7 作為呼叫端，collector／formatter 一律在 **pwsh 7+** 執行。

## 1. 明確 UTF-8 capture，JSON 參數走檔案

PS5.1 的 `>`／`Out-File` 預設是 UTF-16LE。固定使用 bundled `scripts/capture-daily-work-log.ps1`：PS5.1／7 呼叫端只傳路徑，helper 在 pwsh 7+ child 讀 UTF-8 JSON 參數並寫 BOM-less UTF-8；成功時不印 raw stdout。無須每輪撰寫 capture 或 Python 選讀程式，也不改全域 encoding。`Mode` 明確選 `probe`、`collect`、`format`，一次只執行一次，不自動重試。

設定 `$skillRoot` 為實際安裝目錄，`$parameters` 為本次範圍與來源覆寫；原本省略時間可先省略 From／To，正式 collect 前再固定 probe 日界線。各區塊沿用同一個呼叫端 session 的變數。這是私有中間證據，不是最終日報寫檔授權。

```powershell
# recipe: setup
$parameters = @{ From = '<probe-from>'; To = '<probe-to>'; Timezone = 'Asia/Taipei' }
$tempParent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $tempParent -PathType Container)) { throw 'Temporary parent is unavailable.' }
$taskRoot = Join-Path $tempParent ('daily-work-log-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $taskRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
$collectorPath = Join-Path $skillRoot 'scripts/collect-daily-work-log.ps1'
$formatterPath = Join-Path $skillRoot 'scripts/format-daily-work-log-evidence.ps1'
$capturePath = Join-Path $skillRoot 'scripts/capture-daily-work-log.ps1'
$parametersPath = Join-Path $taskRoot 'parameters.json'
$probePath = Join-Path $taskRoot 'probe.json'
$rawPath = Join-Path $taskRoot 'collector.json'
$erpPath = Join-Path $taskRoot 'erp-evidence.json'
$indexPath = Join-Path $taskRoot 'evidence-index.json'
$compatibilityPath = Join-Path $taskRoot 'compatibility-drafts.json'
[IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 100), $utf8)
```

PS5.1 與 7 均可執行下面呼叫；空白、中文、引號與多行值留在參數檔，不拼 command string。`ScriptPath` 預設依 Mode 選 bundled collector／formatter；以下明列路徑方便測試替換外部 collector。參數檔不放 `ProbeOnly`，由 Mode 決定。

```powershell
# recipe: probe
& pwsh -NoProfile -File $capturePath -Mode probe -ScriptPath $collectorPath -ParametersPath $parametersPath -OutputPath $probePath
if ($LASTEXITCODE -ne 0) { throw 'Probe failed; stop without collection.' }
$probe = Get-Content -LiteralPath $probePath -Raw -Encoding utf8 | ConvertFrom-Json
$probe.meta | ConvertTo-Json -Depth 100 -Compress
```

先讀 probe，向使用者公告各來源／略過理由；兩來源均 unavailable 時在此結束。公告完成才執行下一段，不能把兩段合成無條件自動 collect。沿用同任務已完成的 probe／collect；逾時、非 JSON 或讀取全失敗就回報並停止，不重收、不加 fallback 預算。

```powershell
# recipe: collect
& pwsh -NoProfile -File $capturePath -Mode collect -ProbePath $probePath -ScriptPath $collectorPath -ParametersPath $parametersPath -OutputPath $rawPath
if ($LASTEXITCODE -ne 0) { throw 'Collection failed; retain diagnostics and stop without retry.' }
```

Collect 要求同次成功 probe：`meta.probeOnly=true`、`errors=[]`、`meta.sources` 至少一來源 available，且有 `meta.from`／`to`／`timezone`。Helper 自動固定該範圍；明傳不一致值就拒絕，不能跨午夜改成新一天。來源公告仍由 agent 在兩次呼叫間完成，helper 無法代替公告。原始 JSON 不印到工具輸出；檔案存在／exit 0 不代替檢查 JSON 的 errors 與狀態。

接著只對既有檔案執行 formatter，不重 collect、不接 ERP、不補查 API。`-InputPath` 與 stdin JSON 擇一；舊 collector JSON 仍可使用。

```powershell
# recipe: format
$viewParametersPath = Join-Path $taskRoot 'view-parameters.json'
$viewParameters = @{ InputPath = $rawPath; View = 'erp' }
[IO.File]::WriteAllText($viewParametersPath, ($viewParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $viewParametersPath -OutputPath $erpPath
if ($LASTEXITCODE -ne 0) { throw 'Formatter failed; stop and inspect the existing capture.' }
```

## 2. 以 bounded index 讀缺口與 repo 索引

```powershell
# recipe: index
$indexParametersPath = Join-Path $taskRoot 'index-parameters.json'
$indexParameters = @{ InputPath = $rawPath; View = 'index' }
[IO.File]::WriteAllText($indexParametersPath, ($indexParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $indexParametersPath -OutputPath $indexPath
if ($LASTEXITCODE -ne 0) { throw 'Index formatting failed; inspect the existing capture.' }
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 | ConvertFrom-Json
$index | ConvertTo-Json -Depth 100 -Compress

# 完整 ERP 視圖保留在 $erpPath；只按需選讀，不把全文送進主上下文。
```

`-View index` 提供狀態、固定 scalar 診斷、limits、各陣列的 count／raw pointer 與 repo count，不複製完整 metadata 或明細。Unknown count 維持 `null`，不能解讀為零。`-InputPath` 的 raw refs 附上輸入檔名；stdin refs 不虛構 filename。先依 skill 檢查 errors／canGenerateLog／collectionStatus、每一來源 readStatus 與全部 coverage；`no-sources`／`read-failed`／`canGenerateLog=false` 時停止；`no-activity` 只說明無當日證據，來源失敗不當作無活動，`coverage.complete=false` 不改稱完整。依既有規則檢查 GitHub 可用性。索引中的 count 與 pointer 只協助定位，不是完整證據或交付內容。

若 index 顯示 `compatibilityIssues.count > 0` 或 count 為 unknown，使用 `-View compatibility` 檢查是否有草稿並讀取完整、已脫敏內容；只有已知 count 為 0 才可略過。Index count／pointer 只供定位，不能代替實際交付。依 `detailRef` 或 `$rawPath` 原始 JSON pointer 只在需要時讀其他欄位，不重 collect：

```powershell
# recipe: compatibility
$compatibilityParametersPath = Join-Path $taskRoot 'compatibility-parameters.json'
$compatibilityParameters = @{ InputPath = $rawPath; View = 'compatibility' }
[IO.File]::WriteAllText($compatibilityParametersPath, ($compatibilityParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $compatibilityParametersPath -OutputPath $compatibilityPath
if ($LASTEXITCODE -ne 0) { throw 'Compatibility view failed; inspect the existing capture.' }
$compatibility = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding utf8 | ConvertFrom-Json
$compatibility.drafts | ConvertTo-Json -Depth 100
```

對話中逐份呈現完整草稿、目的地及「尚未發布」狀態；先判斷目的地正確，只有使用者本次明確同意才可發布。Formatter render 成功不等於已在對話中交付，不能把 `published` 改成 true 或自行記錄 posted／delivered。先完成草稿的實際交付，再進入任務結束清理；若未完成交付，保留當次證據供續行。

需要歸屬或交付判斷時，按 index 選 canonical repo，對照所有 worktree 的完整 commits／PR／sessionEvidence。ERP 視圖不套 commit 上限且保留全文，仍可能很大；用以下固定 filters 分批選讀，不用 `First N` 隨意截斷，不省略第二來源或續行。預設 summary 的 routine tool `detailRef` 指回 `$rawPath`；critical 保留規則見 [`SKILL.md`](../SKILL.md#evidence-views-與私有原始證據)。

### 固定 repo／session 選讀

`GithubRepo` 以 canonical `owner/repo` 篩選全部 worktree（大小寫不敏感）；`SessionId` 精確且區分大小寫，匹配 `sessionId` 或續行 `sessionIds[]`。先用 `View=sessions` 取得來源／lineage／raw pointers，不展開全文；需要內容再用 `View=erp`。只給 repo 就保留該 repo 全部內容；只給 session 就巡覽所有 repo 的該 session。`summary`／`erp`／`index`／`sessions` 均接受 filters，metadata／warnings／errors 仍保留。

```powershell
# recipe: selection-request
$selection = @{ GithubRepo = '<owner/repo>'; SessionId = '<known-session-id>' }
```

```powershell
# recipe: select
$selectionPath = Join-Path $taskRoot 'selection.json'
$selectedPath = Join-Path $taskRoot 'selected.json'
$sessionsPath = Join-Path $taskRoot 'sessions.json'
$selectionParameters = @{ InputPath = $rawPath; View = 'sessions' }
foreach ($key in $selection.Keys) { $selectionParameters[$key] = $selection[$key] }
[IO.File]::WriteAllText($selectionPath, ($selectionParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $selectionPath -OutputPath $sessionsPath
if ($LASTEXITCODE -ne 0) { throw 'Session index failed; inspect existing evidence.' }
$selectionParameters.View = 'erp'
[IO.File]::WriteAllText($selectionPath, ($selectionParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $selectionPath -OutputPath $selectedPath
if ($LASTEXITCODE -ne 0) { throw 'Selection failed; inspect existing evidence without collection.' }
```

### 精確 raw pointer 選讀

`sessions`／`index`／summary 的 `detailRef.jsonPointer` 都指向**同次原始 `$rawPath`**，篩選不重編陣列位置。以下填入已取得的 pointer；raw 不與 repo／session filter 合用。空字串明確代表整份 document，通常只讀最小需要節點。Pointer 使用 JSON Pointer escaping（`~0` 是 `~`、`~1` 是 `/`），鍵名區分大小寫；錯誤 pointer 會回 errors，不能當成空證據。

```powershell
# recipe: raw-request
$pointer = '<detailRef.jsonPointer>'
```

```powershell
# recipe: raw
$rawSelectionPath = Join-Path $taskRoot 'raw-selection.json'
$rawParametersPath = Join-Path $taskRoot 'raw-parameters.json'
$rawParameters = @{ InputPath = $rawPath; View = 'raw'; JsonPointer = $pointer }
[IO.File]::WriteAllText($rawParametersPath, ($rawParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -Mode format -ScriptPath $formatterPath -ParametersPath $rawParametersPath -OutputPath $rawSelectionPath
if ($LASTEXITCODE -ne 0) { throw 'Raw selection failed; inspect existing evidence.' }
```

結果為 `{detailRef, value}`；`value` 保留原始 JSON 的 null、空陣列、數字與時間字串。`compatibility` 是來源層完整草稿，不接受 repo／session filters。

只讀 `$selectedPath` 的必要欄位；若選定內容仍大，縮小條件或讀已知 detailRef 的欄位／範圍，不把全部內容送進主上下文。選讀空結果保留缺口，不擴搜來源。Recall 也只查當次日期、點名 repo 與偏好；失敗、空結果、截斷或大型輸出未取得有效偏好時停止 recall，不擴搜尋、不把截斷內容當成果證據，沿用預設流程。

ERP 視圖仍含完整 meta／來源／session 及私人文字；省略 repo path 不等於去識別化。對話、日報及公開 PR 只轉述必要工作主題與公開編號，不貼 raw／ERP JSON、內部 path 或 conversation。

未使用 filters 時，`summary` 與 `erp` 的既有內容契約不變；`index`／`sessions` 是導航，不取代 ERP 完整證據或草稿交付。

## 3. Adapter contract 與 diagnostics

### Collector 分段量測與補報狀態

`meta.diagnostics.schemaVersion=1` 提供六個固定 stages：`sourceAdapter`、`json`、`repoDiscovery`、`git`、`github`、`output`，各有 `durationMs`／`calls`／`cacheHits`。未執行維持 `null`，不是量到零；失敗／提前返回保留已知計量。Calls 是該 stage 的 instrumented operation 次數，不全等於 native process 或網路呼叫。Stage 可巢狀／重疊，**不可加總**；`totalDurationMs` 由獨立 wall clock 取得。`output` 到主 evidence JSON 序列化完成為止，不含末尾 diagnostics 編碼／置換與 stdout 傳輸；total 同樣不是完整 capture／摘要／ERP 的 end-to-end 耗時。診斷僅固定 aggregate，不含私人內容、命令、路徑或 credentials；index 保留 v1 固定 scalars，未知 schema 由 raw pointer 選讀。

PR 候選先比明確 PR 編號／branch（cheap match），已能判斷就省略 details；未匹配的適用候選仍保留 commit hash fallback 與錯誤語意。同輪 viewer／PR list／details cache 沿用，worktree 關聯各自判斷。Aggregate 展開只重用同次正規化 exact path（含空結果），每個來源仍保留 session evidence／warnings／coverage；不以祖先前綴猜 repo。

補報用報告範圍內 commit／可靠 session 的明確 PR 引用作有界精確補證，可涵蓋隔日更新／合併及 session-only；近期更新不構成當日關聯。PR `reportEvidence` 說明報告日關聯依據（`commit-match`／`commit-reference`／`commit-hash`／`session-reference`）；`stateObservedAt` 是目前 state 的觀察時間。隔日 MERGED 不回溯成報告日已合併，issue state 仍依 skill 精確核對。

條件式並行／Git root batching 缺少本票收益證據，延後。五分鐘只是排除使用者等待的人工軟目標，不是 CI assertion、合併門檻或 300 秒 timeout。交付時分報 collector → raw 與開始 → 可用完整摘要的可觀測耗時，排除使用者等待，ERP 另計；無實測就寫未測，不從 stages 推估加速倍率。

### Codex 能力與 canonical evidence

- `runtime.codexContract=0.164.0-alpha.11.1` 是已核對的 reference contract，不是執行時版本白名單。不同、unknown 或 missing 的 `cli_version` 只作診斷；不因此 reject、降級或產 compatibility draft。Python 3.11+ 是 adapter runtime prerequisite，與 Codex CLI version 分開判定。
- 只有必要能力可安全查詢時才使用 SQL：`threads` 必要 identity／path 欄位及 created／updated 至少一種時間表示；日期分支須有既有 leading-column index 並由實際 query plan 證明 indexed `SEARCH`。History 必要欄位與 `thread_id` indexed `SEARCH` 同樣是 gate；拒絕 `SCAN`，不新增 index 或全表查詢。既有 range、payload、row 與共用 deadline 限制不變。
- Metadata time unknown 不推成零或猜日期；unknown／invalid item time、message content 或 type 記為 gap。以已選 thread／item 為界逐筆隔離壞 item，繼續其他有效 items；history adapter capability failure 不取消其他來源或候選。Capability 不符時只用原有有界 exact／date-partition fallback，不增加 query、掃描範圍、cache 或讀取預算。
- Canonical `item_completed` message/tool 與 SQL history mirror 依真實 canonical item identity 對照，合併時保留原始 details、mirror details 與 provenance；legacy projection 沿用其可用 identity／時間／內容規則。Exact JSONL EOF 只表示讀到檔尾，不證明來源完整或 interop coverage。
- 只有必要 schema、time、content 或 indexed-query capability gap 產生 compatibility draft。草稿目的地為 `https://github.com/Sevenflanks/skills/issues`，內容描述本機 adapter capability，不推論 Codex upstream bug；不包含原文、private path、URL、auth 或 config。草稿保留 `requiresExplicitConsent=true`、`published=false`，render 不改寫發布狀態。Missing、permission、valid-empty 與單純版本差異不產草稿。

### OpenCode discovery aggregate

OpenCode 的固定 aggregate 位於 `meta.sources.opencode.discovery`，分 `metadata`、`workdir`、`expansion` 三個 stage。Index 保留此固定 nested aggregate；不包含逐路徑／session／exception array：

- `metadata`: `status`, `rows`, `nonemptyInputs`, `skippedInputs{notFullyQualified,normalizationError}`, `normalizedUniqueCandidates`, `duplicateInputs`, `results{repo,aggregateDirectory,notResolved}`。Metadata candidates 的 resolver 結果是 normalized unique candidate 的分區。
- `workdir`: `status`, `reason`, `limit`, `truncated`, `returnedRows`, `processedRows`, `invalidRows`, `emptyInputs`, `nonemptyInputs`, `skippedInputs{notFullyQualified,normalizationError}`, `normalizedUniqueCandidates`, `repeatedCandidateRows`, `results{repoRows,alreadyAttributedRows,notResolvedRows}`。`returnedRows` 含 sentinel，最多 `processedRows=2048`；`truncated` 表示回傳超過此界。
- `expansion`: `status`, `candidates`, `resolvedCandidates`, `notResolvedCandidates`；candidates 是進入原 path resolver 的 OpenCode candidate objects，不等於唯一 session／repo 數。
- `not-read`／failed stage 的未知計數維持 `null`，不當作 0。Probe 不查 DB；metadata 成功 `[]` 不補查 workdir。`2048 + sentinel` 限制候選列回傳／處理，不代表 DB I/O、latency 或 process memory 上限。
- Metadata、workdir 與 expansion 母體不可互相加總。Invalid rows、skipped inputs、duplicates、already-attributed rows 與 unresolved paths 分別解讀；stage success 不代表每個路徑都解析成功。Index formatter 適配 source root 與 nested coverage 的實際欄位位置，pointer 指向真實 raw JSON 節點。

## 4. 任務結束後清理當次證據

完成按需核對、compatibility 草稿實際交付（若有）與最終日誌交付後，才刪除本次建立且仍由本次持有的 `$taskRoot`（含 raw capture／各 view／參數檔）。Bundled scripts 留在 skill 安裝目錄，不在清理範圍。Formatter 輸出不算交付；交接時只在私有交接記錄指向證據，由接手者清理。若草稿尚未實際交付，保留 task root；不存全域 cache，不提交原始檔。

```powershell
# recipe: cleanup
Remove-Item -LiteralPath $taskRoot -Recurse -Force
```
