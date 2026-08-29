<#
  Read and raise the multiplayer graphics settings.

  THREE INIs EXIST, AND ONLY ONE OF THEM MATTERS

      %USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\
          ACBrotherhood.ini      <- [Graphics] + input profiles   *** this one ***
          ACBrotherhoodMP.ini    <- key bindings only
      <game>\
          ACBrotherhoodMP.ini    <- [Graphics] with Options* names, and INERT

  The game-directory file was missed entirely until today, and FINDINGS had its
  Options* key names filed under the Saved Games path. Finding it was real; the
  first conclusion drawn from it was not. It is not the file multiplayer uses.

  WHICH FILE, AND WHEN IT IS WRITTEN - both settled by experiment

  ACBMP.exe writes Saved Games\ACBrotherhood.ini and does NOT write either
  MP-named file. Measured twice by different routes: a launch rewrote the Saved
  Games file and left both ACBrotherhoodMP.ini untouched. So the game-directory
  file is real, and is not the one that matters. This script targets the file
  the game actually writes; -File GameMP reaches the other one.

  The write happens AT STARTUP, not on exit - a watcher caught the file change
  twice with the process alive, seconds after launch. FINDINGS said write-on-exit
  all day, which made a clean menu exit look necessary. It is not. Launch, wait,
  read. Editing the file while the game runs is pointless rather than dangerous:
  the values have already been read.

  CEILINGS - measured, by arming every key at 9 and reading back what the game
  wrote. Every one clamped to the value it ALREADY held:

      TextureQuality 2   EnvironmentQuality 5   ShadowQuality 4
      ReflectionQuality 3   CharacterQuality 4   MultiSampleType 8   PostFX 1

  The config was already at maximum on every axis. There is no INI headroom, and
  that is a closed question rather than an open one. -Set Max simply restores
  those values, which is worth doing after the in-game menu has lowered one.
  -Set Beyond is kept so the experiment reproduces, not because it will find
  anything.

  VSync=1 and RefreshRate=240 persisted, but were never raised above a valid
  value, so that shows re-emission and not that the game honours them.

  Scripting note: a bare ACBMP.exe launch exits at once with code 41 and writes
  nothing. It needs /onlineUser and /onlinePassword to reach the point where it
  writes its config - without them a run is indistinguishable from "inert keys".

  USAGE
    .\acb-graphics.ps1 -Status
    .\acb-graphics.ps1 -Set Max       # every key back at its measured ceiling
    .\acb-graphics.ps1 -Set Beyond    # the closed experiment, reproducible
    .\acb-graphics.ps1 -Verify        # after one launch: what survived?
    .\acb-graphics.ps1 -Status -File GameMP
    .\acb-graphics.ps1 -Restore
    .\acb-graphics.ps1 -Set Max -RefreshRate 144
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory)]
    [ValidateSet('Max', 'Beyond')]
    [string]$Set,

    [Parameter(ParameterSetName = 'Status')] [switch]$Status,
    [Parameter(ParameterSetName = 'Verify')] [switch]$Verify,
    [Parameter(ParameterSetName = 'Restore')][switch]$Restore,

    # Only used with -Set. Left at 0, the stock 60 is raised to the display's
    # actual rate and any other value is treated as a deliberate choice and kept.
    [Parameter(ParameterSetName = 'Set')]
    [int]$RefreshRate = 0,

    # SavedSP is the file ACBMP.exe demonstrably writes. GameMP is the
    # game-directory ACBrotherhoodMP.ini, which it demonstrably does not.
    [ValidateSet('SavedSP', 'GameMP')]
    [string]$File = 'SavedSP',

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'

$saved   = Join-Path $env:USERPROFILE "Saved Games\Assassin's Creed Brotherhood"
$savedSP = Join-Path $saved "ACBrotherhood.ini"
$gameMP  = Join-Path $GamePath "ACBrotherhoodMP.ini"

