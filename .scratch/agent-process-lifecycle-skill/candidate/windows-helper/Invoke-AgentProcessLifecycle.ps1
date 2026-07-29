[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Launch', 'Finalize')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$RecordPath,

    [string]$Executable,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory,
    [string]$StdoutPath,
    [string]$StderrPath,
    [string]$ReadinessIdentity,
    [hashtable]$ReadinessContext = @{},
    [scriptblock]$ReadinessCheck,
    [ValidateRange(1, 60000)]
    [int]$ReadinessDeadlineMilliseconds = 5000,
    [ValidateSet('Stop')]
    [string]$RequestedDisposition = 'Stop',
    [ValidateSet('Stop')]
    [string]$Disposition = 'Stop',
    [scriptblock]$GracefulAction,
    [hashtable]$GracefulContext = @{},
    [ValidateRange(1, 60000)]
    [int]$GracefulDeadlineMilliseconds = 5000,
    [object]$DownstreamResult
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'The self-managed lifecycle helper only supports Windows.'
}

if (-not ('CandidateAgentProcessLifecycle.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CandidateAgentProcessLifecycle
{
    public sealed class NativeProcess
    {
        public IntPtr ProcessHandle { get; set; }
        public IntPtr ThreadHandle { get; set; }
        public uint ProcessId { get; set; }
    }

    public static class Native
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint Synchronize = 0x00100000;
        private const uint JobObjectQuery = 0x0004;
        private const uint JobObjectTerminate = 0x0008;
        private const int JobObjectBasicAccountingInformation = 1;
        private const uint WaitObject0 = 0;
        private static readonly IntPtr ProcThreadAttributeHandleList = new IntPtr(0x00020002);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int cb;
            public IntPtr lpReserved;
            public IntPtr lpDesktop;
            public IntPtr lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobAccounting
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenJobObjectW(uint desiredAccess, bool inheritHandle, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out JobAccounting information, uint length, IntPtr returnedLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, ref StartupInfoEx startupInfo, out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, uint flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string fileName, uint desiredAccess, uint shareMode, ref SecurityAttributes securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder imagePath, ref uint size);

        public static IntPtr CreateNamedJob(string name)
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, name);
            if (job == IntPtr.Zero) ThrowLastError("CreateJobObjectW");
            if (Marshal.GetLastWin32Error() == 183) throw new InvalidOperationException("A fresh Job name already exists.");
            return job;
        }

        public static IntPtr OpenNamedJob(string name)
        {
            IntPtr job = OpenJobObjectW(JobObjectQuery | Synchronize, false, name);
            if (job == IntPtr.Zero) ThrowLastError("OpenJobObjectW");
            return job;
        }

        public static bool NamedJobExists(string name)
        {
            IntPtr job = OpenJobObjectW(JobObjectQuery, false, name);
            if (job == IntPtr.Zero) return false;
            CloseHandle(job);
            return true;
        }

        public static void SetInheritable(IntPtr handle, bool enabled)
        {
            if (!SetHandleInformation(handle, HandleFlagInherit, enabled ? HandleFlagInherit : 0)) ThrowLastError("SetHandleInformation");
        }

        public static NativeProcess StartHolder(string executable, string[] arguments, string workingDirectory, IntPtr jobHandle)
        {
            return Start(executable, arguments, workingDirectory, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, new IntPtr[] { jobHandle }, CreateNoWindow);
        }

        public static NativeProcess StartSuspended(string executable, string[] arguments, string workingDirectory, string stdoutPath, string stderrPath)
        {
            IntPtr input = IntPtr.Zero;
            IntPtr output = IntPtr.Zero;
            IntPtr error = IntPtr.Zero;
            try
            {
                SecurityAttributes inheritable = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), InheritHandle = true };
                input = CreateFileW("NUL", 0x80000000, 3, ref inheritable, 3, 0, IntPtr.Zero);
                output = CreateFileW(stdoutPath, 0x40000000, 3, ref inheritable, 2, 0, IntPtr.Zero);
                error = CreateFileW(stderrPath, 0x40000000, 3, ref inheritable, 2, 0, IntPtr.Zero);
                if (input == new IntPtr(-1) || output == new IntPtr(-1) || error == new IntPtr(-1)) ThrowLastError("CreateFileW(stdio)");
                return Start(executable, arguments, workingDirectory, input, output, error, new IntPtr[] { input, output, error }, CreateSuspended | CreateNoWindow);
            }
            finally
            {
                CloseIfValid(input);
                CloseIfValid(output);
                CloseIfValid(error);
            }
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process)) ThrowLastError("AssignProcessToJobObject");
        }

        public static void TerminateCallbackJob(IntPtr job)
        {
            if (!TerminateJobObject(job, 124)) ThrowLastError("TerminateJobObject(callback worker)");
        }

        public static void TerminateUnassignedCallbackWorker(IntPtr process)
        {
            if (!TerminateProcess(process, 124)) ThrowLastError("TerminateProcess(unassigned callback worker)");
        }

        public static void Resume(IntPtr thread)
        {
            if (ResumeThread(thread) == UInt32.MaxValue) ThrowLastError("ResumeThread");
        }

        public static IntPtr OpenRoot(uint processId)
        {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation | Synchronize, false, processId);
            if (process == IntPtr.Zero) ThrowLastError("OpenProcess");
            return process;
        }

        public static long CreationTimeFileTime(IntPtr process)
        {
            FileTime creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) ThrowLastError("GetProcessTimes");
            return ((long)creation.High << 32) | creation.Low;
        }

        public static string ImagePath(IntPtr process)
        {
            uint size = 32768;
            StringBuilder value = new StringBuilder((int)size);
            if (!QueryFullProcessImageNameW(process, 0, value, ref size)) ThrowLastError("QueryFullProcessImageNameW");
            return value.ToString();
        }

        public static bool IsMember(IntPtr process, IntPtr job)
        {
            bool member;
            if (!IsProcessInJob(process, job, out member)) ThrowLastError("IsProcessInJob");
            return member;
        }

        public static uint ActiveProcessCount(IntPtr job)
        {
            JobAccounting accounting;
            if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, out accounting, (uint)Marshal.SizeOf<JobAccounting>(), IntPtr.Zero)) ThrowLastError("QueryInformationJobObject");
            return accounting.ActiveProcesses;
        }

        public static bool WaitForExit(IntPtr process, uint milliseconds)
        {
            return WaitForSingleObject(process, milliseconds) == WaitObject0;
        }

        public static void Close(IntPtr handle)
        {
            CloseIfValid(handle);
        }


        private static NativeProcess Start(string executable, string[] arguments, string workingDirectory, IntPtr input, IntPtr output, IntPtr error, IntPtr[] inheritedHandles, uint flags)
        {
            StartupInfoEx startup = new StartupInfoEx { StartupInfo = new StartupInfo { cb = Marshal.SizeOf<StartupInfoEx>() } };
            if (input != IntPtr.Zero)
            {
                startup.StartupInfo.dwFlags = StartfUseStdHandles;
                startup.StartupInfo.hStdInput = input;
                startup.StartupInfo.hStdOutput = output;
                startup.StartupInfo.hStdError = error;
            }

            IntPtr attributeListSize = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            bool initialized = false;
            try
            {
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize)) ThrowLastError("InitializeProcThreadAttributeList");
                initialized = true;
                startup.AttributeList = attributeList;
                int handleBytes = IntPtr.Size * inheritedHandles.Length;
                handleList = Marshal.AllocHGlobal(handleBytes);
                for (int index = 0; index < inheritedHandles.Length; index++) Marshal.WriteIntPtr(handleList, index * IntPtr.Size, inheritedHandles[index]);
                if (!UpdateProcThreadAttribute(attributeList, 0, ProcThreadAttributeHandleList, handleList, new IntPtr(handleBytes), IntPtr.Zero, IntPtr.Zero)) ThrowLastError("UpdateProcThreadAttribute(handle list)");

                ProcessInformation process;
                if (!CreateProcessW(executable, new StringBuilder(BuildCommandLine(executable, arguments)), IntPtr.Zero, IntPtr.Zero, true, flags | ExtendedStartupInfoPresent, IntPtr.Zero, workingDirectory, ref startup, out process)) ThrowLastError("CreateProcessW");
                return new NativeProcess { ProcessHandle = process.hProcess, ThreadHandle = process.hThread, ProcessId = process.dwProcessId };
            }
            finally
            {
                if (initialized) DeleteProcThreadAttributeList(attributeList);
                if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
            }
        }

        private static string BuildCommandLine(string executable, string[] arguments)
        {
            StringBuilder command = new StringBuilder(Quote(executable));
            foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
            return command.ToString();
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
            StringBuilder quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') { quoted.Append('\\', (slashes * 2) + 1).Append('"'); slashes = 0; continue; }
                quoted.Append('\\', slashes).Append(character); slashes = 0;
            }
            quoted.Append('\\', slashes * 2).Append('"');
            return quoted.ToString();
        }

        private static void CloseIfValid(IntPtr handle)
        {
            if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle);
        }

        private static void ThrowLastError(string operation)
        {
            int error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, operation + " failed with Win32 error " + error);
        }
    }
}
'@
}

