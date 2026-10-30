[CmdletBinding()]
param(
  [string]$EvidenceRoot,
  [ValidateSet('none', 'utf16', 'expanded-index', 'early-cleanup')][string]$Mutation = 'none'
)

# Seam: execute the documented capture/selection recipes and real formatter CLI.
# Observer: a consumer reading UTF-8 JSON and selected sessions, never raw stdout.
# Breaks: PS5 UTF-16 redirect, damaged JSON/quotes/newlines, wrong worktree/session selection.
# 下方 consumer flow 是受控可執行 harness，不代表 agent 已實際交付。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this test driver with pwsh 7+.' }
$skillRoot = Split-Path -Parent $PSScriptRoot
$recipePath = Join-Path $skillRoot 'references/evidence-views.md'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$ps5 = (Get-Command powershell.exe -ErrorAction Stop).Source
$parent = [IO.Path]::GetTempPath()
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Missing temporary parent.' }
if ($EvidenceRoot -and -not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'EvidenceRoot must already exist.' }
$root = Join-Path $parent ("capture 中文 'quoted' spaces-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Utf8($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
try {
  $note = "中文第一行`n第二行含 `"double quotes`"、'single quotes'、反斜線 C:\synthetic\尾端\"
  $session = "session `"中文`"`n'continued'"
  $large = ("LARGE-PRIVATE-SYNTHETIC 中文 `"quoted`" 'single' \`n" * 24000)
  $consumerFixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'consumer-flow.fixture.json') -Raw -Encoding utf8 | ConvertFrom-Json
  $diagnostics = @(for ($i = 0; $i -lt 546; $i++) {
    @{sessionId="synthetic-$i";path="C:\synthetic\$i";reason=('PRIVATE-META-SYNTHETIC 中文缺口' * 40);status='partial'}
  })
  $fixture = [ordered]@{
    meta = @{from='2026-05-29T00:00:00+08:00';to='2026-05-29T23:59:59+08:00';timezone='Asia/Taipei';note=$note;canGenerateLog=$true;collectionStatus='partial';sources=@{opencode=@{available=$true;readStatus='success'};codex=@{available=$true;readStatus='partial';coverage=@{complete=$false;limitHits=@('fileBytes')}}}}
    warnings=@('合成缺口');errors=@();repos=@(
      @{name='worktree-a';path='C:\synthetic\a';githubRepo='fixture/shared';source=@('session');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='opencode';source='session';sessionId=$session;title=$note},
        @{agent='opencode';source='session';sessionId='not-selected';title=$large})},
      @{name='worktree-b';path='C:\synthetic\b';githubRepo='fixture/shared';source=@('codex');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='codex';source='codex';sessionId='parent';sessionIds=@('parent',$session);title=$note;role='user'})},
      @{name='other-repo';githubRepo='fixture/other';source=@('session');isGitRepo=$true;commits=@();prs=@();warnings=@();sessionEvidence=@(
        @{agent='opencode';sessionId=$session;title=$large})}
    )
  }
  # 大型 metadata 涵蓋 source 根層與 coverage 兩種位置。
  # 草稿由 producer 先脫敏；formatter 不負責脫敏。
  $codex = $fixture.meta.sources.codex
  $codex.compatibilityIssues = @($consumerFixture.drafts[0])
  $codex.adapters = @{exact=@{status='partial';sessions=$diagnostics}}
  $codex.sqliteResources = @{rows=42;payloadBytes=512;limitHits=@('deadline');unread=$diagnostics}
  $codex.coverage.candidateDays = $diagnostics
  $codex.coverage.unvisitedDays = $diagnostics
  $codex.coverage.skipped = $diagnostics
  $codex.coverage.compatibilityIssues = @($consumerFixture.drafts[1])
  $codex.coverage.exactFallback = @{lineBytes=65536;recoveredOversizedLines=1;unread=$diagnostics}
  Write-Utf8 "$root\fixture.json" ($fixture | ConvertTo-Json -Depth 100)
  Write-Utf8 "$root\expected-drafts.json" ($consumerFixture.drafts | ConvertTo-Json -Depth 100)
  # The only replacement is the external collector boundary; no source entry is probed.
  Write-Utf8 "$root\synthetic-collector.ps1" @'
param([string]$From, [string]$To, [string]$Timezone, [string]$Note, [switch]$ProbeOnly)
$ErrorActionPreference = 'Stop'
$data = Get-Content -LiteralPath "$PSScriptRoot/fixture.json" -Raw -Encoding utf8 | ConvertFrom-Json
$data.meta.from = '2026-05-29T00:00:00+08:00'
$data.meta.to = '2026-05-29T23:59:59+08:00'
if ($Note -cne $data.meta.note -or $From -ne '2026-05-29T00:00:00+08:00' -or $To -ne '2026-05-29T23:59:59+08:00' -or $Timezone -ne 'Asia/Taipei') { throw 'Parameter round-trip damaged.' }
[IO.File]::AppendAllText("$PSScriptRoot/calls.txt", $(if ($ProbeOnly) { "probe`n" } else { "collect`n" }))
if ($ProbeOnly) {
  $data.meta | Add-Member -NotePropertyName probeOnly -NotePropertyValue $true
  @{meta=$data.meta;errors=@()} | ConvertTo-Json -Depth 100
} else { Get-Content -LiteralPath "$PSScriptRoot/fixture.json" -Raw -Encoding utf8 }
'@
  $scenario = @'
param([string]$Root, [string]$RecipePath, [string]$SkillRoot, [string]$Mutation, [string]$RunLabel = $PSVersionTable.PSVersion.Major)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Resolve-RawReference($Reference) {
  Assert ($Reference.document -eq 'raw-collector-json' -and $Reference.inputPath -ceq $rawPath) 'Index reference points outside this capture.'
  $node = Get-Content -LiteralPath $Reference.inputPath -Raw -Encoding utf8 | ConvertFrom-Json
  foreach ($token in $Reference.jsonPointer.TrimStart('/').Split('/')) {
    $key = $token.Replace('~1','/').Replace('~0','~')
    if ($node -is [array]) { $node = $node[[int]$key] } else { $node = $node.PSObject.Properties[$key].Value }
  }
  return $node
}
$recipes = @{}
$markdown = [IO.File]::ReadAllText($RecipePath, [Text.Encoding]::UTF8)
foreach ($match in [regex]::Matches($markdown, '(?ms)^```powershell\r?\n# recipe: ([\w-]+)\r?\n(.*?)^```')) {
  $recipes[$match.Groups[1].Value] = [scriptblock]::Create($match.Groups[2].Value)
}
$taskRoot = $null
$flow = @{announced=$false;draftCheckpoint=$false;logCheckpoint=$false}
$events = New-Object 'System.Collections.Generic.List[string]'
# 測試編排逐字執行文件配方；合成 checkpoint 不會把 raw／formatter
# 標成已交付，也不授權發布。
function Invoke-ConsumerStep([string]$Name) {
  if ($Name -eq 'collect' -and -not $flow.announced) { throw 'announcement checkpoint required' }
  if ($Name -eq 'cleanup' -and -not ($flow.draftCheckpoint -and $flow.logCheckpoint)) { throw 'synthetic delivery checkpoints required' }
  $events.Add($Name)
  . $recipes[$Name]
}
try {
  . $recipes.setup
  if ($Mutation -eq 'expanded-index') {
    # 只變異 task-local formatter 副本，讓真正的 index 請求改走完整
    # ERP 分支，重現 index 意外展開全部 metadata 的缺陷。
    $formatter = [IO.File]::ReadAllText($formatterPath, [Text.Encoding]::UTF8)
    $formatter = $formatter.Replace('begin {', "begin {`n  if (`$View -eq 'index') { `$View = 'erp' }")
    $formatterPath = Join-Path $taskRoot 'mutated-formatter.ps1'
    [IO.File]::WriteAllText($formatterPath, $formatter, $utf8)
  }
  $fixture = Get-Content -LiteralPath "$Root/fixture.json" -Raw -Encoding utf8 | ConvertFrom-Json
  $collectorPath = Join-Path $Root 'synthetic-collector.ps1'
  # Pin date strings across PS5 and PS7; ConvertFrom-Json may infer DateTime in PS7.
  $parameters = @{From='2026-05-29T00:00:00+08:00';To='2026-05-29T23:59:59+08:00';Timezone='Asia/Taipei';Note=$fixture.meta.note}
  [IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 100), $utf8)
  if ($Mutation -eq 'utf16') {
    # Mutate an owned helper copy, never the shared implementation.
    $capture = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8)
    $capture = $capture.Replace('[Text.UTF8Encoding]::new($false)', '[Text.Encoding]::Unicode')
    $capturePath = Join-Path $taskRoot 'mutated-capture.ps1'
    [IO.File]::WriteAllText($capturePath, $capture, $utf8)
  }
  $probeOutput = @(. $recipes.probe)
  Assert ($probe.meta.sources.opencode.available -and $probe.meta.sources.codex.available) 'Synthetic probe unavailable.'
  # This orchestration models the announcement boundary; no actual collection precedes it.
  Assert ([IO.File]::ReadAllText("$Root/calls.txt") -eq "probe`n") 'Collection occurred before announcement boundary.'
  $blocked = $false
  try { Invoke-ConsumerStep 'collect' } catch { if ($_.Exception.Message -ne 'announcement checkpoint required') { throw }; $blocked = $true }
  Assert ($blocked -and -not (Test-Path -LiteralPath $rawPath)) 'Controlled consumer collected without announcement.'
  $flow.announced = $true
  Assert (@(Invoke-ConsumerStep 'collect').Count -eq 0) 'Capture leaked raw JSON into tool stdout.'
  Assert (@(. $recipes.format).Count -eq 0) 'Formatter leaked ERP JSON into tool stdout.'
  foreach ($path in @($probePath,$rawPath,$erpPath)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert ($bytes.Length -gt 0 -and [Array]::IndexOf($bytes, [byte]0) -eq -1 -and $bytes[0] -ne 255 -and $bytes[0] -ne 239) 'Capture is not BOM-less UTF-8 (UTF-16/default redirect regression).'
    $null = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes)
  }
  $original = [IO.File]::ReadAllText("$Root/fixture.json", [Text.Encoding]::UTF8)
  $captured = [IO.File]::ReadAllText($rawPath, [Text.Encoding]::UTF8)
  Assert ($original.TrimEnd("`r","`n") -ceq $captured.TrimEnd("`r","`n")) 'Raw Chinese/quotes/newlines/large output changed in transit.'
  $index = (. $recipes.index) -join "`n"
  Assert ([Text.Encoding]::UTF8.GetByteCount($index) -lt 16000 -and $index -notmatch 'LARGE-PRIVATE-SYNTHETIC|PRIVATE-META-SYNTHETIC|完整草稿尾端') 'Index expanded private metadata/session/draft content (UTF-8 byte bound).'
  $indexData = $index | ConvertFrom-Json
  Assert (@($indexData.repos).Count -eq 3 -and $indexData.repos[0].sessions -eq 2) 'Index omitted repo/session counts.'
  $sourceIndex = $indexData.meta.sources.codex
  foreach ($check in @(
    @{entry=$sourceIndex.adapters.exact.sessions;pointer='/meta/sources/codex/adapters/exact/sessions'},
    @{entry=$sourceIndex.sqliteResources.unread;pointer='/meta/sources/codex/sqliteResources/unread'},
    @{entry=$sourceIndex.coverage.candidateDays;pointer='/meta/sources/codex/coverage/candidateDays'},
    @{entry=$sourceIndex.coverage.unvisitedDays;pointer='/meta/sources/codex/coverage/unvisitedDays'},
    @{entry=$sourceIndex.coverage.skipped;pointer='/meta/sources/codex/coverage/skipped'},
    @{entry=$sourceIndex.coverage.exactFallback.unread;pointer='/meta/sources/codex/coverage/exactFallback/unread'}
  )) {
    $entry = $check.entry
    Assert ($entry.count -eq 546 -and $entry.detailRef.jsonPointer -eq $check.pointer -and @(Resolve-RawReference $entry.detailRef).Count -eq 546) 'Large diagnostic count/reference does not resolve to all raw entries at the correct origin.'
  }
  foreach ($check in @(
    @{entry=$sourceIndex.compatibilityIssues;pointer='/meta/sources/codex/compatibilityIssues'},
    @{entry=$sourceIndex.coverage.compatibilityIssues;pointer='/meta/sources/codex/coverage/compatibilityIssues'}
  )) {
    $entry = $check.entry
    Assert ($entry.count -eq 1 -and $entry.detailRef.jsonPointer -eq $check.pointer -and @(Resolve-RawReference $entry.detailRef).Count -eq 1) 'Draft count/raw reference is not resolvable at the correct origin.'
  }
  Assert ($sourceIndex.readStatus -eq 'partial' -and -not $sourceIndex.coverage.complete -and $sourceIndex.coverage.limitHits.count -eq 1 -and $indexData.meta.canGenerateLog) 'Index lost partial coverage or collection guards.'
  Assert ($indexData.repos[0].detailRef.jsonPointer -eq '/repos/0' -and (Resolve-RawReference $indexData.repos[0].detailRef).name -eq 'worktree-a') 'Repo index reference does not resolve.'
  $draftOutput = @(. $recipes.compatibility) -join "`n"
  $draftView = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding utf8 | ConvertFrom-Json
  $expectedDrafts = Get-Content -LiteralPath "$Root/expected-drafts.json" -Raw -Encoding utf8 | ConvertFrom-Json
  Assert (@($draftView.drafts).Count -eq 2) 'Compatibility recipe did not read every root/coverage draft.'
  $renderedDrafts = $draftOutput | ConvertFrom-Json
  Assert (@($renderedDrafts).Count -eq 2) 'Compatibility recipe did not expose complete drafts for presentation.'
  for ($i = 0; $i -lt 2; $i++) {
    $draft = $draftView.drafts[$i]
    $expected = $expectedDrafts[$i]
    foreach ($name in @('destination','title','body','requiresExplicitConsent','published')) {
      Assert ($draft.$name -ceq $expected.$name -and $renderedDrafts[$i].$name -ceq $expected.$name) "Compatibility draft $i lost full sanitized $name."
    }
    $pointer = @('/meta/sources/codex/compatibilityIssues/0','/meta/sources/codex/coverage/compatibilityIssues/0')[$i]
    Assert ($draft.detailRef.jsonPointer -eq $pointer -and (Resolve-RawReference $draft.detailRef).body -ceq $expected.body) 'Draft origin does not resolve to complete sanitized body.'
    Assert ($null -eq $draft.PSObject.Properties['delivered'] -and $null -eq $draft.PSObject.Properties['posted']) 'Formatter invented delivery/publication receipt.'
  }
  Assert ($draftOutput -notmatch 'PRIVATE-META-SYNTHETIC|LARGE-PRIVATE-SYNTHETIC|C:\\\\synthetic') 'Compatibility view expanded unrelated private evidence.'
  foreach ($path in @($rawPath,$erpPath,$indexPath,$compatibilityPath)) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    Assert ($text -notmatch '"(?:posted|delivered)"\s*:|"published"\s*:\s*true') 'View/capture invented a publication or delivery receipt.'
  }
  Assert ([IO.File]::ReadAllText($rawPath, [Text.Encoding]::UTF8) -ceq $captured) 'Rendering changed raw evidence or publication state.'
  if ($Mutation -eq 'early-cleanup') { . $recipes.cleanup }
  Assert ((Test-Path -LiteralPath $rawPath) -and (Test-Path -LiteralPath $compatibilityPath)) 'Render automatically cleaned evidence before delivery checkpoint.'
  $blocked = $false
  try { Invoke-ConsumerStep 'cleanup' } catch { if ($_.Exception.Message -ne 'synthetic delivery checkpoints required') { throw }; $blocked = $true }
  Assert ($blocked -and (Test-Path -LiteralPath $taskRoot)) 'Controlled consumer cleaned evidence after render only.'
  # 實際檔案 sink 只模擬對話邊界，不是真實 agent／使用者交付。
  $presentation = @($draftView.drafts | ForEach-Object { "目的地：$($_.destination)`n尚未發布；發布需本次明確同意。`n$($_.title)`n$($_.body)" }) -join "`n`n"
  $presentationPath = Join-Path $Root ('synthetic-presentation-' + $RunLabel + '.txt')
  [IO.File]::WriteAllText($presentationPath, $presentation, $utf8)
  $sink = [IO.File]::ReadAllText($presentationPath, [Text.Encoding]::UTF8)
  foreach ($expected in $expectedDrafts) {
    Assert ($sink.Contains($expected.body) -and $sink.Contains($expected.destination) -and $sink.Contains($expected.title)) 'Synthetic presentation did not receive full draft/destination.'
  }
  $flow.draftCheckpoint = $true
  $blocked = $false
  try { Invoke-ConsumerStep 'cleanup' } catch { if ($_.Exception.Message -ne 'synthetic delivery checkpoints required') { throw }; $blocked = $true }
  Assert ($blocked -and (Test-Path -LiteralPath $rawPath)) 'Controlled consumer cleaned before final-log checkpoint.'
  $evidence = Get-Content -LiteralPath $erpPath -Raw -Encoding utf8 | ConvertFrom-Json
  Assert ($evidence.repos[0].sessionEvidence[1].title -ceq $fixture.repos[0].sessionEvidence[1].title) 'ERP formatter damaged large payload.'
  Assert ($evidence.repos[0].sessionEvidence[0].title -ceq $fixture.meta.note -and -not $evidence.meta.sources.codex.coverage.complete) 'ERP lost multilingual evidence or coverage gap.'
  $selection = @{githubRepo='fixture/shared';sessionId=$fixture.repos[0].sessionEvidence[0].sessionId}
  Assert (@(. $recipes.select).Count -eq 0) 'Selection leaked raw payload into tool stdout.'
  $selectedText = Get-Content -LiteralPath $selectedPath -Raw -Encoding utf8
  $selected = $selectedText | ConvertFrom-Json
  Assert (@($selected.repos).Count -eq 2 -and $selected.repos[0].name -eq 'worktree-a' -and $selected.repos[1].name -eq 'worktree-b') 'Selection lost worktree or included another canonical repo.'
  Assert (@($selected.repos[0].sessionEvidence).Count -eq 1 -and @($selected.repos[1].sessionEvidence).Count -eq 1) 'Selection retained unrelated sessions or lost continuation.'
  Assert ($selected.repos[0].sessionEvidence[0].sessionId -ceq $selection.sessionId -and $selected.repos[1].sessionEvidence[0].sessionIds[1] -ceq $selection.sessionId) 'Quoted/multiline selector or continuation changed.'
  Assert ($selected.repos[0].sessionEvidence[0].title -ceq $fixture.meta.note -and $selectedText -notmatch 'LARGE-PRIVATE-SYNTHETIC') 'Selected read damaged text or included large unselected session content.'
  Assert (-not $selected.meta.sources.codex.coverage.complete -and $selected.meta.sources.codex.coverage.skipped.Count -eq 546 -and $selected.warnings[0] -ceq $fixture.warnings[0]) 'Selected ERP lost full metadata or partial coverage.'
  $sessionText = Get-Content -LiteralPath $sessionsPath -Raw -Encoding utf8
  $sessionView = $sessionText | ConvertFrom-Json
  Assert ([Text.Encoding]::UTF8.GetByteCount($sessionText) -lt 16000 -and $sessionText -notmatch 'LARGE-PRIVATE-SYNTHETIC|PRIVATE-META-SYNTHETIC|完整草稿尾端') 'Sessions navigation expanded private payload.'
  Assert (@($sessionView.repos).Count -eq 2 -and $sessionView.repos[0].sessionEvidence[0].detailRef.jsonPointer -eq '/repos/0/sessionEvidence/0' -and $sessionView.repos[1].sessionEvidence[0].detailRef.jsonPointer -eq '/repos/1/sessionEvidence/0') 'Sessions navigation changed original raw positions.'
  $pointer = $sessionView.repos[1].sessionEvidence[0].detailRef.jsonPointer
  Assert (@(. $recipes.raw).Count -eq 0) 'Raw pointer selection leaked payload into stdout.'
  $rawSelection = Get-Content -LiteralPath $rawSelectionPath -Raw -Encoding utf8 | ConvertFrom-Json
  Assert ($rawSelection.detailRef.jsonPointer -eq '/repos/1/sessionEvidence/0' -and $rawSelection.value.title -ceq $fixture.meta.note -and $rawSelection.value.sessionIds[1] -ceq $selection.sessionId) 'Raw pointer did not recover complete original continuation.'
  Assert ([IO.File]::ReadAllText($rawPath, [Text.Encoding]::UTF8) -ceq $captured) 'Selection changed raw evidence.'
  Assert ([IO.File]::ReadAllText("$Root/calls.txt") -eq "probe`ncollect`n") 'Formatter/selection recollected evidence.'
  $run = Join-Path $Root ('result-' + $RunLabel)
  $null = New-Item -ItemType Directory -Path $run
  foreach ($path in @($probePath,$rawPath,$erpPath,$selectedPath,$sessionsPath,$rawSelectionPath,$indexPath,$compatibilityPath)) { Copy-Item -LiteralPath $path -Destination $run }
  [IO.File]::WriteAllText((Join-Path $run 'index.json'), $index, $utf8)
  [IO.File]::WriteAllText((Join-Path $run 'runtime.json'), (@{caller=$PSVersionTable.PSVersion.ToString();rawBytes=(Get-Item -LiteralPath $rawPath).Length;selectedBytes=(Get-Item -LiteralPath $selectedPath).Length;indexUtf8Bytes=[Text.Encoding]::UTF8.GetByteCount($index);compatibilityBytes=(Get-Item -LiteralPath $compatibilityPath).Length;diagnosticEntriesPerArray=546;draftCount=2;processId=$PID;ownedTaskRoot=$taskRoot} | ConvertTo-Json), $utf8)
  # 只有合成 checkpoint 完成後才執行真正 cleanup 配方。
  [IO.File]::AppendAllText($presentationPath, "`n合成日誌：處理 fixture/shared 工作（session-only，無 commit／PR 證據；coverage.complete=false）。", $utf8)
  Copy-Item -LiteralPath $presentationPath -Destination $run
  $flow.logCheckpoint = $true
  Assert (@(Invoke-ConsumerStep 'cleanup').Count -eq 0 -and -not (Test-Path -LiteralPath $taskRoot)) 'Cleanup recipe failed after synthetic delivery checkpoints.'
  Assert (Test-Path -LiteralPath (Join-Path $SkillRoot 'scripts/capture-daily-work-log.ps1')) 'Cleanup removed the bundled helper.'
  Assert (($events -join ',') -eq 'collect,cleanup' -and [IO.File]::ReadAllText("$Root/calls.txt") -eq "probe`ncollect`n") 'Consumer flow retried collection or escaped approved recipes.'
  [IO.File]::WriteAllText((Join-Path $run 'consumer-flow.json'), (@{scope='synthetic controlled harness; actual agent/conversation delivery not verified';events=@($events);renderRetainsEvidence=$true;cleanupRequiresBothSyntheticCheckpoints=$true;published=$false} | ConvertTo-Json), $utf8)
} finally {
  # 測試即使 red 也須清理自有合成狀態；這不是 consumer 的交付後清理。
  if ($taskRoot -and (Test-Path -LiteralPath $taskRoot)) { Remove-Item -LiteralPath $taskRoot -Recurse -Force }
}
'@
  # PS5.1 的 -File 以 ANSI 解讀無 BOM 原始碼；只替含中文的 scenario 加 BOM。
  # Capture JSON 仍由 Write-Utf8／配方維持 UTF-8 無 BOM 契約。
  [IO.File]::WriteAllText("$root\scenario.ps1", $scenario, [Text.UTF8Encoding]::new($true))
  # 固定 ANSI fallback，避免本機 ACP 65001 掩蓋 PS5.1 對無 BOM 原始碼的誤讀。
  # 讀取同一份 scenario 後真正執行配方及輸出斷言，不只檢查 BOM bytes。
  Write-Utf8 "$root\ansi-source-consumer.ps1" @'
