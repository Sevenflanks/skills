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
    [ValidateSet('Stop', 'Preserve')]
    [string]$RequestedDisposition = 'Stop',
    [string]$RequestedLaterOwner,
    [ValidateSet('Stop', 'Preserve')]
    [string]$Disposition = 'Stop',
    [string]$LaterOwner,
    [scriptblock]$GracefulAction,
    [hashtable]$GracefulContext = @{},
    [ValidateRange(1, 60000)]
    [int]$GracefulDeadlineMilliseconds = 5000,
    [object]$DownstreamResult
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExplicitParameters = @{}
foreach ($parameterName in $PSBoundParameters.Keys) {
    $script:ExplicitParameters[$parameterName] = $true
}

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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string path, ref SecurityAttributes securityAttributes);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

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
            IntPtr job = OpenJobObjectW(JobObjectQuery | JobObjectTerminate | Synchronize, false, name);
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

        public static void CreateCurrentUserProtectedDirectory(string path, string currentUserSid)
        {
            IntPtr securityDescriptor = IntPtr.Zero;
            uint size;
            string descriptor = "O:" + currentUserSid + "D:P(A;;FA;;;" + currentUserSid + ")";
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor, 1, out securityDescriptor, out size))
            {
                ThrowLastError("ConvertStringSecurityDescriptorToSecurityDescriptorW");
            }
            try
            {
                SecurityAttributes attributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    SecurityDescriptor = securityDescriptor,
                    InheritHandle = false
                };
                if (!CreateDirectoryW(path, ref attributes)) ThrowLastError("CreateDirectoryW(callback directory)");
            }
            finally
            {
                if (securityDescriptor != IntPtr.Zero) LocalFree(securityDescriptor);
            }
        }

        public static NativeProcess StartSuspended(string executable, string[] arguments, string workingDirectory, IntPtr output, IntPtr error)
        {
            IntPtr input = IntPtr.Zero;
            bool outputInheritable = false;
            bool errorInheritable = false;
            try
            {
                SecurityAttributes inheritable = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), InheritHandle = true };
                input = CreateFileW("NUL", 0x80000000, 3, ref inheritable, 3, 0, IntPtr.Zero);
                if (input == new IntPtr(-1)) ThrowLastError("CreateFileW(NUL)");
                SetInheritable(output, true);
                outputInheritable = true;
                SetInheritable(error, true);
                errorInheritable = true;
                return Start(executable, arguments, workingDirectory, input, output, error, new IntPtr[] { input, output, error }, CreateSuspended | CreateNoWindow);
            }
            finally
            {
                if (errorInheritable) SetInheritable(error, false);
                if (outputInheritable) SetInheritable(output, false);
                CloseIfValid(input);
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

        public static void TerminateFinalizedWorkloadJob(IntPtr job)
        {
            if (!TerminateJobObject(job, 124)) ThrowLastError("TerminateJobObject(current-run Finalize)");
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

function Assert-FreshStdioPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $fullPath = Assert-SafeRecordParent -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name target is a reparse point." }
        throw "$Name must be a fresh absent file."
    }
    return $fullPath
}

function Assert-CurrentUserProtectedStdioStream {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [Parameter(Mandatory)][string]$Path)

    $item = [IO.FileInfo]::new($Path)
    if (-not $item.Exists) { throw "The protected stdio file is absent: $Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "The protected stdio file is a reparse point: $Path" }

    $security = [IO.FileSystemAclExtensions]::GetAccessControl($Stream)
    $currentSid = Get-CurrentUserSid
    if (-not $security.AreAccessRulesProtected -or $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentSid.Value) {
        throw "The stdio ACL is not protected for the current user: $Path"
    }

    $allowsCurrentUser = $false
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.IdentityReference.Value -ne $currentSid.Value) { throw "The stdio ACL allows an unapproved principal: $Path" }
        if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) {
            $allowsCurrentUser = $true
        }
    }
    if (-not $allowsCurrentUser) { throw "The current user does not have full control of stdio: $Path" }
}

function New-ProtectedStdioStream {
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    $created = $false
    try {
        $stream = [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($Path),
            [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough,
            (New-CurrentUserFileSecurity)
        )
        $created = $true
        Assert-CurrentUserProtectedStdioStream -Stream $stream -Path $Path
        return $stream
    }
    catch {
        if ($stream) { $stream.Dispose() }
        if ($created) { Remove-ProtectedStdioFile -Path $Path }
        throw
    }
}

function Remove-ProtectedStdioFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return }
    $item = [IO.FileInfo]::new($Path)
    $security = [IO.FileSystemAclExtensions]::GetAccessControl($item)
    $currentSid = Get-CurrentUserSid
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $security.AreAccessRulesProtected -or
        $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentSid.Value) {
        throw "Refused to remove a stdio leaf that is no longer the protected current-user file: $Path"
    }
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference.Value -ne $currentSid.Value) {
            throw "Refused to remove a stdio leaf that allows an unapproved principal: $Path"
        }
    }
    [IO.File]::Delete($Path)
    if ([IO.File]::Exists($Path)) { throw "The exact protected stdio leaf remained after cleanup: $Path" }
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

function New-CallbackCleanupFailure {
    param([Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)][string]$Detail)

    $failure = [InvalidOperationException]::new("The $Purpose callback cleanup invariant failed: $Detail")
    $failure.Data['AgentProcessLifecycle.CallbackCleanupFailure'] = $true
    return $failure
}

function Assert-CurrentUserProtectedCallbackItem {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item, [Parameter(Mandatory)][bool]$Directory)

    if (-not $Item.Exists) { throw "The protected callback artifact is absent: $($Item.FullName)" }
    if (($Item -is [IO.DirectoryInfo]) -ne $Directory) { throw "The protected callback artifact has the wrong type: $($Item.FullName)" }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "The protected callback artifact is a reparse point: $($Item.FullName)" }

    $security = [IO.FileSystemAclExtensions]::GetAccessControl($Item)
    $currentSid = Get-CurrentUserSid
    if (-not $security.AreAccessRulesProtected -or $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentSid.Value) {
        throw "The callback artifact ACL is not protected for the current user: $($Item.FullName)"
    }

    $allowsCurrentUser = $false
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.IdentityReference.Value -ne $currentSid.Value) { throw "The callback artifact ACL allows an unapproved principal: $($Item.FullName)" }
        if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) {
            $allowsCurrentUser = $true
        }
    }
    if (-not $allowsCurrentUser) { throw "The current user does not have full control of the callback artifact: $($Item.FullName)" }
}

function New-ProtectedCallbackDirectory {
    param([Parameter(Mandatory)][string]$ParentPath, [Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)][string]$Token)

    Assert-SafeRecordParent -Path (Join-Path $ParentPath 'callback-parent-check') | Out-Null
    $path = Join-Path $ParentPath "$Purpose-$Token.callback"
    $created = $false
    try {
        [CandidateAgentProcessLifecycle.Native]::CreateCurrentUserProtectedDirectory($path, (Get-CurrentUserSid).Value)
        $created = $true
        Assert-CurrentUserProtectedCallbackItem -Item ([IO.DirectoryInfo]::new($path)) -Directory $true
        return $path
    }
    catch {
        if ($created -and [IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path) }
        throw
    }
}

function New-ProtectedCallbackFile {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$Content)

    $stream = $null
    try {
        $stream = [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($Path),
            [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough,
            (New-CurrentUserFileSecurity)
        )
        if ($null -ne $Content) {
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 4096, $true)
            try {
                $writer.Write($Content)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally {
                $writer.Dispose()
            }
        }
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    Assert-CurrentUserProtectedCallbackItem -Item ([IO.FileInfo]::new($Path)) -Directory $false
}

function Get-CallbackActiveProcessCount {
    param([Parameter(Mandatory)][IntPtr]$JobHandle, [Parameter(Mandatory)][string]$Purpose)

    try {
        return [CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($JobHandle)
    }
    catch {
        throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail $_.Exception.Message)
    }
}

function Stop-CallbackJob {
    param([Parameter(Mandatory)][IntPtr]$JobHandle, [Parameter(Mandatory)][string]$Purpose)

    try {
        [CandidateAgentProcessLifecycle.Native]::TerminateCallbackJob($JobHandle)
    }
    catch {
        throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail $_.Exception.Message)
    }
}

