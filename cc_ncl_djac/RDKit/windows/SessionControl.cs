// RDKit ordinary-user session controller. Compatible with C# 5 / .NET Framework 4.
// Compile as a Windows application with System.Management and System.Windows.Forms.
// The RustDesk portable wrapper launches an extracted runtime and exits:
// https://github.com/rustdesk/rustdesk/blob/1.5.0/libs/portable/src/main.rs
// A suspended launch into a Windows job captures those descendants without PID guessing:
// https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using CleanupPlan = SessionCleanup.DeletionPlan;

internal static class SessionControl
{
    private const string ExecutableName = "rustdesk-1.5.0-x86_64.exe";
    private const uint JobQuery = 0x0004;
    private const uint JobTerminate = 0x0008;
    private const uint KillOnJobClose = 0x00002000;
    private const uint CreateSuspended = 0x00000004;
    private const int ErrorFileNotFound = 2;
    private const int ErrorAlreadyExists = 183;
    private const int BasicAccountingInformation = 1;
    private const int ExtendedLimitInformation = 9;

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string command = args.Length == 0 ? "start" : args[0].ToLowerInvariant();
            bool cleanupWorker = command == "cleanup-worker";
            if ((cleanupWorker && args.Length != 2) || (!cleanupWorker && args.Length > 1) ||
                (command != "start" && command != "stop" && command != "status" && command != "cleanup" && !cleanupWorker))
                throw new InvalidOperationException("Use the RDKit Start, Stop, or Stop and Clean Up shortcuts.");

            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                // Never offer elevation or enable a privilege. Run both shortcuts normally.
                if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                    throw new InvalidOperationException("Run this shortcut normally, without 'Run as administrator'. RDKit manages an ordinary-user session only.");
                if (identity.User == null)
                    throw new InvalidOperationException("Could not identify the current Windows account.");

                int sessionId;
                using (Process current = Process.GetCurrentProcess())
                    sessionId = current.SessionId;
                string key = identity.User.Value + "." + sessionId.ToString(CultureInfo.InvariantCulture);
                string jobName = "Local\\RDKit.Session." + key;
                // The RustDesk profile is shared across this account's Windows sessions.
                string mutexName = "Global\\RDKit.Control." + identity.User.Value;