param([string]$Root, [string]$RecipePath, [string]$SkillRoot, [string]$Mutation)
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $Root 'scenario.ps1'), [Text.Encoding]::GetEncoding(1252))
& ([scriptblock]::Create($source)) -Root $Root -RecipePath $RecipePath -SkillRoot $SkillRoot -Mutation $Mutation -RunLabel '5-ansi1252'
'@
  foreach ($shell in @($ps5, $pwsh)) {
    if (Test-Path -LiteralPath "$root\calls.txt") { Remove-Item -LiteralPath "$root\calls.txt" }
    # Process-only policy for synthetic scripts; no registry/profile/global change.
    & $shell -NoProfile -ExecutionPolicy Bypass -File "$root\scenario.ps1" -Root $root -RecipePath $recipePath -SkillRoot $skillRoot -Mutation $Mutation
    if ($LASTEXITCODE -ne 0) { throw "Windows capture failed with $shell (mutation=$Mutation)." }
  }
  if (Test-Path -LiteralPath "$root\calls.txt") { Remove-Item -LiteralPath "$root\calls.txt" }
  & $ps5 -NoProfile -ExecutionPolicy Bypass -File "$root\ansi-source-consumer.ps1" -Root $root -RecipePath $recipePath -SkillRoot $skillRoot -Mutation $Mutation
  if ($LASTEXITCODE -ne 0) { throw "Windows capture failed with ANSI-1252 source fallback (mutation=$Mutation)." }
  if ($EvidenceRoot) {
    $destination = Join-Path $EvidenceRoot ('windows-capture-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $destination
    Copy-Item -Path "$root\result-*" -Destination $destination -Recurse
    "Synthetic evidence: $destination"
  }
  'PASS Windows PowerShell 5.1 -> pwsh 7, pwsh 7 -> pwsh 7 and ANSI-1252 source fallback; bundled UTF-8 capture, bounded index/sessions, full compatibility drafts/ERP, fixed repo/session/raw selection and synthetic checkpoint-controlled cleanup (not actual conversation delivery).'
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
