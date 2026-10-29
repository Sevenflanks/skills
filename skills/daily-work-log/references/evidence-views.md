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

## 2. 先讀缺口與 repo 索引，再按需讀證據

```powershell
# recipe: index
$evidence = Get-Content -LiteralPath $erpPath -Raw -Encoding utf8 | ConvertFrom-Json
@{
  meta = $evidence.meta
  warnings = $evidence.warnings
  errors = $evidence.errors
  repos = @($evidence.repos | ForEach-Object {
    @{name=$_.name; githubRepo=$_.githubRepo; source=$_.source; warnings=$_.warnings;
      commits=@($_.commits).Count; prs=@($_.prs).Count; sessions=@($_.sessionEvidence).Count}
  })
} | ConvertTo-Json -Depth 100 -Compress
```

先依 skill 檢查 errors／canGenerateLog／collectionStatus、每一來源 readStatus 與全部 coverage。`no-sources`／`read-failed`／`canGenerateLog=false` 時停止；`no-activity` 只說明無當日證據，來源失敗不當作無活動，`coverage.complete=false` 不改稱完整。依既有規則檢查 GitHub 可用性。

需要歸屬或交付判斷時，按索引選 canonical repo，對照所有 worktree 的完整 commits／PR／sessionEvidence。ERP 視圖不套 commit 上限且保留全文，仍可能很大；依 repo、來源、session ID 或已知 hash 分批選讀，不用 `First N` 隨意截斷，不省略第二來源或續行。預設 summary 的 routine tool `detailRef` 指回 `$rawPath`；critical 保留規則見 [`SKILL.md`](../SKILL.md#evidence-views-與私有原始證據)。

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

## 3. 任務結束後清理當次證據

完成按需核對與最終交付後，刪除本次建立且仍由本次持有的 `$taskRoot`（含 capture／selection 程式及參數）。交接時只在私有交接記錄指向證據，由接手者清理；不存全域 cache，不提交原始檔。

```powershell
# recipe: cleanup
Remove-Item -LiteralPath $taskRoot -Recurse -Force
```
