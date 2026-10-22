# 私有證據落檔與 ERP 結構視圖

先完成 probe → 對話來源預告，再執行本頁正式 collection。以下使用 PowerShell 7+；工具 collect timeout 沿用 600000 ms。來源 guard、無活動停止、Codex 有界額度與無自動重跑規則照常適用。

## 1. 原始 JSON 直接落在當次私有暫存

`$parameters` 使用與 probe 相同的來源與範圍；原本省略時間時，填入 probe 的 `meta.from`／`meta.to`。`$skillRoot` 是實際安裝的 skill 目錄。這裡的 task-local JSON 是中間證據，不是將最終日報寫檔的授權。

```powershell
$parameters = @{ From = '<probe-from>'; To = '<probe-to>'; Timezone = 'Asia/Taipei' }
$tempParent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $tempParent -PathType Container)) { throw 'Temporary parent is unavailable.' }
$taskRoot = Join-Path $tempParent ('daily-work-log-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $taskRoot
$rawPath = Join-Path $taskRoot 'collector.json'
$erpPath = Join-Path $taskRoot 'erp-evidence.json'
& (Join-Path $skillRoot 'scripts/collect-daily-work-log.ps1') @parameters |
  Set-Content -LiteralPath $rawPath -Encoding utf8NoBOM
& (Join-Path $skillRoot 'scripts/format-daily-work-log-evidence.ps1') -InputPath $rawPath -View erp |
  Set-Content -LiteralPath $erpPath -Encoding utf8NoBOM
```

這兩次命令不把 JSON 印到工具輸出。Formatter 只讀既有檔案，不重 collect、不接 ERP、不補查 API。原始格式不變，舊 collector JSON 亦可直接使用。`-InputPath` 與 stdin JSON 擇一；預設 `-View summary`／`-MaxCommitsPerRepo 8` 的輸出格式維持相容，ERP 視圖不套 shown-commit 上限。

## 2. 先讀缺口與 repo 索引，再按需讀證據

```powershell
$evidence = Get-Content -LiteralPath $erpPath -Raw | ConvertFrom-Json
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

先依 skill 檢查 errors／canGenerateLog／collectionStatus、每一來源 readStatus 與全部 coverage。來源失敗不當作無活動；`coverage.complete=false` 不改稱完整。

需要歸屬或交付判斷時，按索引選定 repo，讀其完整 commits／PR／sessionEvidence；同 canonical repo 的所有 worktree 都要對照。資料可容納時可直接讀 ERP 視圖；仍太大時按 repo、來源、session ID 或已知 hash 分批查詢，不用 `First N` 隨意截斷，不省略第二來源或續行。完整原始證據始終留在 `$rawPath`，必要欄位才按需讀取；不可為了省 context 重 collect。

```powershell
# 使用已從索引確認的 canonical repo；不是用資料夾名猜 mapping。
$evidence.repos | Where-Object githubRepo -eq '<owner/repo>' |
  ConvertTo-Json -Depth 100 -Compress
```

ERP 視圖保留全部 `meta`／來源／session 證據，因此仍可能含內部路徑及私人文字。省略 `repos[].path` 不等於去識別化。對話、日報及公開 PR 只轉述必要工作主題與可公開編號，不貼原始／ERP JSON、內部 path 或 conversation。

## 3. 任務結束後清理當次證據

完成按需核對與最終交付後，刪除本次建立且仍由本次持有的 `$taskRoot`。任務中途交接時只在私有交接記錄指向證據，交接者接手清理；不存全域 cache，不提交原始檔。

```powershell
Remove-Item -LiteralPath $taskRoot -Recurse -Force
```
