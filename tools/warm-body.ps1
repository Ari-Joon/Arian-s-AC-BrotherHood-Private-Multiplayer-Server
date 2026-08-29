<#
  Put a warm body in a multiplayer match.

  WHY THIS EXISTS
  Ability challenges ("use a disguise to escape your pursuers") only score
  during a live match. They need another player present - not a good one. The
  game assigns contracts itself, so a bot that logs in, joins and moves around
  is enough to generate the situations a challenge scores.

  That is a far lower bar than tools/bot_vm.py aims at. This does NOT identify
  targets, does not read the screen, and makes no decisions. It logs in, walks
  a menu macro, then wanders. Everything it needs is already proven:
  onlineUser/onlinePassword are confirmed working switches, and the input layer
  is the same SendInput/scancode approach as tools/acb-bot.ps1.

  MULTIPLE CLIENTS ON ONE PC - SOLVED
  The engine holds a named semaphore, \Sessions\<n>\BaseNamedObjects  scimitar_semaphore, and a second client sees it and exits after ~5s with
  code 0 - a clean exit, which is why it reads as "the game will not start"
  rather than an error. Releasing that handle in the running client lets the
  next one start. This script does that between launches, so N bots run in ONE
  Windows session with no user switching.

  Nothing on disk is patched. The handle has to be released again after every
  launch, because each new client creates the semaphore itself.

  WHAT IS AND IS NOT VERIFIED
  Verified: account creation, the launch switches, the input layer, and two
  clients running concurrently in one session, both authenticated.
  NOT verified: the menu macro. The keypresses needed to reach a match cannot
  be worked out without watching it, so the macro is data-driven (-Macro) and
  ships uncalibrated rather than hard-coded to look tested.

  FOCUS. SendInput goes to whatever window has focus, so this brings the
  target instance to the front before every burst. While bots are running you
  cannot use the machine for anything else - that is inherent to driving a game
  through synthetic input, not a limitation of this script.

  USAGE
    .\warm-body.ps1 -Count 2 -DryRun
    .\warm-body.ps1 -Count 2
    .\warm-body.ps1 -Count 1 -Name Ruffiano -Macro .\tools\join-match.macro
    .\warm-body.ps1 -Stop
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 6)]
    [int]$Count = 1,

    # Base name; bots become <Name>1, <Name>2 ... Accounts are created if absent.
    [Parameter(ParameterSetName = 'Run')]
    [string]$Name = 'Bot',

    # Steps to walk from the title screen into a match. See join-match.macro.
    [Parameter(ParameterSetName = 'Run')]
    [string]$Macro,

    # Seconds to wander once in a match. 0 = until stopped.
    [Parameter(ParameterSetName = 'Run')]
    [int]$Duration = 0,

    # Bots are never looked at, so render as little as possible. All clients on
    # one Windows account share Saved Games\ACBrotherhood.ini, so per-client
    # graphics can ONLY come from the command line - changing the INI would
    # change the human player's settings too.
    [Parameter(ParameterSetName = 'Run')]
    [switch]$FullQuality,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$DryRun,

    # Kill every bot instance this script started.
    [Parameter(ParameterSetName = 'Stop')]
    [switch]$Stop,

    # How long to wait for a client to finish LOGGING IN before starting the
    # next one. Waiting on a window handle is not enough - see the launch loop.
    [Parameter(ParameterSetName = 'Run')]
    [int]$ReadySeconds = 120,

    # Extra pause after a client is ready, before the next is launched. Startup
    # continues briefly after login, and overlapping that is what races ports.
    [Parameter(ParameterSetName = 'Run')]
    [int]$SettleSeconds = 8,

    # The server's log. Used to detect a completed login; a client's account
    # name only appears here once it holds a PRUDP session.
    [string]$ServerLog,

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'
$exe      = Join-Path $GamePath "ACBMP.exe"
$pidFile  = Join-Path $env:TEMP "acb-warmbody.pids"
$addUser  = Join-Path $PSScriptRoot "add-player.ps1"
$db       = Join-Path $PSScriptRoot "..\ACB RDV\bin\x86\Release\database.sqlite"

# ---------------------------------------------------------------------------
# Win32: scancode input, and focusing a specific instance.
# ---------------------------------------------------------------------------
if (-not ("WB" -as [type])) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)]
public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)]
public struct INPUT { public uint type; public INPUTUNION u; }

