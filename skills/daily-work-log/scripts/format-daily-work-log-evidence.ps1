[CmdletBinding()]
param(
  [Parameter(ValueFromPipeline = $true)]
  [string]$InputJson,
  [int]$MaxCommitsPerRepo = 8,
  [ValidateSet('summary', 'erp')]
  [string]$View = 'summary',
  [string]$InputPath
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

    $collector = $rawInput | ConvertFrom-Json
    foreach ($warning in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'warnings'))) {
      $warnings.Add([string]$warning)
    }
    foreach ($errorMessage in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'errors'))) {
      $errors.Add([string]$errorMessage)
    }

    foreach ($repo in (ConvertTo-Array -Value (Get-PropertyValue -Object $collector -Name 'repos'))) {
      if ($View -eq 'erp') {
        # ERP 歸屬需 refs、PR 結構及全部來源續行；只省不需要的 repo path 與排版，不能套 summary 上限。
        $repos.Add([ordered]@{
          name = Get-PropertyValue -Object $repo -Name 'name'
          githubRepo = Get-PropertyValue -Object $repo -Name 'githubRepo'
          source = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'source'))
          isGitRepo = Get-PropertyValue -Object $repo -Name 'isGitRepo'
          commits = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'commits'))
          prs = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'prs'))
          sessionEvidence = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'sessionEvidence'))
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

      $repos.Add([ordered]@{
        name = Get-PropertyValue -Object $repo -Name 'name'
        githubRepo = Get-PropertyValue -Object $repo -Name 'githubRepo'
        commitCount = $summaryCommits.Count
        shownCommits = @($summaryCommits | Select-Object -First $MaxCommitsPerRepo)
        prs = @($prTexts)
        lowSignalPrRefs = @($lowSignalPrRefs)
        # 主題合併需要全部來源證據；截斷前五筆會讓另一來源或續行消失。
        sessionEvidence = @(ConvertTo-Array -Value (Get-PropertyValue -Object $repo -Name 'sessionEvidence'))
        warnings = @($repoWarnings)
      })
    }

    [ordered]@{
      meta = Get-PropertyValue -Object $collector -Name 'meta'
      warnings = @($warnings)
      errors = @($errors)
      repos = $repos
    } | ConvertTo-Json -Depth $(if ($View -eq 'erp') { 100 } else { 8 }) -Compress:($View -eq 'erp')
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