function New-RunId {
    $bytes = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Write-Record {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$DestinationPath)

    $temporaryPath = "$DestinationPath.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporaryPath, ($Record | ConvertTo-Json -Depth 12 -Compress))
    try {
        [IO.File]::Move($temporaryPath, $DestinationPath, $true)
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Invoke-BoundedCallback {
    param([Parameter(Mandatory)][scriptblock]$Callback, [Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][int]$DeadlineMilliseconds, [Parameter(Mandatory)][string]$Purpose)

    $token = [Guid]::NewGuid().ToString('N')
    $directory = Split-Path -Parent $RecordPath
    $contextPath = Join-Path $directory "$Purpose-$token.context.xml"
    $resultPath = Join-Path $directory "$Purpose-$token.result.xml"
    $scriptPath = Join-Path $directory "$Purpose-$token.ps1"
    $stdoutPath = Join-Path $directory "$Purpose-$token.stdout.log"
    $stderrPath = Join-Path $directory "$Purpose-$token.stderr.log"
    $worker = $null
    $callbackJob = [IntPtr]::Zero
    $workerStartedSuspended = $false
    $workerAssignedToCallbackJob = $false
    $callbackCompleted = $false
    $watch = $null
    try {
        $Context | Export-Clixml -LiteralPath $contextPath
        $callbackText = $Callback.ToString()
        [IO.File]::WriteAllText($scriptPath, "param([string]`$ContextPath, [string]`$ResultPath)`n`$context = Import-Clixml -LiteralPath `$ContextPath`n`$result = & { $callbackText } `$context`n`$result | Export-Clixml -LiteralPath `$ResultPath")
        $callbackJob = [CandidateAgentProcessLifecycle.Native]::CreateNamedJob("Local\AgentProcessLifecycle.Callback.$token.Job")
        $worker = [CandidateAgentProcessLifecycle.Native]::StartSuspended("$PSHOME\pwsh.exe", [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ContextPath', $contextPath, '-ResultPath', $resultPath), $directory, $stdoutPath, $stderrPath)
        $workerStartedSuspended = $true
        [CandidateAgentProcessLifecycle.Native]::Assign($callbackJob, $worker.ProcessHandle)
        $workerAssignedToCallbackJob = $true
        [CandidateAgentProcessLifecycle.Native]::Resume($worker.ThreadHandle)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $remaining = [Math]::Max(0, $DeadlineMilliseconds - [int]$watch.ElapsedMilliseconds)
        if ($remaining -le 0 -or -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($worker.ProcessHandle, [uint32]$remaining)) {
            # callback Job 與 workload Job 沒有任何共享 member；timeout 只能回收這次 callback tree。
            [CandidateAgentProcessLifecycle.Native]::TerminateCallbackJob($callbackJob)
            $cleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0 -and $cleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
            if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0) { throw "The $Purpose callback Job did not empty after its deadline." }
            throw "The $Purpose callback exceeded its deadline."
        }
        while ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0 -and $watch.ElapsedMilliseconds -lt $DeadlineMilliseconds) { [Threading.Thread]::Sleep(20) }
        if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0) {
            [CandidateAgentProcessLifecycle.Native]::TerminateCallbackJob($callbackJob)
            $cleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0 -and $cleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
            if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0) { throw "The $Purpose callback Job did not empty after descendant timeout." }
            throw "The $Purpose callback descendants exceeded its deadline."
        }
        if (-not [IO.File]::Exists($resultPath)) { throw "The $Purpose callback did not publish a result." }
        $result = Import-Clixml -LiteralPath $resultPath
        $callbackCompleted = $true
        return $result
    }
    finally {
        if ($workerStartedSuspended -and -not $callbackCompleted) {
            if ($workerAssignedToCallbackJob) {
                if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0) {
                    [CandidateAgentProcessLifecycle.Native]::TerminateCallbackJob($callbackJob)
                    $callbackCleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
                    while ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0 -and $callbackCleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
                    if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($callbackJob) -ne 0) { throw "The $Purpose callback Job did not empty during fail-closed cleanup." }
                }
            }
            else {
                [CandidateAgentProcessLifecycle.Native]::TerminateUnassignedCallbackWorker($worker.ProcessHandle)
                if (-not [CandidateAgentProcessLifecycle.Native]::WaitForExit($worker.ProcessHandle, 1000)) { throw "The $Purpose unassigned callback worker did not exit during setup cleanup." }
            }
        }
        if ($worker) {
            [CandidateAgentProcessLifecycle.Native]::Close($worker.ThreadHandle)
            [CandidateAgentProcessLifecycle.Native]::Close($worker.ProcessHandle)
        }
        if ($callbackJob -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($callbackJob) }
        foreach ($path in @($contextPath, $resultPath, $scriptPath, $stdoutPath, $stderrPath)) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
    }
}