function Invoke-BoundedCallback {
    param([Parameter(Mandatory)][scriptblock]$Callback, [Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][int]$DeadlineMilliseconds, [Parameter(Mandatory)][string]$Purpose)

    $token = New-RunId
    $recordParent = Split-Path -Parent (Assert-SafeRecordParent -Path $RecordPath)
    $directory = $null
    $contextPath = $null
    $resultPath = $null
    $scriptPath = $null
    $stdoutPath = $null
    $stderrPath = $null
    $artifactPaths = @()
    $worker = $null
    $callbackJob = [IntPtr]::Zero
    $workerStartedSuspended = $false
    $workerAssignedToCallbackJob = $false
    $callbackCompleted = $false
    $watch = $null
    $callbackStdoutStream = $null
    $callbackStderrStream = $null
    try {
        $directory = New-ProtectedCallbackDirectory -ParentPath $recordParent -Purpose $Purpose -Token $token
        $contextPath = Join-Path $directory 'context.xml'
        $resultPath = Join-Path $directory 'result.xml'
        $scriptPath = Join-Path $directory 'callback.ps1'
        $stdoutPath = Join-Path $directory 'stdout.log'
        $stderrPath = Join-Path $directory 'stderr.log'
        $artifactPaths = @($contextPath, $resultPath, $scriptPath, $stdoutPath, $stderrPath)
        $callbackText = $Callback.ToString()
        # 每個 leaf 都先以 protected DACL 原子建立，避免 parent 的 object-inherit ACE 在 worker 讀取前取得 callback 寫入權。
        New-ProtectedCallbackFile -Path $contextPath -Content ([Management.Automation.PSSerializer]::Serialize($Context))
        New-ProtectedCallbackFile -Path $resultPath
        New-ProtectedCallbackFile -Path $scriptPath -Content "param([string]`$ContextPath, [string]`$ResultPath)`n`$context = Import-Clixml -LiteralPath `$ContextPath`n`$result = & { $callbackText } `$context`n`$result | Export-Clixml -LiteralPath `$ResultPath"
        New-ProtectedCallbackFile -Path $stdoutPath
        New-ProtectedCallbackFile -Path $stderrPath
        $callbackJob = [CandidateAgentProcessLifecycle.Native]::CreateNamedJob("Local\AgentProcessLifecycle.Callback.$token.Job")
        $callbackStdoutStream = [IO.File]::Open($stdoutPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $callbackStderrStream = [IO.File]::Open($stderrPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $worker = [CandidateAgentProcessLifecycle.Native]::StartSuspended(
                "$PSHOME\pwsh.exe",
                [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ContextPath', $contextPath, '-ResultPath', $resultPath),
                $directory,
                $callbackStdoutStream.SafeFileHandle.DangerousGetHandle(),
                $callbackStderrStream.SafeFileHandle.DangerousGetHandle()
            )
        }
        finally {
            $callbackStderrStream.Dispose()
            $callbackStderrStream = $null
            $callbackStdoutStream.Dispose()
            $callbackStdoutStream = $null
        }
        $workerStartedSuspended = $true
        [CandidateAgentProcessLifecycle.Native]::Assign($callbackJob, $worker.ProcessHandle)
        $workerAssignedToCallbackJob = $true
        [CandidateAgentProcessLifecycle.Native]::Resume($worker.ThreadHandle)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $remaining = [Math]::Max(0, $DeadlineMilliseconds - [int]$watch.ElapsedMilliseconds)
        if ($remaining -le 0 -or -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($worker.ProcessHandle, [uint32]$remaining)) {
            # callback Job 與 workload Job 沒有任何共享 member；timeout 只能回收這次 callback tree。
            Stop-CallbackJob -JobHandle $callbackJob -Purpose $Purpose
            $cleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0 -and $cleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
            if ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0) { throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail 'The callback Job did not empty after its deadline.') }
            throw "The $Purpose callback exceeded its deadline."
        }
        while ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0 -and $watch.ElapsedMilliseconds -lt $DeadlineMilliseconds) { [Threading.Thread]::Sleep(20) }
        if ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0) {
            Stop-CallbackJob -JobHandle $callbackJob -Purpose $Purpose
            $cleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0 -and $cleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
            if ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0) { throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail 'The callback Job did not empty after descendant timeout.') }
            throw "The $Purpose callback descendants exceeded its deadline."
        }
        if (-not [IO.File]::Exists($resultPath) -or [IO.FileInfo]::new($resultPath).Length -eq 0) { throw "The $Purpose callback did not publish a result." }
        $result = Import-Clixml -LiteralPath $resultPath
        $callbackCompleted = $true
        return $result
    }
    finally {
        if ($callbackStderrStream) { $callbackStderrStream.Dispose() }
        if ($callbackStdoutStream) { $callbackStdoutStream.Dispose() }
        if ($workerStartedSuspended -and -not $callbackCompleted) {
            if ($workerAssignedToCallbackJob) {
                if ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0) {
                    Stop-CallbackJob -JobHandle $callbackJob -Purpose $Purpose
                    $callbackCleanupDeadline = [Diagnostics.Stopwatch]::StartNew()
                    while ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0 -and $callbackCleanupDeadline.ElapsedMilliseconds -lt 1000) { [Threading.Thread]::Sleep(20) }
                    if ((Get-CallbackActiveProcessCount -JobHandle $callbackJob -Purpose $Purpose) -ne 0) { throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail 'The callback Job did not empty during fail-closed cleanup.') }
                }
            }
            else {
                try {
                    [CandidateAgentProcessLifecycle.Native]::TerminateUnassignedCallbackWorker($worker.ProcessHandle)
                    if (-not [CandidateAgentProcessLifecycle.Native]::WaitForExit($worker.ProcessHandle, 1000)) { throw 'The unassigned callback worker did not exit during setup cleanup.' }
                }
                catch {
                    throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail $_.Exception.Message)
                }
            }
        }
        if ($worker) {
            [CandidateAgentProcessLifecycle.Native]::Close($worker.ThreadHandle)
            [CandidateAgentProcessLifecycle.Native]::Close($worker.ProcessHandle)
        }
        if ($callbackJob -ne [IntPtr]::Zero) { [CandidateAgentProcessLifecycle.Native]::Close($callbackJob) }
        $artifactCleanupErrors = [Collections.Generic.List[string]]::new()
        # 只刪除本次已知 leaves，再以 non-recursive delete 移除精確 directory；未知內容必須讓 cleanup fail closed。
        foreach ($path in $artifactPaths) {
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            try {
                while ([IO.File]::Exists($path)) {
                    try { [IO.File]::Delete($path) } catch {
                        if ($deadline.ElapsedMilliseconds -ge 1000) { throw }
                        [Threading.Thread]::Sleep(20)
                    }
                }
            }
            catch {
                $artifactCleanupErrors.Add("${path}: $($_.Exception.Message)")
            }
        }
        if ($directory) {
            try {
                if ([IO.Directory]::Exists($directory)) {
                    Assert-CurrentUserProtectedCallbackItem -Item ([IO.DirectoryInfo]::new($directory)) -Directory $true
                    [IO.Directory]::Delete($directory)
                }
                if ([IO.Directory]::Exists($directory)) { $artifactCleanupErrors.Add("Callback directory remained: $directory") }
            }
            catch {
                $artifactCleanupErrors.Add("${directory}: $($_.Exception.Message)")
            }
        }
        if ($artifactCleanupErrors.Count -gt 0) { throw (New-CallbackCleanupFailure -Purpose $Purpose -Detail ($artifactCleanupErrors -join ' ')) }
        # TEST-INJECTION: callback-cleanup-invariant
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

