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
    .\tools\acb-launcher.ps1 -AmbientOcclusion on -FullMips on -Shadows full
#>
param(
    [ValidateSet('Fullscreen','Borderless','Windowed')] [string]$Display = 'Fullscreen',
    [ValidateSet('Default','High')]                     [string]$Quality = 'Default',
    [int]$Width  = 0,
    [int]$Height = 0,
    [string]$User,
    [string]$Password,

    # Individual switches. Each overrides whatever -Quality would have set, so
    # the GUI can drive them one at a time. 'default' means "do not pass it".
    [ValidateSet('default','off','on','normal','full')] [string]$Shadows = 'default',
    [ValidateSet('default','off','on','normal','full')] [string]$PostFX  = 'default',
    [ValidateSet('default','none','2x','4x','6x','8x')] [string]$MSAA    = 'default',
    [ValidateSet('default','on','off')] [string]$FullMips  = 'default',
    [ValidateSet('default','on','off')] [string]$AtlasMips = 'default',
    [ValidateSet('default','on','off')] [string]$AmbientOcclusion = 'default',
    [int]$FarDist = 0,
    [string]$GamePath,

    # --- match rules ---------------------------------------------------------
    # These edit the gamesettings the SERVER hands to clients, so they apply to
    # everyone who joins - nobody else has to change anything on their machine.
    # Rules are always rebuilt from the pristine backup, never from the current
    # file, so passing -CooldownScale 0.5 twice does not end up at 0.25.
    [double]$CooldownScale = 0,
    [double]$DurationScale = 0,

    # Precise overrides, repeatable: -AbilityRule AbilitySmokeBomb:Radius=8.0
    [string[]]$AbilityRule,

    # Minimum players a PRIVATE lobby needs before LAUNCH goes live.
    # Shipped as 2-4 depending on mode, which is why a lobby of one will
    # not start. Re-applied on every host launch rather than once, because
    # -ResetRules used to restore the whole .cxb and silently undid it.
    [int]$PrivateMinPlayers = 1,

    # Put the shipped rules back.
    [switch]$ResetRules,

    # Apply the rules and stop, without launching server or game.
    [switch]$RulesOnly
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root "ACB RDV\bin\x86\Release"

# --- find the game, wherever Steam put it -----------------------------------
# Hardcoding C:\Program Files (x86)\Steam breaks for anyone with a second
# library drive, which is most people. Steam records every library in
# libraryfolders.vdf; app 48190 is Brotherhood.
function Find-GamePath {
    param([string]$Override)
    if ($Override -and (Test-Path (Join-Path $Override "ACBMP.exe"))) { return $Override }

    $steam = $null
    foreach ($k in 'HKCU:\SOFTWARE\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $v = (Get-ItemProperty -Path $k -ErrorAction Stop)
            $steam = if ($v.SteamPath) { $v.SteamPath } else { $v.InstallPath }
            if ($steam) { break }
        } catch { }
    }
    $roots = @()
    if ($steam) {
        $roots += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $roots += $m.Groups[1].Value -replace '\\','\'
            }
        }
    }
    $roots += 'C:\Program Files (x86)\Steam'
    foreach ($r in ($roots | Select-Object -Unique)) {
        $p = Join-Path $r "steamapps\common\Assassins Creed Brotherhood"
        if (Test-Path (Join-Path $p "ACBMP.exe")) { return $p }
    }
    return $null
}

$game = Find-GamePath $GamePath
if (-not $game) {
    Write-Host "Could not find Assassins Creed Brotherhood." -ForegroundColor Red
    Write-Host 'Pass -GamePath "D:\SteamLibrary\steamapps\common\Assassins Creed Brotherhood"' -ForegroundColor Red
    exit 1
}
$db     = Join-Path $server "database.sqlite"

# --- credentials: default to the first real account in the database ----------
# HOST or CLIENT. Only the host has the server, its database, and sqlite3. A
# joining player has none of them, so every host-only step below is guarded -
# without that this script died before ever launching the game for them.
$isHost = (Test-Path (Join-Path $server "ACBRDV.exe")) -and (Test-Path $db) -and
          [bool](Get-Command sqlite3 -ErrorAction SilentlyContinue)

if ($isHost) {
    if (-not $User)     { $User     = (sqlite3 "$db" "SELECT name FROM users WHERE name <> 'Tracking' ORDER BY pid LIMIT 1;") }
    if (-not $Password) { $Password = (sqlite3 "$db" "SELECT password FROM users WHERE name='$User';") }
} else {
    # Client: use whatever client-setup.ps1 saved next to this script.
    $cfgFile = Join-Path $PSScriptRoot "settings.json"
    if (Test-Path $cfgFile) {
        try {
            $saved = Get-Content $cfgFile -Raw | ConvertFrom-Json
            if (-not $User)     { $User     = $saved.User }
            if (-not $Password) { $Password = $saved.Password }
        } catch { }
    }
}
if (-not $User -or -not $Password) {
    Write-Host "No account to log in with." -ForegroundColor Red
    Write-Host "Run: tools\client-setup.ps1 -HostIP <host> -User <name> -Password <password>" -ForegroundColor Red
    exit 1
}