$ini     = if ($File -eq 'GameMP') { $gameMP } else { $savedSP }
$backup  = Join-Path $GamePath ("_graphics_backup\" + (Split-Path $ini -Leaf) + ".original")
$pending = Join-Path $PSScriptRoot "graphics-pending.json"

# Baseline all three whichever one is edited. A run that rewrites a file nobody
# was watching looks identical to a run that rewrote nothing, and that mistake
# is what made the first attempt at this unreadable.
$allInis = @($savedSP, $gameMP, (Join-Path $saved "ACBrotherhoodMP.ini"))

# The file the game writes uses BARE key names; the game-directory file uses the
# Options* ones. TextureQuality stays at 2 in every profile: raising it was
# tested and the game clamps it straight back, so asking again wastes a launch.
$allProfiles = @{
    SavedSP = @{
        # The measured ceilings. Writing these is a restore, not an experiment.
        Max = [ordered]@{
            PostFX             = 1
            TextureQuality     = 2
            ShadowQuality      = 4
            ReflectionQuality  = 3
            CharacterQuality   = 4
            EnvironmentQuality = 5
        }
        # Above every ceiling. Answered: the game rewrites each one back down.
        Beyond = [ordered]@{
            PostFX             = 9
            TextureQuality     = 9
            ShadowQuality      = 9
            ReflectionQuality  = 9
            CharacterQuality   = 9
            EnvironmentQuality = 9
        }
    }
    GameMP = @{
        Max = [ordered]@{
            OptionsPostFX            = 2
            OptionsTextureQuality    = 2
            OptionsShadowQuality     = 2
            OptionsReflectionQuality = 2
            OptionsCharacterQuality  = 2
        }
        Beyond = [ordered]@{
            OptionsPostFX            = 2
            OptionsTextureQuality    = 2
            OptionsShadowQuality     = 4
            OptionsReflectionQuality = 3
            OptionsCharacterQuality  = 4
        }
    }
}
$profiles = $allProfiles[$File]

# Only the [Graphics] section. ACBrotherhood.ini also holds [Startup], [Input]
# and four keyboard-profile sections whose keys repeat (every profile has its own
# VendorID), so a flat key=value read collides and a flat rewrite would destroy
# the bindings.
function Read-Ini([string]$path) {
    $map = [ordered]@{}
    if (-not (Test-Path $path)) { return $map }
    $inGraphics = $false
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $inGraphics = ($Matches[1] -eq 'Graphics'); continue }
        if ($inGraphics -and $line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

# Edit in place: replace matching keys inside [Graphics], append any that are
# missing at the end of that section, and leave every other line untouched.
function Write-Ini([string]$path, $updates) {
    $raw = [System.IO.File]::ReadAllText($path)
    $nl  = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($path))

    $section = ''
    $seen = @{}
    $endOfGraphics = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+?)\]\s*$') {
            if ($section -eq 'Graphics') { $endOfGraphics = $i }
            $section = $Matches[1]
            continue
        }
        if ($section -ne 'Graphics') { continue }
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $k = $Matches[1]
            if ($updates.Contains($k)) { $lines[$i] = "$k=$($updates[$k])"; $seen[$k] = $true }
        }
    }
    if ($section -eq 'Graphics') { $endOfGraphics = $lines.Count }
    if ($endOfGraphics -lt 0) { throw "No [Graphics] section in $path" }

    $missing = @($updates.Keys | Where-Object { -not $seen.ContainsKey($_) })
    if ($missing.Count) {
        $lines.InsertRange($endOfGraphics, [string[]]@($missing | ForEach-Object { "$_=$($updates[$_])" }))
    }

    $tail = if ($raw.EndsWith("`n")) { $nl } else { '' }
    [System.IO.File]::WriteAllText($path, ($lines -join $nl) + $tail,
                                   (New-Object System.Text.UTF8Encoding $false))
}

function Get-Fingerprint([string]$path) {
    if (-not (Test-Path $path)) { return [pscustomobject]@{ Path = $path; Exists = $false; Hash = ''; Length = 0 } }
    [pscustomobject]@{
        Path   = $path
        Exists = $true
        Hash   = (Get-FileHash $path -Algorithm SHA256).Hash
        Length = (Get-Item $path).Length
    }
}

function Get-NativeMode {
    # Hybrid-graphics laptops expose several controllers; take the largest panel.
    try {
        $m = Get-CimInstance Win32_VideoController -ErrorAction Stop |
             Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
             Sort-Object { [long]$_.CurrentHorizontalResolution * [long]$_.CurrentVerticalResolution } -Descending |
             Select-Object -First 1
        if ($m) {
            return @{
                Width   = [int]$m.CurrentHorizontalResolution
                Height  = [int]$m.CurrentVerticalResolution
                Refresh = [int]$m.CurrentRefreshRate
            }
        }
    } catch { }
    return $null
}