public class WB {
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    const uint KEYBOARD = 1, MOUSE = 0;
    const uint SCANCODE = 0x0008, KEYUP = 0x0002, EXTENDED = 0x0001;
    const uint MOVE = 0x0001;

    public static void Key(ushort scan, bool down, bool extended) {
        INPUT[] i = new INPUT[1];
        i[0].type = KEYBOARD;
        i[0].u.ki.wScan = scan;
        i[0].u.ki.dwFlags = SCANCODE | (down ? 0 : KEYUP) | (extended ? EXTENDED : 0);
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Move(int dx, int dy) {
        INPUT[] i = new INPUT[1];
        i[0].type = MOUSE;
        i[0].u.mi.dx = dx; i[0].u.mi.dy = dy;
        i[0].u.mi.dwFlags = MOVE;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
    public static bool Focus(IntPtr h) { ShowWindow(h, 9); return SetForegroundWindow(h); }
}
"@
}

# Scancode set 1. Extended keys (arrows) need the extended flag or the game
# reads them as the numeric keypad.
$SC = @{
    W=@(0x11,$false); A=@(0x1E,$false); S=@(0x1F,$false); D=@(0x20,$false)
    Space=@(0x39,$false); Shift=@(0x2A,$false); Ctrl=@(0x1D,$false)
    E=@(0x12,$false); Q=@(0x10,$false); F=@(0x21,$false); Esc=@(0x01,$false)
    Enter=@(0x1C,$false); Tab=@(0x0F,$false)
    Up=@(0x48,$true); Down=@(0x50,$true); Left=@(0x4B,$true); Right=@(0x4D,$true)
}

function Send-Key([string]$key, [int]$holdMs = 60) {
    if (-not $SC.ContainsKey($key)) { Write-Host "   unknown key '$key'" -ForegroundColor Yellow; return }
    $scan, $ext = $SC[$key]
    if ($DryRun) { Write-Host ("   [dry] {0} {1}ms" -f $key, $holdMs) -ForegroundColor DarkGray; return }
    [WB]::Key($scan, $true, $ext)
    Start-Sleep -Milliseconds $holdMs
    [WB]::Key($scan, $false, $ext)
}

function Focus-Bot($proc) {
    if ($DryRun) { return $true }
    $proc.Refresh()
    if ($proc.MainWindowHandle -eq 0) { return $false }
    [void][WB]::Focus($proc.MainWindowHandle)
    Start-Sleep -Milliseconds 250
    return $true
}

# ---------------------------------------------------------------------------
if ($Stop) {
    if (-not (Test-Path $pidFile)) { Write-Host "No bots recorded."; exit 0 }
    foreach ($line in Get-Content $pidFile) {
        $id = ($line -split ',')[0]
        try { Stop-Process -Id ([int]$id) -Force -ErrorAction Stop; Write-Host "  stopped pid $id" }
        catch { Write-Host "  pid $id already gone" -ForegroundColor DarkGray }
    }
    Remove-Item $pidFile -Force
    exit 0
}

if (-not (Test-Path $exe)) { Write-Host "ACBMP.exe not found at $exe" -ForegroundColor Red; exit 1 }

# --- accounts --------------------------------------------------------------
# Passwords are plaintext in this protocol, so these are throwaways by design.
$accounts = @()
for ($i = 1; $i -le $Count; $i++) {
    $bot = "$Name$i"
    $pw = $null
    if (Test-Path $db) {
        $row = sqlite3 "$db" "SELECT password FROM users WHERE name='$bot';" 2>$null
        if ($row) { $pw = $row.Trim() }
    }
    if (-not $pw) {
        if ($DryRun) { $pw = 'dryrun'; Write-Host "   [dry] would create account $bot" -ForegroundColor DarkGray }
        else {
            Write-Host "  creating account $bot"
            & powershell -NoProfile -File $addUser -Name $bot | Out-Null
            $row = sqlite3 "$db" "SELECT password FROM users WHERE name='$bot';" 2>$null
            $pw = if ($row) { $row.Trim() } else { $null }
        }
    }
    if (-not $pw) { Write-Host "  could not provision $bot" -ForegroundColor Red; exit 1 }
    $accounts += [pscustomobject]@{ Name = $bot; Password = $pw }
}
Write-Host ""
$accounts | ForEach-Object { Write-Host ("  account  {0}" -f $_.Name) -ForegroundColor Green }

# --- macro -----------------------------------------------------------------
# Lines of: <key> <holdMs> <waitMs> [# comment]. Blank lines and # ignored.
$steps = @()
if ($Macro) {
    if (-not (Test-Path $Macro)) { Write-Host "macro not found: $Macro" -ForegroundColor Red; exit 1 }
    foreach ($l in Get-Content $Macro) {
        $t = $l.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $p = $t -split '\s+'
        $steps += [pscustomobject]@{ Key = $p[0]; Hold = [int]$p[1]; Wait = [int]$p[2] }
    }
    Write-Host ("  macro    {0} steps from {1}" -f $steps.Count, (Split-Path $Macro -Leaf))
} else {
    Write-Host "  macro    none supplied - bots will sit at whatever screen they land on" -ForegroundColor Yellow
    Write-Host "           (see tools/join-match.macro; it needs calibrating against your menus)" -ForegroundColor Yellow
}

# --- launch ----------------------------------------------------------------
$procs = @()
# release-guard lives beside this script. $guardProj was previously USED but
# never assigned, so "dotnet run --project" got an empty path and failed every
# time - which is why only the first bot ever started. The failure was quiet:
# the guard went unreleased, and the next client then exited cleanly with code
# 0 as though the game simply refused to run.
$guardRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$guardProj = Join-Path $guardRoot 'release-guard'
if (-not (Test-Path (Join-Path $guardProj 'release-guard.csproj'))) {
    Write-Host "  release-guard not found at $guardProj" -ForegroundColor Red
    Write-Host "  more than one client cannot be launched without it." -ForegroundColor Yellow
}
elseif (-not $DryRun) {
    # Build once here so the per-client retries can use --no-build and stay fast.
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & dotnet build $guardProj -v q --nologo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  release-guard failed to build" -ForegroundColor Yellow }
    $ErrorActionPreference = $prevEAP
}

if (-not $ServerLog) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ServerLog = Join-Path $root '..\ACB RDV\bin\x86\Release\log.txt'
}

