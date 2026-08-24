// SurfJob: background child process with captured output, compiled by Add-Type from
// Surf.psm1. Written in C# 5 so PowerShell 5.1's in-box compiler accepts it; the same
// source compiles under PowerShell 7 (Roslyn).
//
// Design constraints (from the 0.3.0 design review):
//  - One kernel job object PER instance with KILL_ON_JOB_CLOSE: KillTree() is an atomic
//    TerminateJobObject, immune to PID reuse and mid-kill spawns; closing the handle
//    (Dispose, or the host process dying) also reaps the whole tree.
//  - Manual char-buffered reader threads, NOT BeginOutputReadLine: line-buffered events
//    never deliver an unterminated "continue? y/n " prompt while the child is alive.
//    The pending tail is exposed as PartialLine; a lone \r rewrites the tail in place
//    so progress spinners do not flood the history.
//  - All indices on the public surface are monotonic absolute line numbers. The ring
//    evicts oldest lines past MaxLines or MaxBytes; SnapshotLines clamps to FirstIndex.
//  - Reader threads run on a .NET Framework host where an unhandled exception kills
//    the whole PowerShell process: every thread body and event path swallows.
//  - All public members tolerate the exited and disposed states instead of throwing.

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Surf
{
    public sealed class SurfJob : IDisposable
    {
        private const int MaxLines = 5000;
        private const int MaxLineLength = 4096;
        private const long MaxBytes = 5L * 1024 * 1024;

        private readonly object _sync = new object();
        private readonly string[] _ring = new string[MaxLines];
        private long _first;              // absolute index of the oldest retained line
        private long _total;              // absolute count of completed lines ever seen
        private long _bytes;              // chars retained in the ring
        private string _partialOut = "";
        private string _partialErr = "";
        private bool _disposed;
        private int _readersDone;

        private readonly Process _proc;
        private readonly StreamWriter _stdin;
        private readonly StreamReader _stdout;   // captured in the ctor: the Process
        private readonly StreamReader _stderr;   // getters throw after Dispose()
        private IntPtr _job = IntPtr.Zero;
        private bool _jobAttached;
        private bool _errClixmlSeen;             // '#< CLIXML' header observed on stderr
        private bool _errSuppressLine;           // mid-flight oversized CLIXML line: drop fragments

        public readonly int ProcessId;
        public readonly string CommandText;
        public readonly string WorkingDirectory;
        public readonly DateTime StartedAt;

        public SurfJob(string commandText, string workingDirectory)
            : this(commandText, workingDirectory, "powershell.exe")
        {
        }

        public SurfJob(string commandText, string workingDirectory, string launcher)
        {
            CommandText = commandText;
            WorkingDirectory = workingDirectory;
            StartedAt = DateTime.Now;

            // -EncodedCommand sidesteps every quoting hazard. The prelude suppresses
            // progress records (redirected stderr would receive them as CLIXML noise);
            // the trailing statement propagates the native exit code, which
            // powershell.exe otherwise resets to 0.
            string script = "$ProgressPreference = 'SilentlyContinue'\r\n" + commandText +
                "\r\nif ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = launcher;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded;
            psi.WorkingDirectory = workingDirectory;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;
            psi.StandardOutputEncoding = new UTF8Encoding(false);
            psi.StandardErrorEncoding = new UTF8Encoding(false);
            psi.EnvironmentVariables["FORCE_COLOR"] = "1";

            _job = CreateJobObject(IntPtr.Zero, null);
            if (_job != IntPtr.Zero)
            {
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if (!SetInformationJobObject(_job, JobObjectExtendedLimitInformation,
                        ref info, Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                {
                    CloseHandle(_job);
                    _job = IntPtr.Zero;
                }
            }

            _proc = new Process();
            _proc.StartInfo = psi;
            try
            {
                _proc.Start();
            }
            catch
            {
                ReleaseJobHandle();
                throw;
            }

            // Residual race: children the wrapper spawns before this call escape the job.
            // powershell.exe needs hundreds of ms to even parse, so the window is
            // theoretical; a fully suspended start would require replacing Process.Start
            // with CreateProcessW(CREATE_SUSPENDED).
            if (_job != IntPtr.Zero)
            {
                try { _jobAttached = AssignProcessToJobObject(_job, _proc.Handle); }
                catch { _jobAttached = false; }
            }

            ProcessId = _proc.Id;
            _stdout = _proc.StandardOutput;
            _stderr = _proc.StandardError;

            // UTF-8 without BOM: a BOM would be delivered to the child as input bytes
            _stdin = new StreamWriter(_proc.StandardInput.BaseStream, new UTF8Encoding(false));
            _stdin.AutoFlush = true;

            Thread outThread = new Thread(new ThreadStart(ReadStdout));
            outThread.IsBackground = true;
            outThread.Name = "SurfJob stdout " + ProcessId;
            outThread.Start();

            Thread errThread = new Thread(new ThreadStart(ReadStderr));
            errThread.IsBackground = true;
            errThread.Name = "SurfJob stderr " + ProcessId;
            errThread.Start();
        }

        // ---- public read surface (all safe on exited/disposed instances) ----------

        public bool HasExited
        {
            get
            {
                try { return _proc.HasExited; }
                catch { return true; }
            }
        }

        /// <summary>Exited AND both reader threads have delivered the final output.</summary>
        public bool HasDrained
        {
            get { return HasExited && Thread.VolatileRead(ref _readersDone) >= 2; }
        }

        public int ExitCode
        {
            get
            {
                try { return _proc.ExitCode; }
                catch { return -1; }
            }
        }

        public long TotalLines
        {
            get { lock (_sync) { return _total; } }
        }

        public long FirstIndex
        {
            get { lock (_sync) { return _first; } }
        }

        /// <summary>The current unterminated output tail (e.g. a prompt), empty if none.</summary>
        public string PartialLine
        {
            get
            {
                lock (_sync)
                {
                    if (_partialOut.Length > 0) return _partialOut;
                    return _partialErr;
                }
            }
        }

        /// <summary>Newest output: the partial tail if present, else the last completed line.</summary>
        public string LastLine
        {
            get
            {
                lock (_sync)
                {
                    if (_partialOut.Length > 0) return _partialOut;
                    if (_partialErr.Length > 0) return _partialErr;
                    if (_total == _first) return "";
                    return _ring[(int)((_total - 1) % MaxLines)];
                }
            }
        }

        /// <summary>
        /// Completed lines from absolute index fromIndex to the newest. Indices below
        /// FirstIndex (evicted) are clamped; callers compare fromIndex to FirstIndex to
        /// render a "lines dropped" marker.
        /// </summary>
        public string[] SnapshotLines(long fromIndex)
        {
            lock (_sync)
            {
                long start = fromIndex < _first ? _first : fromIndex;
                if (start >= _total) return new string[0];
                int count = (int)(_total - start);
                string[] result = new string[count];
                for (int i = 0; i < count; i++)
                {
                    result[i] = _ring[(int)((start + i) % MaxLines)];
                }
                return result;
            }
        }

        // ---- input -----------------------------------------------------------------

        /// <summary>Send a line (plus newline) to the child's stdin. False if the child is gone.</summary>
        public bool WriteInputLine(string text)
        {
            return WriteInputRaw(text + "\n");
        }

        /// <summary>Send raw characters (no newline appended). False if the child is gone.</summary>
        public bool WriteInputRaw(string text)
        {
            if (_disposed || HasExited) return false;
            try
            {
                _stdin.Write(text);
                return true;
            }
            catch (IOException) { return false; }
            catch (ObjectDisposedException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        // ---- lifecycle ---------------------------------------------------------------

        /// <summary>Terminate the child and every descendant, atomically via the job. Idempotent.</summary>
        public void KillTree()
        {
            IntPtr job = _job;
            if (job != IntPtr.Zero && _jobAttached)
            {
                try { TerminateJobObject(job, 1); }
                catch { }
            }
            else
            {
                // job creation or assignment failed: best-effort tree kill via taskkill
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("taskkill", "/T /F /PID " + ProcessId);
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    Process killer = Process.Start(psi);
                    if (killer != null)
                    {
                        killer.WaitForExit(3000);
                        killer.Dispose();
                    }
                }
                catch { }
            }
            try
            {
                if (!_proc.HasExited) _proc.Kill();
            }
            catch { }
        }

        public void Dispose()
        {
            lock (_sync)
            {
                if (_disposed) return;
                _disposed = true;
            }
            try { _stdin.Close(); } catch { }
            try { _proc.Dispose(); } catch { }
            // closing the job handle fires kill-on-close, reaping any stragglers
            ReleaseJobHandle();
        }

        private void ReleaseJobHandle()
        {
            IntPtr job = Interlocked.Exchange(ref _job, IntPtr.Zero);
            if (job != IntPtr.Zero)
            {
                try { CloseHandle(job); } catch { }
            }
        }

        // ---- reader threads ------------------------------------------------------------

        private void ReadStdout()
        {
            try { ReadLoop(_stdout, false); } catch { }
        }

        private void ReadStderr()
        {
            try { ReadLoop(_stderr, true); } catch { }
        }

        private void ReadLoop(StreamReader reader, bool isErr)
        {
            // Never let an exception escape: on .NET Framework an unhandled exception on
            // this thread would terminate the whole PowerShell host.
            try
            {
                char[] buf = new char[4096];
                StringBuilder pending = new StringBuilder();
                bool sawCr = false;
                while (true)
                {
                    int n;
                    try { n = reader.Read(buf, 0, buf.Length); }
                    catch { break; }
                    if (n <= 0) break;

                    for (int i = 0; i < n; i++)
                    {
                        char c = buf[i];
                        if (c == '\n')
                        {
                            if (isErr)
                            {
                                if (_errSuppressLine) _errSuppressLine = false;
                                else AppendErrLine(pending.ToString());
                            }
                            else
                            {
                                AppendLine(pending.ToString());
                            }
                            pending.Length = 0;
                            sawCr = false;
                            continue;
                        }
                        if (sawCr)
                        {
                            // \r followed by anything but \n: a progress rewrite -
                            // replace the tail in place instead of flooding history
                            pending.Length = 0;
                            sawCr = false;
                        }
                        if (c == '\r')
                        {
                            sawCr = true;
                            continue;
                        }
                        if (_errSuppressLine && isErr) continue;   // discard the rest of an oversized CLIXML line
                        pending.Append(c);
                        if (pending.Length >= MaxLineLength)
                        {
                            if (isErr && IsClixmlStart(pending))
                            {
                                // an oversized CLIXML blob: drop it whole rather than
                                // letting raw XML fragments bypass the stderr filter
                                _errSuppressLine = true;
                            }
                            else if (isErr)
                            {
                                AppendErrLine(pending.ToString() + " ...");
                            }
                            else
                            {
                                AppendLine(pending.ToString() + " ...");
                            }
                            pending.Length = 0;
                        }
                    }
                    if (isErr && (IsClixmlStart(pending) || _errSuppressLine))
                    {
                        SetPartial(true, "");   // never expose raw CLIXML as the live tail
                    }
                    else
                    {
                        SetPartial(isErr, pending.ToString());
                    }
                }
                if (pending.Length > 0)
                {
                    if (isErr)
                    {
                        if (!_errSuppressLine) AppendErrLine(pending.ToString());
                    }
                    else
                    {
                        AppendLine(pending.ToString());
                    }
                }
                SetPartial(isErr, "");
            }
            catch { }
            finally
            {
                Interlocked.Increment(ref _readersDone);
            }
        }

        // powershell.exe serializes its own error/progress records to a redirected
        // stderr as CLIXML, always preceded by a '#< CLIXML' header line. Gating on
        // that header means a native tool that legitimately prints '<Objs ...' text
        // passes through untouched. Blobs are translated to their readable payload
        // (error/warning/verbose/debug stream text).
        private bool IsClixmlStart(StringBuilder pending)
        {
            if (pending.Length < 6) return false;
            string head = pending.ToString(0, Math.Min(pending.Length, 9));
            if (head.StartsWith("#< CLIXML", StringComparison.Ordinal)) return true;
            return _errClixmlSeen && head.StartsWith("<Objs", StringComparison.Ordinal);
        }

        private void AppendErrLine(string line)
        {
            if (line == null) return;
            if (line.StartsWith("#< CLIXML", StringComparison.Ordinal))
            {
                _errClixmlSeen = true;
                return;
            }
            if (_errClixmlSeen && line.StartsWith("<Objs ", StringComparison.Ordinal))
            {
                foreach (System.Text.RegularExpressions.Match m in
                    System.Text.RegularExpressions.Regex.Matches(line,
                        "<S S=\"(?:error|warning|verbose|debug|information)\">(.*?)</S>",
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                {
                    string text = m.Groups[1].Value
                        .Replace("_x000D__x000A_", " ")
                        .Replace("_x000A_", " ")
                        .Replace("_x000D_", "")
                        .Replace("&lt;", "<").Replace("&gt;", ">")
                        .Replace("&quot;", "\"").Replace("&apos;", "'")
                        .Replace("&amp;", "&")
                        .TrimEnd();
                    if (text.Length > 0)
                    {
                        AppendLine(text);
                    }
                }
                return;
            }
            AppendLine(line);
        }

        private void SetPartial(bool isErr, string value)
        {
            lock (_sync)
            {
                if (_disposed) return;
                if (isErr) _partialErr = value;
                else _partialOut = value;
            }
        }

        private void AppendLine(string line)
        {
            if (line == null) return;
            lock (_sync)
            {
                if (_disposed) return;
                int slot = (int)(_total % MaxLines);
                if (_total - _first >= MaxLines)
                {
                    string evicted = _ring[slot];
                    if (evicted != null) _bytes -= evicted.Length;
                    _first++;
                }
                _ring[slot] = line;
                _bytes += line.Length;
                _total++;
                while (_bytes > MaxBytes && _first < _total - 1)
                {
                    string old = _ring[(int)(_first % MaxLines)];
                    if (old != null) _bytes -= old.Length;
                    _first++;
                }
            }
        }

        // ---- Win32 -------------------------------------------------------------------

        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, int cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);
    }

    /// <summary>Console helpers for the attach view.</summary>
    public static class SurfConsole
    {
        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        /// <summary>Enable VT/ANSI rendering on the console. True if active afterwards.</summary>
        public static bool EnableVt()
        {
            try
            {
                IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
                uint mode;
                if (!GetConsoleMode(handle, out mode)) return false;
                if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) return true;
                return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            }
            catch
            {
                return false;
            }
        }
    }
}
