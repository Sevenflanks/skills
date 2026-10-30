# 私有證據落檔與 ERP 結構視圖

先完成 probe → 對話來源預告，再正式 collect；工具 collect timeout 沿用 600000 ms。來源 guard、無活動停止、Codex 有界額度與無自動重跑規則照常適用。以下支援 Windows PowerShell 5.1 或 PowerShell 7 作為呼叫端，collector／formatter 一律在 **pwsh 7+** 執行。

## 1. 明確 UTF-8 capture，JSON 參數走檔案

PS5.1 的 `>`／`Out-File` 預設是 UTF-16LE，`Set-Content` 預設也不是 UTF-8；不要在外層 shell 重導向 native stdout。以下把 capture 留在 pwsh child，以 `utf8NoBOM` 寫檔；呼叫端只傳路徑，不傳 inline JSON。無須改 `$OutputEncoding`、console encoding、profile 或全域設定。

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
$parametersPath = Join-Path $taskRoot 'parameters.json'
$probePath = Join-Path $taskRoot 'probe.json'
$rawPath = Join-Path $taskRoot 'collector.json'
$erpPath = Join-Path $taskRoot 'erp-evidence.json'
$indexPath = Join-Path $taskRoot 'evidence-index.json'
$compatibilityPath = Join-Path $taskRoot 'compatibility-drafts.json'
$capturePath = Join-Path $taskRoot 'capture.ps1'
$capture = @'
param([string]$ScriptPath, [string]$ParametersPath, [string]$OutputPath, [switch]$ProbeOnly)
$ErrorActionPreference = 'Stop'
$arguments = Get-Content -LiteralPath $ParametersPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($ProbeOnly) { $arguments.ProbeOnly = $true }
& $ScriptPath @arguments | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
# 無效 JSON 是停止條件；檔案存在不等於 collection 成功。
$null = Get-Content -LiteralPath $OutputPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
'@
[IO.File]::WriteAllText($capturePath, $capture, $utf8)
[IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 100), $utf8)
```

Task-local `capture.ps1` 只包裝既有 CLI 的輸出，不蒐集或改寫證據。PS5.1 與 7 均可執行下面呼叫；腳本與參數檔路徑各是一個 argument，空白、中文及單引號不需要拼成 command string。

```powershell
# recipe: probe
& pwsh -NoProfile -File $capturePath -ScriptPath $collectorPath -ParametersPath $parametersPath -OutputPath $probePath -ProbeOnly
if ($LASTEXITCODE -ne 0) { throw 'Probe failed; stop without collection.' }
$probe = Get-Content -LiteralPath $probePath -Raw -Encoding utf8 | ConvertFrom-Json
$probe.meta | ConvertTo-Json -Depth 100 -Compress
```

先讀 probe，向使用者公告各來源／略過理由；兩來源均 unavailable 時在此結束。公告完成才執行下一段，不能把兩段合成無條件自動 collect。沿用同任務已完成的 probe／collect；逾時、非 JSON 或讀取全失敗就回報並停止，不重收、不加 fallback 預算。

```powershell
# recipe: collect
$parameters.From = $probe.meta.from
$parameters.To = $probe.meta.to
[IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 100), $utf8)
& pwsh -NoProfile -File $capturePath -ScriptPath $collectorPath -ParametersPath $parametersPath -OutputPath $rawPath
if ($LASTEXITCODE -ne 0) { throw 'Collection failed; retain diagnostics and stop without retry.' }
```

原始 JSON 不印到工具輸出。接著只對既有檔案執行 formatter，不重 collect、不接 ERP、不補查 API。`-InputPath` 與 stdin JSON 擇一；舊 collector JSON 仍可使用。

```powershell
# recipe: format
$viewParametersPath = Join-Path $taskRoot 'view-parameters.json'
$viewParameters = @{ InputPath = $rawPath; View = 'erp' }
[IO.File]::WriteAllText($viewParametersPath, ($viewParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -ScriptPath $formatterPath -ParametersPath $viewParametersPath -OutputPath $erpPath
if ($LASTEXITCODE -ne 0) { throw 'Formatter failed; stop and inspect the existing capture.' }
```

## 2. 以 bounded index 讀缺口與 repo 索引

```powershell
# recipe: index
$indexParametersPath = Join-Path $taskRoot 'index-parameters.json'
$indexParameters = @{ InputPath = $rawPath; View = 'index' }
[IO.File]::WriteAllText($indexParametersPath, ($indexParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -ScriptPath $formatterPath -ParametersPath $indexParametersPath -OutputPath $indexPath
if ($LASTEXITCODE -ne 0) { throw 'Index formatting failed; inspect the existing capture.' }
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 | ConvertFrom-Json
$index | ConvertTo-Json -Depth 100 -Compress

# ERP 完整 metadata 仍供後續依 repo／session 選讀。
$evidence = Get-Content -LiteralPath $erpPath -Raw -Encoding utf8 | ConvertFrom-Json
```

`-View index` 提供狀態、固定 scalar 診斷、limits、各陣列的 count／raw pointer 與 repo count，不複製完整 metadata 或明細。Unknown count 維持 `null`，不能解讀為零。`-InputPath` 的 raw refs 附上輸入檔名；stdin refs 不虛構 filename。先依 skill 檢查 errors／canGenerateLog／collectionStatus、每一來源 readStatus 與全部 coverage；`no-sources`／`read-failed`／`canGenerateLog=false` 時停止；`no-activity` 只說明無當日證據，來源失敗不當作無活動，`coverage.complete=false` 不改稱完整。依既有規則檢查 GitHub 可用性。索引中的 count 與 pointer 只協助定位，不是完整證據或交付內容。

若 index 顯示 `compatibilityIssues.count > 0` 或 count 為 unknown，使用 `-View compatibility` 檢查是否有草稿並讀取完整、已脫敏內容；只有已知 count 為 0 才可略過。Index count／pointer 只供定位，不能代替實際交付。依 `detailRef` 或 `$rawPath` 原始 JSON pointer 只在需要時讀其他欄位，不重 collect：

```powershell
# recipe: compatibility
$compatibilityParametersPath = Join-Path $taskRoot 'compatibility-parameters.json'
$compatibilityParameters = @{ InputPath = $rawPath; View = 'compatibility' }
[IO.File]::WriteAllText($compatibilityParametersPath, ($compatibilityParameters | ConvertTo-Json), $utf8)
& pwsh -NoProfile -File $capturePath -ScriptPath $formatterPath -ParametersPath $compatibilityParametersPath -OutputPath $compatibilityPath
if ($LASTEXITCODE -ne 0) { throw 'Compatibility view failed; inspect the existing capture.' }
$compatibility = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding utf8 | ConvertFrom-Json
$compatibility.drafts | ConvertTo-Json -Depth 100
```

對話中逐份呈現完整草稿、目的地及「尚未發布」狀態；先判斷目的地正確，只有使用者本次明確同意才可發布。Formatter render 成功不等於已在對話中交付，不能把 `published` 改成 true 或自行記錄 posted／delivered。先完成草稿的實際交付，再進入任務結束清理；若未完成交付，保留當次證據供續行。

需要歸屬或交付判斷時，按 index 選 canonical repo，從 `$evidence` 對照所有 worktree 的完整 commits／PR／sessionEvidence。ERP 視圖不套 commit 上限且保留全文，仍可能很大；依 repo、來源、session ID 或已知 hash 分批選讀，不用 `First N` 隨意截斷，不省略第二來源或續行。預設 summary 的 routine tool `detailRef` 指回 `$rawPath`；critical 保留規則見 [`SKILL.md`](../SKILL.md#evidence-views-與私有原始證據)。

### 需要多行 Python 選讀時

優先用既有 PowerShell 物件篩選；若需要 Python，將程式存 `.py`、選擇條件存 UTF-8 JSON，只透過 argument array 傳檔案路徑。以下用 Python 3.11+ 從 ERP 視圖挑已確認 repo 的特定 session（省略 sessionId 則保留該 repo 全部內容），保留同 canonical repo 的所有 worktree。它只是當次選讀，不是新 formatter 或 cache。

```powershell
# recipe: selection-request
$selection = @{ githubRepo = '<owner/repo>'; sessionId = '<known-session-id>' }
```

```powershell
# recipe: select
$selectionPath = Join-Path $taskRoot 'selection.json'
$selectedPath = Join-Path $taskRoot 'selected.json'
$pythonPath = Join-Path $taskRoot 'select-evidence.py'
[IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json), $utf8)
$python = @'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selection = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
repos = [repo for repo in data["repos"] if repo.get("githubRepo") == selection["githubRepo"]]
if "sessionId" in selection:
    for repo in repos:
        repo["sessionEvidence"] = [item for item in repo.get("sessionEvidence", [])
                                   if selection["sessionId"] in [item.get("sessionId"), *item.get("sessionIds", [])]]
Path(sys.argv[3]).write_text(json.dumps(repos, ensure_ascii=False), encoding="utf-8")
'@
[IO.File]::WriteAllText($pythonPath, $python, $utf8)
$pythonArguments = @('-X', 'utf8', $pythonPath, $erpPath, $selectionPath, $selectedPath)
& python @pythonArguments
if ($LASTEXITCODE -ne 0) { throw 'Selection failed; inspect the existing files without collection.' }
```

只讀 `$selectedPath` 的必要欄位；若選定內容仍大，縮小條件或讀已知 detailRef 的欄位／範圍，不把全部內容送進主上下文。選讀空結果保留缺口，不擴搜來源。Recall 也只查當次日期、點名 repo 與偏好；失敗、空結果、截斷或大型輸出未取得有效偏好時停止 recall，不擴搜尋、不把截斷內容當成果證據，沿用預設流程。

ERP 視圖仍含完整 meta／來源／session 及私人文字；省略 repo path 不等於去識別化。對話、日報及公開 PR 只轉述必要工作主題與公開編號，不貼 raw／ERP JSON、內部 path 或 conversation。

`summary` 與 `erp` 視圖的既有內容契約不變；`index` 與 `compatibility` 是供分階段讀取的新增 views。

## 3. Adapter contract 與 diagnostics

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

完成按需核對、compatibility 草稿實際交付（若有）與最終日誌交付後，才刪除本次建立且仍由本次持有的 `$taskRoot`（含 raw capture／各 view／capture／selection 程式及參數）。Formatter 輸出不算交付；交接時只在私有交接記錄指向證據，由接手者清理。若草稿尚未實際交付，保留 task root；不存全域 cache，不提交原始檔。

```powershell
# recipe: cleanup
Remove-Item -LiteralPath $taskRoot -Recurse -Force
```