# A stopped server is indistinguishable from a broken client if you are only
# watching the game window: clients start, sit there, and quietly exit. An hour
# of test results was thrown away to this, so it is checked up front.
if (-not (Get-Process ACBRDV -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  The server (ACBRDV.exe) is NOT running." -ForegroundColor Red
    Write-Host "  Bots will start, fail to log in, and exit. Start it first." -ForegroundColor Yellow
    if (-not $DryRun) { exit 1 }
}
$useLog = Test-Path $ServerLog
if (-not $useLog) {
    Write-Host "  server log not found at $ServerLog" -ForegroundColor DarkYellow
    Write-Host "  falling back to a fixed wait between launches" -ForegroundColor DarkYellow
}

if ($accounts.Count -gt 1) {
    Write-Host ""
    Write-Host "  NOTE: on one PC only ONE client will survive." -ForegroundColor Yellow
    Write-Host "  The first client binds UDP 7917/12000/12001 and every client after" -ForegroundColor DarkGray
    Write-Host "  it dies with 0xC0000005. Tested at 6s and 120s spacing alike." -ForegroundColor DarkGray
    Write-Host "  Bots need their own network stack - a VM or a second PC." -ForegroundColor DarkGray
}

$index = 0
foreach ($a in $accounts) {
    # Explicit index: deriving it from $procs.Count silently collapses to 0 for
    # every bot on a dry run, where nothing is added to $procs.
    $args = @("/onlineUser:$($a.Name)", "/onlinePassword:$($a.Password)", "/userindex:$index")
    $index++
    if (-not $FullQuality) {
        # Values are from the game's own argument table: off|on|force|default|
        # normal|full, with msaa taking none|2x|4x|6x|8x instead.
        # MEASURED AND IT DOES NOT HELP AT A MENU. A low-spec bot sat at 391 MB
        # against 374-380 MB for full-quality clients - no saving, because a
        # menu renders almost nothing either way. These may pay off inside a
        # match, where there is a world to draw, but that is UNTESTED and should
        # not be claimed. Kept because it costs nothing and is the only
        # per-client route, since all clients share one INI.
        #
        # The measure that does work is minimising the window: a minimised DX9
        # window stops presenting frames, so the GPU stops drawing it.
        $args += @(
            "/shadows:off",       # shadow maps
            "/postfx:off",        # post-processing chain
            "/msaa:none",         # anti-aliasing
            "/skipmips:force",    # load only small mips: the big texture saving
            "/skipmipscharacter:force",
            "/skipmipsenvironment:force",
            "/skipao:on",         # no ambient occlusion computation
            "/nofogofwar"
        )
    }
    Write-Host ""
    Write-Host ("  launching {0}{1}" -f $a.Name, $(if ($FullQuality) { "  (full quality)" } else { "  (low spec)" })) -ForegroundColor Cyan
    Write-Verbose ($args -join ' ')
    if ($DryRun) { continue }
    $p = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $GamePath -PassThru
    $procs += $p
    "$($p.Id),$($a.Name)" | Add-Content $pidFile
    # WAIT FOR LOGIN, NOT FOR A WINDOW.
    # This used to break out as soon as MainWindowHandle became non-zero. That
    # handle appears at the SPLASH screen, long before the client has
    # authenticated or bound its UDP ports, so the next client was routinely
    # launched into the middle of the previous one's startup and the two raced
    # for the fixed port set. Inconsistent bot behaviour traced back to here.
    #
    # The reliable signal is the server: an account name is only tagged in the
    # log once that client holds a PRUDP session, i.e. it is really logged in.
    $logMark = if ($useLog) { (Get-Item $ServerLog).Length } else { 0 }
    $ready = $false
    $seenInLog = $false
    # The set a match needs. A client that holds none of these is not up yet.
    $fixedPorts = @(7917, 9100, 12000, 12001)
    for ($w = 1; $w -le $ReadySeconds; $w++) {
        Start-Sleep -Seconds 1
        $p.Refresh()
        if ($p.HasExited) {
            Write-Host "   exited during startup (exit $($p.ExitCode))" -ForegroundColor Red
            break
        }
        if ($useLog) {
            # Read only what is new; the log reaches hundreds of thousands of
            # lines in a session and re-reading it every second is not free.
            try {
                $fs = [System.IO.File]::Open($ServerLog, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -lt $logMark) { $logMark = 0 }   # server restarted, log truncated
                    [void]$fs.Seek($logMark, 'Begin')
                    $sr = New-Object System.IO.StreamReader($fs)
                    $fresh = $sr.ReadToEnd()
                } finally { $fs.Dispose() }
                if ($fresh -match [regex]::Escape("[$($a.Name)]")) { $seenInLog = $true }
            }
            catch { }   # the server holds the log open; a failed read just retries

            # The log tag appears at the first PRUDP handshake, which is only
            # seconds in - well before the client has bound the fixed UDP
            # ports. Those ports are the contended resource, so waiting on the
            # tag alone still lets the next client race for them. Require both.
            if ($seenInLog) {
                $bound = @(Get-NetUDPEndpoint -OwningProcess $p.Id -ErrorAction SilentlyContinue |
                           Where-Object { $fixedPorts -contains $_.LocalPort })
                if ($bound.Count) {
                    Write-Host ("   ready after {0}s (session up, holds {1})" -f $w, (($bound.LocalPort | Sort-Object) -join ', ')) -ForegroundColor DarkGray
                    $ready = $true
                    break
                }
            }
        }
        elseif ($p.MainWindowHandle -ne 0 -and $w -ge 45) {
            # No log to watch, so fall back to a window plus a generous fixed
            # wait. Slower than necessary, but it does not race.
            Write-Host "   window up, waited ${w}s (no log to confirm login)" -ForegroundColor DarkGray
            $ready = $true
            break
        }
    }
    if (-not $p.HasExited -and -not $ready) {
        Write-Host "   never confirmed logged in after ${ReadySeconds}s - continuing anyway" -ForegroundColor Yellow
        Write-Host "   if the next client misbehaves, this is why" -ForegroundColor DarkGray
    }
    # Let startup finish before anything else touches the ports.
    if (-not $p.HasExited -and $index -lt $accounts.Count -and $SettleSeconds -gt 0) {
        Start-Sleep -Seconds $SettleSeconds
    }
    # Release this client's single-instance guard so the NEXT one can start.
    # Must happen after it is up, since the semaphore is created during startup.
    if (-not $p.HasExited -and $index -lt $accounts.Count) {
        # $ErrorActionPreference is 'Stop', which turns ANY native command's
        # stderr into a terminating error. dotnet writes build noise there, so
        # this killed the run before the second bot was ever launched - the
        # same trap that once aborted a 69-item batch after 7. Relax it just
        # around the call and judge the result by the exit code instead.
        # RETRY UNTIL IT EXISTS. The semaphore is created part-way through
        # engine startup, so a client that is merely running does not have one
        # yet - releasing at 3s finds nothing and reports success-by-omission,
        # and the next client then exits cleanly with code 0 because the guard
        # it collides with was created a moment later.
        #
        # Retrying until the release actually succeeds is the readiness signal
        # that matters: it is precisely the condition the next launch needs.
        # Port binding happens within seconds and the server log tag appears at
        # the first handshake, so neither of those tells you this.
        #
        # $ErrorActionPreference is 'Stop', which turns ANY native command's
        # stderr into a terminating error, and dotnet writes build noise there.
        # That aborted the run before the second bot launched - the same trap
        # that once killed a 69-item batch after 7. Relax it around the call
        # and judge by the exit code.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $guardCode = 1
        $waited = 0
        while ($guardCode -ne 0 -and $waited -lt $ReadySeconds) {
            $p.Refresh()
            if ($p.HasExited) { break }
            $out = & dotnet run --project $guardProj --no-build -- $p.Id --close scimitar_semaphore --quiet 2>&1
            $guardCode = $LASTEXITCODE
            if ($guardCode -ne 0) { Start-Sleep -Seconds 3; $waited += 3 }
        }
        $ErrorActionPreference = $prevEAP
        if ($guardCode -eq 0) { Write-Host "   guard released after ${waited}s" -ForegroundColor DarkGray }
        else { Write-Host "   guard NOT released after ${waited}s - the next client will refuse to start" -ForegroundColor Yellow
               $out | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray } }
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run - nothing launched." -ForegroundColor Yellow
    exit 0
}

