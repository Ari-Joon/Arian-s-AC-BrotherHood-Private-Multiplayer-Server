<#
  Make bot clients accept party invitations automatically.

  WHY THIS IS THE RIGHT SHAPE
  The invite already reaches the bot. Traced through the server:
  GameSessionService case 12 (SendInvitation) checks whether the invitee is
  online - if they are, it sends a LIVE notification via
  NotificationManager.GameInviteSent and deliberately does NOT write to
  game_invites. That is why the table is empty and why GetInvitationsReceived
  returns 0 invite(s): correct behaviour, not a bug.

  So a bot does not need to navigate menus to be invited. It needs to press
  ACCEPT when the prompt appears. That is a far smaller problem than a full
  menu macro, and it is what this does.

  HOW IT WORKS
  Cycles each bot window to the foreground and sends the accept key. If a
  prompt is up it is accepted; if not, the keypress lands harmlessly on a menu.
  Blind pressing is deliberate - reading the screen to detect the prompt would
  need template matching that has never been calibrated, and a bot that
  hallucinates a prompt is worse than one that presses a key nobody asked for.

  FOCUS IS EXCLUSIVE. SendInput goes to whichever window has focus, so this
  steals focus for a fraction of a second per bot per cycle. While it runs you
  cannot comfortably use the machine for anything else. That is inherent to
  driving a game through synthetic input, not a flaw in this script. Use
  -IntervalSeconds to trade responsiveness against how often it interrupts you.

  USAGE
    .\bot-autoaccept.ps1                       every bot except your own account
    .\bot-autoaccept.ps1 -IntervalSeconds 5
    .\bot-autoaccept.ps1 -Keys Enter,Space     if your accept key differs
    .\bot-autoaccept.ps1 -DryRun               show what it would press

  Ctrl-C to stop.
#>
param(
    # Your own account - its client is never touched, so your input is safe.
    [string]$MyAccount = 'JubblyJoon',

    # How often to sweep the bots. Longer = less focus stealing.
    [int]$IntervalSeconds = 8,

    # Keys tried on each sweep. Enter is the usual accept; Space is a common
    # alternative and E is the game's generic confirm on keyboard.
    [string[]]$Keys = @('Enter', 'Space'),

    [int]$Minutes = 0,          # 0 = until Ctrl-C

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not ("AA" -as [type])) {
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
public class AA {
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  const uint KEYBOARD = 1, SCANCODE = 0x0008, KEYUP = 0x0002, EXTENDED = 0x0001;
  public static void Key(ushort scan, bool down, bool ext) {
    INPUT[] i = new INPUT[1];
    i[0].type = KEYBOARD;
    i[0].u.ki.wScan = scan;
    i[0].u.ki.dwFlags = SCANCODE | (down ? 0 : KEYUP) | (ext ? EXTENDED : 0);
    SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
  }
  public static bool Focus(IntPtr h) { ShowWindow(h, 9); return SetForegroundWindow(h); }
}
"@
}

# Scancode set 1; arrows are extended or the game reads them as the keypad.
$SC = @{
    Enter=@(0x1C,$false); Space=@(0x39,$false); E=@(0x12,$false)
    Esc=@(0x01,$false);   Up=@(0x48,$true);     Down=@(0x50,$true)
}

function Press([string]$k) {
    if (-not $SC.ContainsKey($k)) { return }
    $scan, $ext = $SC[$k]
    if ($DryRun) { Write-Host "      [dry] $k" -ForegroundColor DarkGray; return }
    [AA]::Key($scan, $true, $ext)
    Start-Sleep -Milliseconds 70
    [AA]::Key($scan, $false, $ext)
    Start-Sleep -Milliseconds 220
}

# Which client belongs to which account, from the pid file warm-body.ps1 writes.
$pidFile = Join-Path $env:TEMP "acb-warmbody.pids"
$owners = @{}
if (Test-Path $pidFile) {
    foreach ($line in Get-Content $pidFile) {
        $parts = $line -split ','
        if ($parts.Count -ge 2) { $owners[[int]$parts[0]] = $parts[1] }
    }
}

Write-Host ""
Write-Host "  accept keys : $($Keys -join ', ')"
Write-Host "  interval    : ${IntervalSeconds}s"
Write-Host "  never touched: $MyAccount"
Write-Host "  Ctrl-C to stop." -ForegroundColor DarkGray
Write-Host ""

$deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { [datetime]::MaxValue }
$mine = $null

while ((Get-Date) -lt $deadline) {
    $clients = @(Get-Process ACBMP -ErrorAction SilentlyContinue |
                 Where-Object { $_.MainWindowHandle -ne 0 })
    if (-not $clients) { Write-Host "  no clients running"; Start-Sleep -Seconds $IntervalSeconds; continue }

    # Remember which window was yours so focus can be handed back.
    if (-not $DryRun) { $mine = [AA]::GetForegroundWindow() }

    foreach ($c in $clients) {
        $who = if ($owners.ContainsKey($c.Id)) { $owners[$c.Id] } else { "pid $($c.Id)" }
        if ($who -eq $MyAccount) { continue }          # never drive the human's client
        Write-Host ("  {0:HH:mm:ss}  {1}" -f (Get-Date), $who)
        if (-not $DryRun) {
            if (-not [AA]::Focus($c.MainWindowHandle)) { Write-Host "      could not focus" -ForegroundColor DarkYellow; continue }
            Start-Sleep -Milliseconds 300
        }
        foreach ($k in $Keys) { Press $k }
    }

    # Give the foreground back, so the machine stays usable between sweeps.
    if (-not $DryRun -and $mine -ne [IntPtr]::Zero) { [void][AA]::Focus($mine) }
    Start-Sleep -Seconds $IntervalSeconds
}