function Assert-GameClosed {
    if (Get-Process ACBMP -ErrorAction SilentlyContinue) {
        Write-Host "ACBMP.exe is running. It reads this INI at STARTUP, so anything" -ForegroundColor Red
        Write-Host "written now has already been missed - and the game may rewrite the" -ForegroundColor Red
        Write-Host "file from what it loaded. Close the game, then set." -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $ini)) {
    Write-Host "No $ini." -ForegroundColor Yellow
    Write-Host "Launch the multiplayer game once - it writes the file shortly after startup." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- status -----
if ($PSCmdlet.ParameterSetName -eq 'Status') {
    $cur    = Read-Ini $ini
    $native = Get-NativeMode
    Write-Host ""
    Write-Host "  $ini"
    Write-Host ""
    Write-Host ("  {0,-26} {1,-8} {2}" -f 'key', 'current', 'note')
    Write-Host ("  {0,-26} {1,-8} {2}" -f '---', '-------', '----')
    foreach ($k in $cur.Keys) {
        $note = ''
        if ($profiles.Max.Contains($k)) {
            $hi = $profiles.Max[$k]
            $now = 0; [void][int]::TryParse("$($cur[$k])", [ref]$now)
            if     ($now -lt $hi) { $note = "below its measured ceiling of $hi" }
            elseif ($now -eq $hi) { $note = 'at its measured ceiling' }
            else                  { $note = "above the ceiling of $hi - the game clamps this on next launch" }
        }
        if ($k -eq 'RefreshRate' -and $native -and [int]$cur[$k] -lt $native.Refresh) {
            $note = "display runs at $($native.Refresh) Hz"
        }
        if ($k -eq 'MultiSampleType') { $note = 'MSAA; accepted levels 0 2 4 6 8' }
        Write-Host ("  {0,-26} {1,-8} {2}" -f $k, $cur[$k], $note)
    }
    Write-Host ""
    Write-Host "  backup: $(if (Test-Path $backup) { 'present' } else { 'none yet' })"
    if (Test-Path $pending) { Write-Host "  a -Set is awaiting -Verify (run the game once, quit, then -Verify)" -ForegroundColor Cyan }
    Write-Host ""
    return
}

# --------------------------------------------------------------- restore -----
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    Assert-GameClosed
    if (-not (Test-Path $backup)) { Write-Host "No backup to restore." -ForegroundColor Yellow; exit 1 }
    Copy-Item $backup $ini -Force
    Remove-Item $pending -ErrorAction SilentlyContinue
    Write-Host "Restored the original $ini." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- verify -----
if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    if (-not (Test-Path $pending)) {
        Write-Host "Nothing pending. Run -Set first, then play once and quit." -ForegroundColor Yellow
        exit 1
    }
    if (Get-Process ACBMP -ErrorAction SilentlyContinue) {
        Write-Host "The game is still running. Let it finish writing, or quit, then verify." -ForegroundColor Yellow
        exit 1
    }
    $state = Get-Content $pending -Raw | ConvertFrom-Json
    $want  = $state.Wrote

    # Which files did the game actually rewrite? This has to come first. A value
    # left at 5 in a file the game never opened is not evidence of anything, and
    # comparing values alone reports it as a pass.
    Write-Host ""
    Write-Host "  Did the game rewrite each INI?"
    Write-Host ""
    $targetRewritten = $false
    foreach ($b in $state.Baseline) {
        $now = Get-Fingerprint $b.Path
        $same = ($now.Exists -eq $b.Exists) -and ($now.Hash -eq $b.Hash)
        if (-not $same -and $b.Path -eq $ini) { $targetRewritten = $true }
        $mark = if ($same) { 'unchanged' } else { 'REWRITTEN' }
        $col  = if ($same) { 'DarkGray' } else { 'Green' }
        Write-Host ("    {0,-10} {1}" -f $mark, $b.Path) -ForegroundColor $col
    }
    Write-Host ""

    if (-not $targetRewritten) {
        Write-Host "  The game did not rewrite the file we edited." -ForegroundColor Yellow
        Write-Host "  This run says NOTHING about these keys - not that they were honoured," -ForegroundColor Yellow
        Write-Host "  not that they clamped. Either the game never started, or it does not" -ForegroundColor Yellow
        Write-Host "  write this file at all - which is exactly true of the game-directory" -ForegroundColor Yellow
        Write-Host "  ACBrotherhoodMP.ini, so check -File if you targeted that one." -ForegroundColor Yellow
        if (@($state.Baseline | Where-Object { (Get-Fingerprint $_.Path).Hash -ne $_.Hash }).Count) {
            Write-Host "  Note that another INI above DID change - that is where to look next." -ForegroundColor Cyan
        }
        Write-Host ""
        return   # deliberately keep $pending: nothing was learned, the test still stands
    }

    $cur = Read-Ini $ini
    $honoured = 0; $clamped = 0; $dropped = 0
    Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f 'key', 'wrote', 'now', 'verdict')
    Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f '---', '-----', '---', '-------')
    foreach ($p in $want.PSObject.Properties) {
        if (-not $cur.Contains($p.Name)) {
            $dropped++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, '-', 'DROPPED - the game does not track this key')
        } elseif ("$($cur[$p.Name])" -eq "$($p.Value)") {
            $honoured++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, $cur[$p.Name], 'honoured - written back unchanged')
        } else {
            $clamped++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, $cur[$p.Name], 'clamped')
        }
    }
    Write-Host ""
    if ($dropped)  { Write-Host "  Dropped keys are inert - the game rewrote the file and did not re-emit them." -ForegroundColor Yellow }
    if ($clamped)  { Write-Host "  Clamped keys are read, and the menu ceiling is the engine ceiling for them." -ForegroundColor Yellow }
    if ($honoured) { Write-Host "  Honoured keys are real headroom the menu does not expose. This is the win." -ForegroundColor Green }
    Write-Host "  Record the result in re/FINDINGS.md so it is not retested." -ForegroundColor DarkGray
    Write-Host ""
    Remove-Item $pending -ErrorAction SilentlyContinue
    return
}

