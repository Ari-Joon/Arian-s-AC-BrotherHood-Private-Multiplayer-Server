<#
  AC Brotherhood - patrol bot.

  Drives a REAL game client with synthetic hardware input. It is a genuine P2P
  peer, so it fills a lobby slot properly.

  IMPORTANT - run this on a SECOND machine (or VM). A second ACBMP.exe on the
  same PC collides on the single-instance lock, Steam, and the P2P ports.

  WHAT WORKS NOW
    - Scancode input via SendInput (the game ignores SendKeys/PostMessage).
    - Patrol routes with human-like timing jitter, hesitation and drift.
    - A behaviour state machine: PATROL -> SUSPICIOUS -> APPROACH -> CHASE.
    - Deliberate imperfection so it reads as a player, not a machine.

  WHAT NEEDS CALIBRATION (see Read-Compass)
    - Perception. The bot is meant to read the on-screen compass the same way a
      player does. The capture region and the needle/fill thresholds differ per
      resolution and HUD scale, so Read-Compass ships as a stub that returns
      $null until calibrated with -Calibrate.

  Usage:
    .\acb-bot.ps1 -Calibrate            # capture a HUD sample to measure from
    .\acb-bot.ps1 -DryRun               # print actions, send no input
    .\acb-bot.ps1                       # run for real
#>
param(
    [switch]$Calibrate,
    [switch]$DryRun,
    [int]$DurationMinutes = 30,
    [string]$RouteFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Input. Games read raw scancodes; window messages are ignored, so this uses
# SendInput with KEYEVENTF_SCANCODE.
# ---------------------------------------------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)]
public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)]
public struct INPUT { public uint type; public INPUTUNION u; }

public class Sim {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);

    const uint INPUT_KEYBOARD = 1, INPUT_MOUSE = 0;
    const uint KEYEVENTF_SCANCODE = 0x0008, KEYEVENTF_KEYUP = 0x0002;
    const uint MOUSEEVENTF_MOVE = 0x0001;

    public static void Key(ushort scan, bool down) {
        INPUT[] i = new INPUT[1];
        i[0].type = INPUT_KEYBOARD;
        i[0].u.ki.wScan = scan;
        i[0].u.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP);
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void MouseMove(int dx, int dy) {
        INPUT[] i = new INPUT[1];
        i[0].type = INPUT_MOUSE;
        i[0].u.mi.dx = dx; i[0].u.mi.dy = dy;
        i[0].u.mi.dwFlags = MOUSEEVENTF_MOVE;   // relative, as the camera expects
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

# Scancode set 1
$SC = @{ W=0x11; A=0x1E; S=0x1F; D=0x20; Space=0x39; Shift=0x2A; Ctrl=0x1D; E=0x12; Q=0x10; F=0x21 }

$script:Dry = $DryRun.IsPresent

function Hold-Key($name, $ms) {
    if ($script:Dry) { Write-Host ("  [dry] {0} for {1}ms" -f $name, $ms) -ForegroundColor DarkGray; Start-Sleep -Milliseconds ([Math]::Min($ms,120)); return }
    [Sim]::Key($SC[$name], $true)
    Start-Sleep -Milliseconds $ms
    [Sim]::Key($SC[$name], $false)
}
function Down-Key($name) { if (-not $script:Dry) { [Sim]::Key($SC[$name], $true) } }
function Up-Key($name)   { if (-not $script:Dry) { [Sim]::Key($SC[$name], $false) } }
function Turn($dx)       { if (-not $script:Dry) { [Sim]::MouseMove([int]$dx, 0) } else { Write-Host "  [dry] turn $dx" -ForegroundColor DarkGray } }

# ---------------------------------------------------------------------------
# Humanising. A bot that moves on exact intervals reads as a bot instantly;
# in this game that gets it killed, which is the point of the tells.
# ---------------------------------------------------------------------------
function Jitter([int]$ms, [double]$spread = 0.25) {
    $d = [int]($ms * $spread)
    return [Math]::Max(60, $ms + (Get-Random -Minimum (-$d) -Maximum $d))
}
function Maybe([double]$p) { return ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt $p) }

function Human-Pause {
    # Players stop to look around, get distracted, misjudge a corner.
    if (Maybe 0.18) {
        $t = Jitter 900 0.6
        Write-Host "  ...pausing ${t}ms (tell)" -ForegroundColor DarkYellow
        Start-Sleep -Milliseconds $t
    }
    if (Maybe 0.12) {
        $d = Get-Random -Minimum -220 -Maximum 220
        Write-Host "  ...glancing $d (tell)" -ForegroundColor DarkYellow
        Turn $d
        Start-Sleep -Milliseconds (Jitter 260)
    }
}

# ---------------------------------------------------------------------------
# Perception - reads the HUD the way a player does.
#
# NOT YET CALIBRATED. Run with -Calibrate while in a match: it saves a
# screenshot so the compass region and colours can be measured, then fill in
# $CompassRegion and the thresholds below.
# ---------------------------------------------------------------------------
[void][Sim]::SetProcessDPIAware()
$ScreenW = [Sim]::GetSystemMetrics(0)
$ScreenH = [Sim]::GetSystemMetrics(1)

# x, y, w, h - placeholder, centred lower-middle where the ACB compass sits.
$CompassRegion = @(([int]($ScreenW*0.42)), ([int]($ScreenH*0.80)), ([int]($ScreenW*0.16)), ([int]($ScreenH*0.14)))

function Capture-Region($r) {
    $bmp = New-Object System.Drawing.Bitmap($r[2], $r[3])
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r[0], $r[1], 0, 0, (New-Object System.Drawing.Size($r[2], $r[3])))
    $g.Dispose()
    return $bmp
}

