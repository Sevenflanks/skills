param([ValidateSet('index','legacy','compatibility','auth','all')][string]$Case = 'all', [string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$formatter = Join-Path $PSScriptRoot '../scripts/format-daily-work-log-evidence.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('index-view-' + [guid]::NewGuid().ToString('N'))
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($root)))) { throw 'Temporary parent unavailable' }
$null = [IO.Directory]::CreateDirectory($root)
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), $utf8) }
function Format($Value, [string]$View = 'index', [switch]$Stdin) {
  Write-Json "$root/raw.json" $Value
  if ($Stdin) { $text = ([IO.File]::ReadAllText("$root/raw.json") | & $pwsh -NoProfile -File $formatter -View $View) -join "`n" }
  else { $text = (& $pwsh -NoProfile -File $formatter -InputPath "$root/raw.json" -View $View) -join "`n" }
  Assert ($LASTEXITCODE -eq 0) "formatter CLI failed: $View"
  [pscustomobject]@{ Text = $text; Data = ($text | ConvertFrom-Json -Depth 100); Bytes = [Text.Encoding]::UTF8.GetByteCount($text) }
}
function Fixture([int]$Count) {
  $rows = @(for ($i=0; $i -lt $Count; $i++) { @{sessionId="private-$i";path="C:\private\$i";reason=('診斷私文' * 40);status='partial'} })
  [ordered]@{
    meta=[ordered]@{generatedAt='2026-10-29T08:00:00Z';from='2026-10-29T00:00:00Z';to='2026-10-30T00:00:00Z';timezone='Asia/Taipei';sourceMode='session';probeOnly=$false;collectionStatus='partial';canGenerateLog=$true;ghAvailable=$false;scanRoots=@('C:\private');sources=[ordered]@{
      opencode=@{available=$true;readStatus='partial';reason='aggregate-only';discovery=@{metadataRows=@{count=2049;complete=$false};normalizedUnique=@{count=$null;reason='not-read'}}}
      codex=[ordered]@{available=$true;readStatus='partial';reason='local-records-readable';coverage=[ordered]@{
        complete=$false;strategy='bounded';accountingKnown=$false;readBytes=123;stopReason='totalBytes';limits=@{files=128;totalBytes=64000000}
        selectedDays=$rows;candidateDays=$rows;visitedDays=$rows;unvisitedDays=$rows;skipped=$rows;limitHits=@('totalBytes')
        exactFallback=@{lineBytes=65536;recoveredOversizedLines=1;unread=$rows}
        adapters=@{state=@{status='partial';reason='unknown-time';unknownMetadataTimes=2};history=@{status='permission';reason='unreadable';rejectedItems=1};exact=@{status='partial';sessions=$rows}}
        runtime=@{python='3.13.1';sqlite='3.49.0';codexContract='fixture'}
        sqliteResources=@{rows=42;payloadBytes=512;limits=@{rows=5000;payloadBytes=100000;deadlineSeconds=30};limitHits=@('deadline');unread=$rows}
        compatibilityIssues=@(@{destination='local-adapter';title='合成草稿';body='已脫敏全文';requiresExplicitConsent=$true;published=$false})
      }}
      'other/~source'=@{available=$true;readStatus='failed';reason='unknown-adapter';privatePayload=$rows}
    }}
    warnings=@('coverage incomplete');errors=@('retained error');repos=@(@{name='fixture';githubRepo='fixture/repo';source=@('session','codex');isGitRepo=$true;path='C:\private';commits=@(@{hash='a'},@{hash='b'});prs=@();sessionEvidence=$rows;warnings=@('repo warning')})
  }
}
try {
  if ($Case -in @('auth','all')) {
    # 呼叫端依 GitHub／auth guard 判斷是否可繼續；遺失 login／null 或展開私人 identity 都是違約。
    $observed = @(foreach ($auth in @(
      @{ghAvailable=$true;ghViewer=$null},
      @{ghAvailable=$true;ghViewer='fixture-login'},
      @{ghAvailable=$false;ghViewer=$null}
    )) {
      $fixture = @{meta=@{ghAvailable=$auth.ghAvailable;ghViewer=$auth.ghViewer;currentIdentity=@{gitEmail='private@example.invalid';gitName='private-identity'}};repos=@();warnings=@();errors=@()}
      $index = Format $fixture
      Assert ($null -ne $index.Data.meta.PSObject.Properties['ghViewer']) 'index omitted GitHub authenticated viewer guard'
      Assert ($index.Data.meta.ghAvailable -ceq $auth.ghAvailable -and $index.Data.meta.ghViewer -ceq $auth.ghViewer) 'GitHub availability/viewer null or login changed'
      Assert ($null -eq $index.Data.meta.PSObject.Properties['currentIdentity'] -and $index.Text -notmatch 'private@example.invalid|private-identity') 'index expanded private currentIdentity'
      $originalMeta = ($fixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json).meta | ConvertTo-Json -Depth 10 -Compress
      foreach ($view in @('summary','erp')) {
        $data = (Format $fixture -View $view).Data
        Assert (($data.meta | ConvertTo-Json -Depth 10 -Compress) -ceq $originalMeta) "$view full auth/identity metadata changed"
      }
      @{ghAvailable=$index.Data.meta.ghAvailable;ghViewer=$index.Data.meta.ghViewer;currentIdentityExcluded=$true;indexUtf8=$index.Bytes}
    })
    if ($EvidenceRoot) { Write-Json (Join-Path $EvidenceRoot 'auth-viewer-after.json') $observed }
    'PASS auth available+null, available+login, unavailable+null; index identity excluded; summary/ERP full metadata unchanged'
  }
  if ($Case -in @('index','all')) {
    # Index 呼叫端需保留 partial guard 與正確 raw 位址，不能展開大型診斷陣列。
    $small = Format (Fixture 1)
    $large = Format (Fixture 546)
    $data = $large.Data
    Assert ($large.Bytes -lt 16000 -and [Math]::Abs($large.Bytes - $small.Bytes) -lt 1000) 'index grows with diagnostic/session array contents (UTF-8 bytes)'
    Assert ($data.meta.canGenerateLog -and $data.meta.collectionStatus -eq 'partial' -and -not $data.meta.ghAvailable -and -not $data.meta.sources.codex.coverage.complete) 'partial/GitHub guards changed'
    $coverage = $data.meta.sources.codex.coverage
    Assert ($coverage.stopReason -eq 'totalBytes' -and $coverage.readBytes -eq 123 -and $coverage.limits.files -eq 128 -and -not $coverage.accountingKnown) 'fixed diagnostics lost'
    Assert ($coverage.adapters.history.status -eq 'permission' -and $coverage.adapters.history.reason -eq 'unreadable' -and $coverage.adapters.state.unknownMetadataTimes -eq 2) 'adapter status/reason/counters lost'
    Assert ($coverage.adapters.history.rejectedItems -eq 1) 'rejected item count lost'
    Assert ($coverage.runtime.python -eq '3.13.1' -and $coverage.sqliteResources.rows -eq 42) 'runtime/resources lost or version interpreted'
    foreach ($name in @('selectedDays','candidateDays','visitedDays','unvisitedDays','skipped')) {
      Assert ($coverage.$name.count -eq 546 -and $coverage.$name.detailRef.jsonPointer -eq "/meta/sources/codex/coverage/$name") "wrong $name count/pointer"
    }
    Assert ($coverage.adapters.exact.sessions.count -eq 546 -and $coverage.adapters.exact.sessions.detailRef.jsonPointer -eq '/meta/sources/codex/coverage/adapters/exact/sessions') 'sessions count/raw pointer wrong'
    Assert ($coverage.exactFallback.unread.count -eq 546 -and $coverage.sqliteResources.unread.count -eq 546 -and $coverage.compatibilityIssues.count -eq 1) 'unread/draft count wrong'
    Assert ($coverage.adapters.exact.sessions.detailRef.inputPath -eq "$root/raw.json" -and $coverage.adapters.exact.sessions.detailRef.document -eq 'raw-collector-json') 'raw document reference wrong'
    Assert ($data.meta.sources.'other/~source'.detailRef.jsonPointer -eq '/meta/sources/other~1~0source' -and $data.meta.sources.'other/~source'.readStatus -eq 'failed') 'unknown source raw pointer/status wrong'
    Assert (($data.meta.sources.opencode.discovery | ConvertTo-Json -Depth 10 -Compress) -eq ((Fixture 1).meta.sources.opencode.discovery | ConvertTo-Json -Depth 10 -Compress)) 'fixed OpenCode aggregate changed'
    Assert ($data.repos[0].commits -eq 2 -and $data.repos[0].prs -eq 0 -and $data.repos[0].sessions -eq 546 -and $data.repos[0].warnings[0] -eq 'repo warning') 'repo evidence counts/gaps wrong'
    Assert ($data.errors[0] -eq 'retained error' -and $data.warnings[0] -eq 'coverage incomplete') 'top gaps lost'
    Assert ($large.Text -notmatch 'private-|C:\\\\private|診斷私文|已脫敏全文|privatePayload|scanRoots') 'index expanded private diagnostics or draft body'
    # 既有 collector 根層與 nested coverage 兩種位置都必須保留精確 pointer。
    $rootLayout = Fixture 1
    foreach ($name in @('adapters','runtime','sqliteResources','compatibilityIssues')) {
      $rootLayout.meta.sources.codex[$name] = $rootLayout.meta.sources.codex.coverage[$name]
      $rootLayout.meta.sources.codex.coverage.Remove($name)
    }
    $rootView = (Format $rootLayout).Data
    Assert ($rootView.meta.sources.codex.adapters.exact.sessions.detailRef.jsonPointer -eq '/meta/sources/codex/adapters/exact/sessions') 'actual collector source pointer wrong'
    $stdin = Format (Fixture 1) -Stdin
    Assert ($null -eq $stdin.Data.meta.sources.codex.detailRef.PSObject.Properties['inputPath']) 'stdin invented a filename'
    if ($EvidenceRoot) {
      Assert (Test-Path -LiteralPath $EvidenceRoot -PathType Container) 'EvidenceRoot must already exist'
      $beforeSmall = [Text.Encoding]::UTF8.GetByteCount(((Fixture 1).meta | ConvertTo-Json -Depth 100 -Compress))
      $beforeLarge = [Text.Encoding]::UTF8.GetByteCount(((Fixture 546).meta | ConvertTo-Json -Depth 100 -Compress))
      Write-Json (Join-Path $EvidenceRoot 'index-before-representative.json') @{description='舊 recipe 原樣展開 meta 的 UTF-8 體量；只留代表性 entry，非完整 dump';smallMetaUtf8=$beforeSmall;largeMetaUtf8=$beforeLarge;diagnosticArrayEntries=546;representativeEntry=@{sessionId='private-0';status='partial';reason='診斷私文（合成）'}}
      Write-Json (Join-Path $EvidenceRoot 'index-comparison.json') @{smallUtf8=$small.Bytes;largeUtf8=$large.Bytes;smallDiagnostics=1;largeDiagnostics=546;oldSmallMetaUtf8=$beforeSmall;oldLargeMetaUtf8=$beforeLarge}
      [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'index-after.json'), $large.Text, $utf8)
    }
    "PASS index smallUtf8=$($small.Bytes) largeUtf8=$($large.Bytes)"
  }
  if ($Case -in @('legacy','all')) {
    # 舊版呼叫端的缺值不可變成零，summary／ERP 也不可遺失原 metadata。
    $legacy = @{meta=@{collectionStatus='read-failed';canGenerateLog=$false;ghAvailable=$false;sources=@{codex=@{readStatus='failed';adapters=@{exact=@{status='not-read'}};coverage=@{complete=$false;selectedDays=@();unvisitedDays=$null}}}};repos=@(@{name='legacy';commits=@();prs=$null});warnings=@();errors=@('source failed')}
    $data = (Format $legacy).Data
    Assert ($data.meta.collectionStatus -eq 'read-failed' -and -not $data.meta.canGenerateLog -and -not $data.meta.ghAvailable -and $data.meta.sources.codex.readStatus -eq 'failed') 'read failure guard lost'
    Assert ($null -eq $data.meta.sources.codex.compatibilityIssues.count -and $null -eq $data.meta.sources.codex.adapters.exact.sessions.count) 'unreported drafts/sessions became zero'
    Assert ($data.meta.sources.codex.coverage.selectedDays.count -eq 0 -and $null -eq $data.meta.sources.codex.coverage.unvisitedDays.count -and $null -eq $data.meta.sources.codex.coverage.candidateDays.count) 'absent/null/empty diagnostics conflated'
    Assert ($data.meta.sources.codex.compatibilityIssues.detailRef.jsonPointer -eq '/meta/sources/codex' -and $data.meta.sources.codex.coverage.candidateDays.detailRef.jsonPointer -eq '/meta/sources/codex/coverage' -and $data.meta.sources.codex.coverage.unvisitedDays.detailRef.jsonPointer -eq '/meta/sources/codex/coverage/unvisitedDays') 'missing legacy field reference must resolve to its existing parent, null field to itself'
    Assert ($null -eq $data.meta.sources.codex.coverage.readBytes -and $null -eq $data.meta.sources.codex.coverage.limits.files -and $null -eq $data.repos[0].sessions -and $null -eq $data.repos[0].prs -and $data.repos[0].commits -eq 0) 'legacy unknown counters became zero'
    foreach ($status in @('no-sources','no-activity','error','partial')) {
      $legacy.meta.collectionStatus = $status
      Assert ((Format $legacy).Data.meta.collectionStatus -eq $status) "$status guard changed"
    }
    $fixture = Fixture 3
    $originalMeta = ($fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json).meta | ConvertTo-Json -Depth 100 -Compress
    foreach ($view in @('summary','erp')) {
      $viewData = (Format $fixture -View $view).Data
      Assert (($viewData.meta | ConvertTo-Json -Depth 100 -Compress) -eq $originalMeta) "$view full metadata changed"
      Assert ($viewData.repos[0].sessionEvidence.Count -eq 3) "$view session evidence truncated"
    }
    $empty = (Format @{meta=@{};repos=@()}).Data
    Assert ($null -eq $empty.meta.sources -and $null -eq $empty.meta.canGenerateLog -and $null -eq $empty.meta.ghAvailable) 'legacy empty metadata guessed guards'
    'PASS legacy and full metadata'
  }
  if ($Case -in @('compatibility','all')) {
    # 草稿呈現者需要全文與正確來源，不能以筆數代替或虛構發布狀態。
    $fixture = Fixture 1
    $fixture.meta.sources.codex.compatibilityIssues = @(
      @{destination='adapter-maintainer';title='本機能力';body="完整已脫敏草稿`n第二行";requiresExplicitConsent=$true;published=$false},
      @{destination='upstream-review';title='已知狀態';body='保留原值';requiresExplicitConsent=$false;published=$true}
    )
    $result = Format $fixture -View compatibility
    Assert ($result.Data.drafts.Count -eq 3) 'drafts truncated across root and coverage'
    $first = $result.Data.drafts[0]
    Assert ($first.destination -eq 'adapter-maintainer' -and $first.title -eq '本機能力' -and $first.body -eq "完整已脫敏草稿`n第二行" -and $first.requiresExplicitConsent -and -not $first.published) 'full draft fields/status changed'
    Assert ($first.detailRef.jsonPointer -eq '/meta/sources/codex/compatibilityIssues/0' -and $first.detailRef.inputPath -eq "$root/raw.json") 'root draft origin wrong'
    Assert ($result.Data.drafts[1].published -and -not $result.Data.drafts[1].requiresExplicitConsent) 'existing published/consent value overwritten'
    Assert ($result.Data.drafts[2].destination -eq 'local-adapter' -and $result.Data.drafts[2].detailRef.jsonPointer -eq '/meta/sources/codex/coverage/compatibilityIssues/0') 'coverage draft origin wrong'
    Assert ($result.Text -notmatch 'delivered|posted|private-|診斷私文') 'invented delivery or expanded unrelated diagnostics'
    $rawAfter = [IO.File]::ReadAllText("$root/raw.json") | ConvertFrom-Json
    Assert (-not $rawAfter.meta.sources.codex.compatibilityIssues[0].published) 'formatter modified raw publication status'
    $stdin = Format $fixture -View compatibility -Stdin
    Assert ($null -eq $stdin.Data.drafts[0].detailRef.PSObject.Properties['inputPath']) 'stdin draft invented filename'
    $missing = (Format @{meta=@{sources=@{codex=@{}}}} -View compatibility).Data
    $empty = (Format @{meta=@{sources=@{codex=@{compatibilityIssues=@()}}}} -View compatibility).Data
    Assert ($missing.drafts.Count -eq 0 -and $empty.drafts.Count -eq 0 -and $null -eq $missing.sources[0].count -and $empty.sources[0].count -eq 0) 'missing/empty drafts conflated or invented'
    $unknown = (Format @{meta=@{sources=@{codex=@{compatibilityIssues=@(@{title='legacy';body='全文'})}}}} -View compatibility).Data
    Assert ($null -eq $unknown.drafts[0].published -and $null -eq $unknown.drafts[0].requiresExplicitConsent) 'legacy draft unknown flags invented'
    if ($EvidenceRoot) { Write-Json (Join-Path $EvidenceRoot 'compatibility-after.json') $result.Data }
    'PASS compatibility all drafts, absent/empty, no publication'
  }
} finally { [IO.Directory]::Delete($root, $true) }
