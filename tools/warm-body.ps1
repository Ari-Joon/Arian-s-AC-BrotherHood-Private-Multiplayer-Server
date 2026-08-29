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
    # Wait for a window before starting the next; two clients racing through
    # startup is the likeliest way this falls over.
    for ($w = 0; $w -lt 60; $w++) {
        Start-Sleep -Seconds 1
        $p.Refresh()
        if ($p.HasExited) { Write-Host "   exited during startup (exit $($p.ExitCode))" -ForegroundColor Red; break }
        if ($p.MainWindowHandle -ne 0) { Write-Host "   window up after ${w}s" -ForegroundColor DarkGray; break }
    }
    # Release this client's single-instance guard so the NEXT one can start.
    # Must happen after it is up, since the semaphore is created during startup.
    if (-not $p.HasExited -and $index -lt $accounts.Count) {
        $out = & dotnet run --project $guardProj --no-build -- $p.Id --close scimitar --quiet 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "   guard released" -ForegroundColor DarkGray }
        else { Write-Host "   guard NOT released - the next client will refuse to start" -ForegroundColor Yellow
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
