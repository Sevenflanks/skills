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
            if (Marshal.GetLastWin32Error() == 183)
            {
                CloseHandle(job);
                throw new InvalidOperationException("A fresh Job name already exists.");
            }
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

        public static void TerminateCurrentProcess(IntPtr process)
        {
            if (!TerminateProcess(process, 124)) ThrowLastError("TerminateProcess(current-run process)");
        }

        public static void TerminateLaunchJob(IntPtr job)
        {
            if (!TerminateJobObject(job, 124)) ThrowLastError("TerminateJobObject(current-run launch)");
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

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User
}

function Get-TrustedRecordParentSids {
    return @(
        (Get-CurrentUserSid).Value,
        'S-1-5-18', # LocalSystem owns Windows-managed root paths.
        'S-1-5-32-544', # BUILTIN\Administrators is trusted for machine-wide path administration.
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # Windows TrustedInstaller owns protected system paths.
    )
}

function Test-RecordParentMutationRight {
    param([Parameter(Mandatory)][Security.AccessControl.FileSystemRights]$Rights)

    $mutationRights = [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    return (($Rights -band $mutationRights) -ne 0)
}

function Assert-RecordParentDirectorySecurity {
    param([Parameter(Mandatory)][IO.DirectoryInfo]$Directory)

    $security = [IO.FileSystemAclExtensions]::GetAccessControl($Directory)
    $trustedSids = Get-TrustedRecordParentSids
    # TEST-INJECTION: parent-owner-check
    if ($trustedSids -notcontains $security.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
        throw "RecordPath parent has an untrusted owner: $($Directory.FullName)"
    }
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0 -or
            $trustedSids -contains $rule.IdentityReference.Value) {
            continue
        }
        if (Test-RecordParentMutationRight -Rights $rule.FileSystemRights) {
            throw "RecordPath parent allows an untrusted principal to mutate entries: $($Directory.FullName)"
        }
    }
}

function Assert-SafeRecordParent {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directoryPath = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directoryPath)) { throw 'RecordPath must have a parent directory.' }

    $directory = [IO.DirectoryInfo]::new($directoryPath)
    while ($null -ne $directory) {
        if (-not $directory.Exists) { throw "RecordPath parent does not exist: $($directory.FullName)" }
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "RecordPath parent is a reparse point: $($directory.FullName)" }
        Assert-RecordParentDirectorySecurity -Directory $directory
        $directory = $directory.Parent
    }

    return $fullPath
}

function Ensure-SafeRecordParent {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directoryPath = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directoryPath)) { throw 'RecordPath must have a parent directory.' }

    $missingDirectories = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $existingAncestor = [IO.DirectoryInfo]::new($directoryPath)
    while (-not $existingAncestor.Exists) {
        $missingDirectories.Push($existingAncestor)
        if ($null -eq $existingAncestor.Parent) { throw "RecordPath parent has no existing safe ancestor: $directoryPath" }
        $existingAncestor = $existingAncestor.Parent
    }
    Assert-SafeRecordParent -Path (Join-Path $existingAncestor.FullName 'record-parent-check') | Out-Null

    while ($missingDirectories.Count -gt 0) {
        $missingDirectory = $missingDirectories.Pop()
        if (-not $missingDirectory.Exists) {
            [IO.FileSystemAclExtensions]::CreateDirectory((New-CurrentUserDirectorySecurity), $missingDirectory.FullName) | Out-Null
        }
        $missingDirectory = [IO.DirectoryInfo]::new($missingDirectory.FullName)
        if (($missingDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "RecordPath parent is a reparse point: $($missingDirectory.FullName)" }
        Assert-RecordParentDirectorySecurity -Directory $missingDirectory
    }
    return Assert-SafeRecordParent -Path $fullPath
}

function Assert-CurrentUserProtectedRecord {
    param([Parameter(Mandatory)][string]$Path)

    $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))
    $currentSid = Get-CurrentUserSid
    if (-not $security.AreAccessRulesProtected -or $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentSid.Value) {
        throw 'The record ACL is not protected for the current user.'
    }

    $allowsCurrentUser = $false
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.IdentityReference.Value -ne $currentSid.Value) {
            throw 'The record ACL allows an unapproved principal.'
        }
        if ($rule.IdentityReference.Value -eq $currentSid.Value -and
            (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)) {
            $allowsCurrentUser = $true
        }
    }
    if (-not $allowsCurrentUser) { throw 'The current user does not have full control of the record.' }
}