# ------------------------------------------------------------------- set -----
Assert-GameClosed

if (-not (Test-Path $backup)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
    Copy-Item $ini $backup
    Write-Host "Saved the original -> $backup" -ForegroundColor DarkGray
}

$cur    = Read-Ini $ini
$before = [ordered]@{}; foreach ($k in $cur.Keys) { $before[$k] = $cur[$k] }

foreach ($k in $profiles[$Set].Keys) { $cur[$k] = $profiles[$Set][$k] }

# MSAA and refresh rate are not quality-menu entries and are not clamped by it.
$cur['MultiSampleType'] = 8

# The game writes RefreshRate=60 whatever the panel does. Raise that, but treat
# any other value as somebody's deliberate choice and leave it alone.
$native = Get-NativeMode
if ($RefreshRate -gt 0) {
    $cur['RefreshRate'] = $RefreshRate
} elseif ($native -and $native.Refresh -gt 0) {
    $now = 0; [void][int]::TryParse("$($cur['RefreshRate'])", [ref]$now)
    if ($now -eq 0 -or $now -eq 60) { $cur['RefreshRate'] = $native.Refresh }
}

Write-Ini $ini $cur

$changed = @($cur.Keys | Where-Object { "$($before[$_])" -ne "$($cur[$_])" })
Write-Host ""
if ($changed.Count) {
    Write-Host "  Changed:" -ForegroundColor Green
    foreach ($k in $changed) { Write-Host ("    {0,-26} {1} -> {2}" -f $k, $before[$k], $cur[$k]) }
} else {
    Write-Host "  Already at these values; nothing changed." -ForegroundColor DarkGray
}
Write-Host ""

if ($Set -eq 'Beyond') {
    # Baseline every INI, not just the one edited. Which file multiplayer honours
    # is unresolved, so a run that rewrites a file we were not watching would
    # otherwise be indistinguishable from a run that rewrote nothing.
    [pscustomobject]@{
        Wrote    = [pscustomobject]$profiles.Beyond
        Baseline = @($allInis | ForEach-Object { Get-Fingerprint $_ })
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $pending -Encoding utf8

    Write-Host "  These are ABOVE what the options menu can select, and untested." -ForegroundColor Cyan
    Write-Host "  The game writes this file at STARTUP, so the test is cheap - launch," -ForegroundColor Cyan
    Write-Host "  wait about fifteen seconds, quit however you like, then run:" -ForegroundColor Cyan
    Write-Host "      powershell -File tools\acb-graphics.ps1 -Verify"
    Write-Host ""
    Write-Host "  A file the game never wrote still holds these values, which reads as" -ForegroundColor Yellow
    Write-Host "  a pass and is not one. -Verify checks whether the file was rewritten" -ForegroundColor Yellow
    Write-Host "  before it believes any value." -ForegroundColor Yellow
    Write-Host "  Do not touch the in-game graphics menu in between - saving it writes" -ForegroundColor DarkGray
    Write-Host "  the menu's own values back over these." -ForegroundColor DarkGray
    Write-Host ""
}
