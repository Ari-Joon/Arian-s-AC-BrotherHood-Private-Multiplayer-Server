// Stop Windows throttling a background game client.
//
// WHY THIS EXISTS
// A bot client that is not in the foreground dies within about a minute:
//
//     NOTIFICATION
//     Connection to Assassin's Creed Brotherhood server lost.
//     The game will now exit.
//
// The server log shows the matching side: a PING ACK, then silence, then
// TIMEOUT ~25 seconds later. Windows throttles background processes - timers
// are coalesced and execution speed is reduced - so the client stops sending
// PRUDP keepalives and the server drops it.
//
// Measured directly: backgrounded a bot dies inside 60 seconds; held in the
// foreground it survived 4 minutes unchanged. That is the whole difference.
//
// This clears PROCESS_POWER_THROTTLING_EXECUTION_SPEED and raises the priority
// class, so a background client keeps running at full speed. It does NOT touch
// the game's own "pause when unfocused" behaviour if it has any - if clients
// still drop after this, that is the next thing to look at rather than power
// throttling.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

class Program
{
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version, ControlMask, StateMask;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr h, int cls, ref PROCESS_POWER_THROTTLING_STATE s, int size);

    const int ProcessPowerThrottling = 4;
    const uint PROCESS_POWER_THROTTLING_CURRENT_VERSION = 1;
    const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1;
    const uint PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = 0x4;

    static int Main(string[] argv)
    {
        var targets = argv.Length > 0
            ? Array.ConvertAll(argv, a => Process.GetProcessById(int.Parse(a)))
            : Process.GetProcessesByName("ACBMP");
        if (targets.Length == 0) { Console.WriteLine("  no ACBMP processes"); return 1; }

        int ok = 0;
        foreach (var p in targets)
        {
            try
            {
                var s = new PROCESS_POWER_THROTTLING_STATE
                {
                    Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION,
                    // Control both bits, set neither: "explicitly do NOT throttle".
                    ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED |
                                  PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
                    StateMask = 0
                };
                bool r = SetProcessInformation(p.Handle, ProcessPowerThrottling, ref s,
                                               Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE)));
                if (!r) { Console.WriteLine($"  pid {p.Id}: {new Win32Exception().Message}"); continue; }
                p.PriorityClass = ProcessPriorityClass.High;
                Console.WriteLine($"  pid {p.Id}: throttling disabled, priority High");
                ok++;
            }
            catch (Exception ex) { Console.WriteLine($"  pid {p.Id}: {ex.Message}"); }
        }
        Console.WriteLine($"  {ok} of {targets.Length} client(s) unthrottled");
        return ok > 0 ? 0 : 1;
    }
}