# --- match rules ------------------------------------------------------------
# QuazalWV's PersistentStoreService serves gamesettings_c1380_d873_s6285.cxb
# with File.ReadAllBytes at the moment a client requests it, so editing the
# file here changes the rules for every player who joins. Done before the
# server starts purely so the ordering is obvious; the server re-reads the
# file per request either way.
$cxb = Join-Path $server "gamesettings_c1380_d873_s6285.cxb"
$bak = "$cxb.bak"

if (-not $isHost -and ($ResetRules -or $CooldownScale -or $DurationScale -or $AbilityRule)) {
    Write-Host "Match rules are set by the host; ignoring them here." -ForegroundColor DarkGray
}
elseif ($ResetRules) {
    if (Test-Path $bak) {
        # Restore ONLY the abilities section. This used to copy the whole
        # file back, which also reverted every other section - map, mode and
        # lobby settings included - with no message saying so. The settings
        # screen passes -ResetRules whenever cooldown and duration are both
        # left on default, so that fired on essentially every launch.
        $rx = Join-Path $env:TEMP "acb-reset.xml"
        $ce = Join-Path $root "tools\cxb-edit"
        $pe = $ErrorActionPreference; $ErrorActionPreference ='Continue'
        & dotnet run --project $ce --no-build -- extract $bak abilitymanagermulti $rx 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & dotnet run --project $ce --no-build -- replace $cxb abilitymanagermulti $rx 2>&1 | Out-Null
        }
        $ErrorActionPreference = $pe
        Write-Host "Ability rules reset to the shipped values." -ForegroundColor Cyan
    } else {
        Write-Host "No backup at $bak - rules were never changed." -ForegroundColor DarkGray
    }
}
elseif ($CooldownScale -or $DurationScale -or $AbilityRule) {
    if (-not (Test-Path $cxb)) {
        Write-Error "Cannot find $cxb - the server needs it to serve rules."
        exit 1
    }
    # Keep one pristine copy. Every rule application starts from it, so
    # repeated runs set an absolute value rather than compounding.
    if (-not (Test-Path $bak)) { Copy-Item $cxb $bak }

    $xml = Join-Path $env:TEMP "acb-ability.xml"
    $cxbEdit = Join-Path $root "tools\cxb-edit"
    $rules   = Join-Path $root "tools\ability_rules.py"

    # dotnet and python write progress to stderr, which is a TERMINATING error
    # while $ErrorActionPreference is 'Stop'. Relax it around them and judge by
    # exit code instead - the same trap that has bitten three scripts here.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & dotnet run --project $cxbEdit --no-build -- extract $bak abilitymanagermulti $xml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not read the rules out of $bak" }

        $ruleArgs = @("--xml", $xml)
        if ($CooldownScale) { $ruleArgs += @("--scale-cooldowns", $CooldownScale) }
        if ($DurationScale) { $ruleArgs += @("--scale-durations", $DurationScale) }
        foreach ($r in $AbilityRule) { $ruleArgs += @("--set", $r) }

        $out = & python $rules @ruleArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }

        # cxb-edit verifies by re-reading its own output before writing, so a
        # corrupt file is never served.
        $out = & dotnet run --project $cxbEdit --no-build -- replace $cxb abilitymanagermulti $xml 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }

        Write-Host "Match rules applied:" -ForegroundColor Cyan
        if ($CooldownScale) { Write-Host ("  ability cooldowns x{0}" -f $CooldownScale) -ForegroundColor DarkGray }
        if ($DurationScale) { Write-Host ("  ability durations x{0}" -f $DurationScale) -ForegroundColor DarkGray }
        foreach ($r in $AbilityRule) { Write-Host "  $r" -ForegroundColor DarkGray }
        Write-Host "  everyone who joins plays by these." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Match rules NOT applied: $_"
        Write-Host "  the shipped rules are still in place." -ForegroundColor DarkGray
    }
    finally { $ErrorActionPreference = $prevEAP }
}

