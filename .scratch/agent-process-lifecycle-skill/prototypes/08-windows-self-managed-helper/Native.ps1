# THROWAWAY PROTOTYPE: minimal Win32 surface for the empirical lifecycle test.

if ('ThrowawayAgentProcessLifecycle.Native' -as [type]) {
    return
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ThrowawayAgentProcessLifecycle
{
    public sealed class LaunchResult
    {
        public IntPtr JobHandle { get; set; }
        public int ProcessId { get; set; }
        public DateTime ProcessCreationTimeUtc { get; set; }
        public bool LauncherWasAlreadyInJob { get; set; }
    }

    public static class Native
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint CreateAlways = 2;
        private const uint OpenExisting = 3;
        private const uint JobObjectTerminate = 0x0008;
        private const uint JobObjectQuery = 0x0004;
        private const uint Synchronize = 0x00100000;
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint EventModifyState = 0x0002;
        private const uint EventSynchronize = 0x00100000;
        private const uint DuplicateSameAccess = 0x00000002;
        private const int ErrorAlreadyExists = 183;
        private const int JobObjectBasicProcessIdList = 3;
        private static readonly IntPtr ProcThreadAttributeHandleList = new IntPtr(0x00020002);

        public const uint WaitObject0 = 0x00000000;
        public const uint WaitTimeout = 0x00000102;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public uint X;
            public uint Y;
            public uint XSize;
            public uint YSize;
            public uint XCountChars;
            public uint YCountChars;
            public uint FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
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
        private static extern bool QueryInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength,
            out uint returnLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            uint flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateHandle(
            IntPtr sourceProcess,
            IntPtr sourceHandle,
            IntPtr targetProcess,
            out IntPtr targetHandle,
            uint desiredAccess,
            bool inheritHandle,
            uint options);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(
            IntPtr process,
            out FileTime creation,
            out FileTime exit,
            out FileTime kernel,
            out FileTime user);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateEventW(
            IntPtr eventAttributes,
            bool manualReset,
            bool initialState,
            string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenEventW(uint desiredAccess, bool inheritHandle, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetEvent(IntPtr handle);

        public static LaunchResult StartSuspendedInNamedJob(
            string jobName,
            string applicationPath,
            string commandLine,
            string workingDirectory,
            string stdoutPath,
            string stderrPath)
        {
            IntPtr job = IntPtr.Zero;
            IntPtr standardInput = IntPtr.Zero;
            IntPtr standardOutput = IntPtr.Zero;
            IntPtr standardError = IntPtr.Zero;
            IntPtr inheritedJobHandle = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr inheritedHandles = IntPtr.Zero;
            bool attributeListInitialized = false;
            ProcessInformation process = new ProcessInformation();
            bool processCreated = false;
            bool assignedToJob = false;

            try
            {
                job = CreateJobObjectW(IntPtr.Zero, jobName);
                if (job == IntPtr.Zero)
                {
                    ThrowLastError("CreateJobObjectW");
                }
                if (Marshal.GetLastWin32Error() == ErrorAlreadyExists)
                {
                    throw new InvalidOperationException("The cryptographically random Job name already exists.");
                }

                var attributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    InheritHandle = true
                };
                uint shares = FileShareRead | FileShareWrite | FileShareDelete;
                standardInput = CreateFileW("NUL", GenericRead, shares, ref attributes, OpenExisting, 0, IntPtr.Zero);
                standardOutput = CreateFileW(stdoutPath, GenericWrite, shares, ref attributes, CreateAlways, 0, IntPtr.Zero);
                standardError = CreateFileW(stderrPath, GenericWrite, shares, ref attributes, CreateAlways, 0, IntPtr.Zero);
                EnsureFileHandle(standardInput, "CreateFileW(NUL)");
                EnsureFileHandle(standardOutput, "CreateFileW(stdout)");
                EnsureFileHandle(standardError, "CreateFileW(stderr)");
                IntPtr currentProcess = GetCurrentProcess();
                if (!DuplicateHandle(
                    currentProcess,
                    job,
                    currentProcess,
                    out inheritedJobHandle,
                    0,
                    true,
                    DuplicateSameAccess))
                {
                    ThrowLastError("DuplicateHandle(Job)");
                }

                var startup = new StartupInfoEx
                {
                    StartupInfo = new StartupInfo
                    {
                        Size = Marshal.SizeOf<StartupInfoEx>(),
                        Flags = StartfUseStdHandles,
                        StandardInput = standardInput,
                        StandardOutput = standardOutput,
                        StandardError = standardError
                    }
                };

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
                {
                    ThrowLastError("InitializeProcThreadAttributeList");
                }
                attributeListInitialized = true;
                startup.AttributeList = attributeList;

                int inheritedHandleBytes = IntPtr.Size * 4;
                inheritedHandles = Marshal.AllocHGlobal(inheritedHandleBytes);
                Marshal.WriteIntPtr(inheritedHandles, 0, standardInput);
                Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size, standardOutput);
                Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size * 2, standardError);
                Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size * 3, inheritedJobHandle);
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    inheritedHandles,
                    new IntPtr(inheritedHandleBytes),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    ThrowLastError("UpdateProcThreadAttribute(handle list)");
                }

                if (!CreateProcessW(
                    applicationPath,
                    new StringBuilder(commandLine),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended | CreateNoWindow | ExtendedStartupInfoPresent,
                    IntPtr.Zero,
                    workingDirectory,
                    ref startup,
                    out process))
                {
                    ThrowLastError("CreateProcessW");
                }
                processCreated = true;

                if (!AssignProcessToJobObject(job, process.Process))
                {
                    ThrowLastError("AssignProcessToJobObject");
                }
                assignedToJob = true;

                DateTime creationTime = ReadCreationTime(process.Process);
                if (ResumeThread(process.Thread) == UInt32.MaxValue)
                {
                    ThrowLastError("ResumeThread");
                }

                bool launcherWasInJob;
                if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out launcherWasInJob))
                {
                    ThrowLastError("IsProcessInJob(current)");
                }

                return new LaunchResult
                {
                    JobHandle = job,
                    ProcessId = process.ProcessId,
                    ProcessCreationTimeUtc = creationTime,
                    LauncherWasAlreadyInJob = launcherWasInJob
                };
            }
            catch
            {
                if (processCreated)
                {
                    if (assignedToJob)
                    {
                        TerminateJobObject(job, 87);
                    }
                    else
                    {
                        TerminateProcess(process.Process, 87);
                    }
                    WaitForSingleObject(process.Process, 3000);
                }
                if (job != IntPtr.Zero)
                {
                    CloseHandle(job);
                }
                throw;
            }
            finally
            {
                CloseIfValid(standardInput);
                CloseIfValid(standardOutput);
                CloseIfValid(standardError);
                CloseIfValid(inheritedJobHandle);
                if (attributeListInitialized)
                {
                    DeleteProcThreadAttributeList(attributeList);
                }
                if (attributeList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(attributeList);
                }
                if (inheritedHandles != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(inheritedHandles);
                }
                CloseIfValid(process.Thread);
                CloseIfValid(process.Process);
            }
        }

        public static IntPtr OpenOwnedJob(string jobName)
        {
            IntPtr handle = OpenJobObjectW(JobObjectQuery | JobObjectTerminate | Synchronize, false, jobName);
            if (handle == IntPtr.Zero)
            {
                ThrowLastError("OpenJobObjectW");
            }
            return handle;
        }

        public static long[] QueryJobProcessIds(IntPtr job)
        {
            const int bufferSize = 65536;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                uint returned;
                if (!QueryInformationJobObject(job, JobObjectBasicProcessIdList, buffer, bufferSize, out returned))
                {
                    ThrowLastError("QueryInformationJobObject");
                }
                int assigned = Marshal.ReadInt32(buffer, 0);
                int listed = Marshal.ReadInt32(buffer, 4);
                if (listed != assigned)
                {
                    throw new InvalidOperationException("The fixed prototype Job membership buffer was too small.");
                }
                long[] processIds = new long[listed];
                for (int index = 0; index < listed; index++)
                {
                    int offset = 8 + (index * IntPtr.Size);
                    processIds[index] = IntPtr.Size == 8
                        ? Marshal.ReadInt64(buffer, offset)
                        : Marshal.ReadInt32(buffer, offset);
                }
                return processIds;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static bool IsProcessInSpecificJob(int processId, IntPtr job)
        {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
            if (process == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                bool result;
                return IsProcessInJob(process, job, out result) && result;
            }
            finally
            {
                CloseHandle(process);
            }
        }

        public static DateTime? TryGetProcessCreationTimeUtc(int processId)
        {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation | Synchronize, false, processId);
            if (process == IntPtr.Zero)
            {
                return null;
            }
            try
            {
                return ReadCreationTime(process);
            }
            catch
            {
                return null;
            }
            finally
            {
                CloseHandle(process);
            }
        }

        public static bool IsProcessInstanceAlive(int processId, DateTime expectedCreationTimeUtc)
        {
            DateTime? actual = TryGetProcessCreationTimeUtc(processId);
            return actual.HasValue
                && actual.Value.Ticks == expectedCreationTimeUtc.ToUniversalTime().Ticks;
        }

        public static IntPtr CreateManualResetEvent(string name)
        {
            IntPtr handle = CreateEventW(IntPtr.Zero, true, false, name);
            if (handle == IntPtr.Zero)
            {
                ThrowLastError("CreateEventW");
            }
            return handle;
        }

        public static bool SignalExistingEvent(string name)
        {
            IntPtr handle = OpenEventW(EventModifyState | EventSynchronize, false, name);
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                if (!SetEvent(handle))
                {
                    ThrowLastError("SetEvent");
                }
                return true;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        public static uint Wait(IntPtr handle, uint milliseconds)
        {
            return WaitForSingleObject(handle, milliseconds);
        }

        public static void TerminateOwnedJob(IntPtr job)
        {
            if (!TerminateJobObject(job, 137))
            {
                ThrowLastError("TerminateJobObject");
            }
        }

        public static bool NamedJobExists(string jobName)
        {
            IntPtr handle = OpenJobObjectW(JobObjectQuery, false, jobName);
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            CloseHandle(handle);
            return true;
        }

        public static bool IsCurrentProcessInJob()
        {
            bool result;
            if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out result))
            {
                ThrowLastError("IsProcessInJob(current)");
            }
            return result;
        }

        public static void Close(IntPtr handle)
        {
            if (handle != IntPtr.Zero && !CloseHandle(handle))
            {
                ThrowLastError("CloseHandle");
            }
        }

        public static string BuildCommandLine(params string[] arguments)
        {
            var commandLine = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (commandLine.Length > 0)
                {
                    commandLine.Append(' ');
                }
                commandLine.Append(QuoteArgument(argument));
            }
            return commandLine.ToString();
        }

        private static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return argument;
            }

            var quoted = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', (backslashes * 2) + 1);
                    quoted.Append('"');
                    backslashes = 0;
                    continue;
                }
                quoted.Append('\\', backslashes);
                backslashes = 0;
                quoted.Append(character);
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private static DateTime ReadCreationTime(IntPtr process)
        {
            FileTime creation;
            FileTime exit;
            FileTime kernel;
            FileTime user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
            {
                ThrowLastError("GetProcessTimes");
            }
            long value = ((long)creation.High << 32) | creation.Low;
            return DateTime.FromFileTimeUtc(value);
        }

        private static void EnsureFileHandle(IntPtr handle, string operation)
        {
            if (handle == new IntPtr(-1))
            {
                ThrowLastError(operation);
            }
        }

        private static void CloseIfValid(IntPtr handle)
        {
            if (handle != IntPtr.Zero && handle != new IntPtr(-1))
            {
                CloseHandle(handle);
            }
        }

        private static void ThrowLastError(string operation)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
    }
}
'@
