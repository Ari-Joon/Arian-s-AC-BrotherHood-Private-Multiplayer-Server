<#
  AC Brotherhood private-server launcher / mod manager.

  Starts the Rendez-Vous server if needed, launches the multiplayer client with
  the chosen graphics switches, then applies a borderless or windowed style to
  the game window via Win32 (the game exposes no such option itself).

  Examples:
    .\tools\acb-launcher.ps1
    .\tools\acb-launcher.ps1 -Display Borderless
    .\tools\acb-launcher.ps1 -Display Windowed -Width 1600 -Height 900
    .\tools\acb-launcher.ps1 -Quality High -Display Borderless
#>
param(
    [ValidateSet('Fullscreen','Borderless','Windowed')] [string]$Display = 'Fullscreen',
    [ValidateSet('Default','High')]                     [string]$Quality = 'Default',
    [int]$Width  = 0,
    [int]$Height = 0,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root "ACB RDV\bin\x86\Release"
$game   = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
$db     = Join-Path $server "database.sqlite"

# --- credentials: default to the first real account in the database ----------
if (-not $User) {
    $User = (sqlite3 "$db" "SELECT name FROM users WHERE name <> 'Tracking' ORDER BY pid LIMIT 1;")
}
if (-not $Password) {
    $Password = (sqlite3 "$db" "SELECT password FROM users WHERE name='$User';")
}
if (-not $User -or -not $Password) { Write-Error "Could not resolve an account from $db"; exit 1 }

# --- start the server if it isn't already up --------------------------------
if (-not (Get-Process ACBRDV -ErrorAction SilentlyContinue)) {
    Write-Host "Starting Rendez-Vous server..." -ForegroundColor Cyan
    Start-Process -FilePath "$server\ACBRDV.exe" -WorkingDirectory $server
    $bound = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 21030,21031 }
        if ($udp.Count -ge 2) { $bound = $true; break }
    }
    if (-not $bound) { Write-Warning "Server did not bind 21030/21031. See $server\log.txt" }
} else {
    Write-Host "Server already running." -ForegroundColor DarkGray
}

# --- controller support ------------------------------------------------------
# The game reads XInput and enumerates pads ONCE at startup. A DualSense speaks
# HID/DirectInput, so DS4Windows (+ViGEm) must already be running to present it
# as a virtual Xbox 360 pad - otherwise the game sees no controller at all.
$ds4 = Join-Path $root "DS4Windows\DS4Windows\DS4Windows.exe"
if (Test-Path $ds4) {
    if (-not (Get-Process DS4Windows -ErrorAction SilentlyContinue)) {
        Write-Host "Starting DS4Windows for controller support..." -ForegroundColor Cyan
        Start-Process -FilePath $ds4 -WorkingDirectory (Split-Path $ds4)
        # Give it time to create the virtual pad before the game enumerates.
        foreach ($i in 1..20) {
            Start-Sleep -Milliseconds 500
            $x = Get-PnpDevice -ErrorAction SilentlyContinue |
                 Where-Object { $_.Present -and $_.FriendlyName -match "Xbox 360 Controller for Windows" }
            if ($x) { Write-Host "  virtual XInput pad ready." -ForegroundColor DarkGray; break }
        }
    } else {
        Write-Host "DS4Windows already running." -ForegroundColor DarkGray
    }
}

# --- build the client command line ------------------------------------------
$argv = @("/onlineUser:$User", "/onlinePassword:$Password")
if ($Quality -eq 'High') {
    # Switch names AND their value vocabulary read out of ACBMP.exe's own tables.
    # The general vocabulary is  off | on | force | default | normal | full.
    #
    # msaa has a SEPARATE one - none | 2x | 4x | 6x | 8x - matching the
    # Multisample_8x .. Multisample_None enum in the binary. "/msaa:full" is not
    # a value the game accepts, so it was doing nothing.
    $argv += @("/shadows:full", "/postfx:full", "/msaa:8x")

    # Keep the full mip chain. The default drops mips: measured against a bogus
    # control switch (noise floor 0.2 MB), these three add ~109 MB of resident
    # texture data. That is evidence the switches DO something, not evidence
    # that the image looks better - nobody has compared frames yet.
    $argv += @("/skipmips:off", "/skipmipscharacter:off", "/skipmipsenvironment:off")

    # /lightmode is deliberately NOT passed. DisplayOptions::LightingMode
    # enumerates NormalLighting | DefaultLight | FullBright, so "/lightmode:full"
    # most likely selects FullBright - a flat debug view with the lighting taken
    # out. That is a fidelity loss, not a gain.
    #
    # /generateatlasmipmaps:on measures ~111 MB, close enough to the skipmips
    # figure that it is probably the same effect counted twice. Left out until
    # someone separates them.
}
Write-Host "Launching as $User ($Display, $Quality quality)" -ForegroundColor Cyan
Start-Process -FilePath "$game\ACBMP.exe" -WorkingDirectory $game -ArgumentList $argv

# --- apply the window style --------------------------------------------------
if ($Display -eq 'Fullscreen') { return }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int  GetSystemMetrics(int i);
}
"@

$GWL_STYLE   = -16
$WS_CAPTION  = 0x00C00000
$WS_THICKFRAME = 0x00040000
$WS_MINIMIZEBOX = 0x00020000
$WS_MAXIMIZEBOX = 0x00010000
$WS_SYSMENU  = 0x00080000
$SWP_FRAMECHANGED = 0x0020
$SWP_SHOWWINDOW   = 0x0040

Write-Host "Waiting for the game window..." -ForegroundColor DarkGray
$proc = $null
foreach ($i in 1..120) {
    Start-Sleep -Seconds 1
    $proc = Get-Process ACBMP -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($proc) { break }
}
if (-not $proc) { Write-Warning "Game window never appeared; leaving display mode unchanged."; exit 0 }

$h = $proc.MainWindowHandle
Start-Sleep -Seconds 3   # let the renderer finish creating its swap chain

[void][Win32]::SetProcessDPIAware()
$scrW = [Win32]::GetSystemMetrics(0)   # SM_CXSCREEN, true pixels
$scrH = [Win32]::GetSystemMetrics(1)   # SM_CYSCREEN
if ($Width  -le 0) { $Width  = $scrW }
if ($Height -le 0) { $Height = $scrH }

$style = [Win32]::GetWindowLong($h, $GWL_STYLE)
if ($Display -eq 'Borderless') {
    $style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX -bor $WS_SYSMENU))
    [void][Win32]::SetWindowLong($h, $GWL_STYLE, $style)
    [void][Win32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $scrW, $scrH, $SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW)
    Write-Host "Applied borderless ${scrW}x${scrH}." -ForegroundColor Green
} else {
    $style = $style -bor $WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU
    [void][Win32]::SetWindowLong($h, $GWL_STYLE, $style)
    $x = [int](($scrW - $Width ) / 2)
    $y = [int](($scrH - $Height) / 2)
    [void][Win32]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $Width, $Height, $SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW)
    Write-Host "Applied windowed ${Width}x${Height}." -ForegroundColor Green
}