# --- private lobby minimum players ------------------------------------------
# "There are not enough members in your group to play this mode in a PRIVATE
# session" is data, not code: every mode carries PrivateMinPlayers, shipped as
# 2-4. The .cxb is server-authoritative, so lowering it here lets the host
# start a lobby alone without anyone patching or installing anything.
#
# Applied on EVERY host launch, not once. An earlier one-off edit was undone
# silently the next time the settings screen passed -ResetRules.
if ($isHost -and $PrivateMinPlayers -gt 0 -and (Test-Path $cxb)) {
    $lobby   = Join-Path $root "tools\lobby_rules.py"
    $cxbEdit = Join-Path $root "tools\cxb-edit"
    $lx      = Join-Path $env:TEMP "acb-lobby.xml"
    $modes = @("advteamwanted","advwanted","assassinate","catsmice",
               "pacman","teamvip","teamwanted","wanted_2")
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $changed = 0; $failed = @()
    foreach ($m in $modes) {
        & dotnet run --project $cxbEdit --no-build -- extract $cxb "gamemode_$m" $lx 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed += $m; continue }
        $out = & python $lobby --xml $lx --private-min $PrivateMinPlayers --min $PrivateMinPlayers 2>&1
        if ($LASTEXITCODE -ne 0) { $failed += $m; continue }
        if ($out -match "already at those values") { continue }
        & dotnet run --project $cxbEdit --no-build -- replace $cxb "gamemode_$m" $lx 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed += $m } else { $changed++ }
    }
    $ErrorActionPreference = $prevEAP
    if ($changed) {
        Write-Host "Private lobbies can start with $PrivateMinPlayers player(s) ($changed mode(s) set)." -ForegroundColor Cyan
    }
    if ($failed.Count) {
        Write-Warning "Lobby minimum NOT set for: $($failed -join ', ')"
    }
}

if ($RulesOnly) {
    Write-Host "Rules only - not launching." -ForegroundColor DarkGray
    exit 0
}

# --- start the server if it isn't already up --------------------------------
if (-not $isHost) {
    Write-Host "Client mode - connecting to the host's server." -ForegroundColor DarkGray
}
elseif (-not (Get-Process ACBRDV -ErrorAction SilentlyContinue)) {
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

# -Quality High is a preset over the individual switches below; anything set
# explicitly wins over it.
if ($Quality -eq 'High') {
    if ($Shadows  -eq 'default') { $Shadows  = 'full' }
    if ($PostFX   -eq 'default') { $PostFX   = 'full' }
    if ($MSAA     -eq 'default') { $MSAA     = '8x'   }
    if ($FullMips -eq 'default') { $FullMips = 'on'   }
}

if ($Shadows -ne 'default') { $argv += "/shadows:$Shadows" }
if ($PostFX  -ne 'default') { $argv += "/postfx:$PostFX"   }
if ($MSAA    -ne 'default') { $argv += "/msaa:$MSAA"       }

# "Full mip chains on" means telling the game NOT to skip mips, so the value is
# inverted against the switch name.
if ($FullMips -ne 'default') {
    $skip = if ($FullMips -eq 'on') { 'off' } else { 'on' }
    $argv += @("/skipmips:$skip", "/skipmipscharacter:$skip", "/skipmipsenvironment:$skip")
}
if ($AtlasMips -ne 'default') { $argv += "/generateatlasmipmaps:$AtlasMips" }
if ($AmbientOcclusion -ne 'default') {
    $argv += @("/computeao:$AmbientOcclusion",
               "/skipao:$(if ($AmbientOcclusion -eq 'on') { 'off' } else { 'on' })")
}
if ($FarDist -gt 0) { $argv += "/fardist:$FarDist" }

# NOTES ON THE SWITCHES, so nobody re-derives them.
#
# The general value vocabulary is off | on | force | default | normal | full.
# msaa has its OWN - none | 2x | 4x | 6x | 8x - matching the Multisample_8x ..
# Multisample_None enum. "/msaa:full" is not a value the game accepts and did
# nothing for as long as it was passed here.
#
# /lightmode is deliberately absent and should stay absent.
# DisplayOptions::LightingMode enumerates NormalLighting | DefaultLight |
# FullBright, so "full" most likely selects FullBright - a flat debug view with
# the lighting removed. That is a fidelity loss dressed as a gain.
#
# Memory measured against an invented control switch, 0.2 MB noise floor:
#   full mip chains       +108.6 MB
#   atlas mipmaps         +111.5 MB   (close enough to be the same effect twice)
#   ambient occlusion     -110.5 MB
#   /fardist:10000         -60.9 MB
# That is evidence the switches DO something. It is NOT evidence the image
# improves - nobody has compared frames. /shadows and /postfx are unmeasured
# even for residency.
#
# CONTENTION: /shadows here and ShadowQuality in the INI both drive shadows and
# it is not established which wins. If you are testing an INI key, pass
# -Quality Default and leave -Shadows alone, or the result is unreadable.
$switches = @($argv | Where-Object { $_ -notlike '/online*' })
Write-Host "Launching as $User ($Display)" -ForegroundColor Cyan
if ($switches.Count) {
    Write-Host "  switches: $($switches -join ' ')" -ForegroundColor DarkGray
} else {
    Write-Host "  no graphics switches - the game uses its own defaults" -ForegroundColor DarkGray
}
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