function Wait-Readiness {
    param([Parameter(Mandatory)][scriptblock]$Check, [Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][int]$DeadlineMilliseconds)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $remaining = Get-RemainingMilliseconds -Watch $watch -DeadlineMilliseconds $DeadlineMilliseconds
        if ($remaining -le 0) { throw "The caller-defined readiness check did not succeed within $DeadlineMilliseconds ms." }
        if (Invoke-BoundedCallback -Callback $Check -Context $Context -DeadlineMilliseconds $remaining -Purpose 'readiness') {
            return $watch.ElapsedMilliseconds
        }
        [Threading.Thread]::Sleep(20)
    }
}

function Get-RemainingMilliseconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch]$Watch, [Parameter(Mandatory)][int]$DeadlineMilliseconds)

    return [Math]::Max(0, $DeadlineMilliseconds - [int]$Watch.ElapsedMilliseconds)
}

function Invoke-Launch {
    foreach ($name in 'Executable', 'WorkingDirectory', 'StdoutPath', 'StderrPath', 'ReadinessIdentity') {
        if (-not (Get-Variable -Name $name -ValueOnly)) {
            throw "$name is required for Launch."
        }
    }
    if ($null -eq $ReadinessCheck) {
        throw 'ReadinessCheck is required for Launch.'
    }
    if ([IO.File]::Exists($RecordPath)) {
        throw 'RecordPath must be fresh for Launch.'
    }

    $recordDirectory = Split-Path -Parent $RecordPath
    [IO.Directory]::CreateDirectory($recordDirectory) | Out-Null
    [IO.File]::WriteAllText($RecordPath, '{}')

    $runId = New-RunId
    $namePrefix = "Local\AgentProcessLifecycle.$runId"
    $jobHandle = [IntPtr]::Zero
    $root = $null
    $holder = $null
    $finalizeEvent = $null
    $holderReadyEvent = $null
    $holderExitedEvent = $null

    try {
        $jobHandle = [CandidateAgentProcessLifecycle.Native]::CreateNamedJob("$namePrefix.Job")
        $created = $false
        $finalizeEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "$namePrefix.Finalize", [ref]$created)
        if (-not $created) { throw 'Fresh Finalize event name already exists.' }
        $created = $false
        $holderReadyEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "$namePrefix.HolderReady", [ref]$created)
        if (-not $created) { throw 'Fresh holder-ready event name already exists.' }
        $created = $false
        $holderExitedEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "$namePrefix.HolderExited", [ref]$created)
        if (-not $created) { throw 'Fresh holder-exited event name already exists.' }

        # 只讓 holder 暫時繼承 Job handle；root 在 resume 前已被 assign，但絕不能取得可終止整個 Job 的 handle。
        [CandidateAgentProcessLifecycle.Native]::SetInheritable($jobHandle, $true)
        try {
            $holder = [CandidateAgentProcessLifecycle.Native]::StartHolder(
                "$PSHOME\pwsh.exe",
                [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'JobHandleHolder.ps1'), '-JobHandle', [string]$jobHandle.ToInt64(), '-FinalizeEventName', "$namePrefix.Finalize", '-ReadyEventName', "$namePrefix.HolderReady", '-ExitedEventName', "$namePrefix.HolderExited"),
                $WorkingDirectory,
                $jobHandle
            )
        }
        finally {
            [CandidateAgentProcessLifecycle.Native]::SetInheritable($jobHandle, $false)
        }
        if (-not $holderReadyEvent.WaitOne(5000)) {
            throw 'The Job handle holder did not become ready.'
        }

        $root = [CandidateAgentProcessLifecycle.Native]::StartSuspended($Executable, $ArgumentList, $WorkingDirectory, $StdoutPath, $StderrPath)
        [CandidateAgentProcessLifecycle.Native]::Assign($jobHandle, $root.ProcessHandle)
        $record = [ordered]@{
            schema_version = 1
            state = 'bound'
            run_id = $runId
            job_name = "$namePrefix.Job"
            root = [ordered]@{
                process_id = $root.ProcessId
                creation_time_filetime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($root.ProcessHandle)
                image_path = [CandidateAgentProcessLifecycle.Native]::ImagePath($root.ProcessHandle)
            }
            holder = [ordered]@{
                process_id = $holder.ProcessId
                creation_time_filetime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($holder.ProcessHandle)
                image_path = [CandidateAgentProcessLifecycle.Native]::ImagePath($holder.ProcessHandle)
            }
            stdio = [ordered]@{ stdout_path = [IO.Path]::GetFullPath($StdoutPath); stderr_path = [IO.Path]::GetFullPath($StderrPath) }
            readiness = [ordered]@{ identity = $ReadinessIdentity; deadline_milliseconds = $ReadinessDeadlineMilliseconds }
            requested_disposition = $RequestedDisposition
            events = [ordered]@{ finalize = "$namePrefix.Finalize"; holder_exited = "$namePrefix.HolderExited" }
        }
        Write-Record -Record $record -DestinationPath $RecordPath
        [CandidateAgentProcessLifecycle.Native]::Resume($root.ThreadHandle)

        $readinessElapsed = Wait-Readiness -Check $ReadinessCheck -Context $ReadinessContext -DeadlineMilliseconds $ReadinessDeadlineMilliseconds
        $record.state = 'ready'
        $record.readiness.result = 'succeeded'
        $record.readiness.elapsed_milliseconds = $readinessElapsed
        Write-Record -Record $record -DestinationPath $RecordPath

        return [ordered]@{
            action = 'Launch'
            tier = 'windows-self-managed'
            requested_disposition = $RequestedDisposition
            binding = [ordered]@{ run_id = $runId; job_name = $record.job_name; record_path = $RecordPath; root_process_id = $root.ProcessId }
            stdio = [ordered]@{ isolated = $true; stdout_path = $record.stdio.stdout_path; stderr_path = $record.stdio.stderr_path }
            readiness = [ordered]@{ identity = $ReadinessIdentity; succeeded = $true; deadline_milliseconds = $ReadinessDeadlineMilliseconds; elapsed_milliseconds = $readinessElapsed }
            lifecycle_result = [ordered]@{ status = 'success'; operation = 'launch' }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = $RequestedDisposition; status = 'pending' }
            evidence = [ordered]@{ record_path = $RecordPath; named_job_retained = $true; job_holder_process_id = $holder.ProcessId }
        }
    }
    finally {
        if ($root) {
            [CandidateAgentProcessLifecycle.Native]::Close($root.ThreadHandle)
            [CandidateAgentProcessLifecycle.Native]::Close($root.ProcessHandle)
        }
        if ($holder) {
            [CandidateAgentProcessLifecycle.Native]::Close($holder.ThreadHandle)
            [CandidateAgentProcessLifecycle.Native]::Close($holder.ProcessHandle)
        }
        if ($jobHandle -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($jobHandle) }
        if ($finalizeEvent) { $finalizeEvent.Dispose() }
        if ($holderReadyEvent) { $holderReadyEvent.Dispose() }
        if ($holderExitedEvent) { $holderExitedEvent.Dispose() }
    }
}

