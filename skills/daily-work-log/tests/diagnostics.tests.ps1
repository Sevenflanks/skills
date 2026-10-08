[CmdletBinding()]
param([string]$EvidenceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot '..\scripts\collect-daily-work-log.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Collector syntax errors' }
# 只載入 function definitions，不執行 main，也不 probe 真實來源或呼叫 CLI。
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class DiagnosticFaultStream : MemoryStream {
  private int reads;
  private int failAfter;
  private bool failDispose;
  public DiagnosticFaultStream(byte[] bytes, int failAfter, bool failDispose) : base(bytes) {
    this.failAfter = failAfter; this.failDispose = failDispose;
  }
  public override int Read(byte[] buffer, int offset, int count) {
    if (reads++ >= failAfter) throw new IOException("synthetic read failure");
    return base.Read(buffer, offset, count);
  }
  protected override void Dispose(bool disposing) {
    base.Dispose(disposing);
    if (failDispose) throw new IOException("synthetic dispose failure");
  }
}
'@
$reader = ($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Read-CodexLinesBounded' }).Extent.Text
$constructor = "[IO.FileStream]::new(`$Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 1)"
if (-not $reader.Contains($constructor)) { throw 'Fault injection seam changed: review test fixture' }
# 替換唯一 stream construction；計帳、parser、catch/finally 都仍為 production functions。
Invoke-Expression ($reader.Replace($constructor, '$script:InjectedStream'))
$root = Join-Path ([IO.Path]::GetTempPath()) ('dwl-diag-' + [guid]::NewGuid().ToString('N'))
$CodexTotalBytes = 64MB; $CodexFileBytes = 8MB; $Timezone = 'Asia/Taipei'
$from = [datetimeoffset]'2026-05-29T00:00:00+08:00'; $to = [datetimeoffset]'2026-05-29T23:59:59+08:00'
function Assert($value, [string]$message) { if (-not $value) { throw $message } }
$passes = 0
try {
  $partition = Join-Path $root 'sessions\2026\05\29'
  $null = [IO.Directory]::CreateDirectory($partition)
  [IO.File]::WriteAllText("$partition\fault.jsonl", '')
  $meta = @{type='session_meta';payload=@{id='synthetic';cwd="$root\repo"}} | ConvertTo-Json -Compress
  $event = '{"type":"event_msg","timestamp":"2026-05-29T02:00:00Z","payload":{"type":"user_message","message":"合成事件"}}'
  $prefix = $meta+"`n"+$event+"`n"
  $cases = @(
    @{name='zero-read-failure';text=$prefix;reads=0;expected=0;events=0;discard=0},
    @{name='partial-read-failure';text=$prefix+('x'*100000);reads=1;expected=4096;events=1;discard=0},
    @{name='oversized-read-failure';text=$prefix+('x'*100000);reads=18;expected=18*4096;events=1;discard=18*4096-[Text.Encoding]::UTF8.GetByteCount($prefix)},
    @{name='dispose-failure';text=$prefix;reads=99;dispose=$true;expected=[Text.Encoding]::UTF8.GetByteCount($prefix);events=1;discard=0}
  )
  foreach ($case in $cases) {
    $script:InjectedStream = [DiagnosticFaultStream]::new([Text.Encoding]::UTF8.GetBytes($case.text),$case.reads,$case.ContainsKey('dispose'))
    $source = [pscustomobject]@{entries=@([pscustomobject]@{kind='sessions';path="$root\sessions";available=$true;reason='readable-directory'});readStatus='not-read'}
    $warnings = [Collections.Generic.List[string]]::new()
    $result = @(Get-CodexSessionDirectories -Source $source -FromRange $from -ToRange $to -Warnings $warnings)
    $c = $source.coverage; $d = $c.readBytesDistribution
    Assert ($c.openedFiles -eq 1 -and $d.count -eq 1 -and $c.readBytes -eq $case.expected -and $d.totalBytes -eq $case.expected -and $d.minBytes -eq $case.expected -and $d.maxBytes -eq $case.expected) "$($case.name): finally lost successful read accounting"
    Assert ($c.filesWithRangeEvents -eq $case.events -and $result.Count -eq $case.events -and $c.oversizedDiscardBytes -eq $case.discard -and $c.fileCapStops -eq 0) "$($case.name): retained events/oversized bytes/error stop accounting wrong"
    Assert ($source.readStatus -eq 'failed') "$($case.name): existing exception readStatus changed"
    $passes++
    if ($EvidenceRoot) {
      [IO.File]::WriteAllText("$EvidenceRoot\$($case.name).json", (@{coverage=$c;readStatus=$source.readStatus;retainedEvidenceRows=$result.Count;fault='synthetic stream only'} | ConvertTo-Json -Depth 10))
    }
    "PASS $($case.name)"
  }
  "PASS diagnostics: $passes/$($cases.Count)"
} finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