$live = $procs | Where-Object { -not $_.HasExited }
if (-not $live) { Write-Host "`nNo instance survived startup." -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host ("  {0} of {1} instance(s) running" -f $live.Count, $procs.Count) -ForegroundColor Green

# --- walk the menus --------------------------------------------------------
if ($steps.Count) {
    foreach ($p in $live) {
        Write-Host ""
        Write-Host ("  running macro on pid {0}" -f $p.Id) -ForegroundColor Cyan
        if (-not (Focus-Bot $p)) { Write-Host "   no window to focus, skipping" -ForegroundColor Yellow; continue }
        foreach ($s in $steps) {
            Send-Key $s.Key $s.Hold
            Start-Sleep -Milliseconds $s.Wait
        }
    }
}

# --- wander ----------------------------------------------------------------
# Not pathfinding. Enough movement that the body is not obviously parked, which
# is all a challenge situation needs.
Write-Host ""
Write-Host "  wandering. Ctrl-C to stop, or run with -Stop from another shell." -ForegroundColor Cyan
$rng = [Random]::new()
$deadline = if ($Duration -gt 0) { (Get-Date).AddSeconds($Duration) } else { [datetime]::MaxValue }
try {
    while ((Get-Date) -lt $deadline) {
        foreach ($p in $live) {
            $p.Refresh()
            if ($p.HasExited) { continue }
            if (-not (Focus-Bot $p)) { continue }
            [WB]::Move($rng.Next(-180, 180), 0)
            Send-Key 'W' $rng.Next(500, 1400)
            if ($rng.NextDouble() -lt 0.25) { Send-Key 'Space' 90 }
            Start-Sleep -Milliseconds $rng.Next(300, 900)
        }
        if (-not ($live | Where-Object { -not $_.HasExited })) {
            Write-Host "  all instances exited." -ForegroundColor Yellow
            break
        }
    }
}
finally {
    Write-Host ""
    Write-Host "  bots still running; stop them with:  .\tools\warm-body.ps1 -Stop" -ForegroundColor DarkGray
}