function Invoke-Finalize {
    if ($Disposition -ne 'Stop') {
        throw 'Ticket 11 Finalize only supports Stop.'
    }
    if ($null -eq $GracefulAction) {
        throw 'GracefulAction is required for ticket 11 Finalize Stop.'
    }
    $record = [IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json -AsHashtable
    if ($record.schema_version -ne 1 -or $record.state -ne 'ready' -or $record.requested_disposition -ne 'Stop') {
        throw 'The run binding is not a ready Stop record.'
    }

    $jobHandle = [IntPtr]::Zero
    $rootHandle = [IntPtr]::Zero
    $holderHandle = [IntPtr]::Zero
    try {
        $jobHandle = [CandidateAgentProcessLifecycle.Native]::OpenNamedJob([string]$record.job_name)
        $rootHandle = [CandidateAgentProcessLifecycle.Native]::OpenRoot([uint32]$record.root.process_id)
        if ([CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($rootHandle) -ne [int64]$record.root.creation_time_filetime -or
            -not [CandidateAgentProcessLifecycle.Native]::IsMember($rootHandle, $jobHandle) -or
            -not [string]::Equals([CandidateAgentProcessLifecycle.Native]::ImagePath($rootHandle), [string]$record.root.image_path, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The reopened binding does not prove the recorded root instance.'
        }

        $binding = [ordered]@{ run_id = $record.run_id; job_name = $record.job_name; root_process_id = $record.root.process_id; graceful_context = $GracefulContext }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-BoundedCallback -Callback $GracefulAction -Context $binding -DeadlineMilliseconds $GracefulDeadlineMilliseconds -Purpose 'graceful' | Out-Null

        $remaining = Get-RemainingMilliseconds -Watch $watch -DeadlineMilliseconds $GracefulDeadlineMilliseconds
        if ($remaining -le 0 -or -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($rootHandle, [uint32]$remaining)) {
            throw 'The root did not exit within the caller-provided graceful deadline.'
        }
        if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($jobHandle) -ne 0) {
            throw 'The named Job still contains workload processes after graceful Stop.'
        }

        $holderHandle = [CandidateAgentProcessLifecycle.Native]::OpenRoot([uint32]$record.holder.process_id)
        if ([CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($holderHandle) -ne [int64]$record.holder.creation_time_filetime -or
            -not [string]::Equals([CandidateAgentProcessLifecycle.Native]::ImagePath($holderHandle), [string]$record.holder.image_path, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The retained holder handle does not prove the recorded holder instance.'
        }
        $finalizeEvent = [Threading.EventWaitHandle]::OpenExisting([string]$record.events.finalize)
        $holderExitedEvent = [Threading.EventWaitHandle]::OpenExisting([string]$record.events.holder_exited)
        try {
            $finalizeEvent.Set() | Out-Null
            $remaining = Get-RemainingMilliseconds -Watch $watch -DeadlineMilliseconds $GracefulDeadlineMilliseconds
            if ($remaining -le 0 -or -not $holderExitedEvent.WaitOne($remaining)) {
                throw 'The Job handle holder did not exit within the graceful deadline.'
            }
        }
        finally {
            $finalizeEvent.Dispose()
            $holderExitedEvent.Dispose()
        }

        $remaining = Get-RemainingMilliseconds -Watch $watch -DeadlineMilliseconds $GracefulDeadlineMilliseconds
        if ($remaining -le 0 -or -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($holderHandle, [uint32]$remaining)) {
            throw 'The Job handle holder did not terminate within the graceful deadline.'
        }
        [CandidateAgentProcessLifecycle.Native]::Close($holderHandle)
        $holderHandle = [IntPtr]::Zero
        [CandidateAgentProcessLifecycle.Native]::Close($rootHandle)
        $rootHandle = [IntPtr]::Zero
        [CandidateAgentProcessLifecycle.Native]::Close($jobHandle)
        $jobHandle = [IntPtr]::Zero
        $namedJobAbsent = -not [CandidateAgentProcessLifecycle.Native]::NamedJobExists([string]$record.job_name)
        if (-not $namedJobAbsent) {
            throw 'The named Job remained after the holder released its handle.'
        }
        [IO.File]::Delete($RecordPath)

        return [ordered]@{
            action = 'Finalize'
            tier = 'windows-self-managed'
            requested_disposition = 'Stop'
            binding = [ordered]@{ run_id = $record.run_id; job_name = $record.job_name; root_process_id = $record.root.process_id }
            stdio = [ordered]@{ isolated = $true; stdout_path = $record.stdio.stdout_path; stderr_path = $record.stdio.stderr_path }
            readiness = [ordered]@{ identity = $record.readiness.identity; succeeded = ($record.readiness.result -eq 'succeeded') }
            lifecycle_result = [ordered]@{ status = 'success'; operation = 'graceful-stop' }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = 'Stop'; status = 'completed' }
            evidence = [ordered]@{ graceful_action_invocations = 1; forced_termination_used = $false; root_process_absent = $true; named_job_absent = $true; job_holder_absent = $true }
        }
    }
    finally {
        if ($holderHandle -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($holderHandle) }
        if ($rootHandle -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($rootHandle) }
        if ($jobHandle -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($jobHandle) }
    }
}

if ($Action -eq 'Launch') {
    Invoke-Launch
}
else {
    Invoke-Finalize
}
