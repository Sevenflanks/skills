[CmdletBinding()]
param(
    [Parameter(Mandatory)][Int64]$JobHandle,
    [Parameter(Mandatory)][string]$FinalizeEventName,
    [Parameter(Mandatory)][string]$ReadyEventName,
    [Parameter(Mandatory)][string]$ExitedEventName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('CandidateAgentProcessLifecycle.HolderNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CandidateAgentProcessLifecycle
{
    public static class HolderNative
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

$readyEvent = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
$finalizeEvent = [Threading.EventWaitHandle]::OpenExisting($FinalizeEventName)
$exitedEvent = [Threading.EventWaitHandle]::OpenExisting($ExitedEventName)

try {
    $readyEvent.Set() | Out-Null
    $finalizeEvent.WaitOne() | Out-Null

    # 只有 holder 保留 Job handle；Finalize 在 root 已結束後才釋放它，讓 named Job 可跨 invocation 重開。
    if (-not [CandidateAgentProcessLifecycle.HolderNative]::CloseHandle([IntPtr]$JobHandle)) {
        throw 'The inherited Job handle could not be closed.'
    }
    $exitedEvent.Set() | Out-Null
}
finally {
    $readyEvent.Dispose()
    $finalizeEvent.Dispose()
    $exitedEvent.Dispose()
}