function Wait-ForEmptyJob {
    param([Parameter(Mandatory)][IntPtr]$JobHandle, [Parameter(Mandatory)][int]$DeadlineMilliseconds)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ([CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($JobHandle) -eq 0) { return $true }
        $remaining = Get-RemainingMilliseconds -Watch $watch -DeadlineMilliseconds $DeadlineMilliseconds
        if ($remaining -le 0) { return $false }
        [Threading.Thread]::Sleep([Math]::Min(20, $remaining))
    }
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
    $requestedLaterOwnerProvided = $script:ExplicitParameters.ContainsKey('RequestedLaterOwner')
    if ($RequestedDisposition -eq 'Preserve') {
        if (-not $requestedLaterOwnerProvided -or [string]::IsNullOrWhiteSpace($RequestedLaterOwner)) {
            throw 'RequestedLaterOwner is required and must be nonblank when RequestedDisposition is Preserve.'
        }
    }
    elseif ($requestedLaterOwnerProvided) {
        throw 'RequestedLaterOwner is only valid when RequestedDisposition is Preserve.'
    }

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
    $stdoutPathForRun = $null
    $stderrPathForRun = $null
    $stdoutStream = $null
    $stderrStream = $null

    try {
        $failureKind = 'stdio-isolation'
        $stdoutPathForRun = Assert-FreshStdioPath -Path $StdoutPath -Name 'StdoutPath'
        $stderrPathForRun = Assert-FreshStdioPath -Path $StderrPath -Name 'StderrPath'
        if ([string]::Equals($stdoutPathForRun, $stderrPathForRun, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'StdoutPath and StderrPath must resolve to different paths.'
        }

        $failureKind = 'record-preparation'
        $recordPathForRun = New-PreparingRecord -Path $RecordPath
        $recordCreated = $true
        $failureKind = 'stdio-isolation'
        $stdoutStream = New-ProtectedStdioStream -Path $stdoutPathForRun
        try {
            # TEST-INJECTION: stderr-before-create
            $stderrStream = New-ProtectedStdioStream -Path $stderrPathForRun
        }
        catch {
            $stdoutStream.Dispose()
            $stdoutStream = $null
            # stderr 建立失敗時只能回收本次已證明的 stdout leaf，不可碰 caller 既有或同名競爭者。
            Remove-ProtectedStdioFile -Path $stdoutPathForRun
            throw
        }
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
        try {
            # CreateProcessW 只取得這兩個 pinned handles；native 返回後立刻撤銷 inheritance，parent 隨即關閉 streams。
            $root = [CandidateAgentProcessLifecycle.Native]::StartSuspended(
                $Executable,
                $ArgumentList,
                $WorkingDirectory,
                $stdoutStream.SafeFileHandle.DangerousGetHandle(),
                $stderrStream.SafeFileHandle.DangerousGetHandle()
            )
        }
        finally {
            $stderrStream.Dispose()
            $stderrStream = $null
            $stdoutStream.Dispose()
            $stdoutStream = $null
        }
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
            stdio = [ordered]@{ stdout_path = $stdoutPathForRun; stderr_path = $stderrPathForRun }
            readiness = [ordered]@{ identity = $ReadinessIdentity; deadline_milliseconds = $ReadinessDeadlineMilliseconds; result = $null; completed_at_utc = $null }
            requested_disposition = $RequestedDisposition
            requested_later_owner = if ($RequestedDisposition -eq 'Preserve') { $RequestedLaterOwner } else { $null }
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
            later_owner = if ($RequestedDisposition -eq 'Preserve') { $RequestedLaterOwner } else { $null }
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
            stdio = [ordered]@{ isolated = $stdioIsolated; stdout_path = if ($stdoutPathForRun) { $stdoutPathForRun } else { $StdoutPath }; stderr_path = if ($stderrPathForRun) { $stderrPathForRun } else { $StderrPath } }
            readiness = [ordered]@{ identity = $ReadinessIdentity; succeeded = $readinessSucceeded; deadline_milliseconds = $ReadinessDeadlineMilliseconds }
            lifecycle_result = [ordered]@{ status = $status; operation = 'launch'; failure_kind = $failureKind; cleanup = $cleanup; unresolved_reason = if ($status -eq 'unresolved') { ($cleanup.errors -join ' ') } else { $null }; error = $_.Exception.Message }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = $RequestedDisposition; status = 'not-established' }
            later_owner = if ($RequestedDisposition -eq 'Preserve') { $RequestedLaterOwner } else { $null }
            evidence = [ordered]@{ record_path = $recordPathForRun; cleanup = $cleanup; job_holder_process_id = if ($holder) { $holder.ProcessId } else { $null }; root_identity = $rootIdentity; holder_identity = $holderIdentity }
        }
    }
    finally {
        if ($stderrStream) { $stderrStream.Dispose() }
        if ($stdoutStream) { $stdoutStream.Dispose() }
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

function Test-FinalizeRecordString {
    param([object]$Value)

    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-FinalizeNullableRecordString {
    param([object]$Value)

    return $null -eq $Value -or (Test-FinalizeRecordString -Value $Value)
}

function Test-FinalizeRecordInteger {
    param([object]$Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Test-FinalizeIdentityShape {
    param([object]$Identity)

    return $Identity -is [Collections.IDictionary] -and
        (Test-FinalizeRecordInteger -Value $Identity['process_id']) -and [int64]$Identity['process_id'] -gt 0 -and
        (Test-FinalizeRecordInteger -Value $Identity['creation_time_filetime']) -and [int64]$Identity['creation_time_filetime'] -gt 0 -and
        (Test-FinalizeRecordString -Value $Identity['image_path'])
}

function Test-FinalizeRecordSchema {
    param([object]$Record)

    if ($Record -isnot [Collections.IDictionary]) { return $false }
    if (-not (Test-FinalizeRecordInteger -Value $Record['schema_version']) -or [int64]$Record['schema_version'] -ne 1) { return $false }
    if (-not (Test-FinalizeRecordString -Value $Record['state']) -or -not (Test-FinalizeRecordString -Value $Record['run_id']) -or -not (Test-FinalizeRecordString -Value $Record['job_name'])) { return $false }
    if (-not (Test-FinalizeIdentityShape -Identity $Record['root']) -or -not (Test-FinalizeIdentityShape -Identity $Record['holder'])) { return $false }
    if ($Record['stdio'] -isnot [Collections.IDictionary] -or -not (Test-FinalizeRecordString -Value $Record['stdio']['stdout_path']) -or -not (Test-FinalizeRecordString -Value $Record['stdio']['stderr_path'])) { return $false }
    if ($Record['readiness'] -isnot [Collections.IDictionary] -or -not (Test-FinalizeRecordString -Value $Record['readiness']['identity']) -or -not (Test-FinalizeRecordString -Value $Record['readiness']['result'])) { return $false }
    if (-not (Test-FinalizeRecordString -Value $Record['requested_disposition'])) { return $false }
    if (-not (Test-FinalizeNullableRecordString -Value $Record['requested_later_owner']) -or -not (Test-FinalizeNullableRecordString -Value $Record['later_owner'])) { return $false }
    return $Record['events'] -is [Collections.IDictionary] -and
        (Test-FinalizeRecordString -Value $Record['events']['finalize']) -and
        (Test-FinalizeRecordString -Value $Record['events']['holder_exited'])
}

function Test-FinalizeRecordUnchanged {
    param([string]$Path, [byte[]]$OriginalBytes)

    if ($null -eq $OriginalBytes) { return $true }
    try {
        $currentBytes = [IO.File]::ReadAllBytes($Path)
        if ($currentBytes.Length -ne $OriginalBytes.Length) { return $false }
        for ($index = 0; $index -lt $OriginalBytes.Length; $index++) {
            if ($currentBytes[$index] -ne $OriginalBytes[$index]) { return $false }
        }
        return $true
    }
    catch {
        return $false
    }
}

function New-FinalizeRecordClaims {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)

    return [ordered]@{
        run_id = $Record['run_id']
        job_name = $Record['job_name']
        root_process_id = $Record['root']['process_id']
        holder_process_id = $Record['holder']['process_id']
        finalize_event = $Record['events']['finalize']
        holder_exited_event = $Record['events']['holder_exited']
    }
}

function New-FinalizeRejectionResult {
    param(
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][string]$UnresolvedReason,
        [Parameter(Mandatory)][string]$ValidationStage,
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string[]]$MissingEvidence,
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][bool]$RecordPresent,
        [byte[]]$RecordBytes,
        [object]$RecordClaims = $null,
        [object]$LaterOwner = $null,
        [Parameter(Mandatory)][string]$ResponsibilityStatus
    )

    return [ordered]@{
        action = 'Finalize'
        tier = 'windows-self-managed'
        requested_disposition = $Disposition
        binding = $null
        stdio = $null
        readiness = $null
        lifecycle_result = [ordered]@{
            status = 'unresolved'
            operation = 'finalize-rejected'
            failure_kind = $FailureKind
            cleanup = [ordered]@{ attempted = $false; status = 'not-attempted'; result = 'authority-unverified' }
            unresolved_reason = $UnresolvedReason
        }
        downstream_result = $DownstreamResult
        final_disposition = [ordered]@{ requested = $Disposition; status = 'unresolved' }
        later_owner = $LaterOwner
        evidence = [ordered]@{
            validation_stage = $ValidationStage
            reason_code = $ReasonCode
            missing_evidence = @($MissingEvidence)
            record_path = $RecordPath
            record_present = $RecordPresent
            record_unchanged = (Test-FinalizeRecordUnchanged -Path $RecordPath -OriginalBytes $RecordBytes)
            record_claims = $RecordClaims
            authority_verified = $false
            graceful_action_invocations = 0
            termination_attempted = $false
            forced_termination_used = $false
            responsibility_status = $ResponsibilityStatus
        }
    }
}

