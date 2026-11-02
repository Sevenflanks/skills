[CmdletBinding()]
param(
  [Parameter(ValueFromPipeline = $true)]
  [string]$InputJson,
  [int]$MaxCommitsPerRepo = 8,
  [ValidateSet('summary', 'erp', 'index', 'compatibility', 'sessions', 'raw')]
  [string]$View = 'summary',
  [string]$InputPath,
  [string]$GithubRepo,
  [string]$SessionId,
  [AllowEmptyString()][string]$JsonPointer
)

begin {
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  $inputChunks = [System.Collections.Generic.List[string]]::new()
}

process {
  if ($null -ne $InputJson) {
    $inputChunks.Add($InputJson)
  }
}

end {
  function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
      return @()
    }

    return @($Value)
  }

  function Get-PropertyValue {
    param(
      $Object,
      [string]$Name
    )

    if ($null -eq $Object) {
      return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
      return $null
    }

    return $property.Value
  }

  function Test-StashNoiseSubject {
    param([string]$Subject)

    return ($Subject -match '^(refs/stash|index on |untracked files on )')
  }

  function New-RawReference {
    param([string]$Pointer)
    $reference = [ordered]@{ document = 'raw-collector-json'; jsonPointer = $Pointer }
    if ($InputPath) { $reference.inputPath = $InputPath }
    return $reference
  }

  function ConvertTo-PointerToken {
    param([string]$Name)
    return $Name.Replace('~', '~0').Replace('/', '~1')
  }

  function Write-RawSelection {
    param([string]$Json, [string]$Pointer)
    if ($Pointer -ne '' -and -not $Pointer.StartsWith('/')) { throw 'JsonPointer must be empty (document root) or start with /.' }
    # JSON DOM keeps null/empty arrays, exact case-sensitive keys, numbers and timestamp strings.
    # Re-serializing a PowerShell object here can silently change those raw JSON values.
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 1024
    $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    try {
      $node = $document.RootElement
      if ($Pointer -ne '') {
        foreach ($encoded in $Pointer.Substring(1).Split('/')) {
          if ($encoded -match '~(?![01])') { throw 'Invalid JSON pointer escape.' }
          $token = $encoded.Replace('~1', '/').Replace('~0', '~')
          switch ($node.ValueKind.ToString()) {
            'Object' { $node = $node.GetProperty($token) }
            'Array' {
              $offset = 0
              if ($token -cnotmatch '^(0|[1-9][0-9]*)$' -or -not [int]::TryParse($token, [ref]$offset) -or $offset -ge $node.GetArrayLength()) { throw 'JSON pointer array index does not exist.' }
              $node = $node[$offset]
            }
            default { throw 'JSON pointer cannot descend into a scalar or null.' }
          }
        }
      }
      $reference = New-RawReference $Pointer | ConvertTo-Json -Depth 100 -Compress
      '{"detailRef":' + $reference + ',"value":' + $node.GetRawText() + '}'
    }
    finally { $document.Dispose() }
  }

  function Test-SelectedSession {
    param($Evidence)
    return ((Get-PropertyValue $Evidence 'sessionId') -ceq $SessionId -or
      $SessionId -cin @(ConvertTo-Array (Get-PropertyValue $Evidence 'sessionIds')))
  }

  function Get-KnownCount {
    param($Object, [string]$Name)
    # 舊版未提供與明確空陣列不同；null 是 unknown，不能報成零筆。
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $null }
    $value = $Object.PSObject.Properties[$Name].Value
    if ($null -eq $value) { return $null }
    return @($value).Count
  }

  function New-ArrayIndex {
    param($Object, [string]$Name, [string]$Pointer)
    # 缺欄位時指回存在的 parent；不可把不存在的陣列位置假稱為可解析的 raw pointer。
    $target = if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { "$Pointer/$(ConvertTo-PointerToken $Name)" } else { $Pointer }
    return [ordered]@{ count = Get-KnownCount $Object $Name; detailRef = New-RawReference $target }
  }

  function Select-IndexScalars {
    param($Object, [string[]]$Names)
    $result = [ordered]@{}
    foreach ($name in $Names) {
      $value = Get-PropertyValue $Object $name
      # 白名單僅允許 scalar；未識別的 nested diagnostics 由 raw ref 選讀。
      $result[$name] = if ($null -eq $value -or $value -is [string] -or $value -is [ValueType]) { $value } else { $null }
    }
    return $result
  }

  function Get-DiagnosticIndex {
    param($Object, [string]$Pointer)
    $result = Select-IndexScalars $Object @('complete','strategy','archive','accountingKnown','daysConsidered','visitedEntries','candidateFiles','openedFiles','readBytes','enumerationFailures','stopReason','oversizedLines','fileCapStops','oversizedDiscardBytes','filesWithRangeEvents')
    $result.limits = Select-IndexScalars (Get-PropertyValue $Object 'limits') @('days','entries','files','totalBytes','fileBytes','lineBytes','pathComponents')
    foreach ($name in @('selectedDays','candidateDays','visitedDays','unvisitedDays','skipped','limitHits')) {
      $result[$name] = New-ArrayIndex $Object $name $Pointer
    }
    $distribution = Get-PropertyValue $Object 'readBytesDistribution'
    if ($null -ne $distribution) {
      $result.readBytesDistribution = Select-IndexScalars $distribution @('count','totalBytes','minBytes','maxBytes')
      $result.readBytesDistribution.buckets = Select-IndexScalars (Get-PropertyValue $distribution 'buckets') @('zero','upTo256KiB','upTo1MiB','upTo8MiB','over8MiB')
    }
    $fallback = Get-PropertyValue $Object 'exactFallback'
    if ($null -ne $fallback) {
      $result.exactFallback = Select-IndexScalars $fallback @('lineBytes','recoveredOversizedLines')
      $result.exactFallback.unread = New-ArrayIndex $fallback 'unread' "$Pointer/exactFallback"
    }
    Add-SourceDiagnostics $result $Object $Pointer
    return $result
  }

  function Add-SourceDiagnostics {
    param($Result, $Object, [string]$Pointer)
    # 相容已存在的 source 根層及 coverage 內欄位；pointer 必須保留實際位置。
    $adapters = Get-PropertyValue $Object 'adapters'
    if ($null -ne $adapters) {
      $Result.adapters = [ordered]@{}
      foreach ($property in $adapters.PSObject.Properties) {
        $adapterPointer = "$Pointer/adapters/$(ConvertTo-PointerToken $property.Name)"
        $adapter = Select-IndexScalars $property.Value @('status','reason','candidates','returnedItems','rejectedItems','unknownMetadataTimes')
        $adapter.detailRef = New-RawReference $adapterPointer
        foreach ($name in @('sessions','unread','missingRequiredColumns','missingRequiredIndexes')) {
          if (($property.Name -eq 'exact' -and $name -eq 'sessions') -or
              ($null -ne $property.Value -and $property.Value.PSObject.Properties[$name])) { $adapter[$name] = New-ArrayIndex $property.Value $name $adapterPointer }
        }
        $Result.adapters[$property.Name] = $adapter
      }
    }
    $resources = Get-PropertyValue $Object 'sqliteResources'
    if ($null -ne $resources) {
      $Result.sqliteResources = Select-IndexScalars $resources @('rows','payloadBytes','accounting')
      $Result.sqliteResources.limits = Select-IndexScalars (Get-PropertyValue $resources 'limits') @('rows','payloadBytes','deadlineSeconds')
      foreach ($name in @('limitHits','unread')) { $Result.sqliteResources[$name] = New-ArrayIndex $resources $name "$Pointer/sqliteResources" }
    }
    $runtime = Get-PropertyValue $Object 'runtime'
    if ($null -ne $runtime) { $Result.runtime = Select-IndexScalars $runtime @('python','sqlite','codexContract') }
    if ($Object.PSObject.Properties['compatibilityIssues']) { $Result.compatibilityIssues = New-ArrayIndex $Object 'compatibilityIssues' $Pointer }
  }

  function Get-IndexMeta {
    param($Meta)
    $result = Select-IndexScalars $Meta @('generatedAt','timezone','from','to','sourceMode','probeOnly','collectionStatus','canGenerateLog','ghAvailable','ghViewer','authorScope')
    # 新診斷 schema 尚未適配時仍可完整選讀，index 不展開未知 metadata。
    $result.detailRef = New-RawReference $(if ($collector.PSObject.Properties['meta']) { '/meta' } else { '' })
    if ($null -ne $Meta -and $Meta.PSObject.Properties['diagnostics']) {
      $diagnostics = Get-PropertyValue $Meta 'diagnostics'
      $result.diagnostics = Select-IndexScalars $diagnostics @('schemaVersion')
      $result.diagnostics.detailRef = New-RawReference '/meta/diagnostics'
      if ($result.diagnostics.schemaVersion -ceq 1) {
        $result.diagnostics.totalDurationMs = (Select-IndexScalars $diagnostics @('totalDurationMs')).totalDurationMs
        $result.diagnostics.stages = [ordered]@{}
        $stages = Get-PropertyValue $diagnostics 'stages'
        foreach ($stage in @('sourceAdapter','json','repoDiscovery','git','github','output')) {
          $result.diagnostics.stages[$stage] = Select-IndexScalars (Get-PropertyValue $stages $stage) @('durationMs','calls','cacheHits')
        }
        # Stage durations may overlap; total is the producer's independent clock, never their sum.
      }
    }
    $result.sources = [ordered]@{}
    $sources = Get-PropertyValue $Meta 'sources'
    if ($null -eq $sources) { $result.sources = $null; return $result }
    foreach ($property in $sources.PSObject.Properties) {
      $source = $property.Value
      $pointer = "/meta/sources/$(ConvertTo-PointerToken $property.Name)"
      $entry = Select-IndexScalars $source @('available','cliAvailable','readStatus','reason')
      $entry.detailRef = New-RawReference $pointer
      if ($property.Name -in @('opencode','codex') -and $null -ne $source) {
        $entry.entries = New-ArrayIndex $source 'entries' $pointer
        $entry.unknownTimeEvents = Get-PropertyValue $source 'unknownTimeEvents'
        $coverage = Get-PropertyValue $source 'coverage'
        if ($null -ne $coverage) { $entry.coverage = Get-DiagnosticIndex $coverage "$pointer/coverage" }
        Add-SourceDiagnostics $entry $source $pointer
        if (-not $source.PSObject.Properties['compatibilityIssues'] -and
            ($null -eq $coverage -or -not $coverage.PSObject.Properties['compatibilityIssues'])) {
          $entry.compatibilityIssues = New-ArrayIndex $source 'compatibilityIssues' $pointer
        }
        $probeWork = Get-PropertyValue $source 'probeWork'
        if ($null -ne $probeWork) { $entry.probeWork = Select-IndexScalars $probeWork @('checkedPaths','visitedEntries','openedFiles','readBytes') }
        # OpenCode discovery 是 producer 保證固定大小、無私有路徑的 nested aggregate。
        $discovery = Get-PropertyValue $source 'discovery'
        if ($property.Name -eq 'opencode' -and $null -ne $discovery) { $entry.discovery = $discovery }
      }
      $result.sources[$property.Name] = $entry
    }
    return $result
  }

  function Get-CompatibilityView {
    param($Collector)
    $drafts = [System.Collections.Generic.List[object]]::new()
    $origins = [System.Collections.Generic.List[object]]::new()
    $sources = Get-PropertyValue (Get-PropertyValue $Collector 'meta') 'sources'
    if ($null -ne $sources) {
      foreach ($property in $sources.PSObject.Properties) {
        $pointer = "/meta/sources/$(ConvertTo-PointerToken $property.Name)"
        $source = $property.Value
        $coverage = Get-PropertyValue $source 'coverage'
        $containers = @(@{ value = $source; pointer = $pointer })
        if ($null -ne $coverage -and $coverage.PSObject.Properties['compatibilityIssues']) {
          $containers += @{ value = $coverage; pointer = "$pointer/coverage" }
        }
        foreach ($container in $containers) {
          # coverage 有明確草稿時，不再增加根層不存在欄位的 unknown entry。
          if ($container.pointer -eq $pointer -and $containers.Count -gt 1 -and
              ($null -eq $source -or -not $source.PSObject.Properties['compatibilityIssues'])) { continue }
          $origin = New-ArrayIndex $container.value 'compatibilityIssues' $container.pointer
          $origins.Add([ordered]@{ source = $property.Name; count = $origin.count; detailRef = $origin.detailRef })
          $items = @(ConvertTo-Array (Get-PropertyValue $container.value 'compatibilityIssues'))
          for ($i = 0; $i -lt $items.Count; $i++) {
            # producer 已脫敏的原草稿照值傳遞；render 不代表交付，更不改寫 published。
            $draft = [ordered]@{}
            foreach ($name in @('destination','title','body','requiresExplicitConsent','published')) { $draft[$name] = Get-PropertyValue $items[$i] $name }
            $draft.detailRef = New-RawReference "$($container.pointer)/compatibilityIssues/$i"
            $drafts.Add($draft)
          }
        }
      }
    }
    return [ordered]@{ drafts = @($drafts); sources = @($origins); warnings = @($warnings); errors = @($errors) }
  }

  function Format-DateValue {
    param($Value)

    if ($null -eq $Value) {
      return $null
    }

    if ($Value -is [datetimeoffset]) {
      return $Value.ToString('o')
    }

    if ($Value -is [datetime]) {
      return $Value.ToString('yyyy-MM-ddTHH:mm:ss')
    }

    return [string]$Value
  }

  function Format-PrReference {
    param($PullRequest)

    $number = Get-PropertyValue -Object $PullRequest -Name 'number'
    $title = [string](Get-PropertyValue -Object $PullRequest -Name 'title')
    $state = [string](Get-PropertyValue -Object $PullRequest -Name 'state')
    $stateSuffix = if ([string]::IsNullOrWhiteSpace($state)) { '' } else { ' [{0}]' -f $state }

    if ([string]::IsNullOrWhiteSpace($title) -or $title.Trim() -ieq 'noop') {
      return [ordered]@{
        IsLowSignal = $true
        Text = ('PR #{0}{1}' -f $number, $stateSuffix)
      }
    }

    return [ordered]@{
      IsLowSignal = $false
      Text = ('PR #{0}: {1}{2}' -f $number, $title.Trim(), $stateSuffix)
    }
  }

  function Format-SummaryEvidence {
    param($Evidence, [string]$RawPointer, [object[]]$AllEvidence)

    if ((Get-PropertyValue $Evidence 'source') -ne 'codex' -or (Get-PropertyValue $Evidence 'role') -ne 'tool') { return $Evidence }
    $tool = Get-PropertyValue $Evidence 'tool'
    $status = [string](Get-PropertyValue $tool 'status')
    $exitCode = Get-PropertyValue $tool 'exitCode'
    $errorValue = Get-PropertyValue $tool 'error'
    # 只有已知正常的工具結果可 compact。未知／失敗及 structured metadata 保守展開，
    # 成功 readback、驗證與交付也屬 critical；不可只憑工具名稱或 exit 0 丟內容。
    if (($null -eq $exitCode -and $status -notin @('completed', 'success')) -or
        ($null -ne $exitCode -and $exitCode -ne 0) -or $errorValue -or
        $status -in @('failed', 'error', 'cancelled', 'interrupted')) { return $Evidence }
    $context = [System.Collections.Generic.List[object]]::new()
    $context.Add((Get-PropertyValue $Evidence 'detail'))
    foreach ($related in $AllEvidence) {
      if ((Get-PropertyValue $related 'sourceId') -eq (Get-PropertyValue $Evidence 'sourceId') -and
          (Get-PropertyValue $related 'sessionId') -eq (Get-PropertyValue $Evidence 'sessionId') -and
          (Get-PropertyValue $related 'turnId') -eq (Get-PropertyValue $Evidence 'turnId')) {
        $context.Add((Get-PropertyValue $related 'detail'))
        $context.Add((Get-PropertyValue $related 'mirrorDetails'))
      }
    }
    $meaning = ConvertTo-Json -InputObject @($context) -Depth 100 -Compress
    if ($meaning -match '"(structuredContent|_meta|error|isError)"\s*:' -or
        $meaning -match '(?i)\b(readback|receipt|verification|verified|requirement|delivery)\b|讀回|驗證|交付|需求' -or
        $meaning -match '(?i)(^|[\s"/:.\\-])(tests?|unittest|pytest|verify|validate|checks?|build)([\s"/:.\\-]|$)|\bgh\s+(pr|issue|release)\b|\bgit\s+(push|commit|tag)\b') { return $Evidence }

    $compact = [ordered]@{}
    foreach ($property in $Evidence.PSObject.Properties) {
      if ($property.Name -notin @('title', 'text', 'detail', 'mirrorDetails')) { $compact[$property.Name] = $property.Value }
    }
    $label = [string](Get-PropertyValue $tool 'name')
    if (-not $label) { $label = [string](Get-PropertyValue $Evidence 'eventType') }
    $compact.title = "tool: $label; status: $status; exitCode: $exitCode"
    $compact.text = $compact.title
    # 指向同一次 raw collector document；即使 stdin 沒有檔名，也能依 pointer + source IDs 精確追溯。
    $compact.detailRef = [ordered]@{ document = 'raw-collector-json'; jsonPointer = $RawPointer }
    if ($InputPath) { $compact.detailRef.inputPath = $InputPath }
    return $compact
  }

  $warnings = [System.Collections.Generic.List[string]]::new()
  $errors = [System.Collections.Generic.List[string]]::new()
  $repos = [System.Collections.Generic.List[object]]::new()

  try {
    $rawInput = ($inputChunks -join [Environment]::NewLine).Trim()
    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
      if (-not [string]::IsNullOrWhiteSpace($rawInput)) { throw 'Provide InputPath or stdin JSON, not both.' }
      $rawInput = [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath))
    }
    elseif ([string]::IsNullOrWhiteSpace($rawInput) -and -not [Console]::IsInputRedirected) {
      $rawInput = ''
    }
    elseif ([string]::IsNullOrWhiteSpace($rawInput)) {
      $rawInput = [Console]::In.ReadToEnd().Trim()
    }
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
      throw 'No collector JSON was provided on stdin.'
    }

    if ($MaxCommitsPerRepo -lt 1) {
      throw 'MaxCommitsPerRepo must be greater than zero.'
    }

    if ($View -eq 'raw') {
      if (-not $PSBoundParameters.ContainsKey('JsonPointer')) { throw 'View raw requires JsonPointer; use an empty string for the document root.' }
      if ($PSBoundParameters.ContainsKey('GithubRepo') -or $PSBoundParameters.ContainsKey('SessionId')) { throw 'Raw pointers address the original document; do not combine them with repo/session filters.' }
      Write-RawSelection $rawInput $JsonPointer
      return
    }
    if ($PSBoundParameters.ContainsKey('JsonPointer')) { throw 'JsonPointer requires View raw.' }
    foreach ($filter in @('GithubRepo','SessionId')) {
      if ($PSBoundParameters.ContainsKey($filter) -and [string]::IsNullOrWhiteSpace($PSBoundParameters[$filter])) { throw "$filter must not be empty." }
    }
    if ($View -eq 'compatibility' -and ($GithubRepo -or $SessionId)) { throw 'Compatibility drafts are source-wide; repo/session filters are not supported.' }
    $collector = $rawInput | ConvertFrom-Json
    foreach ($warning in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'warnings'))) {
      $warnings.Add([string]$warning)
    }
    foreach ($errorMessage in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'errors'))) {
      $errors.Add([string]$errorMessage)
    }

    if ($View -eq 'compatibility') {
      Get-CompatibilityView $collector | ConvertTo-Json -Depth 100 -Compress
      return
    }

    $repoIndex = -1
    foreach ($repo in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'repos'))) {
      $repoIndex++
      if ($GithubRepo -and (Get-PropertyValue $repo 'githubRepo') -ine $GithubRepo) { continue }
      # Keep original array positions: filtering the raw arrays first would retarget detailRef.
      # Unfiltered index only needs counts, not an extra traversal of every session.
      $selectedOffsets = @()
      if ($SessionId -or $View -ne 'index') {
        $allEvidence = @(ConvertTo-Array (Get-PropertyValue $repo 'sessionEvidence'))
        $selectedOffsets = @(for ($i = 0; $i -lt $allEvidence.Count; $i++) {
          if (-not $SessionId -or (Test-SelectedSession $allEvidence[$i])) { $i }
        })
      }
      if ($SessionId -and $selectedOffsets.Count -eq 0) { continue }
      if ($View -eq 'index') {
        $repos.Add([ordered]@{
          name = Get-PropertyValue $repo 'name'; githubRepo = Get-PropertyValue $repo 'githubRepo'
          source = Get-PropertyValue $repo 'source'; isGitRepo = Get-PropertyValue $repo 'isGitRepo'
          commits = Get-KnownCount $repo 'commits'; prs = Get-KnownCount $repo 'prs'; sessions = if ($SessionId) { $selectedOffsets.Count } else { Get-KnownCount $repo 'sessionEvidence' }
          warnings = @(ConvertTo-Array (Get-PropertyValue $repo 'warnings')); detailRef = New-RawReference "/repos/$repoIndex"
        })
        continue
      }
      if ($View -eq 'sessions') {
        $sessionIndex = @(foreach ($i in $selectedOffsets) {
          $entry = [ordered]@{}
          foreach ($name in @('source','agent','sessionId','sessionIds','sourceId','turnId','itemId','role','eventType')) { $entry[$name] = Get-PropertyValue $allEvidence[$i] $name }
          $entry.detailRef = New-RawReference "/repos/$repoIndex/sessionEvidence/$i"
          $entry
        })
        $repos.Add([ordered]@{
          name = Get-PropertyValue $repo 'name'; githubRepo = Get-PropertyValue $repo 'githubRepo'
          source = Get-PropertyValue $repo 'source'; sessionEvidence = $sessionIndex
          warnings = @(ConvertTo-Array (Get-PropertyValue $repo 'warnings')); detailRef = New-RawReference "/repos/$repoIndex"
        })
        continue
      }
      if ($View -eq 'erp') {
        # ERP 歸屬需 refs、PR 結構及全部來源續行；只省不需要的 repo path 與排版，不能套 summary 上限。
        $repos.Add([ordered]@{
          name = Get-PropertyValue -Object $repo -Name 'name'
          githubRepo = Get-PropertyValue -Object $repo -Name 'githubRepo'
          source = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'source'))
          isGitRepo = Get-PropertyValue -Object $repo -Name 'isGitRepo'
          commits = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'commits'))
          prs = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'prs'))
          sessionEvidence = @(foreach ($i in $selectedOffsets) { $allEvidence[$i] })
          warnings = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'warnings'))
        })
        continue
      }
      $repoWarnings = [System.Collections.Generic.List[string]]::new()
      foreach ($warning in (ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'warnings'))) {
        $repoWarnings.Add([string]$warning)
      }

      $summaryCommits = [System.Collections.Generic.List[object]]::new()
      foreach ($commit in (ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'commits'))) {
        $subject = [string](Get-PropertyValue -Object $commit -Name 'subject')
        if (Test-StashNoiseSubject -Subject $subject) {
          continue
        }

        $summaryCommits.Add([ordered]@{
          hash = Get-PropertyValue -Object $commit -Name 'hash'
          subject = $subject
          author = Get-PropertyValue -Object $commit -Name 'author'
          authorEmail = Get-PropertyValue -Object $commit -Name 'authorEmail'
          authorDate = if ($null -ne (Get-PropertyValue -Object $commit -Name 'authorDate')) { Format-DateValue -Value (Get-PropertyValue -Object $commit -Name 'authorDate') } else { Format-DateValue -Value (Get-PropertyValue -Object $commit -Name 'date') }
        })
      }

      if ($summaryCommits.Count -gt $MaxCommitsPerRepo) {
        $repoWarnings.Add(('Commit list compacted from {0} to {1} shown commits.' -f $summaryCommits.Count, $MaxCommitsPerRepo))
      }

      $prTexts = [System.Collections.Generic.List[string]]::new()
      $lowSignalPrRefs = [System.Collections.Generic.List[string]]::new()
      foreach ($pullRequest in (ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'prs'))) {
        $formatted = Format-PrReference -PullRequest $pullRequest
        if ($formatted.IsLowSignal) {
          $lowSignalPrRefs.Add($formatted.Text)
        }
        else {
          $prTexts.Add($formatted.Text)
        }
      }

      $summaryEvidence = @(foreach ($i in $selectedOffsets) {
        Format-SummaryEvidence -Evidence $allEvidence[$i] -RawPointer "/repos/$repoIndex/sessionEvidence/$i" -AllEvidence $allEvidence
      })
      $repos.Add([ordered]@{
        name = Get-PropertyValue -Object $repo -Name 'name'
        githubRepo = Get-PropertyValue -Object $repo -Name 'githubRepo'
        commitCount = $summaryCommits.Count
        shownCommits = @($summaryCommits | Select-Object -First $MaxCommitsPerRepo)
        prs = @($prTexts)
        lowSignalPrRefs = @($lowSignalPrRefs)
        # 主題合併需要全部來源證據；截斷前五筆會讓另一來源或續行消失。
        sessionEvidence = $summaryEvidence
        warnings = @($repoWarnings)
      })
    }

    [ordered]@{
      meta = if ($View -in @('index','sessions')) { Get-IndexMeta (Get-PropertyValue $collector 'meta') } else { Get-PropertyValue -Object $collector -Name 'meta' }
      warnings = @($warnings)
      errors = @($errors)
      repos = $repos
    } | ConvertTo-Json -Depth 100 -Compress:($View -in @('erp','index','sessions'))
  }
  catch {
    $errors.Add($_.Exception.Message)
    [ordered]@{
      meta = $null
      warnings = @($warnings)
      errors = @($errors)
      repos = @()
    } | ConvertTo-Json -Depth 8
  }
}