function Read-Compass {
    <#
      Intended contract:
        returns @{ Bearing = <degrees, 0 = ahead>; Proximity = <0..1> }
        or $null when it cannot read the HUD.

      The compass encodes exactly what a player gets: direction to the assigned
      target, and closeness via the fill/pulse. Deliberately returns $null until
      calibrated rather than inventing readings.
    #>
    return $null
}

if ($Calibrate) {
    $bmp = Capture-Region $CompassRegion
    $out = Join-Path $PSScriptRoot "compass-sample.png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Host "Saved HUD sample: $out" -ForegroundColor Green
    Write-Host "Region tried: x=$($CompassRegion[0]) y=$($CompassRegion[1]) w=$($CompassRegion[2]) h=$($CompassRegion[3])"
    Write-Host "If the compass is not centred in that image, adjust `$CompassRegion and re-run."
    return
}

# ---------------------------------------------------------------------------
# Patrol route. Each leg: a direction, a duration, and an optional turn after.
# Kept to ground level - no parkour, by design.
# ---------------------------------------------------------------------------
$DefaultRoute = @(
    @{ Key='W'; Ms=2600; Turn=  90 },
    @{ Key='W'; Ms=1800; Turn=   0 },
    @{ Key='W'; Ms=2200; Turn= -90 },
    @{ Key='W'; Ms=3000; Turn= 180 },
    @{ Key='W'; Ms=2400; Turn= -90 },
    @{ Key='W'; Ms=1600; Turn=  90 }
)
$Route = $DefaultRoute
if ($RouteFile -and (Test-Path $RouteFile)) {
    $Route = Get-Content $RouteFile -Raw | ConvertFrom-Json
    Write-Host "Loaded route: $RouteFile ($($Route.Count) legs)"
}

# Degrees -> relative mouse counts. Sensitivity-dependent; tune after testing.
$TurnScale = 2.4

# ---------------------------------------------------------------------------
# Behaviour state machine
# ---------------------------------------------------------------------------
$State = 'PATROL'
$LastContact = $null

function Step-Patrol($leg) {
    Write-Host "[PATROL] forward $($leg.Ms)ms, then turn $($leg.Turn)deg"
    Hold-Key 'W' (Jitter $leg.Ms)
    Human-Pause
    if ($leg.Turn -ne 0) {
        # Turn in a few increments; humans do not snap to an exact angle.
        $total = [int]($leg.Turn * $TurnScale)
        $steps = Get-Random -Minimum 3 -Maximum 6
        for ($i = 0; $i -lt $steps; $i++) {
            Turn ([int]($total / $steps))
            Start-Sleep -Milliseconds (Jitter 45 0.5)
        }
        if (Maybe 0.3) { Turn ([int]((Get-Random -Minimum -18 -Maximum 18))) }  # overshoot
    }
}

function Step-Approach($c) {
    # Close the distance without sprinting - running is itself a tell in ACB.
    Write-Host "[APPROACH] bearing $($c.Bearing) proximity $([math]::Round($c.Proximity,2))"
    $correct = [int]($c.Bearing * $TurnScale)
    Turn $correct
    Start-Sleep -Milliseconds (Jitter 180)
    Hold-Key 'W' (Jitter 1400)
}

function Step-Chase($c) {
    # Sprint only when already committed. Sprinting broadcasts position.
    Write-Host "[CHASE] committed, sprinting" -ForegroundColor Red
    Down-Key 'Shift'
    Hold-Key 'W' (Jitter 1600)
    Up-Key 'Shift'
    if ($c.Proximity -gt 0.85) {
        Write-Host "  kill attempt" -ForegroundColor Red
        Hold-Key 'E' 120
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$fg = New-Object System.Text.StringBuilder 256
[void][Sim]::GetWindowText([Sim]::GetForegroundWindow(), $fg, 256)
if (-not $script:Dry -and $fg.ToString() -notmatch 'Assassin') {
    Write-Warning "Foreground window is '$($fg.ToString())', not the game."
    Write-Warning "Focus the game window within 5 seconds or input will go elsewhere."
    Start-Sleep -Seconds 5
}

Write-Host "patrol bot starting - $DurationMinutes min, dry-run=$($script:Dry)" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes($DurationMinutes)
$leg = 0

while ((Get-Date) -lt $deadline) {
    $contact = Read-Compass

    if ($null -eq $contact) {
        # No perception yet: patrol blindly. Still fills a slot and moves.
        $State = 'PATROL'
        Step-Patrol $Route[$leg % $Route.Count]
        $leg++
    }
    else {
        $LastContact = $contact
        if ($contact.Proximity -gt 0.75)      { $State = 'CHASE' }
        elseif ($contact.Proximity -gt 0.35)  { $State = 'APPROACH' }
        else                                  { $State = 'SUSPICIOUS' }

        switch ($State) {
            'CHASE'      { Step-Chase   $contact }
            'APPROACH'   { Step-Approach $contact }
            'SUSPICIOUS' {
                # Drift toward the bearing while behaving like a civilian.
                Write-Host "[SUSPICIOUS] drifting toward bearing $($contact.Bearing)"
                Turn ([int]($contact.Bearing * $TurnScale * 0.5))
                Hold-Key 'W' (Jitter 1100)
                Human-Pause
            }
        }
    }

    Start-Sleep -Milliseconds (Jitter 250)
}

Up-Key 'W'; Up-Key 'Shift'
Write-Host "patrol bot finished" -ForegroundColor Cyan