function Test-FinalizeAccessDeniedException {
    param([Parameter(Mandatory)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [UnauthorizedAccessException]) { return $true }
        if ($current -is [ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-FinalizeScopedPublicationArtifacts {
    param([Parameter(Mandatory)][string]$RecordPath)

    $fullPath = Assert-ExistingRecordPath -Path $RecordPath
    $leaf = Split-Path -Leaf $fullPath
    return @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($fullPath)) -Force -File -Filter ".${leaf}.*.tmp*" | ForEach-Object FullName)
}

function Get-FinalizePublicationArtifacts {
    param([Parameter(Mandatory)][string]$RecordPath, [Parameter(Mandatory)][Exception]$Exception)

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data['AgentProcessLifecycle.ArtifactPaths']) {
            foreach ($path in @($current.Data['AgentProcessLifecycle.ArtifactPaths'])) {
                if ([IO.File]::Exists([string]$path)) { $paths.Add([string]$path) | Out-Null }
            }
        }
        $current = $current.InnerException
    }
    foreach ($artifact in @(Get-FinalizeScopedPublicationArtifacts -RecordPath $RecordPath)) {
        $paths.Add($artifact) | Out-Null
    }
    return @($paths)
}

function Remove-FinalizeScopedPublicationArtifacts {
    param([Parameter(Mandatory)][string]$RecordPath)

    try {
        $artifacts = @(Get-FinalizeScopedPublicationArtifacts -RecordPath $RecordPath)
    }
    catch {
        $failure = [InvalidOperationException]::new("Failed to enumerate Preserve publication artifacts: $($_.Exception.Message)")
        $failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @()
        $failure.Data['AgentProcessLifecycle.ArtifactCleanupIncomplete'] = $true
        throw $failure
    }
    foreach ($artifact in $artifacts) {
        try {
            # TEST-INJECTION: finalize-publication-artifact-delete
            [IO.File]::Delete($artifact)
            if ([IO.File]::Exists($artifact)) { throw "Publication artifact remained: $artifact" }
        }
        catch {
            $failure = [InvalidOperationException]::new("Failed to remove Preserve publication artifact ${artifact}: $($_.Exception.Message)")
            $failure.Data['AgentProcessLifecycle.ArtifactPaths'] = @($artifacts)
            $failure.Data['AgentProcessLifecycle.ArtifactCleanupIncomplete'] = $true
            throw $failure
        }
    }
    return @($artifacts)
}

function Get-FinalizePreservePublicationOutcome {
    param(
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][byte[]]$OriginalBytes,
        [Parameter(Mandatory)][string]$ExpectedLaterOwner,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArtifactPaths
    )

    if (Test-FinalizeRecordUnchanged -Path $RecordPath -OriginalBytes $OriginalBytes) {
        return 'original-unchanged'
    }
    try {
        Assert-ExistingRecordPath -Path $RecordPath | Out-Null
        $published = ([IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json -AsHashtable)
        if ((Test-FinalizeRecordSchema -Record $published) -and
            $published['state'] -eq 'preserved' -and
            [string]::Equals([string]$published['later_owner'], $ExpectedLaterOwner, [StringComparison]::Ordinal) -and
            $ArtifactPaths.Count -gt 0) {
            return 'preserved-with-artifact-residue'
        }
    }
    catch {
    }
    return 'unknown'
}