function Assert-FreshRecordPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-SafeRecordParent -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RecordPath target is a reparse point.' }
        throw 'RecordPath must be fresh for Launch.'
    }
    return $fullPath
}

function Assert-ExistingRecordPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-SafeRecordParent -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) { throw 'The expected record file is absent.' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RecordPath target is a reparse point.' }
    Assert-CurrentUserProtectedRecord -Path $fullPath
    return $fullPath
}

function New-CurrentUserFileSecurity {
    $currentSid = Get-CurrentUserSid
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($currentSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    return $security
}

function New-CurrentUserDirectorySecurity {
    $currentSid = Get-CurrentUserSid
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($currentSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    return $security
}

function Write-ProtectedJsonFile {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Path, [ref]$CreatedByCurrentInvocation)

    Assert-SafeRecordParent -Path $Path | Out-Null
    $stream = $null
    if ($PSBoundParameters.ContainsKey('CreatedByCurrentInvocation')) { $CreatedByCurrentInvocation.Value = $false }
    try {
        # TEST-INJECTION: preparing-before-create
        $stream = [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($Path),
            [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough,
            (New-CurrentUserFileSecurity)
        )
        if ($PSBoundParameters.ContainsKey('CreatedByCurrentInvocation')) { $CreatedByCurrentInvocation.Value = $true }
        # TEST-INJECTION: preparing-record-after-create
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 4096, $true)
        try {
            $writer.Write(($Record | ConvertTo-Json -Depth 12 -Compress))
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    catch {
        throw
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function New-PreparingRecord {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Ensure-SafeRecordParent -Path $Path
    $fullPath = Assert-FreshRecordPath -Path $fullPath
    $recordCreated = $false
    $createdByWrite = $false
    try {
        Write-ProtectedJsonFile -Path $fullPath -CreatedByCurrentInvocation ([ref]$createdByWrite) -Record ([ordered]@{
            schema_version = 1
            state = 'preparing'
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('O')
        })
        $recordCreated = $true
        # TEST-INJECTION: preparing-record-validation
        Assert-CurrentUserProtectedRecord -Path $fullPath
        return $fullPath
    }
    catch {
        if ($recordCreated -or $createdByWrite) {
            try {
                Assert-ExistingRecordPath -Path $fullPath | Out-Null
                # TEST-INJECTION: preparing-record-delete
                [IO.File]::Delete($fullPath)
            }
            catch {
                $failure = [InvalidOperationException]::new("Preparing record creation failed and its exact current-run record could not be removed: $($_.Exception.Message)")
                $failure.Data['AgentProcessLifecycle.CreatedByCurrentInvocation'] = $true
                $failure.Data['AgentProcessLifecycle.CleanupIncomplete'] = $true
                throw $failure
            }
        }
        throw
    }
}

function Write-Record {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$DestinationPath)

    $fullPath = Assert-ExistingRecordPath -Path $DestinationPath
    $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($fullPath)) ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$temporaryPath.backup"
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        Write-ProtectedJsonFile -Path $temporaryPath -Record $Record
        # TEST-INJECTION: write-record-after-temp-create
        $fullPath = Assert-ExistingRecordPath -Path $fullPath
        # TEST-INJECTION: write-record-before-replace
        [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        Assert-CurrentUserProtectedRecord -Path $fullPath
    }
    finally {
        foreach ($artifact in @($temporaryPath, $backupPath)) {
            try {
                if ([IO.File]::Exists($artifact)) {
                    if ($artifact -eq $temporaryPath) { # TEST-INJECTION: write-record-temp-delete
                        [IO.File]::Delete($artifact)
                    }
                    else { # TEST-INJECTION: write-record-backup-delete
                        [IO.File]::Delete($artifact)
                    }
                }
                if ([IO.File]::Exists($artifact)) { $cleanupErrors.Add("Artifact remained: $artifact") }
            }
            catch {
                $cleanupErrors.Add("Artifact cleanup failed for ${artifact}: $($_.Exception.Message)")
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            $failure = [InvalidOperationException]::new($cleanupErrors -join ' ')
            $failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @($temporaryPath, $backupPath)
            $failure.Data['AgentProcessLifecycle.ArtifactCleanupIncomplete'] = $true
            throw $failure
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

function Invoke-LaunchFailureCleanup {
    param(
        [object]$Root,
        [bool]$RootAssigned,
        [object]$Holder,
        [IntPtr]$JobHandle,
        [object]$FinalizeEvent,
        [string]$JobName,
        [string]$CleanupRecordPath,
        [bool]$RecordCreated,
        [string[]]$ArtifactPaths = @()
    )

    $errors = [Collections.Generic.List[string]]::new()
    $rootAbsent = $null
    $holderAbsent = $null
    $namedJobAbsent = $null
    $recordAbsent = $null
    $artifactStates = [Collections.Generic.List[object]]::new()

    try {
        if ($Root) {
            if ($RootAssigned -and $JobHandle -ne [IntPtr]::Zero) {
                [CandidateAgentProcessLifecycle.Native]::TerminateLaunchJob($JobHandle)
                $wait = [Diagnostics.Stopwatch]::StartNew()
                while ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($JobHandle) -ne 0 -and $wait.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
                $rootAbsent = ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($JobHandle) -eq 0)
                if (-not $rootAbsent) { $errors.Add('The current-run Job did not empty during Launch cleanup.') }
            }
            else {
                [CandidateAgentProcessLifecycle.Native]::TerminateCurrentProcess($Root.ProcessHandle)
                $rootAbsent = [CandidateAgentProcessLifecycle.Native]::WaitForExit($Root.ProcessHandle, 1000)
                if (-not $rootAbsent) { $errors.Add('The unassigned suspended root did not exit during Launch cleanup.') }
            }
        }
        else {
            $rootAbsent = $true
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    foreach ($artifactPath in $ArtifactPaths) {
        try {
            $before = [IO.File]::Exists($artifactPath)
            if ($before) {
                # TEST-INJECTION: launch-cleanup-artifact-delete
                [IO.File]::Delete($artifactPath)
            }
            $after = [IO.File]::Exists($artifactPath)
            $artifactStates.Add([ordered]@{ path = $artifactPath; existed_before_cleanup = $before; absent = -not $after })
            if ($after) { $errors.Add("Publication artifact remained: $artifactPath") }
        }
        catch {
            $artifactStates.Add([ordered]@{ path = $artifactPath; existed_before_cleanup = [IO.File]::Exists($artifactPath); absent = $false })
            $errors.Add("Publication artifact cleanup failed for ${artifactPath}: $($_.Exception.Message)")
        }
    }

    try {
        if ($Holder) {
            if ($FinalizeEvent) { $FinalizeEvent.Set() | Out-Null }
            $holderAbsent = [CandidateAgentProcessLifecycle.Native]::WaitForExit($Holder.ProcessHandle, 1000)
            if (-not $holderAbsent) { $errors.Add('The current-run Job holder did not exit during Launch cleanup.') }
        }
        else {
            $holderAbsent = $true
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    try {
        if ($JobHandle -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($JobHandle) }
        if ($JobName) {
            $namedJobAbsent = -not [CandidateAgentProcessLifecycle.Native]::NamedJobExists($JobName)
            if (-not $namedJobAbsent) { $errors.Add('The current-run named Job remained after Launch cleanup.') }
        }
        else {
            $namedJobAbsent = $true
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    try {
        if ($RecordCreated) {
            if ([IO.File]::Exists($CleanupRecordPath)) {
                Assert-ExistingRecordPath -Path $CleanupRecordPath | Out-Null
                # TEST-INJECTION: launch-cleanup-record-delete
                [IO.File]::Delete($CleanupRecordPath)
            }
            $recordAbsent = -not [IO.File]::Exists($CleanupRecordPath)
            if (-not $recordAbsent) { $errors.Add('The preparing record remained after Launch cleanup.') }
        }
        else {
            $recordAbsent = $true
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    # TEST-INJECTION: cleanup-verification
    $complete = $errors.Count -eq 0
    return [ordered]@{
        attempted = ($null -ne $Root -or $null -ne $Holder -or $JobHandle -ne [IntPtr]::Zero -or $RecordCreated)
        status = if ($complete) { 'completed' } else { 'unresolved' }
        root_absent = $rootAbsent
        holder_absent = $holderAbsent
        named_job_absent = $namedJobAbsent
        record_absent = $recordAbsent
        publication_artifacts = @($artifactStates)
        errors = @($errors)
    }
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
    $failureKind = 'record-preparation'
    $recordCreated = $false
    $recordPathForRun = $RecordPath
    $runId = $null
    $namePrefix = $null
    $jobName = $null
    $jobHandle = [IntPtr]::Zero
    $root = $null
    $rootAssigned = $false
    $stdioIsolated = $false
    $readinessSucceeded = $false
    $holder = $null
    $finalizeEvent = $null
    $holderReadyEvent = $null
    $holderExitedEvent = $null
    $publicationArtifacts = @()
    $rootIdentity = $null
    $holderIdentity = $null

    try {
        $recordPathForRun = New-PreparingRecord -Path $RecordPath
        $recordCreated = $true
        $runId = New-RunId
        $namePrefix = "Local\AgentProcessLifecycle.$runId"
        $jobName = "$namePrefix.Job"
        $failureKind = 'job-creation'
        $jobHandle = [CandidateAgentProcessLifecycle.Native]::CreateNamedJob($jobName)
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
        $holderIdentity = [ordered]@{
            process_id = $holder.ProcessId
            creation_time_filetime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($holder.ProcessHandle)
            image_path = [CandidateAgentProcessLifecycle.Native]::ImagePath($holder.ProcessHandle)
        }

        $failureKind = 'stdio-isolation'
        # TEST-INJECTION: workload-job-handle-probe
        $root = [CandidateAgentProcessLifecycle.Native]::StartSuspended($Executable, $ArgumentList, $WorkingDirectory, $StdoutPath, $StderrPath)
        $rootIdentity = [ordered]@{
            process_id = $root.ProcessId
            creation_time_filetime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($root.ProcessHandle)
            image_path = [CandidateAgentProcessLifecycle.Native]::ImagePath($root.ProcessHandle)
        }
        $stdioIsolated = $true
        # TEST-INJECTION: stdio-isolation
        $failureKind = 'job-assignment'
        # TEST-INJECTION: job-assignment
        [CandidateAgentProcessLifecycle.Native]::Assign($jobHandle, $root.ProcessHandle)
        $rootAssigned = $true
        $record = [ordered]@{
            schema_version = 1
            state = 'bound'
            run_id = $runId
            job_name = "$namePrefix.Job"
            executable = [IO.Path]::GetFullPath($Executable)
            arguments = @($ArgumentList)
            working_directory = [IO.Path]::GetFullPath($WorkingDirectory)
            root = $rootIdentity
            holder = $holderIdentity
            stdio = [ordered]@{ stdout_path = [IO.Path]::GetFullPath($StdoutPath); stderr_path = [IO.Path]::GetFullPath($StderrPath) }
            readiness = [ordered]@{ identity = $ReadinessIdentity; deadline_milliseconds = $ReadinessDeadlineMilliseconds; result = $null; completed_at_utc = $null }
            requested_disposition = $RequestedDisposition
            later_owner = $null
            events = [ordered]@{ finalize = "$namePrefix.Finalize"; holder_exited = "$namePrefix.HolderExited" }
        }
        $failureKind = 'record-publication'
        # TEST-INJECTION: bound-record-publication
        Write-Record -Record $record -DestinationPath $recordPathForRun
        [CandidateAgentProcessLifecycle.Native]::Resume($root.ThreadHandle)

        $failureKind = 'readiness'
        $readinessElapsed = Wait-Readiness -Check $ReadinessCheck -Context $ReadinessContext -DeadlineMilliseconds $ReadinessDeadlineMilliseconds
        $readinessSucceeded = $true
        $record.state = 'ready'
        $record.readiness.result = 'succeeded'
        $record.readiness.elapsed_milliseconds = $readinessElapsed
        $record.readiness.completed_at_utc = [DateTimeOffset]::UtcNow.ToString('O')
        $failureKind = 'record-publication'
        # TEST-INJECTION: ready-record-publication
        Write-Record -Record $record -DestinationPath $recordPathForRun

        return [ordered]@{
            action = 'Launch'
            tier = 'windows-self-managed'
            requested_disposition = $RequestedDisposition
            binding = [ordered]@{ run_id = $runId; job_name = $record.job_name; record_path = $recordPathForRun; root_process_id = $root.ProcessId; root_identity = $rootIdentity; holder_identity = $holderIdentity }
            stdio = [ordered]@{ isolated = $true; stdout_path = $record.stdio.stdout_path; stderr_path = $record.stdio.stderr_path }
            readiness = [ordered]@{ identity = $ReadinessIdentity; succeeded = $true; deadline_milliseconds = $ReadinessDeadlineMilliseconds; elapsed_milliseconds = $readinessElapsed }
            lifecycle_result = [ordered]@{ status = 'success'; operation = 'launch' }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = $RequestedDisposition; status = 'pending' }
            evidence = [ordered]@{ record_path = $recordPathForRun; named_job_retained = $true; job_holder_process_id = $holder.ProcessId; root_identity = $rootIdentity; holder_identity = $holderIdentity }
        }
    }
    catch {
        $recordCreated = $recordCreated -or ($_.Exception.Data['AgentProcessLifecycle.CreatedByCurrentInvocation'] -eq $true)
        $failureException = $_.Exception
        while ($failureException -and -not $failureException.Data['AgentProcessLifecycle.ArtifactPaths']) { $failureException = $failureException.InnerException }
        if ($failureException -and $failureException.Data['AgentProcessLifecycle.ArtifactPaths']) { $publicationArtifacts = @($failureException.Data['AgentProcessLifecycle.ArtifactPaths']) }
        if ($publicationArtifacts.Count -eq 0 -and $failureKind -eq 'record-publication') {
            $publicationArtifacts = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($recordPathForRun)) -Force -File -Filter ".$(Split-Path -Leaf $recordPathForRun).*tmp*" | ForEach-Object FullName)
        }
        $cleanup = Invoke-LaunchFailureCleanup -Root $root -RootAssigned $rootAssigned -Holder $holder -JobHandle $jobHandle -FinalizeEvent $finalizeEvent -JobName $jobName -CleanupRecordPath $recordPathForRun -RecordCreated $recordCreated -ArtifactPaths $publicationArtifacts
        $jobHandle = [IntPtr]::Zero
        $status = if ($cleanup.status -eq 'completed') { 'failed' } else { 'unresolved' }
        return [ordered]@{
            action = 'Launch'
            tier = 'windows-self-managed'
            requested_disposition = $RequestedDisposition
            binding = [ordered]@{ run_id = $runId; job_name = $jobName; record_path = $recordPathForRun; root_process_id = if ($root) { $root.ProcessId } else { $null }; root_identity = $rootIdentity; holder_identity = $holderIdentity }
            stdio = [ordered]@{ isolated = $stdioIsolated; stdout_path = $StdoutPath; stderr_path = $StderrPath }
            readiness = [ordered]@{ identity = $ReadinessIdentity; succeeded = $readinessSucceeded; deadline_milliseconds = $ReadinessDeadlineMilliseconds }
            lifecycle_result = [ordered]@{ status = $status; operation = 'launch'; failure_kind = $failureKind; cleanup = $cleanup; unresolved_reason = if ($status -eq 'unresolved') { ($cleanup.errors -join ' ') } else { $null }; error = $_.Exception.Message }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = $RequestedDisposition; status = 'not-established' }
            later_owner = $null
            evidence = [ordered]@{ record_path = $recordPathForRun; cleanup = $cleanup; job_holder_process_id = if ($holder) { $holder.ProcessId } else { $null }; root_identity = $rootIdentity; holder_identity = $holderIdentity }
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
