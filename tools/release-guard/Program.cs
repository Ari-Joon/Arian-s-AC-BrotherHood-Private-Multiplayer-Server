// Release the engine's single-instance guard so more than one client can run
// in the same Windows session.
//
// WHAT THE GUARD ACTUALLY IS
// ACBMP.exe holds a named semaphore:
//
//     \Sessions\<n>\BaseNamedObjects\scimitar_semaphore
//
// Scimitar is Ubisoft's codename for the Anvil engine. A second client sees it
// already exists and exits after about five seconds with code 0 - a clean exit,
// which is why it reads as "the game refuses to start" rather than an error.
//
// Releasing that handle in the RUNNING client lets the next one start normally.
// Nothing on disk is touched: no patching, no modified executable, no DRM
// involved. The guard is a convenience check on a game the user owns, being
// used against their own private server. It has to be released again after
// each client starts, because each new client creates the semaphore itself.
//
// HOW IT WAS FOUND, since three sessions guessed wrong first
//   - "port collision" was disproved: binding 12000/12001 and launching a
//     SINGLE client works fine.
//   - "renamed executable" was disproved: a copied exe is refused identically.
//   - "no named objects exist" came from checking CreateMutexA/CreateSemaphoreA
//     call sites for a name argument and finding none. The object is there
//     regardless - enumerating the live process's handle table shows it. The
//     name is not a static string in the binary.
// The lesson worth keeping: read the running process, do not infer the
// mechanism from imports.
//
// USAGE
//   dotnet run --project tools/release-guard -- <pid>                 list
//   dotnet run --project tools/release-guard -- <pid> --close scimitar  release
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

class Program
{
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int need);
    [DllImport("ntdll.dll")]
    static extern int NtQueryObject(IntPtr h, int cls, IntPtr buf, int len, out int need);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr sp, IntPtr sh, IntPtr tp, out IntPtr th,
                                       int access, bool inherit, int opts);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern int ProcessIdToSessionId(int pid, out int sid);

    const int SystemExtendedHandleInformation = 64;
    const int ObjectNameInformation = 1, ObjectTypeInformation = 2;
    const int PROCESS_DUP_HANDLE = 0x0040;
    const int DUPLICATE_SAME_ACCESS = 0x0002, DUPLICATE_CLOSE_SOURCE = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    struct HANDLE_ENTRY
    {
        public IntPtr Object;
        public IntPtr UniqueProcessId;
        public IntPtr HandleValue;
        public uint GrantedAccess;
        public ushort CreatorBackTraceIndex;
        public ushort ObjectTypeIndex;
        public uint HandleAttributes;
        public uint Reserved;
    }

    static string Query(IntPtr h, int cls)
    {
        IntPtr buf = Marshal.AllocHGlobal(4096);
        try
        {
            int need;
            if (NtQueryObject(h, cls, buf, 4096, out need) != 0) return null;
            ushort len = (ushort)Marshal.ReadInt16(buf);          // UNICODE_STRING
            IntPtr p = Marshal.ReadIntPtr(buf, IntPtr.Size);
            return (len == 0 || p == IntPtr.Zero) ? null : Marshal.PtrToStringUni(p, len / 2);
        }
        catch { return null; }
        finally { Marshal.FreeHGlobal(buf); }
    }

    static int Main(string[] argv)
    {
        if (argv.Length < 1)
        {
            Console.WriteLine("usage: release-guard <pid> [--close <name-substring>] [--quiet]");
            return 2;
        }
        if (!int.TryParse(argv[0], out int pid)) { Console.WriteLine("bad pid"); return 2; }
        bool quiet = Array.IndexOf(argv, "--quiet") >= 0;
        string match = null;
        for (int k = 1; k < argv.Length - 1; k++)
            if (argv[k] == "--close") match = argv[k + 1];

        ProcessIdToSessionId(pid, out int sid);
        IntPtr proc = OpenProcess(PROCESS_DUP_HANDLE, false, pid);
        if (proc == IntPtr.Zero)
        {
            Console.WriteLine("cannot open process " + pid + ": " + new Win32Exception().Message);
            return 1;
        }

        int size = 1 << 22;
        IntPtr buf = Marshal.AllocHGlobal(size);
        while (NtQuerySystemInformation(SystemExtendedHandleInformation, buf, size, out _) != 0)
        {
            Marshal.FreeHGlobal(buf);
            size *= 2;
            if (size > (1 << 28)) { Console.WriteLine("handle table too large"); return 1; }
            buf = Marshal.AllocHGlobal(size);
        }

        long count = Marshal.ReadIntPtr(buf).ToInt64();
        int step = Marshal.SizeOf(typeof(HANDLE_ENTRY));
        IntPtr basePtr = buf + IntPtr.Size * 2;
        int released = 0, seen = 0;

        for (long i = 0; i < count; i++)
        {
            var e = Marshal.PtrToStructure<HANDLE_ENTRY>(basePtr + (int)(i * step));
            if (e.UniqueProcessId.ToInt32() != pid) continue;
            if (!DuplicateHandle(proc, e.HandleValue, GetCurrentProcess(), out IntPtr dup,
                                 0, false, DUPLICATE_SAME_ACCESS)) continue;
            try
            {
                string type = Query(dup, ObjectTypeInformation);
                if (type != "Mutant" && type != "Semaphore" && type != "Event") continue;
                string name = Query(dup, ObjectNameInformation);
                if (string.IsNullOrEmpty(name)) continue;
                seen++;
                bool hit = match != null &&
                           name.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0;
                if (!quiet || hit)
                    Console.WriteLine($"  {type,-10} {name}{(hit ? "   <-- releasing" : "")}");
                if (hit)
                {
                    if (DuplicateHandle(proc, e.HandleValue, GetCurrentProcess(), out IntPtr scratch,
                                        0, false, DUPLICATE_CLOSE_SOURCE))
                    { CloseHandle(scratch); Console.WriteLine("             released"); released++; }
                    else Console.WriteLine("             failed: " + new Win32Exception().Message);
                }
            }
            finally { CloseHandle(dup); }
        }
        CloseHandle(proc);
        Console.WriteLine($"  pid {pid} (session {sid}): {seen} named objects, {released} released");
        // Non-zero when asked to release and nothing matched, so a caller can tell
        // "guard cleared" from "guard not found" instead of assuming success.
        return (match != null && released == 0) ? 1 : 0;
    }
}