                if (command == "start")
                    StartSession(jobName, mutexName, sessionId);
                else if (command == "cleanup")
                    ScheduleCleanup(AppDomain.CurrentDomain.BaseDirectory, mutexName);
                else if (cleanupWorker)
                    CompleteCleanup(args[1], jobName, mutexName);
                else
                    ShowMessage(InspectOrStop(jobName, mutexName, command == "stop"));
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "RDKit", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void StartSession(string jobName, string mutexName, int sessionId)
    {
        IntPtr job = IntPtr.Zero;
        IntPtr process = IntPtr.Zero;
        IntPtr thread = IntPtr.Zero;
        bool resumed = false;
        bool prepared = false;
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        List<ConfigChange> changes = new List<ConfigChange>();
        try
        {
            using (ControlLock control = new ControlLock(mutexName))
            {
                IntPtr existing = OpenExistingJob(JobQuery, jobName);
                if (existing != IntPtr.Zero)
                {
                    try
                    {
                        if (ActiveProcesses(existing) != 0)
                            throw new InvalidOperationException("An RDKit RustDesk session is already running in this Windows login. Use Stop RustDesk before starting another copy.");
                        throw new InvalidOperationException("The previous RDKit session is finishing. Wait a moment and launch again.");
                    }
                    finally { Native.CloseHandle(existing); }
                }

                string executable = Path.Combine(folder, ExecutableName);
                RequireFile(executable);
                RequireFile(Path.Combine(folder, "RustDesk.toml"));
                RequireFile(Path.Combine(folder, "RustDesk2.toml"));
                CheckNoExistingRustDesk(-1);

                job = Native.CreateJobObject(IntPtr.Zero, jobName);
                int createError = Marshal.GetLastWin32Error();
                if (job == IntPtr.Zero)
                    throw NativeError("Could not create the RustDesk session", createError);
                if (createError == ErrorAlreadyExists)
                    throw new InvalidOperationException("An RDKit session appeared while starting. Close this message and try again.");

                JobExtendedLimits limits = new JobExtendedLimits();
                limits.BasicLimitInformation.LimitFlags = KillOnJobClose;
                if (!Native.SetInformationJobObject(job, ExtendedLimitInformation, ref limits, Marshal.SizeOf(typeof(JobExtendedLimits))))
                    throw LastNativeError("Could not configure safe session shutdown");

                SessionCleanup.Prepare(folder);
                prepared = true;
                string configFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RustDesk", "config");
                Directory.CreateDirectory(configFolder);
                CopyConfig(folder, configFolder, "RustDesk.toml", changes);
                CopyConfig(folder, configFolder, "RustDesk2.toml", changes);

                StartupInfo startup = new StartupInfo();
                startup.cb = Marshal.SizeOf(typeof(StartupInfo));
                ProcessInformation info;
                // No --tray, --service, --elevate, runas, or installation flags.
                // The full portable app starts its ordinary-user server normally.
                if (!Native.CreateProcess(executable, new StringBuilder("\"" + executable + "\""), IntPtr.Zero, IntPtr.Zero,
                    false, CreateSuspended, IntPtr.Zero, folder, ref startup, out info))
                    throw LastNativeError("Could not start the portable RustDesk application");
                process = info.hProcess;
                thread = info.hThread;
                if (!Native.AssignProcessToJobObject(job, process))
                    throw LastNativeError("Windows could not track this RustDesk session; it was not allowed to start");
                if (Native.ResumeThread(thread) == UInt32.MaxValue)
                    throw LastNativeError("Could not resume the tracked RustDesk application");
                resumed = true;
                Native.CloseHandle(thread);
                thread = IntPtr.Zero;
                Native.CloseHandle(process);
                process = IntPtr.Zero;
            }

            // Keep the job's owning handle open. The portable wrapper may exit immediately;
            // its extracted runtime and descendants stay in the same job. No PID files.
            // The helper is intentionally a background controller, not a Windows service.
            while (ActiveProcesses(job) != 0)
                Thread.Sleep(250);
        }
        catch (Exception error)
        {
            if (!resumed)
            {
                // The only raw process handle here belongs to our suspended new child.
                // Failure must never leave an untracked application running.
                if (process != IntPtr.Zero)
                {
                    Native.TerminateProcess(process, 1);
                    Native.WaitForSingleObject(process, 5000);
                }
                string restoreError;
                using (ControlLock control = new ControlLock(mutexName))
                {
                    restoreError = RestoreConfigs(changes);
                    if (prepared)
                    {
                        try { SessionCleanup.Restore(folder); }
                        catch (Exception cleanupError)
                        {
                            restoreError = (restoreError == null ? "" : restoreError + "; ") + cleanupError.Message;
                        }
                    }
                }
                if (restoreError != null)
                    throw new InvalidOperationException(error.Message + "\r\n\r\nSome previous configuration files could not be restored: " + restoreError, error);
            }
            throw;
        }
        finally
        {
            if (thread != IntPtr.Zero) Native.CloseHandle(thread);
            if (process != IntPtr.Zero) Native.CloseHandle(process);
            // KILL_ON_JOB_CLOSE ends this job if the controller exits unexpectedly.
            if (job != IntPtr.Zero) Native.CloseHandle(job);
        }
    }

    private static string InspectOrStop(string jobName, string mutexName, bool stop)
    {
        using (ControlLock control = new ControlLock(mutexName))
        {
            IntPtr job = OpenExistingJob(JobQuery | (stop ? JobTerminate : 0), jobName);
            if (job == IntPtr.Zero)
                return "No RDKit-managed RustDesk session is running in this Windows login.\r\n\r\nRustDesk started separately or with the old launcher is not controlled by this shortcut.";
            try
            {
                uint count = ActiveProcesses(job);
                if (count == 0)
                    return "This RDKit RustDesk session has already stopped.";
                if (!stop)
                    return "The RDKit RustDesk session is running. Use Stop RustDesk to end it.";

                // Forcefully disconnect this run only. Windows services and unrelated
                // RustDesk processes are never enumerated as termination targets.
                if (!Native.TerminateJobObject(job, 0))
                    throw LastNativeError("Windows could not stop this RDKit session");
                Stopwatch wait = Stopwatch.StartNew();
                while (ActiveProcesses(job) != 0)
                {
                    if (wait.ElapsedMilliseconds >= 15000)
                        throw new InvalidOperationException("Shutdown was requested, but Windows has not confirmed that every tracked process stopped. Do not assume the session has ended; run Stop RustDesk again.");
                    Thread.Sleep(100);
                }
                return "RustDesk stopped. All processes started by this RDKit session have ended.\r\n\r\nIts remote connections and file transfers are disconnected.";
            }
            finally { Native.CloseHandle(job); }
        }
    }