function New-FinalizePreservePublicationFailureResult {
    param(
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$PublicationOutcome,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArtifactPaths,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    $handoffPublished = $PublicationOutcome -eq 'preserved-with-artifact-residue'
    $unresolved = $PublicationOutcome -ne 'original-unchanged'
    $result = [ordered]@{
        action = 'Finalize'
        tier = 'windows-self-managed'
        requested_disposition = 'Preserve'
        binding = [ordered]@{ run_id = $Record['run_id']; record_path = $RecordPath; root_process_id = $Record['root']['process_id'] }
        stdio = [ordered]@{ isolated = $true; stdout_path = $Record['stdio']['stdout_path']; stderr_path = $Record['stdio']['stderr_path'] }
        readiness = [ordered]@{ identity = $Record['readiness']['identity']; succeeded = $true }
        lifecycle_result = [ordered]@{
            status = if ($unresolved) { 'unresolved' } else { 'failed' }
            operation = 'preserve'
            failure_kind = 'record-publication'
            cleanup = [ordered]@{ attempted = $false; status = 'not-attempted'; result = 'workload-retained' }
            unresolved_reason = if ($unresolved) { "Preserve publication outcome is ${PublicationOutcome}: $ErrorMessage" } else { $null }
            error = $ErrorMessage
        }
        downstream_result = $DownstreamResult
        final_disposition = [ordered]@{ requested = 'Preserve'; status = if ($handoffPublished) { 'preserved' } elseif ($unresolved) { 'unresolved' } else { 'not-established' } }
        later_owner = if ($handoffPublished) { $Record['later_owner'] } else { $null }
        evidence = [ordered]@{
            authority_verified = $true
            handoff_published = $handoffPublished
            publication_outcome = $PublicationOutcome
            publication_artifacts = @($ArtifactPaths)
            graceful_action_invocations = 0
            termination_attempted = $false
            forced_termination_used = $false
        }
    }
    if ($handoffPublished) {
        $result['stop_method'] = [ordered]@{ action = 'Finalize'; disposition = 'Stop'; record_path = $RecordPath }
    }
    return $result
}

function Get-FinalizeArtifactPathsFromException {
    param([Parameter(Mandatory)][Exception]$Exception)

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current = $Exception
    while ($null -ne $current) {
        foreach ($path in @($current.Data['AgentProcessLifecycle.ArtifactPaths'])) {
            if ($null -ne $path) { $paths.Add([string]$path) | Out-Null }
        }
        $current = $current.InnerException
    }
    return @($paths)
}

function New-FinalizeStopArtifactCleanupFailureResult {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][string[]]$ArtifactPaths,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [Parameter(Mandatory)][bool]$ForcedTerminationUsed,
        [Parameter(Mandatory)][int]$GracefulActionInvocations,
        [Parameter(Mandatory)][string]$GracefulActionOutcome,
        [Parameter(Mandatory)][bool]$OwnedTreeEmpty,
        [Parameter(Mandatory)][bool]$RootAbsent
    )

    return [ordered]@{
        action = 'Finalize'
        tier = 'windows-self-managed'
        requested_disposition = 'Stop'
        binding = [ordered]@{ run_id = $Record['run_id']; job_name = $Record['job_name']; root_process_id = $Record['root']['process_id'] }
        stdio = [ordered]@{ isolated = $true; stdout_path = $Record['stdio']['stdout_path']; stderr_path = $Record['stdio']['stderr_path'] }
        readiness = [ordered]@{ identity = $Record['readiness']['identity']; succeeded = ($Record['readiness']['result'] -eq 'succeeded') }
        lifecycle_result = [ordered]@{
            status = 'unresolved'
            operation = if ($ForcedTerminationUsed) { 'forced-stop' } else { 'graceful-stop' }
            failure_kind = 'publication-artifact-cleanup'
            cleanup = [ordered]@{ attempted = $true; status = 'unresolved'; result = 'artifact-cleanup-incomplete' }
            unresolved_reason = $ErrorMessage
        }
        downstream_result = $DownstreamResult
        final_disposition = [ordered]@{ requested = 'Stop'; status = 'unresolved' }
        later_owner = 'lifecycle-reconciliation-owner'
        evidence = [ordered]@{
            authority_verified = $true
            graceful_action_invocations = $GracefulActionInvocations
            graceful_action_outcome = $GracefulActionOutcome
            forced_termination_used = $ForcedTerminationUsed
            owned_tree_empty = $OwnedTreeEmpty
            root_process_absent = $RootAbsent
            job_holder_absent = $true
            named_job_absent = $true
            record_path = $RecordPath
            record_present = $true
            record_state = $Record['state']
            publication_artifacts = @($ArtifactPaths)
            responsibility_status = 'transfer-required-not-completed'
        }
    }
}

function New-FinalizeStateRejection {
    param(
        [Parameter(Mandatory)][string]$UnresolvedReason,
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string[]]$MissingEvidence,
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][bool]$RecordPresent,
        [Parameter(Mandatory)][byte[]]$RecordBytes,
        [Parameter(Mandatory)][object]$RecordClaims
    )

    return New-FinalizeRejectionResult -FailureKind 'record-state' -UnresolvedReason $UnresolvedReason -ValidationStage 'state-readiness-disposition' -ReasonCode $ReasonCode -MissingEvidence $MissingEvidence -RecordPath $RecordPath -RecordPresent $RecordPresent -RecordBytes $RecordBytes -RecordClaims $RecordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
}