    private static void CheckNoExistingRustDesk(int sessionId)
    {
        // Read-only queries; no service control or administrator credentials.
        // An installed client can hand work to its independent service, outside our job.
        using (ManagementObjectSearcher services = new ManagementObjectSearcher("SELECT Name, DisplayName, PathName FROM Win32_Service"))
        using (ManagementObjectCollection results = services.Get())
        {
            foreach (ManagementObject service in results)
            using (service)
            {
                if (ContainsRustDesk(service["Name"]) || ContainsRustDesk(service["DisplayName"]) || ContainsRustDesk(service["PathName"]))
                    throw new InvalidOperationException("This PC has an installed RustDesk Windows service. RDKit did not start or change configuration, because a portable session could use that separately managed service.");
            }
        }
        string query = "SELECT Name FROM Win32_Process";
        if (sessionId >= 0) query += " WHERE SessionId = " + sessionId.ToString(CultureInfo.InvariantCulture);
        using (ManagementObjectSearcher processes = new ManagementObjectSearcher(query))
        using (ManagementObjectCollection results = processes.Get())
        {
            foreach (ManagementObject process in results)
            using (process)
            {
                string name = Convert.ToString(process["Name"], CultureInfo.InvariantCulture);
                if (name.StartsWith("rustdesk", StringComparison.OrdinalIgnoreCase) || name.Equals("RuntimeBroker_rustdesk.exe", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Another RustDesk process is running on this PC. Close that copy normally before starting or cleaning up this toolkit. RDKit will not take over or delete files used by a separate session.");
            }
        }
    }

    private static void ScheduleCleanup(string folder, string mutexName)
    {
        using (ControlLock control = new ControlLock(mutexName))
        {
            CleanupPlan layout = SessionCleanup.ResolveLayout(folder);
            SessionCleanup.ValidateNoReparse(layout.PackageRoot);
            if (!File.Exists(layout.StatePath))
                throw new InvalidOperationException("This folder has no cleanup record from the new launcher. No files were deleted. Start with the updated launch.bat first; an older run cannot be safely cleaned automatically.");

            string temporary = Path.Combine(Path.GetTempPath(), "RDKit-cleanup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temporary);
            string worker = Path.Combine(temporary, "SessionControl.exe");
            string script = Path.Combine(temporary, "finish-cleanup.bat");
            bool launched = false;
            try
            {
                SessionCleanup.ValidateNoReparse(temporary);
                File.Copy(Path.Combine(folder, "SessionControl.exe"), worker, false);
                File.WriteAllText(script, CleanupBatch.Replace("\r\n", "\n").Replace("\n", "\r\n"), Encoding.ASCII);
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                // Paths are environment data, expanded once inside quotes; no CALL/eval.
                info.Arguments = "/d /v:off /s /c \"\"%RDKIT_CLEANUP_SCRIPT%\"\"";
                info.UseShellExecute = false;
                info.WorkingDirectory = Environment.SystemDirectory;
                info.EnvironmentVariables["RDKIT_CLEANUP_EXE"] = worker;
                info.EnvironmentVariables["RDKIT_CLEANUP_SCRIPT"] = script;
                info.EnvironmentVariables["RDKIT_CLEANUP_TEMP"] = temporary;
                info.EnvironmentVariables["RDKIT_CLEANUP_ORIGIN"] = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                using (Process child = Process.Start(info))
                {
                    if (child == null) throw new InvalidOperationException("Windows did not start the cleanup window.");
                }
                launched = true;
            }
            finally
            {
                if (!launched)
                {
                    if (File.Exists(worker)) File.Delete(worker);
                    if (File.Exists(script)) File.Delete(script);
                    Directory.Delete(temporary, false);
                }
            }
        }
    }

    private static void CompleteCleanup(string folder, string jobName, string mutexName)
    {
        using (ControlLock control = new ControlLock(mutexName))
        {
            SessionCleanup.ResolveLayout(folder);
            InspectOrStop(jobName, mutexName, true);
            CheckNoExistingRustDesk(-1);
            SessionCleanup.Restore(folder);
            CleanupPlan plan = SessionCleanup.GetDeletionPlan(folder);

            // Restore completed before package deletion. No baseline backup is inside
            // the package. Deletion retries handle original helpers exiting normally.
            Stopwatch wait = Stopwatch.StartNew();
            while (Directory.Exists(plan.PackageRoot))
            {
                try { SessionCleanup.DeleteValidatedPackage(folder); }
                catch (IOException error)
                {
                    int nativeCode = error.HResult & 0xffff;
                    if (nativeCode != 32 && nativeCode != 33 && nativeCode != 145) throw;
                    if (wait.ElapsedMilliseconds >= 15000)
                        throw new IOException("RustDesk stopped and its previous files were restored, but a file is still in use. Close programs using this toolkit and remove the remaining folder: " + plan.PackageRoot);
                    Thread.Sleep(250);
                }
                catch (UnauthorizedAccessException error)
                {
                    // Windows also reports an executable still mapped by an exiting
                    // controller as access denied. Retry briefly; never change rights.
                    if (wait.ElapsedMilliseconds >= 15000)
                        throw new IOException("RustDesk stopped and its previous files were restored, but Windows could not delete part of the toolkit. Close any RDKit message windows and programs using it, then remove the remaining folder: " + plan.PackageRoot + "\r\n" + error.Message, error);
                    Thread.Sleep(250);
                }
            }
            if (plan.ArchivePath != null && File.Exists(plan.ArchivePath))
                throw new IOException("The download ZIP is still present: " + plan.ArchivePath);
        }
    }

    private const string CleanupBatch = @"@echo off
setlocal DisableDelayedExpansion
echo Stopping this RDKit session and cleaning up its files...
start """" /wait ""%RDKIT_CLEANUP_EXE%"" cleanup-worker ""%RDKIT_CLEANUP_ORIGIN%""
set ""RDKIT_RESULT=%errorlevel%""
set ""RDKIT_RETRIES=0""
:delete_worker
if not exist ""%RDKIT_CLEANUP_EXE%"" goto finish
del /q ""%RDKIT_CLEANUP_EXE%"" 2>nul
if not exist ""%RDKIT_CLEANUP_EXE%"" goto finish
set /a RDKIT_RETRIES+=1 >nul
if %RDKIT_RETRIES% GEQ 15 goto worker_locked
timeout /t 1 /nobreak >nul
goto delete_worker
:worker_locked
echo Cleanup is incomplete: the temporary helper could not be removed.
echo Its location is ""%RDKIT_CLEANUP_TEMP%"".
pause
exit /b 1
:finish
rem This entire final block is parsed before the script deletes itself.
(
    del /q ""%RDKIT_CLEANUP_SCRIPT%""
    rmdir ""%RDKIT_CLEANUP_TEMP%""
    if exist ""%RDKIT_CLEANUP_TEMP%"" (
        echo Cleanup is incomplete: temporary files remain at ""%RDKIT_CLEANUP_TEMP%"".
        pause
        exit /b 1
    ) else (
        if ""%RDKIT_RESULT%""==""0"" (
            echo Cleanup complete. This run's files, package, ZIP and temporary helper were removed.
            echo Any previous RustDesk files were restored.
        ) else (
            echo Cleanup is incomplete. Review the error message; recovery files were preserved where possible.
        )
    )
    pause
    exit /b %RDKIT_RESULT%
)
";

    private static bool ContainsRustDesk(object value)
    {
        return Convert.ToString(value, CultureInfo.InvariantCulture).IndexOf("rustdesk", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static void RequireFile(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException("A required RDKit file is missing. Extract the whole ZIP before launching:\r\n" + path);
    }

    private static void CopyConfig(string source, string target, string name, List<ConfigChange> changes)
    {
        string destination = Path.Combine(target, name);
        ConfigChange change = new ConfigChange();
        change.Path = destination;
        change.Previous = File.Exists(destination) ? File.ReadAllBytes(destination) : null;
        changes.Add(change);
        File.Copy(Path.Combine(source, name), destination, true);
    }

    private static string RestoreConfigs(List<ConfigChange> changes)
    {
        List<string> failures = new List<string>();
        for (int i = changes.Count - 1; i >= 0; i--)
        {
            ConfigChange change = changes[i];
            try
            {
                if (change.Previous == null) File.Delete(change.Path);
                else File.WriteAllBytes(change.Path, change.Previous);
            }
            catch (Exception error) { failures.Add(error.Message); }
        }
        return failures.Count == 0 ? null : String.Join("; ", failures.ToArray());
    }

    private static IntPtr OpenExistingJob(uint rights, string name)
    {
        IntPtr job = Native.OpenJobObject(rights, false, name);
        if (job != IntPtr.Zero) return job;
        int error = Marshal.GetLastWin32Error();
        if (error == ErrorFileNotFound) return IntPtr.Zero;
        throw NativeError("Could not access this account's RDKit session", error);
    }

    private static uint ActiveProcesses(IntPtr job)
    {
        JobAccounting accounting;
        if (!Native.QueryInformationJobObject(job, BasicAccountingInformation, out accounting, Marshal.SizeOf(typeof(JobAccounting)), IntPtr.Zero))
            throw LastNativeError("Could not verify the RustDesk session's running processes");
        return accounting.ActiveProcesses;
    }

    private static Exception LastNativeError(string operation)
    {
        return NativeError(operation, Marshal.GetLastWin32Error());
    }

    private static Exception NativeError(string operation, int error)
    {
        return new InvalidOperationException(operation + ".\r\n" + new Win32Exception(error).Message + " (Windows error " + error.ToString(CultureInfo.InvariantCulture) + ").");
    }

    private static void ShowMessage(string message)
    {
        MessageBox.Show(message, "RDKit", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private sealed class ConfigChange
    {
        internal string Path;
        internal byte[] Previous;
    }

    private sealed class ControlLock : IDisposable
    {
        private readonly Mutex mutex;
        private bool owns;
        internal ControlLock(string name)
        {
            mutex = new Mutex(false, name);
            try
            {
                try { owns = mutex.WaitOne(15000); }
                catch (AbandonedMutexException) { owns = true; }
                if (!owns) throw new InvalidOperationException("Another RDKit start or stop action is still in progress. Wait a moment and try again.");
            }
            catch { mutex.Dispose(); throw; }
        }
        public void Dispose()
        {
            if (owns) { mutex.ReleaseMutex(); owns = false; }
            mutex.Dispose();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobBasicLimits
    {
        internal long PerProcessUserTimeLimit;
        internal long PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSetSize;
        internal UIntPtr MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass;
        internal uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        internal ulong ReadOperationCount;
        internal ulong WriteOperationCount;
        internal ulong OtherOperationCount;
        internal ulong ReadTransferCount;
        internal ulong WriteTransferCount;
        internal ulong OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JobExtendedLimits
    {
        internal JobBasicLimits BasicLimitInformation;
        internal IoCounters IoInfo;
        internal UIntPtr ProcessMemoryLimit;
        internal UIntPtr JobMemoryLimit;
        internal UIntPtr PeakProcessMemoryUsed;
        internal UIntPtr PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JobAccounting
    {
        internal long TotalUserTime;
        internal long TotalKernelTime;
        internal long ThisPeriodTotalUserTime;
        internal long ThisPeriodTotalKernelTime;
        internal uint TotalPageFaultCount;
        internal uint TotalProcesses;
        internal uint ActiveProcesses;
        internal uint TotalTerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        internal int cb;
        internal string lpReserved;
        internal string lpDesktop;
        internal string lpTitle;
        internal uint dwX;
        internal uint dwY;
        internal uint dwXSize;
        internal uint dwYSize;
        internal uint dwXCountChars;
        internal uint dwYCountChars;
        internal uint dwFillAttribute;
        internal uint dwFlags;
        internal ushort wShowWindow;
        internal ushort cbReserved2;
        internal IntPtr lpReserved2;
        internal IntPtr hStdInput;
        internal IntPtr hStdOutput;
        internal IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        internal IntPtr hProcess;
        internal IntPtr hThread;
        internal uint dwProcessId;
        internal uint dwThreadId;
    }
    private static class Native
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr OpenJobObject(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref JobExtendedLimits information, int length);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out JobAccounting information, int length, IntPtr returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment,
            string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