function Invoke-Finalize {
    $recordPathForFinalize = $RecordPath
    $recordPresent = $false
    $recordBytes = $null
    $record = $null
    $recordClaims = $null
    try {
        $recordPathForFinalize = Assert-ExistingRecordPath -Path $RecordPath
        $recordPresent = $true
    }
    catch {
        $isAbsent = $_.Exception.Message -eq 'The expected record file is absent.'
        if ($isAbsent) {
            $failureKind = 'record-unavailable'
            $reasonCode = 'record-absent'
            $missingEvidence = @('protected-record')
            $laterOwner = $null
            $responsibilityStatus = 'retained-by-caller'
        }
        else {
            $failureKind = 'record-access'
            $reasonCode = 'record-path-unverifiable'
            $missingEvidence = @('protected-record-path')
            $laterOwner = 'compatible-session-security-context-owner'
            $responsibilityStatus = 'transfer-required-not-completed'
        }
        return New-FinalizeRejectionResult -FailureKind $failureKind -UnresolvedReason $_.Exception.Message -ValidationStage 'protected-path-read-json' -ReasonCode $reasonCode -MissingEvidence $missingEvidence -RecordPath $recordPathForFinalize -RecordPresent $false -LaterOwner $laterOwner -ResponsibilityStatus $responsibilityStatus
    }

    try {
        # TEST-INJECTION: finalize-record-read
        $recordBytes = [IO.File]::ReadAllBytes($recordPathForFinalize)
        $recordText = [IO.File]::ReadAllText($recordPathForFinalize)
    }
    catch {
        return New-FinalizeRejectionResult -FailureKind 'record-access' -UnresolvedReason $_.Exception.Message -ValidationStage 'protected-path-read-json' -ReasonCode 'record-read-failed' -MissingEvidence @('readable-protected-record') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -LaterOwner 'compatible-session-security-context-owner' -ResponsibilityStatus 'transfer-required-not-completed'
    }
    try {
        $record = $recordText | ConvertFrom-Json -AsHashtable
    }
    catch {
        return New-FinalizeRejectionResult -FailureKind 'record-invalid' -UnresolvedReason $_.Exception.Message -ValidationStage 'protected-path-read-json' -ReasonCode 'record-json-invalid' -MissingEvidence @('parseable-record') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -ResponsibilityStatus 'retained-by-caller'
    }
    if (-not (Test-FinalizeRecordSchema -Record $record)) {
        return New-FinalizeRejectionResult -FailureKind 'record-invalid' -UnresolvedReason 'The record schema or required field types are invalid.' -ValidationStage 'schema-types' -ReasonCode 'schema-or-type-invalid' -MissingEvidence @('schema-version') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -ResponsibilityStatus 'retained-by-caller'
    }
    $recordClaims = New-FinalizeRecordClaims -Record $record

    if ($record['state'] -ne 'ready' -and $record['state'] -ne 'preserved') {
        return New-FinalizeStateRejection -UnresolvedReason 'The record is not ready for Finalize.' -ReasonCode 'record-not-ready' -MissingEvidence @('ready-stop-state') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
    }
    if ($record['readiness']['result'] -ne 'succeeded') {
        return New-FinalizeStateRejection -UnresolvedReason 'The recorded readiness result does not prove a ready workload.' -ReasonCode 'readiness-not-succeeded' -MissingEvidence @('readiness-success') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
    }
    if ($Disposition -eq 'Stop' -and $script:ExplicitParameters.ContainsKey('LaterOwner')) {
        return New-FinalizeStateRejection -UnresolvedReason 'LaterOwner is not valid for Stop.' -ReasonCode 'stop-prohibits-later-owner' -MissingEvidence @('stop-without-later-owner') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
    }
    if ($record['state'] -eq 'ready') {
        if ($record['requested_disposition'] -eq 'Stop') {
            if ($Disposition -ne 'Stop') {
                return New-FinalizeStateRejection -UnresolvedReason 'The ready record was launched for Stop and cannot be preserved.' -ReasonCode 'ready-stop-requires-stop' -MissingEvidence @('ready-stop-transition') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
            }
        }
        elseif ($record['requested_disposition'] -eq 'Preserve') {
            if ($Disposition -ne 'Preserve') {
                return New-FinalizeStateRejection -UnresolvedReason 'The recorded requested disposition is not Stop.' -ReasonCode 'record-disposition-not-stop' -MissingEvidence @('stop-disposition') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
            }
            if (-not (Test-FinalizeRecordString -Value $record['requested_later_owner'])) {
                return New-FinalizeStateRejection -UnresolvedReason 'The Preserve record does not contain a requested later owner.' -ReasonCode 'requested-later-owner-missing' -MissingEvidence @('requested-later-owner') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
            }
            if (-not $script:ExplicitParameters.ContainsKey('LaterOwner') -or [string]::IsNullOrWhiteSpace($LaterOwner) -or -not [string]::Equals($LaterOwner, [string]$record['requested_later_owner'], [StringComparison]::Ordinal)) {
                return New-FinalizeStateRejection -UnresolvedReason 'Preserve requires the matching nonblank LaterOwner.' -ReasonCode 'later-owner-mismatch' -MissingEvidence @('matching-later-owner') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
            }
            $explicitGracefulInputs = @(@('GracefulAction', 'GracefulContext', 'GracefulDeadlineMilliseconds') | Where-Object { $script:ExplicitParameters.ContainsKey($_) })
            if ($explicitGracefulInputs.Count -ne 0) {
                return New-FinalizeStateRejection -UnresolvedReason 'Preserve does not accept explicitly supplied graceful inputs.' -ReasonCode 'preserve-prohibits-graceful-inputs' -MissingEvidence @('preserve-without-graceful-inputs') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
            }
        }
        else {
            return New-FinalizeStateRejection -UnresolvedReason 'The recorded requested disposition is invalid.' -ReasonCode 'record-disposition-invalid' -MissingEvidence @('valid-requested-disposition') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
        }
    }
    else {
        if ($record['requested_disposition'] -ne 'Preserve' -or -not (Test-FinalizeRecordString -Value $record['later_owner'])) {
            return New-FinalizeStateRejection -UnresolvedReason 'The preserved record does not contain a valid Preserve handoff.' -ReasonCode 'preserved-handoff-invalid' -MissingEvidence @('preserved-handoff') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
        }
        if ($Disposition -ne 'Stop') {
            return New-FinalizeStateRejection -UnresolvedReason 'A preserved record can only be finalized by a later Stop.' -ReasonCode 'preserved-requires-stop' -MissingEvidence @('later-stop-transition') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims
        }
    }

    $runId = [string]$record['run_id']
    if ($runId -cnotmatch '^[0-9a-f]{32}$') {
        return New-FinalizeRejectionResult -FailureKind 'binding-inconsistent' -UnresolvedReason 'The record run_id is not a launch-derived identifier.' -ValidationStage 'binding-consistency' -ReasonCode 'run-id-invalid' -MissingEvidence @('derived-run-id') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
    }
    $namePrefix = "Local\AgentProcessLifecycle.$runId"
    if (-not [string]::Equals([string]$record['job_name'], "$namePrefix.Job", [StringComparison]::Ordinal)) {
        return New-FinalizeRejectionResult -FailureKind 'binding-inconsistent' -UnresolvedReason 'The record Job name does not match its run_id.' -ValidationStage 'binding-consistency' -ReasonCode 'job-name-mismatch' -MissingEvidence @('derived-job-name') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
    }
    if (-not [string]::Equals([string]$record['events']['finalize'], "$namePrefix.Finalize", [StringComparison]::Ordinal)) {
        return New-FinalizeRejectionResult -FailureKind 'binding-inconsistent' -UnresolvedReason 'The record Finalize event does not match its run_id.' -ValidationStage 'binding-consistency' -ReasonCode 'finalize-event-mismatch' -MissingEvidence @('derived-finalize-event') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
    }
    if (-not [string]::Equals([string]$record['events']['holder_exited'], "$namePrefix.HolderExited", [StringComparison]::Ordinal)) {
        return New-FinalizeRejectionResult -FailureKind 'binding-inconsistent' -UnresolvedReason 'The record HolderExited event does not match its run_id.' -ValidationStage 'binding-consistency' -ReasonCode 'holder-exited-event-mismatch' -MissingEvidence @('derived-holder-exited-event') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
    }

    $jobHandle = [IntPtr]::Zero
    $rootHandle = [IntPtr]::Zero
    $holderHandle = [IntPtr]::Zero
    $finalizeEvent = $null
    $holderExitedEvent = $null
    $authorityVerified = $false
    $gracefulActionInvocations = 0
    $gracefulActionOutcome = 'not-provided'
    $forcedTerminationUsed = $false
    $ownedTreeEmpty = $false
    $rootAbsent = $false
    $callbackCleanupFailure = $null
    try {
        try {
            $jobHandle = [CandidateAgentProcessLifecycle.Native]::OpenNamedJob([string]$record['job_name'])
            # TEST-INJECTION: finalize-job-query
            $null = [CandidateAgentProcessLifecycle.Native]::ActiveProcessCount($jobHandle)
        }
        catch {
            $laterOwner = if (Test-FinalizeAccessDeniedException -Exception $_.Exception) { 'compatible-session-security-context-owner' } else { 'lifecycle-reconciliation-owner' }
            if ($jobHandle -eq [IntPtr]::Zero) {
                $reasonCode = 'job-unavailable'
                $missingEvidence = @('retained-job-handle')
            }
            else {
                $reasonCode = 'job-retain-or-query-failed'
                $missingEvidence = @('queryable-job-handle')
            }
            return New-FinalizeRejectionResult -FailureKind 'job-unverifiable' -UnresolvedReason $_.Exception.Message -ValidationStage 'job-retain-query' -ReasonCode $reasonCode -MissingEvidence $missingEvidence -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner $laterOwner -ResponsibilityStatus 'transfer-required-not-completed'
        }

        try {
            $rootVerificationStep = 'identity'
            $rootHandle = [CandidateAgentProcessLifecycle.Native]::OpenRoot([uint32]$record['root']['process_id'])
            # TEST-INJECTION: finalize-root-query
            $rootCreationTime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($rootHandle)
            if ($rootCreationTime -ne [int64]$record['root']['creation_time_filetime']) {
                return New-FinalizeRejectionResult -FailureKind 'root-unverifiable' -UnresolvedReason 'The retained root handle does not match the recorded creation time.' -ValidationStage 'root-retain-verify' -ReasonCode 'root-creation-time-mismatch' -MissingEvidence @('matching-root-creation-time') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
            $rootImagePath = [CandidateAgentProcessLifecycle.Native]::ImagePath($rootHandle)
            if (-not [string]::Equals($rootImagePath, [string]$record['root']['image_path'], [StringComparison]::OrdinalIgnoreCase)) {
                return New-FinalizeRejectionResult -FailureKind 'root-unverifiable' -UnresolvedReason 'The retained root handle does not match the recorded image.' -ValidationStage 'root-retain-verify' -ReasonCode 'root-image-mismatch' -MissingEvidence @('matching-root-image') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
            $rootIsLive = -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($rootHandle, 0)
            # TEST-INJECTION: finalize-root-live
            if (-not $rootIsLive) {
                return New-FinalizeRejectionResult -FailureKind 'root-unverifiable' -UnresolvedReason 'The retained root handle is already exited.' -ValidationStage 'root-retain-verify' -ReasonCode 'root-not-live' -MissingEvidence @('live-root-instance') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
            $rootVerificationStep = 'membership'
            # TEST-INJECTION: finalize-root-membership-query
            $rootIsMember = [CandidateAgentProcessLifecycle.Native]::IsMember($rootHandle, $jobHandle)
            # TEST-INJECTION: finalize-root-membership
            if (-not $rootIsMember) {
                return New-FinalizeRejectionResult -FailureKind 'root-unverifiable' -UnresolvedReason 'The retained root handle is not a member of the retained Job.' -ValidationStage 'root-retain-verify' -ReasonCode 'root-not-job-member' -MissingEvidence @('root-job-membership') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
        }
        catch {
            $laterOwner = if (Test-FinalizeAccessDeniedException -Exception $_.Exception) { 'compatible-session-security-context-owner' } else { 'lifecycle-reconciliation-owner' }
            if ($rootHandle -eq [IntPtr]::Zero) {
                $reasonCode = 'root-unavailable'
                $missingEvidence = @('live-root-instance')
            }
            else {
                $reasonCode = 'root-retain-or-query-failed'
                if ($rootVerificationStep -eq 'membership') {
                    $missingEvidence = @('queryable-root-membership')
                }
                else {
                    $missingEvidence = @('queryable-root-instance')
                }
            }
            return New-FinalizeRejectionResult -FailureKind 'root-unverifiable' -UnresolvedReason $_.Exception.Message -ValidationStage 'root-retain-verify' -ReasonCode $reasonCode -MissingEvidence $missingEvidence -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner $laterOwner -ResponsibilityStatus 'transfer-required-not-completed'
        }

        try {
            $holderHandle = [CandidateAgentProcessLifecycle.Native]::OpenRoot([uint32]$record['holder']['process_id'])
            # TEST-INJECTION: finalize-holder-query
            $holderCreationTime = [CandidateAgentProcessLifecycle.Native]::CreationTimeFileTime($holderHandle)
            if ($holderCreationTime -ne [int64]$record['holder']['creation_time_filetime']) {
                return New-FinalizeRejectionResult -FailureKind 'holder-unverifiable' -UnresolvedReason 'The retained holder handle does not match the recorded creation time.' -ValidationStage 'holder-retain-verify' -ReasonCode 'holder-creation-time-mismatch' -MissingEvidence @('matching-holder-creation-time') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
            $holderImagePath = [CandidateAgentProcessLifecycle.Native]::ImagePath($holderHandle)
            if (-not [string]::Equals($holderImagePath, [string]$record['holder']['image_path'], [StringComparison]::OrdinalIgnoreCase)) {
                return New-FinalizeRejectionResult -FailureKind 'holder-unverifiable' -UnresolvedReason 'The retained holder handle does not match the recorded image.' -ValidationStage 'holder-retain-verify' -ReasonCode 'holder-image-mismatch' -MissingEvidence @('matching-holder-image') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
            $holderIsLive = -not [CandidateAgentProcessLifecycle.Native]::WaitForExit($holderHandle, 0)
            # TEST-INJECTION: finalize-holder-live
            if (-not $holderIsLive) {
                return New-FinalizeRejectionResult -FailureKind 'holder-unverifiable' -UnresolvedReason 'The retained holder handle is already exited.' -ValidationStage 'holder-retain-verify' -ReasonCode 'holder-not-live' -MissingEvidence @('live-holder-instance') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
            }
        }
        catch {
            $laterOwner = if (Test-FinalizeAccessDeniedException -Exception $_.Exception) { 'compatible-session-security-context-owner' } else { 'lifecycle-reconciliation-owner' }
            if ($holderHandle -eq [IntPtr]::Zero) {
                $reasonCode = 'holder-unavailable'
                $missingEvidence = @('live-holder-instance')
            }
            else {
                $reasonCode = 'holder-retain-or-query-failed'
                $missingEvidence = @('queryable-holder-instance')
            }
            return New-FinalizeRejectionResult -FailureKind 'holder-unverifiable' -UnresolvedReason $_.Exception.Message -ValidationStage 'holder-retain-verify' -ReasonCode $reasonCode -MissingEvidence $missingEvidence -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner $laterOwner -ResponsibilityStatus 'transfer-required-not-completed'
        }

        try {
            # TEST-INJECTION: finalize-finalize-event-open
            $finalizeEvent = [Threading.EventWaitHandle]::OpenExisting("$namePrefix.Finalize")
        }
        catch {
            $laterOwner = if (Test-FinalizeAccessDeniedException -Exception $_.Exception) { 'compatible-session-security-context-owner' } else { 'lifecycle-reconciliation-owner' }
            return New-FinalizeRejectionResult -FailureKind 'event-unverifiable' -UnresolvedReason $_.Exception.Message -ValidationStage 'event-retain-verify' -ReasonCode 'finalize-event-unavailable' -MissingEvidence @('exact-finalize-event') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner $laterOwner -ResponsibilityStatus 'transfer-required-not-completed'
        }
        try {
            # TEST-INJECTION: finalize-holder-exited-event-open
            $holderExitedEvent = [Threading.EventWaitHandle]::OpenExisting("$namePrefix.HolderExited")
        }
        catch {
            $laterOwner = if (Test-FinalizeAccessDeniedException -Exception $_.Exception) { 'compatible-session-security-context-owner' } else { 'lifecycle-reconciliation-owner' }
            return New-FinalizeRejectionResult -FailureKind 'event-unverifiable' -UnresolvedReason $_.Exception.Message -ValidationStage 'event-retain-verify' -ReasonCode 'holder-exited-event-unavailable' -MissingEvidence @('exact-holder-exited-event') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner $laterOwner -ResponsibilityStatus 'transfer-required-not-completed'
        }

        try {
            # Ticket 14: no callback, event signal, record mutation, or termination may begin until this complete authority chain is retained.
            # TEST-INJECTION: finalize-unexpected-preflight
            $authorityVerified = $true
        }
        catch {
            return New-FinalizeRejectionResult -FailureKind 'preflight-unexpected' -UnresolvedReason $_.Exception.Message -ValidationStage 'unexpected-preflight' -ReasonCode 'unexpected-preflight-failure' -MissingEvidence @('complete-finalize-authority') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
        }

        if ($Disposition -eq 'Preserve') {
            # Preserve 只在完整 authority preflight 後變更 record；不可 signal holder 或觸發任何 Stop 路徑。
            $record['state'] = 'preserved'
            $record['later_owner'] = $LaterOwner
            try {
                # TEST-INJECTION: preserve-record-publication
                Write-Record -Record $record -DestinationPath $recordPathForFinalize
            }
            catch {
                $publicationArtifacts = @(Get-FinalizePublicationArtifacts -RecordPath $recordPathForFinalize -Exception $_.Exception)
                $publicationOutcome = Get-FinalizePreservePublicationOutcome -RecordPath $recordPathForFinalize -OriginalBytes $recordBytes -ExpectedLaterOwner $LaterOwner -ArtifactPaths $publicationArtifacts
                return New-FinalizePreservePublicationFailureResult -RecordPath $recordPathForFinalize -Record $record -PublicationOutcome $publicationOutcome -ArtifactPaths $publicationArtifacts -ErrorMessage $_.Exception.Message
            }

            return [ordered]@{
                action = 'Finalize'
                tier = 'windows-self-managed'
                requested_disposition = 'Preserve'
                binding = [ordered]@{ run_id = $record['run_id']; record_path = $recordPathForFinalize; root_process_id = $record['root']['process_id'] }
                stdio = [ordered]@{ isolated = $true; stdout_path = $record['stdio']['stdout_path']; stderr_path = $record['stdio']['stderr_path'] }
                readiness = [ordered]@{ identity = $record['readiness']['identity']; succeeded = $true }
                lifecycle_result = [ordered]@{ status = 'success'; operation = 'preserve' }
                downstream_result = $DownstreamResult
                final_disposition = [ordered]@{ requested = 'Preserve'; status = 'preserved' }
                later_owner = $LaterOwner
                stop_method = [ordered]@{ action = 'Finalize'; disposition = 'Stop'; record_path = $recordPathForFinalize }
                evidence = [ordered]@{
                    authority_verified = $authorityVerified
                    handoff_published = $true
                    graceful_action_invocations = 0
                    termination_attempted = $false
                    forced_termination_used = $false
                    root_process_live = $true
                    job_holder_live = $true
                }
            }
        }

        # TEST-INJECTION: finalize-before-stop
        $binding = [ordered]@{ run_id = $record['run_id']; job_name = $record['job_name']; root_process_id = $record['root']['process_id']; graceful_context = $GracefulContext }
        if ($null -ne $GracefulAction) {
            $gracefulActionInvocations = 1
            $gracefulWatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $gracefulResult = Invoke-BoundedCallback -Callback $GracefulAction -Context $binding -DeadlineMilliseconds $GracefulDeadlineMilliseconds -Purpose 'graceful'
                if ($gracefulResult -eq $false) { throw 'The graceful callback reported failure.' }
                $remaining = Get-RemainingMilliseconds -Watch $gracefulWatch -DeadlineMilliseconds $GracefulDeadlineMilliseconds
                if ($remaining -gt 0 -and [CandidateAgentProcessLifecycle.Native]::WaitForExit($rootHandle, [uint32]$remaining)) {
                    $remaining = Get-RemainingMilliseconds -Watch $gracefulWatch -DeadlineMilliseconds $GracefulDeadlineMilliseconds
                    if ($remaining -gt 0 -and (Wait-ForEmptyJob -JobHandle $jobHandle -DeadlineMilliseconds $remaining)) {
                        $ownedTreeEmpty = $true
                        $gracefulActionOutcome = 'succeeded'
                    }
                    else {
                        $gracefulActionOutcome = 'owned-tree-not-empty'
                    }
                }
                else {
                    $gracefulActionOutcome = 'timed-out'
                }
            }
            catch {
                if ($_.Exception.Data['AgentProcessLifecycle.CallbackCleanupFailure'] -eq $true) {
                    # callback 自己的 cleanup 失敗不能被視為 graceful action failure；仍可用既有 Job 清 workload，但結果必須 unresolved。
                    $callbackCleanupFailure = $_.Exception.Message
                    $gracefulActionOutcome = 'callback-cleanup-failed'
                }
                else {
                    $gracefulActionOutcome = if ($_.Exception.Message -match 'deadline') { 'timed-out' } else { 'failed' }
                }
            }
        }

        if (-not $ownedTreeEmpty) {
            $forcedTerminationUsed = $true
            $forcedDeadlineMilliseconds = [Math]::Min(5000, [Math]::Max(1000, $GracefulDeadlineMilliseconds))
            # 只對剛完成 membership 驗證且仍保留中的 Job handle 強制停止，不能改以 PID 重新找目標。
            [CandidateAgentProcessLifecycle.Native]::TerminateFinalizedWorkloadJob($jobHandle)
            $ownedTreeEmpty = Wait-ForEmptyJob -JobHandle $jobHandle -DeadlineMilliseconds $forcedDeadlineMilliseconds
            if (-not $ownedTreeEmpty) { throw 'The owned Job did not empty after bounded forced Stop.' }
            $rootAbsent = [CandidateAgentProcessLifecycle.Native]::WaitForExit($rootHandle, [uint32]$forcedDeadlineMilliseconds)
            if (-not $rootAbsent) { throw 'The owned root did not exit after bounded forced Stop.' }
        }
        else {
            $rootAbsent = [CandidateAgentProcessLifecycle.Native]::WaitForExit($rootHandle, 0)
            if (-not $rootAbsent) { throw 'The owned Job emptied without confirming root exit.' }
        }

        $finalizeEvent.Set() | Out-Null
        if (-not $holderExitedEvent.WaitOne(1000)) {
            throw 'The Job handle holder did not exit within the graceful deadline.'
        }
        if (-not [CandidateAgentProcessLifecycle.Native]::WaitForExit($holderHandle, 1000)) {
            throw 'The Job handle holder did not terminate within the graceful deadline.'
        }
        [CandidateAgentProcessLifecycle.Native]::Close($holderHandle)
        $holderHandle = [IntPtr]::Zero
        [CandidateAgentProcessLifecycle.Native]::Close($rootHandle)
        $rootHandle = [IntPtr]::Zero
        [CandidateAgentProcessLifecycle.Native]::Close($jobHandle)
        $jobHandle = [IntPtr]::Zero
        $namedJobAbsent = -not [CandidateAgentProcessLifecycle.Native]::NamedJobExists([string]$record['job_name'])
        if (-not $namedJobAbsent) {
            throw 'The named Job remained after the holder released its handle.'
        }
        Assert-ExistingRecordPath -Path $recordPathForFinalize | Out-Null
        Remove-FinalizeScopedPublicationArtifacts -RecordPath $recordPathForFinalize | Out-Null
        [IO.File]::Delete($recordPathForFinalize)

        return [ordered]@{
            action = 'Finalize'
            tier = 'windows-self-managed'
            requested_disposition = 'Stop'
            binding = [ordered]@{ run_id = $record['run_id']; job_name = $record['job_name']; root_process_id = $record['root']['process_id'] }
            stdio = [ordered]@{ isolated = $true; stdout_path = $record['stdio']['stdout_path']; stderr_path = $record['stdio']['stderr_path'] }
            readiness = [ordered]@{ identity = $record['readiness']['identity']; succeeded = ($record['readiness']['result'] -eq 'succeeded') }
            lifecycle_result = [ordered]@{
                status = if ($callbackCleanupFailure) { 'unresolved' } else { 'success' }
                operation = if ($forcedTerminationUsed) { 'forced-stop' } else { 'graceful-stop' }
                failure_kind = if ($callbackCleanupFailure) { 'graceful-callback-cleanup' } else { $null }
                unresolved_reason = $callbackCleanupFailure
            }
            downstream_result = $DownstreamResult
            final_disposition = [ordered]@{ requested = 'Stop'; status = if ($callbackCleanupFailure) { 'unresolved' } else { 'completed' } }
            evidence = [ordered]@{ authority_verified = $authorityVerified; graceful_action_invocations = $gracefulActionInvocations; graceful_action_outcome = $gracefulActionOutcome; callback_cleanup_failure = $callbackCleanupFailure; forced_termination_used = $forcedTerminationUsed; owned_tree_empty = $ownedTreeEmpty; root_process_absent = $rootAbsent; named_job_absent = $true; job_holder_absent = $true }
        }
    }
    catch {
        if (-not $authorityVerified) {
            return New-FinalizeRejectionResult -FailureKind 'preflight-unexpected' -UnresolvedReason $_.Exception.Message -ValidationStage 'unexpected-preflight' -ReasonCode 'unexpected-preflight-failure' -MissingEvidence @('complete-finalize-authority') -RecordPath $recordPathForFinalize -RecordPresent $recordPresent -RecordBytes $recordBytes -RecordClaims $recordClaims -LaterOwner 'lifecycle-reconciliation-owner' -ResponsibilityStatus 'transfer-required-not-completed'
        }
        $artifactCleanupException = $_.Exception
        while ($artifactCleanupException -and $artifactCleanupException.Data['AgentProcessLifecycle.ArtifactCleanupIncomplete'] -ne $true) {
            $artifactCleanupException = $artifactCleanupException.InnerException
        }
        if ($artifactCleanupException) {
            return New-FinalizeStopArtifactCleanupFailureResult -Record $record -RecordPath $recordPathForFinalize -ArtifactPaths @(Get-FinalizeArtifactPathsFromException -Exception $artifactCleanupException) -ErrorMessage $_.Exception.Message -ForcedTerminationUsed $forcedTerminationUsed -GracefulActionInvocations $gracefulActionInvocations -GracefulActionOutcome $gracefulActionOutcome -OwnedTreeEmpty $ownedTreeEmpty -RootAbsent $rootAbsent
        }
        throw
    }
    finally {
        if ($finalizeEvent) { $finalizeEvent.Dispose() }
        if ($holderExitedEvent) { $holderExitedEvent.Dispose() }
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
